# odoo mappings for the shared paymenthub-wiremock

Stubs the Odoo payment confirmation endpoint, which `ph-ee-connector-ams-odoo` calls from its
`transfer-settlement-odoo` Zeebe worker to settle a collection into an Odoo sale (payee identifier
type `ODOOID`). Like the `fineract/` and `tupande/` mappings, this stands in for the account system
being paid into, not the mobile money provider.

These mappings are loaded into the shared `paymenthub-wiremock` deployment alongside the other
connectors' mappings. See `../README.md` for how that deployment works.

## What the connector calls

```
POST {odoo.base-url}{odoo.endpoint.confirmation}   # /rest/Odoo+confirmation+Api+Mock/2.1.0/confirmation
apikey: <odoo_connector.odoo.auth_header>
Content-Type: application/json

{
  "saleId": "2e675b313b65cWf1BUFs",      // the PaymentHub transaction id
  "walletId": "25598208",                // the ODOOID payee identifier
  "status": "successful",                // or "failed"
  "statusCode": 200,
  "mpesaCode": "VAHIG8RO0E",             // the provider's receipt (externalId)
  "amount": 42,
  "message": null,
  "errorCode": null,
  "customData": [ ... ]
}
```

When the collection carries a `callbackUrl`, the connector posts there instead of the default URL;
point that at `http://paymenthub-wiremock/rest/Odoo+confirmation+Api+Mock/2.1.0/confirmation` to
exercise the same stubs. Only HTTP `200` counts as settled.

## What's stubbed

| File | `saleId` | Response |
|---|---|---|
| `odoo-01-confirmation.json` | anything else | `200 {"message": "Confirmation received", "saleId": "<echoed>"}` |
| `odoo-02-confirmation-server-error.json` | starts with `error-` | `500 {"message": "Internal server error"}`: retried three times, then the settlement fails with `500` |

## Simulating a slow or unavailable Odoo (FD-1935)

The connector's retry and circuit-breaker behaviour can be exercised by choosing the transaction id
(`saleId`) sent on the confirmation. Higher priority than the default stub, matched on a prefix:

| `saleId` starts with | Behaviour |
|---|---|
| `slow-` | `200` after a 70 s delay, longer than the connector's 60 s read timeout: the request was sent but gets no answer in time, so the settlement fails with `UNKNOWN_OUTCOME` and is not sent again |
| `down-` | `503`: retried (502/503 are in the connector's `retry-status-codes`), then the settlement fails with `503`; enough of them in a row open the circuit |
| `reset-` | the connection is reset while waiting for the answer: the request may have been processed, so the settlement fails with `UNKNOWN_OUTCOME` after a single attempt and is not sent again |

Anything else goes through the stubs above. While the circuit is open the connector does not call
WireMock at all, so the request journal (`GET /__admin/requests`) is an exact count of what reached
Odoo; `DELETE /__admin/requests` resets it between scenarios.

## Enabling it

Set `wiremock.enabled: true` and `odoo_connector.odoo.base_url: http://paymenthub-wiremock` (the
default `odoo_connector.odoo.endpoint.confirmation` already matches the stub path).
