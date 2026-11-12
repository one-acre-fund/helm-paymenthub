#!/usr/bin/env python3
"""Cross-check a JMeter run against the operations app.

Reads the manifest written by the load test, pulls what the operations app recorded for the
same time window, and reports per flow and scenario whether the expected outcome happened.
See README.md ("Cross-checking against the operations app").

Exit code: 0 everything matches, 1 mismatches or unresolved transactions, 2 could not check.
"""

import argparse
import base64
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from itertools import chain
from zoneinfo import ZoneInfo

DEFAULT_OPS_URL = "https://paymenthub.qa.oneacrefund.org/opsapp"
DEFAULT_TOKEN_URL = (
    "https://accounts.qa.oneacrefund.org/realms/OneAcreFund/protocol/openid-connect/token"
)
# Matches the `tenants` list in the operations app's keycloak profile.
DEFAULT_TENANTS = "oaf,kenya,rwanda,burundi,malawi,usa,zambia,nigeria"
# The app reads startFrom/startTo in this zone (`interface.timezone`, keycloak profile).
DEFAULT_OPS_TIMEZONE = "Asia/Kolkata"
# Cloudflare in front of QA rejects urllib's default "Python-urllib/x.y" (error 1010).
USER_AGENT = "paymenthub-loadtest-reconcile/1.0"

SUCCESS, FAILED, PENDING, MISSING = "success", "failed", "pending", "missing"

# Collections are imported as transaction requests; paybill flows as transfers.
SOURCES = {
    "transactionRequests": {
        "state_field": "state",
        "states": {
            "ACCEPTED": SUCCESS,
            "FAILED": FAILED,
            "REJECTED": FAILED,
            "NOT_AUTOSAVED": FAILED,  # The provider took the money but settlement failed.
            "IN_PROGRESS": PENDING,
            "RECEIVED": PENDING,
        },
    },
    "transfers": {
        "state_field": "status",
        "states": {
            "COMPLETED": SUCCESS,
            "FAILED": FAILED,
            "IN_PROGRESS": PENDING,
            "UNKNOWN": PENDING,
        },
    },
}
ID_FIELDS = ("transactionId", "externalId", "clientCorrelationId")


class OpsError(Exception):
    pass


