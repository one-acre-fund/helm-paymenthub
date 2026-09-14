# paymenthub-wiremock: shared WireMock stand-in for external payment APIs

A single WireMock deployment used to stub the external payment-provider APIs that
ph-ee connectors talk to, so their flows can be exercised end-to-end without hitting a
real sandbox. It's shared infrastructure, not tied to any one connector — today only
`ph-ee-connector-mpesa` uses it (stubbing Safaricom's Daraja API), but other connectors
(e.g. mtn) are meant to adopt the same instance rather than standing up their own.

Deployed via `../../templates/wiremock.yaml`, gated by `wiremock.enabled` (`false` by
default — this is a test/dev aid, not something that runs in production). In-cluster it's
reachable as the `paymenthub-wiremock` Service.

## Adding a connector's mappings

1. Create a `<connector>/mappings/` directory here (mirroring `mpesa/mappings/`).
2. Name each mapping file `<connector>-NN-description.json` (e.g.
   `mtn-01-oauth-token.json`). The connector prefix is required, not just convention: all
   connectors' mapping files are glob'd into one flat ConfigMap keyed by filename
   (see `templates/wiremock.yaml`), so two connectors' files with the same name would
   silently collide/overwrite each other in that ConfigMap.
3. Files are picked up automatically — no template changes needed.
4. Add a `<connector>/README.md` documenting what's stubbed, following `mpesa/README.md`
   as an example.

Since every connector's stubs are served from the same WireMock instance, make sure the
URL paths you stub don't clash across connectors (different providers' APIs are
typically distinct enough — e.g. Safaricom's `/mpesa/...` vs MTN's MoMo API paths — that
this shouldn't come up in practice).
