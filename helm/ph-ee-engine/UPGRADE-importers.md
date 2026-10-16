# Importers: horizontal scaling (FD-1931)

Chart `ph-ee-engine` on `develop`, 2026-10-13. Built on top of the Kafka 4.3.1 change (FD-1928, `UPGRADE-kafka.md`), which is already deployed to acc-qa. Full plan with diagrams: `.claude/plans/2026-10-10-importer-horizontal-scaling.html` (not committed).

## Root cause of the scaling limitation

Verified in acc-qa and acc-prod on 2026-10-10.

1. **Each pod was its own consumer group.** Both importers set `group.id` to the pod hostname, so a second replica would read every record again instead of sharing the work. A side effect: every restart created a new group starting from `latest`, so records produced while the pod was down were skipped.
2. **The topic has one partition.** The Zeebe Kafka exporter creates `zeebe-export` with one partition. A consumer group can run at most one active consumer per partition, so two of the three consumer threads in each pod were idle.
3. **The message key did not preserve per-instance order.** The exporter keyed messages by `partitionId-position`, unique per record. With more partitions, records of one process instance would scatter across pods and the rdbms importer would see them out of order.
4. **Writes were not safe under concurrency or replay.** rdbms: no unique keys on the business columns, per-pod in-memory entity caches, database errors swallowed (offset committed anyway), batch CSV rows re-inserted on replay. es: documents are idempotent by id, but the poll batch was committed before its bulk was flushed, so a kill lost up to one bulk.

## What changed

Importer images (`ph-ee-importer-rdbms` 1.2.0-mifos-1.3.1, `ph-ee-importer-es` 1.1.0):

- Fixed consumer groups `ph-ee-importer-rdbms` and `ph-ee-importer-es` (env `KAFKA_CONSUMER_GROUP`), consumer threads per pod via `KAFKA_CONCURRENCY` (default 3), brokers via `KAFKA_BROKERS`, topic via `IMPORTER_KAFKA_TOPIC`.
- rdbms: in-memory caches are cleared when partitions are revoked and after a failed write; database errors propagate so the record is re-polled (fixed back-off, 10 attempts); batch CSV expansion skips rows already imported; unique keys on `(WORKFLOW_INSTANCE_KEY, ZEEBE_GENERATION, …)`. Existing schemas need `db/FD-1931-unique-keys.sql` from the importer repo, run once per tenant schema.
- rdbms: a redelivered record for an instance that is already completed (Kafka at-least-once after a pod kill or rebalance) reuses the completed row instead of opening a new `ZEEBE_GENERATION`. The check compares the record timestamp with `COMPLETED_AT` at second granularity, because that column is a DATETIME without fractional seconds and MySQL rounds on insert. Without this, the first kill test produced 357 extra transfer rows.
- es: batch listener, one poll is one bulk, flushed before the batch offsets are committed.
- Both: a sink failure (database error, failed bulk) is retried without limit, so the partition stalls and lag grows instead of the record being skipped. Found on 2026-10-13 when a disk-full Elasticsearch rejected bulks for 12 minutes: with the earlier ten-attempt budget 2,602 of 144,000 records were dropped. Malformed records are still logged and skipped (es) or swallowed (rdbms) so they cannot block a partition.
- rdbms: `transfers`, `transaction_requests` and `batches` carry an optimistic lock (`VERSION` column, JPA `@Version`). The importer keeps entities in memory between records and saves them with a merge; with the EclipseLink shared cache off, a stale copy held by a second pod (a consumer fenced mid-batch during a rebalance still finishing its writes) overwrote newer columns. Seen once in 36,000 transfers under node pressure: `TRANSACTION_ID` lost after a pod was OOM-killed. A version mismatch now fails the save, the caches are cleared and the record is re-polled. The inflight managers keep the instance returned by `save()`, because the merge leaves the passed object's version untouched.
- rdbms (review follow-ups, 2026-10-16): routing state no longer lives only in one pod. Process definition to `bpmnProcessId` mappings from DEPLOYMENT records are stored in `tenants.process_definitions` (`db/FD-1931-tenants-db.sql`, also created by the importer DDL on startup) and a record that still cannot be routed is retried instead of parked in memory; call-activity child to parent links are stored in `call_activity_links` (created by `db/FD-1931-unique-keys.sql`); batch completion falls back to the batch row for `REQUEST_FILE` and `BATCH_ID`; a replayed record is matched to the generation that was running at its timestamp; variable history row and entity update share one transaction; `transfers` gets a generated `TRANSFER_KEY` column (`IFNULL(TRANSACTION_ID, IF(BATCH_ID IS NULL, '', NULL))`) so an ordinary transfer that has no transaction id yet still has a unique identity, which MySQL cannot enforce on a nullable column. Needs MySQL 5.7.6 or later (acc-qa runs 5.7.43).

