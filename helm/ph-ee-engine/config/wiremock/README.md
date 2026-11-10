# paymenthub-wiremock: shared WireMock stand-in for external payment APIs

A single WireMock deployment used to stub the external payment-provider APIs that
ph-ee connectors talk to, so their flows can be exercised end-to-end without hitting a
real sandbox. It's shared infrastructure, not tied to any one connector — today
`ph-ee-connector-mpesa` (stubbing Safaricom's Daraja API), `ph-ee-connector-mtn` (stubbing
MTN's MoMo Collection API) and `ph-ee-connector-airtel` (stubbing Airtel Money's Collection
API) use it, along with the account systems Fineract (`fineract/`) and Tupande
(`ph-ee-connector-ams-tupande`, `tupande/`), and further connectors are meant to adopt the same instance rather than
standing up their own.

Deployed via `../../templates/wiremock.yaml`, gated by `wiremock.enabled` (`false` by
default — this is a test/dev aid, not something that runs in production). In-cluster it's
reachable as the `paymenthub-wiremock` Service.

## Callback timing

The mpesa, mtn and airtel stubs deliver their asynchronous callback after a random 5–10 second
delay (`"delay": {"type": "uniform", "lower": 5000, "upper": 10000}` on the callback webhook).
That stands in for the customer reading the prompt on their phone and entering their PIN, so
transactions stay in flight for a realistic time and finish out of order under load. Webhooks
that register per-transaction status stubs have no delay, so the stub is in place before the
callback arrives or the connector polls.

## Adding a connector's mappings

1. Create a `<connector>/mappings/` directory here (mirroring `mpesa/mappings/`,
   `mtn/mappings/` or `airtel/mappings/`).
2. Name each mapping file `<connector>-NN-description.json` (e.g.
   `tnm-01-oauth-token.json`). The connector prefix is required, not just convention: all
   connectors' mapping files are glob'd into one flat ConfigMap keyed by filename
   (see `templates/wiremock.yaml`), so two connectors' files with the same name would
   silently collide/overwrite each other in that ConfigMap.
3. Files are picked up automatically — no template changes needed.
4. Add a `<connector>/README.md` documenting what's stubbed, following `mpesa/README.md`,
   `mtn/README.md` or `airtel/README.md` as an example.

Since every connector's stubs are served from the same WireMock instance, make sure the
URL paths you stub don't clash across connectors (different providers' APIs are
typically distinct enough — e.g. Safaricom's `/mpesa/...` vs MTN's MoMo API paths vs
Airtel's `/merchant/...` and `/standard/...` paths — that this shouldn't come up in
practice).
