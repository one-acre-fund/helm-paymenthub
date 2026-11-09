# Graceful shutdown of the payment-path services (FD-1939)

Chart `ph-ee-engine` on `develop`, 2026-11-08. Full plan, design and test evidence:
`.claude/plans/2026-11-08-fd1939-graceful-shutdown.html` (not committed).

## What was wrong

- Every connector Deployment ran with the Kubernetes default `terminationGracePeriodSeconds: 30`, no
  `preStop` hook and no Spring shutdown settings. Only the importers set a grace period.
- The connectors hand their `ZeebeClient` to Spring as a bean. Spring closes it last, and
  `ZeebeClientImpl.close()` (client 8.1.x) stops polling and then calls `shutdownNow()` on the worker
  thread pool. A job handler halfway through a payment API call was interrupted; the job stayed
  activated at the broker, timed out (5 minutes by default) and was re-offered to another pod, which
  made the payment call again. Jobs polled while Camel was already stopping failed with one retry
  fewer. This is the duplicate-payment and incident path on every rollout.
- The importers (spring-kafka) already commit offsets only after a batch is processed and leave the
  group cleanly on stop, but during a context close Spring waits for the running batch only as long
  as its lifecycle processor allows, 30 s by default (`Failed to shut down 1 bean ... within timeout
  of 30000` in the logs). The rdbms importer polled up to 500 records per thread, close to a minute
  of work, so a rollout closed the data source under the batch and left processed-but-uncommitted
  records to be redelivered.

## What changed

Chart (`values.yaml`, `templates/_helpers.tpl`, every `templates/connector-*.yaml`,
`templates/operations-importer-*.yaml`):

- New `gracefulShutdown` block: `preStopSeconds` (5), `terminationGracePeriodSeconds` (120),
  `phaseTimeout` ("20s"), `zeebeDrainTimeout` ("60s"). A connector overrides the grace period with
  `<connector>.terminationGracePeriodSeconds` (channel: 90, its workers only send callbacks).
- Every connector container gets `terminationGracePeriodSeconds`, a `preStop` `sleep` so the pod keeps
  serving while endpoint removal propagates, and three env entries from the
  `ph-ee-engine.shutdown.env` helper: `SERVER_SHUTDOWN=graceful` and
  `SPRING_LIFECYCLE_TIMEOUT-PER-SHUTDOWN-PHASE` (read by Spring Boot 2.3+, finish accepted HTTP requests)
  and `ZEEBE_WORKER_DRAIN-TIMEOUT` (read by the drain component below; ignored by older images).
- Channel and mpesa readiness probes get `timeoutSeconds: 5`; the channel readiness group includes a
  Zeebe topology call with a 5 s timeout and a 1 s probe flapped on a slow gateway.
- Importers: `importer_rdbms.kafka.maxPollRecords` (100) and `importer_rdbms.kafka.shutdownTimeoutMs`
  (45000), `importer_es.kafka.shutdownTimeoutMs` (30000), wired as `KAFKA_MAX_POLL_RECORDS` and
  `KAFKA_SHUTDOWN_TIMEOUT_MS`. Grace period stays 60 s.
- Rolling-update strategy is unchanged: with one to three replicas the default 25% already rounds to
  `maxSurge 1 / maxUnavailable 0`.

Connector images (one class per fork, `<package>.zeebe.ZeebeWorkerDrain`, plus two tokens per worker
registration: `drain.register(... .handler(drain.track(handler)) ... .open())`):

- Runs first on `ContextClosedEvent` (before Camel, Tomcat and bean destruction): closes every
  registered `JobWorker` so no new jobs are activated for this pod, hands back any job that still
  arrives from a poll already on the wire (fail command with unchanged retries, so the broker
  re-offers it at once), and waits until the handlers already running have completed or failed their
  job, bounded by `zeebe.worker.drain-timeout` (default 60 s). Logs `shutdown: all Zeebe jobs
  drained after N ms`, or an error with the number of jobs left.
- Done in: mpesa, channel, airtel, tnm, ams-fineract, ams-paygops, ams-pesa (branch
  `feat/FD-1939-graceful-shutdown` in each fork). Still needed in the connectors whose sources are
  not on the public one-acre-fund organisation: bancobu, nbs, mtn-rw, tupande, odoo, erply.

Importer images (branch `feat/FD-1939-graceful-shutdown`): `kafka.shutdown-timeout-ms` sets both the
listener container's `shutdownTimeout` (direct stops) and a `lifecycleProcessor` bean's
`timeoutPerShutdownPhase` (the context-close path, not a property on Spring Boot 2.1) in both
importers. rdbms also commits each record's offset as soon as it is processed (`AckMode.RECORD`)
and polls at most `kafka.max-poll-records` (100) records. On minikube, with the database slowed to
1 to 3 records per second per thread, a 100-record poll outlasted the 45 s budget and every record
already written in it was read again; with per-record commits a shutdown that runs out of time
redoes only the records in flight. The cost is one synchronous commit per record, a few
milliseconds each.

## Shutdown budget

| Service | preStop | Drain | Web / Camel | Client close | Grace |
|---|---|---|---|---|---|
| payment connectors | 5 | 60 | 20 | up to 30 | 120 |
| channel | 5 | 60 | 20 | up to 30 | 90 |
| importer-rdbms | 0 | 45 (one 100-record batch is about 10 s) | 0 | about 5 | 60 |
| importer-es | 0 | 30 (one 100-record bulk is a few seconds) | 0 | about 5 | 60 |

## Rollout

The chart can go first: the longer grace period and the Spring web settings help on their own and the
drain env is ignored by images that do not know it. Then the importer images, then the connector
images (mpesa first). Verify a rollout per service in the logs: exit code 143, `shutdown: all Zeebe
jobs drained`, and for the importers `Consumer stopped` after the last commit.

## Not covered

An OOM kill, a node crash or a drain that exceeds the grace period still leaves an activated job
that Zeebe re-offers. The only complete answer is an idempotency check inside the payment handler
(for mpesa, a Redis `SET NX` on the transaction id before the Safaricom call); proposed as a
follow-up ticket.
