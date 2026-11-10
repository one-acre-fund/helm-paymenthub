# collection + paybill load test (JMeter)

Drives Payment Hub's collection and paybill APIs, then lets you cross-check the results
against the operations app. The requests come from the wiremock READMEs and the `Payment Hub
APIs` Bruno collection (`CPUtils/bruno/Payment Hub APIs`, folders `Collection APIs` and
`Paybill APIs`).

Every thread group runs at a steady **50 transactions/minute for 5 minutes**, concurrently.
By default that is **450 transactions/minute, or about 800 requests/minute**, because a paybill
transaction takes two or three requests. Use `-J` overrides to run less (see "Running it").

| Thread group | Requests | Tenant |
|---|---|---|
| `mpesa collection` | `mpesa_scenarios.csv` (`+2547…`), 20 KES | `kenya` |
| `mtn collection` | `mtn_scenarios.csv` (`+25078…`), 15 RWF | `rwanda` |
| `airtel collection` | `airtel_scenarios.csv` (`+25073…`), 15 RWF | `rwanda` |
| `collection variants` | `collection_variants.csv`: the Bruno requests for each AMS, tenant and provider | per row |
| `airtel paybill` | `POST /airtel/paybill/validation`, then `/confirmation` | connector's |
| `mpesa paybill` | `POST /mpesa/validation`, then `/confirmation` | connector's |
| `tnm paybill` | `GET /tnm/paybill/validate/{account}`, `POST /tnm/paybill/pay`, `GET /tnm/paybill/confirm/{id}` | connector's |
| `nbs paybill` | `GET /nbs/paybill/validate/{account}`, `POST /nbs/paybill/confirm`, `GET /nbs/paybill/status/{id}` | connector's |
| `bancobu paybill` | `POST /bancobu/paybill/validate`, then `/confirm` | connector's |
| `squad webhook (NG)` | `POST /channel/squad/transactions`, signed. **Off by default** | connector's |

The collection groups exercise every phone-number scenario documented in `../README.md`
(mpesa), `../../mtn/README.md` and `../../airtel/README.md`: the default success path, the
synchronous provider errors, the failing callbacks, the never-delivered callback and (mpesa
only) the HTTP-200-with-invalid-body responses. `collection variants` covers the Odoo and
Tupande flows and Zambia. For Tupande that includes a settlement the account system rejects
(404) and one where it errors (500), both expected to end as `FAILURE` (`../../tupande/README.md`).

### paybill flows

One iteration is one transaction, with a new provider ID each time. The throughput timer is on
the validation request only, so it limits transactions rather than requests.

Each connector links its steps differently, and the plan follows the source of each one:

- **airtel and mpesa** reuse one provider ID (`transactionId`, `TransID`) on both requests.
- **tnm and nbs** take `oafTransactionReference` from the validation response and send it on
  the payment along with a new `trans_id`.
- **bancobu** takes `customerRefNumber` from the validation response and sends it on the
  confirmation along with a new `bankreference`.

mpesa, tnm, nbs and bancobu skip the payment if validation rejects the transaction, as a real
provider would, and record the rejection in the manifest. tnm and nbs would otherwise start a
brand new workflow for a payment with no reference. airtel paybill still sends the confirmation
regardless, which then gets a 404.

The tnm and nbs status calls don't affect the result: the transaction is normally still in
flight at that point, so any response code counts as a pass. They only add realistic load.

Request values come from Bruno and can be overridden. The exceptions are `debitcustname` and
`sender_name`, which are set to `LOAD TEST` instead of Bruno's example names, and the tnm
currency, which is `MWK` as in the chart rather than Bruno's `RWF`.

### Bruno requests that are not included

- `Collection Request`: it uses `ACCOUNTID`, which routes to a `mpesa_flow_roster-{tenant}`
  flow, and the only one in `CPUtils/bpmn` is for tenant `oaf`. Its tenant is also an unset variable.
- `Airtel - ZM - Initiate payment`: included, but corrected. Bruno's copy is a duplicate of
  `Collection Request` with a Kenyan number and USD, so the plan uses a Zambian Airtel number,
  `zambia`, `ZMW` and `FINERACTACCOUNTID`.
- `Get Squad logged transactions` and `Get squad transactions`: these call Squad's own servers.
- `Squad Retry Missed payments`, `Squad Get All Transactions`, `Squad Channel Endpoint`, and the
  `Paybill APIs/Validation` and `Confirmation` folders: duplicates of requests already covered.

