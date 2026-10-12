# airtel mappings for the shared paymenthub-wiremock

Stubs the parts of Airtel Money's **Collection** API that `ph-ee-connector-airtel` talks
to, so the full success journey — OAuth token, collection request, the asynchronous
callback, and a payment enquiry (status query) — can be exercised without hitting Airtel's
real UAT sandbox.

These mappings are loaded into the shared `paymenthub-wiremock` deployment alongside any
other connector's mappings — see `../README.md` for how that deployment works and how to
enable it. This file covers only the airtel-specific stubs below.

## What's stubbed

| File | Endpoint | Mimics |
|---|---|---|
| `airtel-01-oauth-token.json` | `POST /auth/oauth2/token` | OAuth2 token endpoint (JSON body with `client_id`/`client_secret`/`grant_type`). Returns a fresh `access_token` on every call. |
| `airtel-02-collection-request.json` | `POST /merchant/v1/payments/` | Collection request (default/catch-all). Returns `200` with `data.transaction.status: "TIP"` (transaction in progress) and a `success: true` status envelope, **and** fires a WireMock webhook ~3s later that `POST`s a `TS` (success) callback to the connector's `/collections/callback` — this is what simulates Airtel notifying the connector once the customer approves the payment on their phone. |
| `airtel-02-collection-request-error-*.json` | `POST /merchant/v1/payments/` | Collection request **synchronous** failures — see "Simulating failures" below. Matched by `subscriber.msisdn`, higher priority than the default stub above. |
| `airtel-02-collection-request-callback-*.json` | `POST /merchant/v1/payments/` | Collection request that is accepted synchronously but whose webhook delivers a **failing** (`TF`) callback — see "Simulating failures" below. Matched by `subscriber.msisdn`, higher priority than the default stub above. |
| `airtel-02-collection-request-no-callback.json` | `POST /merchant/v1/payments/` | Collection request that is accepted synchronously but has **no callback webhook at all** — simulates a callback Airtel never delivers. See "Simulating failures" below. |
| `airtel-03-payment-status.json` | `GET /standard/v1/payments/{transactionId}` | Payment enquiry (default/catch-all). Reports the transaction as `TS` (successful). |

The webhook is what makes this "simulate the callback from Airtel" — no manual step needed
for the standard success path. `simulate-airtel-callback.sh` (see below) exists for the
cases the stubs above can't cover: replaying a callback, or a status/message not in the
MSISDN matrix below.

### Where the callback goes

Unlike the mpesa and mtn stubs, which read the callback destination out of the request
(Daraja's `CallBackURL` body field, MoMo's `X-Callback-Url` header), **Airtel's callback URL
is registered with Airtel out of band** — it is not part of the collection request. The
webhook URL is therefore hardcoded in the mapping files as
`http://ph-ee-connector-airtel/collections/callback` — the connector's own in-cluster
Service plus the path its callback route listens on. If you deploy the connector under a
different Service name, edit that URL in
`mappings/airtel-02-collection-request*.json`; it has to be an address WireMock can reach
from inside the cluster.

### Correlation and IDs

Airtel keys both the callback and the payment enquiry on `transaction.id` — the payment hub
transaction ID the connector sends in the collection request body — so there is no separate
provider-side reference to track (contrast MTN, which issues its own `X-Reference-Id`).

`airtel_money_id` is derived from that transaction ID (prefixed `MP`) rather than randomly
generated, so the callback and a later payment enquiry report the *same* ID for the same
transaction without the mock having to remember anything. Airtel's real IDs are opaque
(e.g. `MP210603.1234.L06941`), so don't assert on its shape.

The callback body carries a `hash` field, which these stubs fill with a fixed placeholder —
it is not a real HMAC, and the connector does not verify it.

### Simulating failures

Send the collection request with one of the `subscriber.msisdn` values below to trigger a
specific Airtel-style failure instead of the default success path. These are mock-only
conventions — the MSISDN blocks are just a convenient way to pick a scenario without adding
request headers or query params. Note the connector strips the country code before sending,
so these are the local 9-digit Airtel Rwanda numbers (a payer of `250730000101` arrives here
as `730000101`).

