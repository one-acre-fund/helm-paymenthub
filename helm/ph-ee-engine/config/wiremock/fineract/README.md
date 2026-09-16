# fineract mappings for the shared paymenthub-wiremock

Stubs the Fineract "paymentHub" REST endpoints that a connector calls *into* Fineract as
part of an inbound payment (e.g. after an M-Pesa buygoods payment succeeds), so that
side of the flow can be exercised without a live Fineract instance. This is the reverse
direction from the `mpesa/` mappings: those stub the external provider (Safaricom) a
connector calls out to; these stub Fineract itself as the counterparty being called.

These mappings are loaded into the shared `paymenthub-wiremock` deployment alongside any
other connector's mappings — see `../README.md` for how that deployment works and how to
enable it. This file covers only the fineract-specific stubs below.

## What's stubbed

| File | Endpoint | Mimics |
|---|---|---|
| `fineract-01-payment-hub-verification.json` | `POST /fineract-provider/api/v1/paymentHub/verification` | Validates the payer/account before the payment is posted (Fineract's equivalent of Safaricom C2B's Validation step). Always succeeds: `{"message": "Validation successful", "transactionId": "<random>"}`, with a freshly generated `transactionId` per request (it is not an echo of the request's `RemoteTransactionId`). |
| `fineract-02-payment-hub-confirmation.json` | `POST /fineract-provider/api/v1/paymentHub/confirmation` | Confirms a payment has been posted to the account. Always succeeds: `{"status": "CONFIRMED"}`. |

Both expect the request body to carry a `RemoteTransactionId` field, matching real
request shapes. Verification also requires an `Authorization: Bearer <token>` header (any
non-empty token) and a `fineract-platform-tenantid: default` header (tolerating
incidental leading whitespace in the value, e.g. `fineract-platform-tenantid:  default`);
confirmation requires neither - the real caller doesn't send either on that call, so the
stub doesn't require them.

```bash
# Verification
curl -X POST http://paymenthub-wiremock/fineract-provider/api/v1/paymentHub/verification \
  -H "accept: application/json" \
  -H "authorization: Bearer <token>" \
  -H "content-type: application/json" \
  -H "fineract-platform-tenantid: default" \
  -d '{
    "PhoneNumber": "+254711297602",
    "Account": "5548711",
    "Amount": 850,
    "Currency": "KES",
    "RemoteTransactionId": "12ef28db9487pgBDO0xxxxx"
  }'

# Confirmation (no Authorization or fineract-platform-tenantid header)
curl -X POST http://paymenthub-wiremock/fineract-provider/api/v1/paymentHub/confirmation \
  -H "accept: application/json" \
  -H "content-type: application/json" \
  -d '{
    "RemoteTransactionId": "12ef28db9487pgBDO0xxxxx",
    "PhoneNumber": "254711297602",
    "Account": "5548711",
    "Amount": "850",
    "Currency": "KES",
    "Status": "successful",
    "ReceiptId": "F5MRPDTVMF76f"
  }'
```

## Only the success path is stubbed so far

Both stubs are unconditional 200s — there's no phone-number/account-driven failure matrix
here yet, unlike `mpesa/mappings/mpesa-02-stk-push-initiate-*.json`. Add a
`fineract-NN-description.json` file the same way (matched by `Account` or
`RemoteTransactionId` via `bodyPatterns`, higher `priority` than the stubs above) to
simulate a specific failure — e.g. account not found, validation rejected, or a
non-`200` response — once a real failure shape from Fineract is documented.

## Enabling it

Same as the mpesa mappings — see `../README.md#enabling-it`:

```
--set wiremock.enabled=true
```

Then point the paymentHub confirmation/verification URLs used by whichever connector
posts them at `http://paymenthub-wiremock` instead of the real Fineract instance.

## Extending

Add another `fineract-NN-description.json` file to `mappings/` for additional scenarios —
each file is one WireMock stub mapping and is picked up automatically via the ConfigMap
glob in `../../templates/wiremock.yaml`. Keep the `fineract-` filename prefix so these
never collide with another connector's mapping files in the shared ConfigMap (see
`../README.md`).
