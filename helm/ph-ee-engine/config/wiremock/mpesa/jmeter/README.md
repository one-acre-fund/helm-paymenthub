# mpesa scenario load test (JMeter)

Drives `POST /channel/channel/collection` (the paymenthub channel connector's collection
API) across every phone-number scenario documented in `../README.md` — the default
success path, the three synchronous Daraja errors, the four failing-callback outcomes,
and the never-delivered callback — at a steady **50 requests/minute for 5 minutes**.

Point it at any environment where `paymenthub-wiremock` is enabled and the mpesa
account(s) are wired to it (see `../README.md#enabling-it`); the default target is the QA
channel host.

## Files

- `mpesa-scenario-load-test.jmx` — the JMeter test plan.
- `mpesa_scenarios.csv` — the 9 `scenario,msisdn` pairs it cycles through (shared across
  all threads, so throughput is capped in total, not per thread).

## Running it

```bash
cd helm/ph-ee-engine/config/wiremock/mpesa/jmeter
jmeter -n -t mpesa-scenario-load-test.jmx -l results.jtl
```

That uses the defaults baked into the plan: QA host, HTTPS, `platform-tenantid: kenya`,
50 req/min, 5 minutes, 5 threads. Override any of them with `-J`, e.g. to point at a
different environment or change the load profile:

```bash
jmeter -n -t mpesa-scenario-load-test.jmx -l results.jtl \
  -JHOST=paymenthub.other-env.oneacrefund.org \
  -JTHROUGHPUT_PER_MIN=100 \
  -JDURATION_SECONDS=600
```

Available overrides: `PROTOCOL`, `HOST`, `PORT`, `TENANT`, `FINERACT_ACCOUNT_ID`,
`AMOUNT`, `CURRENCY`, `THREADS`, `DURATION_SECONDS`, `THROUGHPUT_PER_MIN`.

Results land in `results.jtl` (per-request detail) with a summary printed to stdout as
the run progresses; open `results.jtl` in JMeter's GUI (or any `.jtl` viewer) to inspect
outcomes per scenario. The `x-correlationid` header is a fresh UUID per request, so
individual requests can be traced through the channel connector's logs.

## What this does and doesn't check

This is a **load/coverage** test — it exercises the full mix of scenarios under sustained
throughput, it doesn't assert what each scenario's HTTP response *should* be (responses
differ legitimately by design: success vs. rejected vs. accepted-but-later-failed). Use
`results.jtl` alongside the channel connector's/mpesa connector's own logs, and query
`/buygoods/transactionstatus` (or its channel-API equivalent) for the `no_callback_pending`
case in particular, since by design that one never resolves on its own — see
`../README.md#simulating-failures`.

## MSISDN format assumption

`mpesa_scenarios.csv` uses E.164-formatted numbers (`+254700000001`, matching the shape
of the example curl this plan is based on) for the phone-number scenarios documented in
`../README.md`. That assumes the channel/mpesa connector strips the leading `+` before
forwarding the number to Safaricom's (mocked) API as `PhoneNumber` — if the connector
expects a different format, adjust the `msisdn` column in the CSV to match.