Point the plan at any environment
where `paymenthub-wiremock` is enabled and the connectors are wired to it (see each
connector README's "Enabling it" section). The default target is the QA channel host.

## Files

- `mpesa-scenario-load-test.jmx`: the JMeter test plan.
- `mpesa_scenarios.csv`, `mtn_scenarios.csv`, `airtel_scenarios.csv`: `scenario,msisdn,expected`.
- `collection_variants.csv`: one row per extra collection request, with its own tenant,
  identifier, amount, currency and expected outcome.
- `record_transaction.bsh`: writes each transaction to the run manifest.
- `reconcile_with_ops.py`: cross-checks a manifest against the operations app.

Each CSV is shared across all threads of its own group, so throughput is capped per group, not
per thread. Sampler labels are prefixed with the group (for example
`mtn - POST /channel/channel/collection - callback_expired`), which keeps the results separable.

## Running it

```bash
cd helm/ph-ee-engine/config/wiremock/mpesa/jmeter
jmeter -n -t mpesa-scenario-load-test.jmx -l results.jtl
```

That uses the defaults baked into the plan: QA host, HTTPS, 5 minutes, and per connector
5 threads at 50 req/min with the tenant/amount/currency from the table above. Override any
of them with `-J`, for example to point at a different environment or change the load profile:

```bash
jmeter -n -t mpesa-scenario-load-test.jmx -l results.jtl \
  -JHOST=paymenthub.other-env.oneacrefund.org \
  -JMTN_THROUGHPUT_PER_MIN=100 \
  -JDURATION_SECONDS=600
```

To run only some thread groups, set the others' thread count to 0. For example, paybill only:

```bash
jmeter -n -t mpesa-scenario-load-test.jmx -l results.jtl \
  -JMPESA_THREADS=0 -JMTN_THREADS=0 -JAIRTEL_THREADS=0 -JCOLLECTION_VARIANTS_THREADS=0
```

The Squad group needs the channel connector's secret, a Nigerian test customer and threads:

```bash
SQUAD_SECRET_KEY=... jmeter -n -t mpesa-scenario-load-test.jmx -l results.jtl \
  -JSQUAD_THREADS=5 -JSQUAD_CUSTOMER_IDENTIFIER=... -JSQUAD_VIRTUAL_ACCOUNT=...
```

Available overrides:

- Shared: `PROTOCOL`, `HOST`, `PORT`, `FINERACT_ACCOUNT_ID`, `DURATION_SECONDS`, `MANIFEST_FILE`.
- Per collection group (`<C>` is `MPESA`, `MTN` or `AIRTEL`): `<C>_TENANT`, `<C>_AMOUNT`,
  `<C>_CURRENCY`, `<C>_THREADS`, `<C>_THROUGHPUT_PER_MIN`.
- collection variants: `COLLECTION_VARIANTS_THREADS`, `COLLECTION_VARIANTS_THROUGHPUT_PER_MIN`,
  `COLLECTION_VARIANTS_FILE` (another CSV, for example without the rows an environment can't serve).
  Edit `collection_variants.csv` to change the requests.
- Per paybill group (`<P>` is `AIRTEL`, `MPESA`, `TNM`, `NBS` or `BANCOBU`): `<P>_PAYBILL_THREADS`,
  `<P>_PAYBILL_THROUGHPUT_PER_MIN` (transactions/min), `<P>_PAYBILL_ACCOUNT_NUMBER`,
  `<P>_PAYBILL_AMOUNT`.
- airtel paybill: `AIRTEL_PAYBILL_HEADER_SHORTCODE`, `AIRTEL_PAYBILL_SHORTCODE`,
  `AIRTEL_PAYBILL_MSISDN`, `AIRTEL_PAYBILL_CURRENCY`.
- mpesa paybill: `MPESA_PAYBILL_SHORTCODE`, `MPESA_PAYBILL_MSISDN`.
- tnm and nbs paybill (`<P>` is `TNM` or `NBS`): `<P>_PAYBILL_SHORTCODE`, `<P>_PAYBILL_CURRENCY`,
  `<P>_PAYBILL_VALIDATE_MSISDN`, `<P>_PAYBILL_CONFIRM_MSISDN`. nbs also has
  `NBS_PAYBILL_CHANNEL_SOURCE` and `NBS_PAYBILL_BANK_ACCOUNT_ID`.
- bancobu paybill: `BANCOBU_PAYBILL_MSISDN`, `BANCOBU_API_KEY`.
- squad: `SQUAD_THREADS`, `SQUAD_THROUGHPUT_PER_MIN`, `SQUAD_AMOUNT`, `SQUAD_VIRTUAL_ACCOUNT`,
  `SQUAD_CUSTOMER_IDENTIFIER`.

Results land in `results.jtl` (per-request detail) with a summary printed to stdout as
the run progresses; open `results.jtl` in JMeter's GUI (or any `.jtl` viewer) to inspect
outcomes per scenario. The `x-correlationid` header is a fresh UUID per request, so
individual requests can be traced through the channel connector's logs.

The plan's scripts are BeanShell rather than Groovy because Homebrew's `jmeter` runs on its own
Java 25, which JMeter 5.5's Groovy can't run on, whatever `JAVA_HOME` your shell sets.

## Cross-checking against the operations app

An HTTP 200 only means Payment Hub accepted a request, and some APIs return it for transactions
that then fail. For example, mpesa's confirmation returns 202 even when it finds no workflow.
The cross-check compares what should have happened with what the operations app recorded.

Each run writes a manifest, `transactions-manifest-<timestamp>.csv` by default (or
`-JMANIFEST_FILE=...`), with one line per transaction: its flow, scenario, expected outcome, HTTP
code and IDs. Once the run finishes, check it against the app:

```bash
export OPS_TOKEN=<access token>   # or OPS_USERNAME and OPS_PASSWORD to log in through Keycloak
./reconcile_with_ops.py transactions-manifest-<timestamp>.csv \
  --wait-seconds 900 --details-out needs-attention.csv
```

It prints a row per flow and scenario, then the totals:

```text
Expected successful: 429
Successful in ops:   424
Difference:          5
```

`--wait-seconds` keeps re-checking while transactions are still in flight, which matters for
callback timers and importer lag. `--details-out` lists every transaction that needs attention,
with its IDs. The exit code is `0` if everything matches, `1` if something needs attention and
`2` if it could not check.

| Result | Meaning |
|---|---|
| matched | The app shows the expected outcome. A `FAILURE` row may also still be in progress, because a never-delivered callback stays open until its timer fires. |
| mismatch | The app shows the opposite outcome, or a transaction the API refused succeeded anyway. |
| pending | Expected to succeed, but still in progress. |
| missing | The API accepted it, but the app has no record of it. |
| rejected | The API refused it and the app has no success for it, which is consistent. |
| not asserted | `expected` is `ANY`. It is only reported. |
| dupes | More than one workflow matched the transaction's IDs. |

### How transactions are matched

Rows are joined on IDs, not counted, so other traffic in the same window can't skew the result.

| Flow | IDs recorded | Where the app holds them |
|---|---|---|
| collections | `X-CorrelationID`, response `transactionId` | `/api/v1/transactionRequests`: `state` is `ACCEPTED` on success |
| airtel, mpesa paybill | provider ID | `/api/v1/transfers`: `status` is `COMPLETED` on success |
| tnm, nbs paybill | `trans_id`, `oafTransactionReference` | `/api/v1/transfers` |
| bancobu paybill | `bankreference`, `customerRefNumber` | `/api/v1/transfers` |
| squad | `transaction_reference` | `/api/v1/transactionRequests` |

The script reads both endpoints for every tenant in `--tenants`, because a paybill's tenant comes
from connector configuration rather than the request.

### Operations app access

- The user needs a row in the app, and `*` for their currencies, payee party IDs and payee party
  ID types. `/transactionRequests` filters by those assignments, so a restricted user makes
  transactions look missing.
- `--ops-url` defaults to QA. Set `--token-url` too if you point it elsewhere.
- `--ops-timezone` must match the app's `interface.timezone`, or the time window will be off. It
  defaults to `Asia/Kolkata`, the keycloak profile's value, and `--window-pad-minutes` adds a margin.

### Expected outcomes depend on the environment

`SUCCESS` and `FAILURE` assume the connectors are wired to `paymenthub-wiremock`. Fineract and
Tupande have AMS stubs; Odoo doesn't, so the `mpesa_ke_odoo` variant depends on whichever Odoo the
environment uses. The `mpesa_ke_tupande*` variants need `tupande_connector.tupande.base_url`
pointed at the mock: against Tupande's QA function every one of them fails with
`Transaction not found`. The Zambia variants only follow the mock's success path, and need
Zambia's connectors pointed at the mock. Paybill accounts must validate against the AMS in use.

`callback_empty_body` and `callback_no_result_code` are `ANY`, because the outcome depends on
how the connector and its status query handle an unusable response.

The mtn and airtel failure/pending scenarios each register a per-transaction status stub
in WireMock's memory (see their READMEs), so a long run accumulates mappings. Clear them
afterwards with `POST /__admin/mappings/reset`.

## MSISDN format assumption

All three CSVs use E.164 numbers. For mtn, the connector forwards the number as
`payer.partyId` without the `+` (`250780000101`). For airtel, it also strips the country code
(`730000101`). Those are the forms the mappings match on.

`mpesa_scenarios.csv` uses E.164-formatted numbers (`+254700000001`, matching the shape
of the example curl this plan is based on) for the phone-number scenarios documented in
`../README.md`. That assumes the channel/mpesa connector strips the leading `+` before
forwarding the number to Safaricom's (mocked) API as `PhoneNumber` — if the connector
expects a different format, adjust the `msisdn` column in the CSV to match.
