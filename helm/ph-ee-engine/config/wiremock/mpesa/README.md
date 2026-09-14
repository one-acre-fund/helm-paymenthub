# mpesa mappings for the shared paymenthub-wiremock

Stubs the parts of Safaricom's Daraja API that `ph-ee-connector-mpesa`'s **buygoods**
(Lipa na M-Pesa Online / STK Push) flow talks to, so the full success journey — OAuth,
STK push, the asynchronous callback, and a transaction status query — can be exercised
without hitting the real sandbox.

These mappings are loaded into the shared `paymenthub-wiremock` deployment alongside any
other connector's mappings — see `../README.md` for how that deployment works and how to
enable it. This file covers only the mpesa-specific stubs below.

## What's stubbed

| File | Endpoint | Mimics |
|---|---|---|
| `mpesa-01-oauth-token.json` | `GET /oauth/v1/generate` | OAuth2 client-credentials token endpoint. Returns a fresh `access_token` on every call. |
| `mpesa-02-stk-push-initiate.json` | `POST /mpesa/stkpush/v1/processrequest` | STK push initiate (default/catch-all). Returns `ResponseCode: "0"` with a `CheckoutRequestID` derived from the request's `Timestamp`, **and** fires a WireMock webhook ~3s later that `POST`s a successful STK callback (with a randomly generated `MpesaReceiptNumber`) to whatever `CallBackURL` was in the request — this is what simulates Safaricom notifying the connector once the customer completes payment on their phone. |
| `mpesa-02-stk-push-initiate-error-*.json` | `POST /mpesa/stkpush/v1/processrequest` | STK push initiate **synchronous** failures — see "Simulating failures" below. Matched by `PhoneNumber`, higher priority than the default stub above. |
| `mpesa-02-stk-push-initiate-callback-*.json` | `POST /mpesa/stkpush/v1/processrequest` | STK push initiate that succeeds synchronously but whose webhook delivers a **failing** callback — see "Simulating failures" below. Matched by `PhoneNumber`, higher priority than the default stub above. |
| `mpesa-02-stk-push-initiate-no-callback.json` | `POST /mpesa/stkpush/v1/processrequest` | STK push initiate that succeeds synchronously but has **no webhook at all** — simulates a callback Safaricom never delivers. See "Simulating failures" below. |
| `mpesa-03-transaction-status-query.json` | `POST /mpesa/stkpushquery/v2/query` | STK push query (default/catch-all). Reports the transaction as completed successfully (`ResultCode: "0"`, with a randomly generated `MpesaReceiptNumber`). |
| `mpesa-03-transaction-status-query-*.json` | `POST /mpesa/stkpushquery/v2/query` | STK push query for a transaction that ended in one of the failures above — see "Linking the status query to a callback outcome" below. Matched by `CheckoutRequestID`, higher priority than the default stub above. |

The webhook is what makes this "simulate the callback from Safaricom" — no manual step
needed for the standard success path. Every successful `MpesaReceiptNumber` returned by
these stubs (initiate callback and status query alike) is randomly generated per request
(`{{randomValue length=10 type='ALPHANUMERIC' uppercase=true}}`), matching the shape of a
real receipt (e.g. `NLJ7RT61SV`) instead of always returning the same value.
`simulate-safaricom-callback.sh` (see below) exists for the cases the stubs above can't
cover: replaying a callback, or a `ResultCode` not in the phone-number matrix below.

### Simulating failures

