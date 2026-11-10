# tupande mappings for the shared paymenthub-wiremock

Stubs Tupande's payment confirmation endpoint, which `ph-ee-connector-ams-tupande` calls to
settle a collection into a Tupande account (payee identifier type `TUPANDEACCOUNTID`). Like
the `fineract/` mappings, this stands in for the account system being paid into, not the
mobile money provider. The provider leg (for example M-Pesa STK push) still comes from that
provider's own mappings.

These mappings are loaded into the shared `paymenthub-wiremock` deployment alongside the
other connectors' mappings. See `../README.md` for how that deployment works.

## What the connector calls

The connector makes one request per transaction, from its `transfer-settlement-tupande`
Zeebe worker, once the provider leg has finished (successfully or not):

```
POST {tupande.base-url}{tupande.endpoint.confirmation}   # /api/v1/payments/payment-hub/confirmation
Authorization: Bearer <tupande_connector.tupande.auth_header>
Content-Type: application/json

{
  "data": {
    "phoneNumber": "254711111111",
    "account": "24450523",
    "remoteTransactionId": "2e675b313b65cWf1BUFs",
    "status": "successful",          // or "failed", with "reason"
    "amount": 1,
    "currency": "KES",
    "reason": null,
    "paymentCode": "VAHIG8RO0E"       // the provider's receipt (externalId)
  }
}
```

Only HTTP `200` counts as settled. Any other status sets `transferSettlementFailed`, and the
response body and code become the workflow's `errorInformation` and `errorCode`. The
operations app then shows the collection as `NOT_AUTOSAVED`: the provider took the money but
Tupande wasn't updated. The connector doesn't read the success body.

## What's stubbed

The outcome is chosen by the payee account (`data.account`), which is the
`TUPANDEACCOUNTID` value sent on the collection request.

| File | `data.account` | Response |
|---|---|---|
| `tupande-01-payment-confirmation.json` | anything else | `200 {"message": "Payment confirmed", "remoteTransactionId": "<echoed>"}` |
| `tupande-02-payment-confirmation-not-found.json` | starts with `0000` (e.g. `00000001`) | `404 {"message": "Transaction not found for id or remoteTransactionId (<id>)"}` |
| `tupande-02-payment-confirmation-server-error.json` | starts with `9999` (e.g. `99990001`) | `500 {"message": "Internal server error"}` |

The 404 body is what Tupande's QA function actually returns for a transaction it doesn't
know. The success body is a placeholder, because the connector ignores it. Confirmations for
failed payments (`"status": "failed"`) get the same responses, so a provider failure plus
the default account still ends as a failed settlement, as it would against the real API.

Every stub needs an `Authorization` header starting with `Bearer`. The token may be empty,
because the chart's default `auth_header` is `""`. Without the header WireMock returns its
own 404 (no matching stub).

```bash
curl -X POST http://paymenthub-wiremock/api/v1/payments/payment-hub/confirmation \
  -H "Authorization: Bearer " \
  -H "Content-Type: application/json" \
  -d '{"data":{"phoneNumber":"254711111111","account":"00000001","remoteTransactionId":"abc123","status":"successful","amount":1,"currency":"KES","reason":null,"paymentCode":"QWE123"}}'
```

## Enabling it

```
--set wiremock.enabled=true
```

Then point the connector at it instead of Tupande's cloud function:

```yaml
tupande_connector:
  tupande:
    base_url: "http://paymenthub-wiremock"
```

The chart sets both halves of the URL: `TUPANDE_BASE-URL` from `base_url` and
`TUPANDE_ENDPOINT_CONFIRMATION` from `tupande_connector.tupande.confirmation_endpoint`
(`/api/v1/payments/payment-hub/confirmation`), which overrides the connector's built-in
`/paymentConfirmation`. The stubs match that path, so only `base_url` changes.

The provider side of a Tupande collection (for example the `mpesa_ke_tupande` variant in the
load test) also needs that provider's connector pointed at the mock. See `../mpesa/README.md`.