**Synchronous API errors** — the collection request itself fails immediately. No callback
webhook fires:

| `subscriber.msisdn` | HTTP status | `status.success` | `status.response_code` | `status.message` |
|---|---|---|---|---|
| `730000001` | 200 | `false` | `DP00800001004` | Invalid Amount |
| `730000002` | 400 | `false` | — | Bad Request |
| `730000003` | 500 | `false` | — | Internal Server Error |

The first row is Airtel's own "HTTP 200 but the API rejected it" shape, which the connector
surfaces as `errorCode: <response_code>`; the other two are transport-level failures, where
the connector surfaces the HTTP status as the error code and stores the raw body as error
information.

**Asynchronous callback failures** — the collection request is accepted normally (`200`,
`TIP`), but the webhook that fires ~3s later delivers a failing callback
(`status_code: "TF"` with a `message`, and no `airtel_money_id` — matching what Airtel sends
when a transaction doesn't complete):

| `subscriber.msisdn` | Callback `message` | Enquiry `response_code` | Meaning |
|---|---|---|---|
| `730000101` | Transaction Failed. Not enough balance | `DP00800001008` | Payer has insufficient Airtel Money balance |
| `730000102` | Transaction Failed. Incorrect Pin | `DP00800001002` | Customer entered the wrong PIN |
| `730000103` | Transaction Timed Out | `DP00800001024` | Customer never acted on the prompt |
| `730000104` | Transaction not permitted to Payee | `DP00800001010` | Payee/limit restriction |

**No callback at all** — the collection request is accepted normally, but Airtel never
delivers a callback (e.g. dropped by the network, or the transaction gets stuck). Use this
to exercise the connector's own reconciliation path — it polls the payment enquiry endpoint
up to `airtel.max-retry-count` times and then fails the transaction as "retry exceeded":

| `subscriber.msisdn` | Behaviour |
|---|---|
| `730000201` | Collection request succeeds, no webhook ever fires. A payment enquiry for this transaction always reports `TIP` (see below) — it never resolves on its own. |

Any other `subscriber.msisdn` falls through to the default success stub
(`airtel-02-collection-request.json`).

### Linking the payment enquiry to a callback outcome

Airtel's enquiry endpoint is keyed by the transaction ID, not by the scenario, so — like the
mtn stubs, and unlike the mpesa ones, which encode the scenario in the `CheckoutRequestID`
they hand back — these stubs can't recognise a scenario from the enquiry request alone.
Instead, each failure/pending stub above fires a second webhook that registers an enquiry
stub for *that specific transaction ID* through WireMock's own admin API
(`POST http://localhost:8080/__admin/mappings`, i.e. WireMock calling itself). Querying
`GET /standard/v1/payments/{transactionId}` afterwards therefore reports the *same* outcome
the callback delivered (or, for the "no callback" case, reports the transaction as `TIP` —
indefinitely, since nothing ever resolves it):

| Scenario MSISDN | Enquiry response |
|---|---|
| `730000101` | `data.transaction.status: "TF"`, message "Transaction Failed. Not enough balance" |
| `730000102` | `data.transaction.status: "TF"`, message "Transaction Failed. Incorrect Pin" |
| `730000103` | `data.transaction.status: "TF"`, message "Transaction Timed Out" |
| `730000104` | `data.transaction.status: "TF"`, message "Transaction not permitted to Payee" |
| `730000201` | `data.transaction.status: "TIP"` |
| (anything else — default success) | `data.transaction.status: "TS"`, with the derived `airtel_money_id` |

Two things follow from that mechanism. These self-registered stubs live only in the running
WireMock's memory: they're gone after a pod restart (the enquiry then falls back to the `TS`
catch-all), and they accumulate one per failure-scenario transaction until you clear them
with `POST /__admin/mappings/reset`, which reloads just the mappings from this directory.
The default success path deliberately registers nothing, so ordinary load stays stateless.

Note the failing enquiries keep `status.success: true` — that flag reports whether the *API
call* worked, while the transaction's own outcome lives in `data.transaction.status`
(`TS`/`TF`/`TA`/`TIP`), which is what the connector branches on. Only `TS` and `TF` are
terminal for the connector; anything else leaves the transaction pending for another poll.

## Enabling it

```
--set wiremock.enabled=true
```

Then point the airtel connector at it instead of Airtel's UAT sandbox:

```yaml
airtel_connector:
  api:
    base_url: "http://paymenthub-wiremock"
  credentials:
    base_url: "http://paymenthub-wiremock"
```

(`paymenthub-wiremock` is the in-cluster Service name/DNS. Set the per-country
`credentials.zambia_base_url`/`credentials.malawi_base_url` the same way if you're driving
the test through one of those country configs — the stubs don't care which set of
credentials is used. The endpoint paths under the base URL — `api.auth_endpoint`,
`api.collection_endpoint`, `api.status_endpoint` — are what these stubs match on, so leave
them at their defaults.)

## Running the full journey

The flow is normally driven through the channel connector / the `airtel_flow_*` BPMN rather
than by calling the connector directly. What happens once it starts:

1. The connector fetches an access token from `paymenthub-wiremock`
   (`airtel-01-oauth-token.json`).
2. It calls the collection request endpoint (`airtel-02-collection-request.json`), which
   responds `200` with `TIP`, and schedules the callback webhook.
3. ~3s later, `paymenthub-wiremock` `POST`s the callback to the connector's own
   `/collections/callback`, completing the transaction (`status_code: "TS"`).
4. If the callback doesn't arrive in time, the workflow's boundary timer makes the connector
   poll `GET /standard/v1/payments/{transactionId}`
   (`airtel-03-payment-status.json`), which reports the same successful outcome.

To exercise just the stubs, without the connector, port-forward WireMock
(`kubectl port-forward svc/paymenthub-wiremock 8080:80`) and:

```bash
TXN="oaf-$(uuidgen | tr 'A-Z' 'a-z' | tr -d '-')"

curl -X POST http://localhost:8080/merchant/v1/payments/ \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -H "X-Country: RW" \
  -H "X-Currency: RWF" \
  -d "{
    \"reference\": \"Payment to OAF\",
    \"subscriber\": { \"country\": \"RW\", \"currency\": \"RWF\", \"msisdn\": 730000000 },
    \"transaction\": { \"amount\": 250, \"country\": \"RW\", \"currency\": \"RWF\", \"id\": \"${TXN}\" }
  }"

curl -H "Authorization: Bearer token" \
  -H "X-Country: RW" -H "X-Currency: RWF" \
  http://localhost:8080/standard/v1/payments/${TXN}
```

(The collection request's webhook will try to deliver the callback to
`http://ph-ee-connector-airtel/collections/callback` — harmless if the connector isn't
running, WireMock just logs the failed delivery.)

## Simulating a callback manually

`simulate-airtel-callback.sh` `POST`s an Airtel-shaped callback directly to a connector's
`/collections/callback` endpoint. Useful for testing a specific status/message (the webhook
above only ever simulates the scenarios in the MSISDN matrix), replaying a callback, or
exercising the connector's callback handling without the wiremock stack running at all:

```bash
# Success (mirrors what the webhook sends automatically)
./simulate-airtel-callback.sh http://ph-ee-connector-airtel/collections/callback \
  oaf-e355071b6187HcEbkCLa TS

# Failure — e.g. the payer had no balance
./simulate-airtel-callback.sh http://ph-ee-connector-airtel/collections/callback \
  oaf-e355071b6187HcEbkCLa TF

# Any other status/message, with the remaining fields spelled out
./simulate-airtel-callback.sh http://ph-ee-connector-airtel/collections/callback \
  oaf-e355071b6187HcEbkCLa TF "Transaction not permitted to Payee"
```

The second argument is the `transaction.id` (the payment hub transaction ID sent in the
collection request body) — that's what the connector correlates the callback on.

## Extending

Add another `airtel-NN-description.json` file to `mappings/` for additional scenarios (e.g.
a `TA` (ambiguous) enquiry response, or a 401 from the token endpoint to test the
connector's re-auth handling) — each file is one WireMock stub mapping and is picked up
automatically via the ConfigMap glob in `templates/wiremock.yaml`. Keep the `airtel-`
filename prefix so these never collide with another connector's mapping files in the shared
ConfigMap (see `../README.md`).