class OpsClient:
    def __init__(self, base_url, token_url, ops_timezone):
        self.base_url = base_url.rstrip("/")
        self.token_url = token_url
        self.zone = ZoneInfo(ops_timezone)
        self.static_token = os.environ.get("OPS_TOKEN")
        self.token = self.static_token

    def _login(self):
        username = os.environ.get("OPS_USERNAME")
        password = os.environ.get("OPS_PASSWORD")
        if not (username and password):
            raise OpsError(
                "No credentials: set OPS_TOKEN, or OPS_USERNAME and OPS_PASSWORD "
                "(plus OPS_KEYCLOAK_CLIENT_ID / OPS_KEYCLOAK_CLIENT_SECRET if needed)."
            )
        fields = {
            "grant_type": "password",
            "client_id": os.environ.get("OPS_KEYCLOAK_CLIENT_ID", "paymenthub"),
            "username": username,
            "password": password,
        }
        secret = os.environ.get("OPS_KEYCLOAK_CLIENT_SECRET")
        if secret:
            fields["client_secret"] = secret
        request = urllib.request.Request(
            self.token_url,
            data=urllib.parse.urlencode(fields).encode(),
            headers={"User-Agent": USER_AGENT},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                self.token = json.load(response)["access_token"]
        except urllib.error.HTTPError as error:
            detail = error.read(300).decode("utf-8", "replace").strip()
            raise OpsError(f"Keycloak login failed: HTTP {error.code} {detail}") from error
        except (urllib.error.URLError, KeyError, ValueError) as error:
            raise OpsError(f"Keycloak login failed: {error}") from error

    def _get(self, path, tenant, params, retry_auth=True):
        if not self.token:
            self._login()
        url = f"{self.base_url}/api/v1/{path}?{urllib.parse.urlencode(params)}"
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Platform-TenantId": tenant,
                "Accept": "application/json",
                "User-Agent": USER_AGENT,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # Long pulls can outlive a token, so log in again once if we can.
            if error.code == 401 and retry_auth and not self.static_token:
                self._login()
                return self._get(path, tenant, params, retry_auth=False)
            raise OpsError(f"GET {path} (tenant {tenant}): HTTP {error.code}") from error
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            raise OpsError(f"GET {path} (tenant {tenant}): {error}") from error

    def fetch(self, source, tenant, start, end, page_size):
        """Yields every row in the window, oldest first so that new rows can't shift pages."""
        params = {
            "startFrom": start.astimezone(self.zone).strftime("%Y-%m-%d %H:%M:%S"),
            "startTo": end.astimezone(self.zone).strftime("%Y-%m-%d %H:%M:%S"),
            "size": page_size,
            "sortedOrder": "ASC",
        }
        page = 0
        while True:
            content = self._get(source, tenant, {**params, "page": page}).get("content") or []
            # Stop on an empty page: /transfers reports unreliable totals.
            if not content:
                return
            yield from content
            page += 1

    def fetch_without_start_time(self, source, tenant, page_size):
        """Yields rows with no startedAt, which a date filter can never return.

        The importer leaves some rows like this. They sort first in ascending order.
        """
        page = 0
        while True:
            params = {"size": page_size, "sortedOrder": "ASC", "page": page}
            content = self._get(source, tenant, params).get("content") or []
            if not content:
                return
            for record in content:
                if record.get("startedAt"):
                    return
                yield record
            page += 1


def read_manifest(path):
    with open(path, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise OpsError(f"{path} has no transactions.")
    for row in rows:
        row["ids"] = [value for value in row["join_ids"].split("|") if value]
        row["accepted"] = row["request_accepted"] == "true"
        row["timestamp"] = int(row["timestamp_ms"])
    return rows


def run_window(rows, pad_minutes):
    pad = timedelta(minutes=pad_minutes)
    start = datetime.fromtimestamp(min(r["timestamp"] for r in rows) / 1000, timezone.utc)
    end = datetime.fromtimestamp(max(r["timestamp"] for r in rows) / 1000, timezone.utc)
    return start - pad, end + pad


def load_ops_index(client, tenants, start, end, page_size):
    """Maps every ID the app holds to its records. Returns (index, tenants_that_failed)."""
    index = defaultdict(dict)
    failures = {}
    for tenant in tenants:
        for source, config in SOURCES.items():
            try:
                records = chain(
                    client.fetch(source, tenant, start, end, page_size),
                    client.fetch_without_start_time(source, tenant, page_size),
                )
                for record in records:
                    raw_state = record.get(config["state_field"])
                    outcome = config["states"].get(raw_state, PENDING)
                    key = (source, record.get("workflowInstanceKey"))
                    for field in ID_FIELDS:
                        value = record.get(field)
                        if value:
                            index[str(value)][key] = (outcome, raw_state)
            except OpsError as error:
                failures[f"{tenant}/{source}"] = str(error)
    return index, failures


def classify(row, index):
    """Returns (ops outcome, verdict, number of ops records matched)."""
    records = {}
    for value in row["ids"]:
        records.update(index.get(value, {}))

    if records:
        # Prefer the most final state: a transaction that also has a stale record still counts.
        outcomes = {outcome for outcome, _ in records.values()}
        outcome = next(o for o in (SUCCESS, FAILED, PENDING) if o in outcomes)
    else:
        outcome = MISSING

    if not row["accepted"]:
        # The API refused it, so it should not have gone through.
        verdict = "mismatch" if outcome == SUCCESS else "rejected"
    elif row["expected"] == "ANY":
        verdict = "observed"
    elif outcome == MISSING:
        verdict = "missing"
    elif row["expected"] == "SUCCESS":
        verdict = {SUCCESS: "match", FAILED: "mismatch", PENDING: "pending"}[outcome]
    else:
        # A never-delivered callback may legitimately stay in progress until its timer fires.
        verdict = {SUCCESS: "mismatch", FAILED: "match", PENDING: "match"}[outcome]
    return outcome, verdict, len(records)


def evaluate(rows, index):
    return [(row, *classify(row, index)) for row in rows]


def is_unresolved(results):
    return any(verdict in ("missing", "pending") for _, _, verdict, _ in results)


def print_report(results, failures):
    groups = defaultdict(Counter)
    for row, outcome, verdict, matched in results:
        counter = groups[(row["flow"], row["scenario"], row["expected"])]
        counter["sent"] += 1
        # The API refused these, so being absent from ops is correct rather than missing.
        if verdict != "rejected" or outcome != MISSING:
            counter[f"ops_{outcome}"] += 1
        counter[verdict] += 1
        if matched > 1:
            counter["duplicates"] += 1

    columns = [
        ("flow", 22), ("scenario", 36), ("expect", 8), ("sent", 7), ("rejected", 9),
        ("success", 8), ("failed", 7), ("pending", 8), ("missing", 8), ("dupes", 6), ("result", 8),
    ]
    print(" ".join(name.ljust(width) for name, width in columns))
    print(" ".join("-" * width for _, width in columns))
    for (flow, scenario, expected), c in sorted(groups.items()):
        problem = c["mismatch"] or c["missing"] or c["pending"] or c["duplicates"]
        result = "CHECK" if problem else ("info" if expected == "ANY" else "OK")
        values = [
            flow, scenario, expected, c["sent"], c["rejected"], c["ops_success"], c["ops_failed"],
            c["ops_pending"], c["ops_missing"], c["duplicates"], result,
        ]
        print(" ".join(str(v).ljust(w) for v, (_, w) in zip(values, columns)))

    expected_success = [r for r in results if r[0]["expected"] == "SUCCESS" and r[0]["accepted"]]
    confirmed = sum(1 for r in expected_success if r[1] == SUCCESS)
    verdicts = Counter(r[2] for r in results)
    duplicates = sum(1 for r in results if r[3] > 1)
    print()
    print(f"Expected successful: {len(expected_success)}")
    print(f"Successful in ops:   {confirmed}")
    print(f"Difference:          {len(expected_success) - confirmed}")
    print()
    print(
        f"Total {len(results)}: {verdicts['match']} matched, {verdicts['mismatch']} mismatched, "
        f"{verdicts['pending']} pending, {verdicts['missing']} missing from ops, "
        f"{verdicts['rejected']} rejected by the API, {verdicts['observed']} not asserted, "
        f"{duplicates} with duplicate ops records"
    )
    if failures:
        print("\nWARNING: these ops queries failed, so their transactions can look missing:")
        for name, message in sorted(failures.items()):
            print(f"  {name}: {message}")
    return verdicts, duplicates


def write_details(path, results):
    fields = ["timestamp_ms", "flow", "scenario", "expected", "http_code", "join_ids"]
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(fields + ["ops_outcome", "verdict", "ops_records"])
        for row, outcome, verdict, matched in results:
            if verdict in ("mismatch", "missing", "pending") or matched > 1:
                writer.writerow([row[f] for f in fields] + [outcome, verdict, matched])


def token_subject():
    """Shows who we are querying as, because ops filters results by the user's assignments."""
    token = os.environ.get("OPS_TOKEN", "")
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        return claims.get("preferred_username")
    except (IndexError, ValueError):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("manifest", help="manifest CSV written by the JMeter run")
    parser.add_argument("--ops-url", default=DEFAULT_OPS_URL)
    parser.add_argument("--token-url", default=DEFAULT_TOKEN_URL)
    parser.add_argument("--tenants", default=DEFAULT_TENANTS, help="comma-separated tenants")
    parser.add_argument("--ops-timezone", default=DEFAULT_OPS_TIMEZONE)
    parser.add_argument("--window-pad-minutes", type=int, default=10)
    parser.add_argument("--page-size", type=int, default=500)
    parser.add_argument(
        "--wait-seconds", type=int, default=0,
        help="keep re-checking until nothing is pending or missing, for up to this long",
    )
    parser.add_argument("--poll-seconds", type=int, default=60)
    parser.add_argument("--details-out", help="write every transaction needing attention to a CSV")
    args = parser.parse_args()

    try:
        rows = read_manifest(args.manifest)
        client = OpsClient(args.ops_url, args.token_url, args.ops_timezone)
        start, end = run_window(rows, args.window_pad_minutes)
        tenants = [t.strip() for t in args.tenants.split(",") if t.strip()]
        subject = token_subject()
        print(f"Checking {len(rows)} transactions against {args.ops_url}")
        print(f"Window {start:%Y-%m-%d %H:%M:%S} to {end:%H:%M:%S} UTC, tenants {','.join(tenants)}")
        if subject:
            print(f"Querying as {subject}")
        print()

        deadline = time.monotonic() + args.wait_seconds
        while True:
            index, failures = load_ops_index(client, tenants, start, end, args.page_size)
            if len(failures) == len(tenants) * len(SOURCES):
                first = next(iter(failures.values()))
                raise OpsError(f"Every operations app query failed. First error: {first}")
            results = evaluate(rows, index)
            if not is_unresolved(results) or time.monotonic() >= deadline:
                break
            unresolved = sum(1 for r in results if r[2] in ("missing", "pending"))
            print(f"{unresolved} transactions unresolved, checking again in {args.poll_seconds}s")
            time.sleep(args.poll_seconds)
    except OpsError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    verdicts, duplicates = print_report(results, failures)
    if args.details_out:
        write_details(args.details_out, results)
        print(f"\nDetails: {args.details_out}")
    if verdicts["mismatch"] or verdicts["missing"] or verdicts["pending"] or duplicates:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
