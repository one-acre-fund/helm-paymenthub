# Kafka: spotify/kafka → apache/kafka 4.3.1 (KRaft)

Ported to the develop chart layout (`templates/dev-kafka.yaml`, values under `kafka`) on 2026-10-12; originally kafka subchart 2.0.0 on master, 2026-10-10.

## Why

`spotify/kafka` is Kafka 0.10 with ZooKeeper bundled in the same container. It has had no release since 2017 and no security patches. Nothing outside the pod uses ZooKeeper, and the chart had no persistent volume, so there was nothing holding us to it.

| Option | Verdict |
|---|---|
| `apache/kafka` | **Chosen.** Published by the Kafka project on Docker Hub. Patch releases follow Kafka bugfix cadence (4.2.2 on 2026-09-28, 4.3.2 in RC). KRaft only, Java 17 runtime, runs as uid 1000. |
| `bitnami/kafka` | Rejected. Versioned tags were frozen in `bitnamilegacy` in September 2025 with no further updates; free tier is `latest` only. |
| `confluentinc/cp-kafka` | Rejected. Lags upstream, Confluent Community License, nothing we need beyond the Apache image. |
| ZooKeeper vs KRaft | KRaft. Kafka 4.x has removed ZooKeeper mode. Single combined broker+controller node, same topology as before (one pod). |

## What changed

- Image `apache/kafka:4.3.1`, KRaft combined mode. Port 2181 is gone; 9093 is the internal controller port.
- `ADVERTISED_HOST`/`ADVERTISED_PORT` are replaced by `KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://<kafka.advertised.host>:<kafka.advertised.port>`. The values keys under `kafka` are unchanged; new keys are `imageTag`, `nodePort`, `clusterId`, `heapOpts`, `persistence.*`, `podSecurityContext`, `extraEnvs`.
- `KAFKA_HEAP_OPTS` defaults to 512m (image default is 1G, which exceeded the previous memory limits).
- Opt-in persistence: `kafka.persistence.enabled=true` creates PVC `kafka-data` (2Gi default) mounted at `/var/lib/kafka/data`. Default stays `emptyDir`, so behaviour is unchanged unless you ask for it.
- TCP readiness/liveness probes on 9092. `strategy: Recreate` so a RWO volume can move between pods.
- Fixed a duplicate `resources` block that silently overrode the values-driven limits.

## Client compatibility

Kafka 4.0 brokers dropped protocol versions older than Kafka 2.1 (KIP-896). Every client in this stack is newer:

| Client | Library | Bootstrap | OK |
|---|---|---|---|
| Zeebe Kafka exporter (`ph-ee-exporter`) | `kafka-clients 2.4.0` | hard-coded `kafka:9092`, creates topic `zeebe-export` (1 partition, RF 1) via AdminClient | yes |
| `ph-ee-importer-rdbms` | `spring-kafka 2.3.5`, `kafka-streams 2.3.1` | `kafka.brokers: kafka:9092` | yes |
| `ph-ee-importer-es` | same | same | yes |

No chart passes a bootstrap address to any of them; they rely on the Service name `kafka` and port 9092, both unchanged. Verified on minikube against the new broker with the stock Kafka 2.4.0 and 2.3.1 CLI tools (the `kafka_2.12-<version>.tgz` tarballs from archive.apache.org, run from an `eclipse-temurin:11-jre` pod): `kafka-broker-api-versions`, AdminClient topic creation, produce and consume all succeeded for both versions.

## Cutover

1. **No data migration.** The old deployment had no volume; topics were already lost on every restart. The exporter recreates `zeebe-export` when Zeebe starts; importers pick up from their group offsets.
2. Deploy to non-prod first with `kafka.persistence.enabled=false`. Helm replaces the Deployment in place (same name, same Service).
3. Restart the Zeebe broker once Kafka is Ready so the exporter reconnects and recreates the topic. Spring consumers reconnect on their own.
4. Check: `kubectl exec deploy/kafka -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list` shows `zeebe-export`; importer logs show partition assignment; one end-to-end payment lands via `importer_rdbms`.
5. Optionally enable persistence in prod after non-prod is green. Size from observed usage (`du -sh /var/lib/kafka/data` after a week on emptyDir); expand the PVC later rather than over-provisioning.

## Rollback

On this chart Kafka is the `templates/dev-kafka.yaml` template of `ph-ee-engine`, so a rollback is a `helm rollback` of the whole `ph` release (or re-deploying the previous chart version). The notes below were written for the kafka subchart on master and apply unchanged to the Deployment and PVC.

- `helm rollback <release> <previous-revision>`. Templates and values roll back together; the `spotify/kafka` Deployment returns. Data loss on rollback equals today's loss on any restart.
- PVC `kafka-data` carries `helm.sh/resource-policy: keep`, so neither rollback nor uninstall deletes it (without the annotation Helm removes it on rollback, because the previous revision has no PVC; this was observed in the rehearsal). The old image never mounts it; delete it by hand when it is no longer wanted.
- Rehearsed on minikube 2026-10-10: install chart 1.0.0 (`spotify/kafka`), `helm upgrade` to 2.0.0 with persistence, create topic, `helm rollback` to revision 1. Deployment returned to `spotify/kafka` and rolled out; history shows revision 3 deployed as `kafka-1.0.0`.

## Monitoring

This chart adds TCP probes only. Kafka metrics (JMX / `kafka-exporter` ServiceMonitor) are tracked in the monitoring ticket (Epic 1, Ticket 3). Until then, health is: pod Ready, topic listing works, importer logs show assignments.

## Out of scope

Multi-broker clusters, SASL/TLS listeners, removing the NodePort Service type, and the unused `role.yaml`/`rolebinding.yaml` templates.