Chart (`values.yaml`, `importer_rdbms.*` and `importer_es.*`):

- `kafka.*` and `autoscaling.*` blocks under each importer. Env wired into `templates/operations-importer-rdbms.yaml` and `templates/operations-importer-es.yaml`. `terminationGracePeriodSeconds: 60`, rolling update with `maxSurge 1 / maxUnavailable 0`.
- `autoscaling.enabled=true` renders a KEDA `ScaledObject` (kafka trigger on consumer-group lag, `lagThreshold` 1000, min 1, max 6, `allowIdleConsumers=false`) and a `PodDisruptionBudget` (`maxUnavailable 1`) from `templates/operations-importer-scaledobject.yaml`, and stops rendering `replicas`. Default is off, so a plain upgrade changes nothing but the group id.
- Zeebe env `ZEEBE_KAFKAEXPORT_URL/TOPIC/TOPIC_PARTITIONS=6/TOPIC_REPLICATION_FACTOR=1` for an env-configured exporter build (openMF/ph-ee-exporter v1.13.3 or later). The exporter jar itself must also be rebuilt so the message key is the process instance key (`extractKafkaKey` from upstream v8.4.0-1.3); the jar currently served from this repo (`exporter-1.1.0-SNAPSHOT.jar`) ignores these env vars and keeps one partition.
- Kafka (`templates/dev-kafka.yaml`): `kafka.numPartitions: 6` (`KAFKA_NUM_PARTITIONS`), so a topic created before the exporter passes an explicit count still gets six partitions (an importer's metadata request auto-creates it with the broker default otherwise, which happened in the minikube test). A bare `kafka.advertised.host` is now advertised as `kafka.<namespace>.svc.cluster.local`, because the KEDA scaler runs in another namespace and must be able to follow the broker metadata. In-namespace clients resolve both names, so the importers and Zeebe are unaffected.
- ScaledObject `bootstrapServers` defaults to `kafka.<release namespace>.svc.cluster.local:9092` (`autoscaling.bootstrapServers` overrides it). The bare `kafka:9092` the importers use does not resolve from the `keda` namespace; KEDA reported `lookup kafka: no such host` until this was changed.

## Cutover

1. Merge and deploy the chart first; with `autoscaling.enabled=false` and the old image tags it is inert. Then run `db/FD-1931-unique-keys.sql` in every tenant schema (review the duplicate SELECTs it prints first) and `db/FD-1931-tenants-db.sql` once against the tenants database. It also adds the `VERSION BIGINT NOT NULL DEFAULT 0` columns; run it before the 1.2.0 image starts so existing rows read as version 0 rather than NULL.
2. Deploy the new importer images with `autoscaling.enabled=false`. The fixed group ids have no committed offsets yet and both importers default to `auto.offset.reset=earliest`, so the first start replays the retained topic (idempotent: unique keys and redelivery matching in rdbms, record-derived document ids in Elasticsearch). Expect lag and load for a while; with `latest` the records exported during the rollout window would be skipped instead. To avoid the replay, copy the old hostname groups' committed offsets to `ph-ee-importer-rdbms` and `ph-ee-importer-es` with `kafka-consumer-groups.sh --reset-offsets --to-offset` before scaling the new image up. After that, offsets persist across restarts, so a restart resumes where it stopped. The offset reset, retry pause and poll timeout are importer settings (`kafka.auto-offset-reset`, `kafka.retry-backoff-ms` 1000, `kafka.poll-timeout-ms` 3000) with defaults baked into the images; the chart does not pass them as env yet, add them to the importer templates if they ever need tuning per environment.
3. Deploy the rebuilt exporter jar and the `ZEEBE_KAFKAEXPORT_*` env, restart the Zeebe brokers. Kafka uses `emptyDir` by default, so the topic is recreated with 6 partitions on the next Kafka restart; with persistence on, run `kafka-topics.sh --alter --topic zeebe-export --partitions 6` once instead.
4. Check importer logs show `partitions assigned` spread over the pods, and `kafka-consumer-groups.sh --describe --group ph-ee-importer-rdbms` lists 6 partitions.
5. Set `importer_rdbms.autoscaling.enabled=true` and `importer_es.autoscaling.enabled=true` (KEDA must be installed in the cluster; acc-qa has 2.20.1).
6. Load test, then kill one pod of each importer during load. Expect: no duplicate `(WORKFLOW_INSTANCE_KEY, ZEEBE_GENERATION, TRANSACTION_ID)` in `transfers`, Elasticsearch `_count` on `zeebe-record_*` equals records produced, lag returns to 0, replicas return to 1 after the cooldown.

## Verified on minikube (2026-10-10)

Standalone namespace with Kafka 4.3.1 (6-partition topic), MySQL 8, Elasticsearch 7.17.3, KEDA 2.20.1, the two importer images built from the FD-1931 branches, and synthetic `zeebe-export` records keyed by process instance (4 records per instance).

| Check | Result |
|---|---|
| 2 replicas each, consumer groups | 6 members per group (2 pods x 3 threads), one partition each, split across the pods |
| 12,000 records (3,000 instances) | transfers 3,000, variables 6,000, ES docs 12,000, payments 3,000; no duplicate keys; no errors |
| Force-kill one pod of each importer during the next 12,000 records | counts exact (6,000 / 12,000 / 24,000 / 6,000); 296 redelivered records reused their rows; no new generations; no errors |
| Full replay of the first 12,000 records | counts unchanged; 2,695 redeliveries reused rows, 5,392 variable inserts skipped; no errors |
| KEDA, 120,000 records, `lagThreshold 1000` | both deployments scaled from 1 to the configured maximum within a minute of the lag appearing; rdbms drain rate roughly tripled with 3 pods; both scaled back to 1 about 5 minutes after lag reached 0 (cooldown 300 s) |
| `autoscaling.enabled=false` | ScaledObject, HPA and PDB removed, `replicas` rendered again |

minikube could not run six JVMs per importer at the default requests (node out of memory, pods Pending or slow to start), so the KEDA run was capped at `maxReplicas 3` with lower requests. Size requests and limits per environment before raising `maxReplicas`.

## Verified on minikube with the develop layout (2026-10-13)

Same namespace, rebuilt with the flat `develop` templates (`templates/dev-kafka.yaml`, `templates/operations-importer-*.yaml`, `templates/operations-importer-scaledobject.yaml`) rendered from this chart with a values override, instead of the master-layout subcharts.

| Check | Result |
|---|---|
| Topic auto-created by the importers against the develop Kafka template | 6 partitions (`KAFKA_NUM_PARTITIONS`), one per consumer thread, split across the pods |
| 12,000 records, 2 replicas each | all counts exact, 0 duplicate keys, 0 errors |
| Force-kill during the next 12,000 | counts exact (6,000 / 12,000 / 24,000 / 6,000), 0 duplicates, 0 errors |
| KEDA on, 120,000 records | both deployments scaled 1 to 3 within two minutes of the lag appearing; the node then ran out of memory (six importer JVMs plus Kafka, MySQL and Elasticsearch in a 7.5 GiB VM), one pod of each importer was OOM-killed, Kafka's liveness probe failed and the node went NotReady for minutes. Kafka's emptyDir survived the container restart, no record was lost on the topic. |
| Same run, defects | Elasticsearch hit its disk flood-stage watermark (host disk 95% full) and the es importer dropped 2,602 records after its retry budget; one transfer lost `TRANSACTION_ID` to a stale write from the OOM-killed pod. Both fixed (see above). |
| Full replay of all 144,000 records from offset 0 on the fixed images, 2 replicas each | transfers 36,000, variables 72,000, ES docs 144,000, payments 36,000; 0 duplicate keys; every transfer completed with its transaction id; 0 optimistic-lock retries; 0 errors |
| KEDA with the develop `ScaledObject` template, max 2 | 1 replica at lag 0; 2 replicas within a minute of a 12,000-record replay; counts unchanged (idempotent); back to 1 after the HPA window. `autoscaling.enabled=false` removed ScaledObjects and PDBs and rendered `replicas` again |

## Verified on minikube after the review follow-ups (2026-10-16)

rdbms image rebuilt from the review fixes, es image from the batch-scoped bulk change. MySQL 8.0.43 in the cluster, QA runs 5.7.43 (generated columns exist since 5.7.6).

| Check | Result |
|---|---|
| `db/FD-1931-unique-keys.sql` on a copy of the pre-1.2.0 tables with fixture duplicates | Reports and removes NULL-id duplicates of ordinary transfers, keeps two CSV rows without a request id, adds `VERSION`, `TRANSFER_KEY`, all unique keys and `call_activity_links`; a second NULL-id row for the same instance is rejected (`Duplicate entry '1-0-'`), a second CSV row without an id is accepted; `db/FD-1931-tenants-db.sql` creates `process_definitions`. Pass. |
| Tenant schema rebuilt through the real migration, full replay of 156,000 records from offset 0, 2 replicas each | 36,000 transfers, 0 duplicates, 36,000 completed with their transaction id, 72,000 variables, 144,000 Elasticsearch docs, 36,000 payments; `TRANSFER_KEY` equals the transaction id on every row, versions 4 to 6; no skipped records in the rotated container logs, only APM errors. One rdbms pod was OOM-killed once and the Kafka pod restarted once under load during the run; the counts are still exact. Pass. |
| Unroutable record (VARIABLE without `bpmnProcessId`, unknown `processDefinitionKey`) | The owning partition holds with lag 1 and `is not registered yet` retries about once a second; after `INSERT INTO tenants.process_definitions` the partition drains and the transfer row appears. Pass. |
| es-only replay from offset 0 on the batch-scoped bulk image, 2 replicas | 156,002 records in about two minutes, 144,001 `zeebe-record` docs, 36,002 payments, 0 retried batches, 0 skipped records. Pass. |
| Document Elasticsearch rejects for good (string `key` against the `long` mapping) | Logged once as `rejected document … with BAD_REQUEST, dropping it`, the rest of the batch committed, the group kept moving. Pass. |
| Unit tests | rdbms 86 (1 pre-existing skip), es 9. |

## Rollback

- Autoscaling misbehaves: `autoscaling.enabled=false`, redeploy. ScaledObject and PDB are removed, `replicas: 1` is rendered again.
- Importer image misbehaves: roll the tag back. The old image uses hostname group ids again (today's behaviour, including the restart gap).
- Exporter misbehaves: point the init container at the old jar and restart Zeebe. The topic keeps 6 partitions; record-id keys are harmless with one importer replica.
- Unique key blocks writes: drop the key, merge the rows, re-add.

## Monitoring

Lag is visible through the ScaledObject status (`kubectl get scaledobject`) and the importer logs. A Prometheus `kafka-exporter` with a Grafana panel belongs to the monitoring ticket.

## Out of scope

Multi-broker Kafka, the upstream `dev` branch rewrite of importer-rdbms, call-activity BPMN flows (none deployed today; their child records would need keying by root instance).