Send the STK push initiate request with one of the `PhoneNumber` values below to trigger
a specific Safaricom-style failure instead of the default success path. These are mock-only
conventions (Safaricom doesn't publish "magic" test numbers) — the phone-number blocks are
just a convenient way to pick a scenario without adding request headers or query params.

**Synchronous API errors** — the initiate call itself fails immediately (Daraja's
`errorCode`/`errorMessage` envelope). No `CheckoutRequestID` is returned and no callback
webhook fires, matching real Safaricom behaviour:

| `PhoneNumber` | HTTP status | `errorCode` | `errorMessage` |
|---|---|---|---|
| `254700000001` | 500 | `500.001.1001` | Unable to lock subscriber, a transaction is already in process for the current subscriber. |
| `254700000002` | 400 | `400.002.02` | Bad Request - Invalid CallBackURL |
| `254700000003` | 400 | `400.002.05` | Bad Request - Invalid PhoneNumber |

**Asynchronous callback failures** — the initiate call succeeds normally
(`ResponseCode: "0"`, `CheckoutRequestID` issued), but the webhook that fires ~3s later
delivers a failing callback (non-zero `ResultCode`, no `CallbackMetadata` — matching what
Safaricom sends when a transaction doesn't complete):

| `PhoneNumber` | `ResultCode` | `ResultDesc` | Meaning |
|---|---|---|---|
| `254700000101` | 1 | The balance is insufficient for the transaction. | Payer has insufficient M-Pesa balance |
| `254700000102` | 1032 | Request cancelled by user. | Customer pressed cancel on the STK prompt |
| `254700000103` | 1037 | DS timeout user cannot be reached. | Customer never responded to the STK prompt (timeout) |
| `254700000104` | 2001 | The initiator information is invalid. | Customer entered the wrong M-Pesa PIN |

**No callback at all** — the initiate call succeeds normally, but Safaricom never
delivers a callback (e.g. dropped by the network, or the transaction gets stuck). Use
this to exercise the connector's own timeout/reconciliation path (polling
`/buygoods/transactionstatus` instead of waiting on the callback):

| `PhoneNumber` | Behaviour |
|---|---|
| `254700000201` | Initiate succeeds, no webhook ever fires. A status query for this transaction always reports "still processing" (see below) — it never resolves on its own. |

Any other `PhoneNumber` falls through to the default success stub
(`mpesa-02-stk-push-initiate.json`).

### Linking the status query to a callback outcome

Each of the failure/pending stubs above tags the `CheckoutRequestID` it returns with a
suffix identifying the scenario (e.g. `ws_CO_<timestamp>_CANCELLED`). The
`mpesa-03-transaction-status-query-*.json` stubs match on that suffix, so querying
`/buygoods/transactionstatus` for one of these transactions reports the *same* outcome
the callback delivered (or, for the "no callback" case, reports the transaction as still
being processed — indefinitely, since nothing ever resolves it):

| `CheckoutRequestID` suffix | Status query response |
|---|---|
| `_INSUFFICIENTFUNDS` | `ResultCode: "1"`, "The balance is insufficient for the transaction." |
| `_CANCELLED` | `ResultCode: "1032"`, "Request cancelled by user." |
| `_TIMEOUT` | `ResultCode: "1037"`, "DS timeout user cannot be reached." |
| `_WRONGPIN` | `ResultCode: "2001"`, "The initiator information is invalid." |
| `_PENDING` | HTTP 500, `errorCode: "500.001.1001"`, "The transaction is being processed" |
| (none — default success) | `ResultCode: "0"`, with a randomly generated `MpesaReceiptNumber` |

This suffix is a **mock-only convention**, not part of Safaricom's real `CheckoutRequestID`
format (which is an opaque, purely Safaricom-generated token) — it only works here because
these stubs treat `CheckoutRequestID` as an opaque string end-to-end. If the connector ever
validates or parses its shape, this trick would need to move to a different mechanism (e.g.
a stub that self-registers via WireMock's admin API instead of encoding state in the ID).

## Enabling it

```
--set wiremock.enabled=true
```

Then point the mpesa account(s) you're testing with at it instead of Safaricom's real
sandbox, e.g. for the `default` account:

```yaml
mpesa:
  accounts:
    default:
      auth_host: "http://paymenthub-wiremock/oauth/v1/generate"
      api_host: "http://paymenthub-wiremock"
```

(`paymenthub-wiremock` is the in-cluster Service name/DNS; adjust whichever account
group(s) you're driving the test through.)

## Running the full journey

The connector's own `/buygoods` REST endpoint takes the `CallBackURL` straight from the
caller, so point it at the connector's own service and the STK-push-initiate stub's
webhook will deliver the callback there automatically:

```bash
curl -X POST http://ph-ee-connector-mpesa/buygoods \
  -H "Content-Type: application/json" \
  -d '{
    "BusinessShortCode": 174379,
    "Amount": 250,
    "PartyA": 254712345678,
    "PartyB": 174379,
    "PhoneNumber": 254712345678,
    "CallBackURL": "http://ph-ee-connector-mpesa/buygoods/callback",
    "AccountReference": "CompanyXLTD",
    "TransactionDesc": "Payment of X"
  }'
```

What happens:
1. The connector fetches an access token from `paymenthub-wiremock`
   (`mpesa-01-oauth-token.json`).
2. It calls the STK push initiate endpoint (`mpesa-02-stk-push-initiate.json`), which
   responds immediately with a `CheckoutRequestID`, and schedules the callback webhook.
3. ~3s later, `paymenthub-wiremock` `POST`s the STK callback to the connector's own
   `/buygoods/callback`, completing the transaction (`ResultCode: 0`, with a randomly
   generated `MpesaReceiptNumber` in the callback metadata).
4. A status check against `/buygoods/transactionstatus` (or the connector's own retry
   logic) hits `mpesa-03-transaction-status-query.json`, which reports the same
   successful outcome.

## Simulating a callback manually

`simulate-safaricom-callback.sh` posts a Safaricom-shaped STK callback directly to a
connector's `/buygoods/callback` endpoint. Useful for testing a specific `ResultCode`
(the webhook above only ever simulates success), replaying a callback, or exercising the
connector's callback handling without the wiremock stack running at all:

```bash
# Success (mirrors what the webhook sends automatically)
./simulate-safaricom-callback.sh http://ph-ee-connector-mpesa/buygoods/callback \
  ws_CO_20260831190500 0 250 254712345678 NLJ7RT61SV

# Failure — e.g. user cancelled on their phone (ResultCode 1032)
./simulate-safaricom-callback.sh http://ph-ee-connector-mpesa/buygoods/callback \
  ws_CO_20260831190500 1032
```

The `CheckoutRequestID` (second argument) must match the one returned by the STK push
initiate call you're completing.

## Extending

Add another `mpesa-NN-description.json` file to `mappings/` for additional scenarios
(e.g. a non-zero `ResponseCode` from the initiate call itself, to test the connector's
`onException`/retry handling) — each file is one WireMock stub mapping and is picked up
automatically via the ConfigMap glob in `templates/wiremock.yaml`. Keep the `mpesa-`
filename prefix so these never collide with another connector's mapping files in the
shared ConfigMap (see `../README.md`).
