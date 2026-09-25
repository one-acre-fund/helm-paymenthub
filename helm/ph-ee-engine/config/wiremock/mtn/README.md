# mtn mappings for the shared paymenthub-wiremock

Stubs the parts of MTN's MoMo **Collection** API that `ph-ee-connector-mtn` (deployed as
`ph-ee-connector-ams-mtn-rw`) talks to, so the full success journey — OAuth token,
request-to-pay, the asynchronous callback, and a request-to-pay status query — can be
exercised without hitting MTN's real sandbox.

These mappings are loaded into the shared `paymenthub-wiremock` deployment alongside any
other connector's mappings — see `../README.md` for how that deployment works and how to
enable it. This file covers only the mtn-specific stubs below.

## What's stubbed

| File | Endpoint | Mimics |
|---|---|---|
| `mtn-01-oauth-token.json` | `POST /collection/token/` | OAuth2 token endpoint (Basic auth + `Ocp-Apim-Subscription-Key`). Returns a fresh `access_token` on every call. |
| `mtn-02-request-to-pay.json` | `POST /collection/v1_0/requesttopay` | Request-to-pay (default/catch-all). Returns `202 Accepted` with an empty body, **and** fires a WireMock webhook ~3s later that `POST`s a `SUCCESSFUL` callback to whatever `X-Callback-Url` was in the request — this is what simulates MTN notifying the connector once the customer approves the payment on their phone. |
| `mtn-02-request-to-pay-error-*.json` | `POST /collection/v1_0/requesttopay` | Request-to-pay **synchronous** failures — see "Simulating failures" below. Matched by `payer.partyId`, higher priority than the default stub above. |
| `mtn-02-request-to-pay-callback-*.json` | `POST /collection/v1_0/requesttopay` | Request-to-pay that succeeds synchronously but whose webhook delivers a **failing** callback — see "Simulating failures" below. Matched by `payer.partyId`, higher priority than the default stub above. |
| `mtn-02-request-to-pay-no-callback.json` | `POST /collection/v1_0/requesttopay` | Request-to-pay that succeeds synchronously but has **no callback webhook at all** — simulates a callback MTN never delivers. See "Simulating failures" below. |
| `mtn-03-request-to-pay-status.json` | `GET /collection/v1_0/requesttopay/{referenceId}` | Request-to-pay status (default/catch-all). Reports the transaction as `SUCCESSFUL`. |

The webhook is what makes this "simulate the callback from MTN" — no manual step needed
for the standard success path. It's a `POST` to the `X-Callback-Url` — that's what MoMo
sends, and what the connector's `/buygoods/callback` endpoint listens for.
`simulate-mtn-callback.sh` (see below) exists for the cases the stubs above can't cover:
replaying a callback, or a `reason` not in the MSISDN matrix below.

MTN identifies a request-to-pay by the `X-Reference-Id` **header** (a UUID the connector
generates), while the callback body carries `externalId` (the payment hub transaction ID)
— the connector correlates callbacks on `externalId` and polls status by `X-Reference-Id`.
Both are echoed back by these stubs accordingly.

`financialTransactionId` is derived from the `X-Reference-Id` (first 12 hex characters,
dashes stripped) rather than randomly generated, so the callback and a later status query
report the *same* ID for the same transaction without the mock having to remember
anything. MTN's real IDs are opaque numeric strings, so don't assert on its shape.

### Simulating failures

Send the request-to-pay with one of the `payer.partyId` (MSISDN) values below to trigger a
specific MoMo-style failure instead of the default success path. These are mock-only
conventions — the MSISDN blocks are just a convenient way to pick a scenario without
adding request headers or query params.

**Synchronous API errors** — the request-to-pay call itself fails immediately (MoMo's
`code`/`message` error envelope). The transaction is never created and no callback webhook
fires, matching real MTN behaviour:

| `payer.partyId` | HTTP status | `code` | `message` |
|---|---|---|---|
| `250780000001` | 400 | `INVALID_CALLBACK_URL_HOST` | Callback URL host is not registered for this API user. |
| `250780000002` | 409 | `RESOURCE_ALREADY_EXIST` | Duplicated reference id. Creation of resource failed. |
| `250780000003` | 500 | `INTERNAL_PROCESSING_ERROR` | Internal error while processing the request. |

**Asynchronous callback failures** — the request-to-pay succeeds normally (`202 Accepted`),
but the webhook that fires ~3s later delivers a failing callback (`status: "FAILED"` with a
`reason`, and no `financialTransactionId` — matching what MTN sends when a transaction
doesn't complete):

| `payer.partyId` | `reason` | Meaning |
|---|---|---|
| `250780000101` | `NOT_ENOUGH_FUNDS` | Payer has insufficient MoMo balance |
| `250780000102` | `APPROVAL_REJECTED` | Customer rejected the payment prompt |
| `250780000103` | `EXPIRED` | Customer never acted on the prompt (timeout) |
| `250780000104` | `PAYER_LIMIT_REACHED` | Payer's transaction limit reached |

**No callback at all** — the request-to-pay succeeds normally, but MTN never delivers a
callback (e.g. dropped by the network, or the transaction gets stuck). Use this to
exercise the connector's own timeout/reconciliation path (polling the status endpoint
instead of waiting on the callback):

| `payer.partyId` | Behaviour |
|---|---|
| `250780000201` | Request-to-pay succeeds, no webhook ever fires. A status query for this transaction always reports `PENDING` (see below) — it never resolves on its own. |

Any other `payer.partyId` falls through to the default success stub
(`mtn-02-request-to-pay.json`).

### Linking the status query to a callback outcome

MTN's status endpoint is keyed by the `X-Reference-Id` the *connector* generated, so —
unlike the mpesa stubs, which encode the scenario in the `CheckoutRequestID` they hand back
— these stubs can't recognise a scenario from the status request alone. Instead, each
failure/pending stub above fires a second webhook that registers a status stub for *that
specific reference ID* through WireMock's own admin API
(`POST http://localhost:8080/__admin/mappings`, i.e. WireMock calling itself). Querying
`GET /collection/v1_0/requesttopay/{referenceId}` afterwards therefore reports the *same*
outcome the callback delivered (or, for the "no callback" case, reports the transaction as
`PENDING` — indefinitely, since nothing ever resolves it):

| Scenario MSISDN | Status query response |
|---|---|
| `250780000101` | `status: "FAILED"`, `reason: "NOT_ENOUGH_FUNDS"` |
| `250780000102` | `status: "FAILED"`, `reason: "APPROVAL_REJECTED"` |
| `250780000103` | `status: "FAILED"`, `reason: "EXPIRED"` |
| `250780000104` | `status: "FAILED"`, `reason: "PAYER_LIMIT_REACHED"` |
| `250780000201` | `status: "PENDING"` |
| (anything else — default success) | `status: "SUCCESSFUL"`, with the derived `financialTransactionId` |

Two things follow from that mechanism. These self-registered stubs live only in the
running WireMock's memory: they're gone after a pod restart (the status query then falls
back to the `SUCCESSFUL` catch-all), and they accumulate one per failure-scenario
transaction until you clear them with `POST /__admin/mappings/reset`, which reloads just
the mappings from this directory. The default success path deliberately registers nothing,
so ordinary load stays stateless.

Also note `reason` is stubbed as a plain string (`"reason": "NOT_ENOUGH_FUNDS"`), which is
what MoMo's sandbox returns and what the connector parses; the published OpenAPI spec
models it as a `{code, message}` object.

## Enabling it

```
--set wiremock.enabled=true
```

Then point the mtn connector at it instead of MTN's real sandbox:

```yaml
mtn_rwanda_connector:
  mtnrw_auth_host: "http://paymenthub-wiremock"
  mtnrw_api_host: "http://paymenthub-wiremock"
  mtnrw_callback: "http://ph-ee-connector-ams-mtn-rw/buygoods/callback"
```

