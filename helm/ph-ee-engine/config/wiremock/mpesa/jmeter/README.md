# collection + paybill load test (JMeter) — mpesa, mtn, airtel

Drives `POST /channel/channel/collection` (the paymenthub channel connector's collection
API) across every phone-number scenario documented in the wiremock READMEs for each
connector — `../README.md` (mpesa), `../../mtn/README.md` and `../../airtel/README.md`:
the default success path, the synchronous provider errors, the failing-callback outcomes,
the never-delivered callback, and (mpesa only) the HTTP-200-with-invalid-body
callback/status-query responses.

There is one collection thread group per connector, and each runs at a steady **50 requests/minute
for 5 minutes**. All groups run concurrently, so with airtel paybill (below) the default total is **250 req/min**.

| Thread group | Scenarios | `platform-tenantid` | Amount / currency |
|---|---|---|---|
| `mpesa collection` | `mpesa_scenarios.csv` (`+2547…`) | `kenya` | 20 KES |
| `mtn collection` | `mtn_scenarios.csv` (`+25078…`) | `rwanda` | 15 RWF |
| `airtel collection` | `airtel_scenarios.csv` (`+25073…`) | `rwanda` | 15 RWF |

All three send the same body shape (`transactionType.scenario: "MPESA"`, `BUYGOODS`), and
only the MSISDN, tenant, amount and currency differ.

### airtel paybill

A fourth thread group, `airtel paybill`, drives Airtel's paybill (C2B) flow at a steady
**50 transactions/minute** (= 100 req/min). Each iteration is one transaction:

1. `POST /airtel/paybill/validation`
2. `POST /airtel/paybill/confirmation`

The two requests share one `transactionId`, and every transaction gets a new one. It is
27 digits like Airtel's: epoch millis (13), then 100 + the thread number (3), then 11 random
digits. It's set by a `new transactionId` User Parameters pre-processor that runs only
before validation. Confirmation reuses that variable from the same thread. The throughput
timer is also attached to validation only, so it limits transactions rather than requests.

Headers and body follow the reference curls. The defaults are `businessshortcode: 24322607`
(header), `businessShortCode: 789012` (body), account `24039542`, msisdn `07912345672`,
amount `200` and currency `MWK`. Two values are hardcoded as they appear in the curls,
because they differ from the rest: the validation body's `msisdn` (`250986086783`) and the
confirmation's `currency` header (`RWF`).

Confirmation is sent whether or not validation succeeded. This is a load test, and it
doesn't check responses.

Point the plan at any environment
where `paymenthub-wiremock` is enabled and the connectors are wired to it (see each
connector README's "Enabling it" section). The default target is the QA channel host.

## Files

- `mpesa-scenario-load-test.jmx` — the JMeter test plan (all three connectors).
- `mpesa_scenarios.csv` — the 11 mpesa `scenario,msisdn` pairs.
- `mtn_scenarios.csv` — the 9 mtn `scenario,msisdn` pairs.
- `airtel_scenarios.csv` — the 9 airtel `scenario,msisdn` pairs.
- (airtel paybill uses no CSV, since its transactionIds are generated per iteration.)

Each CSV is shared across all threads of its own group, so throughput is capped per
connector, not per thread. Sampler labels are prefixed with the connector (for example
`mtn - POST /channel/channel/collection - callback_expired`), which keeps the results
separable per connector.

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

To run only some thread groups, set the others' thread count to 0. For example, mtn only:

```bash
jmeter -n -t mpesa-scenario-load-test.jmx -l results.jtl \
  -JMPESA_THREADS=0 -JAIRTEL_THREADS=0 -JAIRTEL_PAYBILL_THREADS=0
```

or airtel paybill only:

```bash
jmeter -n -t mpesa-scenario-load-test.jmx -l results.jtl \
  -JMPESA_THREADS=0 -JMTN_THREADS=0 -JAIRTEL_THREADS=0
```

Available overrides:

- Shared: `PROTOCOL`, `HOST`, `PORT`, `FINERACT_ACCOUNT_ID`, `DURATION_SECONDS`.
- Per connector (`<C>` is `MPESA`, `MTN` or `AIRTEL`): `<C>_TENANT`, `<C>_AMOUNT`,
  `<C>_CURRENCY`, `<C>_THREADS`, `<C>_THROUGHPUT_PER_MIN`.
- airtel paybill: `AIRTEL_PAYBILL_THREADS`, `AIRTEL_PAYBILL_THROUGHPUT_PER_MIN`
  (transactions/min), `AIRTEL_PAYBILL_HEADER_SHORTCODE`, `AIRTEL_PAYBILL_SHORTCODE`,
  `AIRTEL_PAYBILL_ACCOUNT_NUMBER`, `AIRTEL_PAYBILL_MSISDN`, `AIRTEL_PAYBILL_AMOUNT`,
  `AIRTEL_PAYBILL_CURRENCY`.

Results land in `results.jtl` (per-request detail) with a summary printed to stdout as
the run progresses; open `results.jtl` in JMeter's GUI (or any `.jtl` viewer) to inspect
outcomes per scenario. The `x-correlationid` header is a fresh UUID per request, so
individual requests can be traced through the channel connector's logs.

## What this does and doesn't check

This is a **load/coverage** test — it exercises the full mix of scenarios under sustained
throughput, it doesn't assert what each scenario's HTTP response *should* be (responses
differ legitimately by design: success vs. rejected vs. accepted-but-later-failed). Use
`results.jtl` alongside the channel connector's and the provider connectors' own logs. The
`no_callback_pending` case needs separate checking for every connector: by design it never
resolves on its own, and its status query keeps reporting pending (mpesa `/buygoods/transactionstatus`,
mtn `PENDING`, airtel `TIP`). See each connector README's "Simulating failures" section.

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