(`paymenthub-wiremock` is the in-cluster Service name/DNS. The same applies to the
`mtnz_auth_host`/`mtnz_api_host`/`mtnz_callback` pair if you're driving the test through
the Zambia country config — the stubs don't care which set of credentials is used.)

`mtnrw_callback` is what the connector puts in the `X-Callback-Url` header and therefore
where the stub's webhook delivers the callback, so it has to be an address WireMock can
reach from inside the cluster — the connector's own Service, as above.

## Running the full journey

The flow is normally driven through the channel connector / the `momo_flow_*` BPMN rather
than by calling the connector directly. What happens once it starts:

1. The connector fetches an access token from `paymenthub-wiremock`
   (`mtn-01-oauth-token.json`).
2. It calls request-to-pay (`mtn-02-request-to-pay.json`) with a freshly generated
   `X-Reference-Id`, which responds `202 Accepted` and schedules the callback webhook.
3. ~3s later, `paymenthub-wiremock` `POST`s the callback to the connector's own
   `/buygoods/callback` (`MTNRW_CALLBACK`), completing the transaction
   (`status: "SUCCESSFUL"`).
4. If the callback doesn't arrive in time, the workflow's boundary timer makes the
   connector poll `GET /collection/v1_0/requesttopay/{referenceId}`
   (`mtn-03-request-to-pay-status.json`), which reports the same successful outcome.

To exercise just the stubs, without the connector, port-forward WireMock
(`kubectl port-forward svc/paymenthub-wiremock 8080:80`) and:

```bash
REF=$(uuidgen | tr 'A-Z' 'a-z')

curl -X POST http://localhost:8080/collection/v1_0/requesttopay \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -H "X-Reference-Id: ${REF}" \
  -H "X-Target-Environment: sandbox" \
  -H "Ocp-Apim-Subscription-Key: subscription-key" \
  -H "X-Callback-Url: http://ph-ee-connector-ams-mtn-rw/buygoods/callback" \
  -d '{
    "amount": "250",
    "currency": "RWF",
    "externalId": "tx-0001",
    "payerMessage": "Payment for tx-0001",
    "payeeNote": "Payment for tx-0001",
    "payer": { "partyIdType": "MSISDN", "partyId": "250788111222" }
  }'

curl -H "Authorization: Bearer token" \
  http://localhost:8080/collection/v1_0/requesttopay/${REF}
```

## Simulating a callback manually

`simulate-mtn-callback.sh` `POST`s a MoMo-shaped callback directly to a connector's
`/buygoods/callback` endpoint. Useful for testing a specific `reason` (the webhook above
only ever simulates the scenarios in the MSISDN matrix), replaying a callback, or
exercising the connector's callback handling without the wiremock stack running at all:

```bash
# Success (mirrors what the webhook sends automatically)
./simulate-mtn-callback.sh http://ph-ee-connector-ams-mtn-rw/buygoods/callback tx-0001 SUCCESSFUL

# Failure — e.g. the customer rejected the prompt
./simulate-mtn-callback.sh http://ph-ee-connector-ams-mtn-rw/buygoods/callback \
  tx-0001 FAILED APPROVAL_REJECTED

# Any other reason code, with the remaining fields spelled out
./simulate-mtn-callback.sh http://ph-ee-connector-ams-mtn-rw/buygoods/callback \
  tx-0001 FAILED PAYEE_NOT_ALLOWED_TO_RECEIVE 250 RWF 250788111222
```

The second argument is the `externalId` (the payment hub transaction ID sent in the
request-to-pay body) — that, not the `X-Reference-Id`, is what the connector correlates
the callback on.

## Extending

Add another `mtn-NN-description.json` file to `mappings/` for additional scenarios (e.g.
a 401 from the token endpoint, to test the connector's re-auth handling) — each file is
one WireMock stub mapping and is picked up automatically via the ConfigMap glob in
`templates/wiremock.yaml`. Keep the `mtn-` filename prefix so these never collide with
another connector's mapping files in the shared ConfigMap (see `../README.md`).
