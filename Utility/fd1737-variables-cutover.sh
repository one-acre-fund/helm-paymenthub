#!/usr/bin/env bash
# FD-1737: swap one tenant's variables table for the partitioned variables_new created by the operations-app
# migration V56. Rehearsed on minikube 2026-11-07 (helm-paymenthub .claude/plans/2026-11-04-fd1737-*.html,
# appendix C). Everything is printed before it runs; without --execute nothing is changed.
#
# Steps, per tenant:
#   1. preflight    variables_new exists, is empty and partitioned; a partition covers the retention cutoff
#   2. copy         rows of the last RETENTION_MONTHS months into variables_new, by ID range, importer running
#   3. pause        importer-rdbms scaled to 0 (KEDA paused when a ScaledObject owns it)
#   4. tail         rows written since step 2, seconds
#   5. swap         AUTO_INCREMENT = MAX(ID)+1 of the old table (mandatory), RENAME both tables, verify counts
#   6. resume       importer back to its previous replicas
# Afterwards: archive variables_old with the "archive-old" command, then DROP TABLE variables_old by hand.
#
# Usage:
#   MYSQL="mysql --defaults-extra-file=qa.cnf -h 127.0.0.1 -P 33306" \
#   KUBECTL="kubectl --context acc-qa/eks-qa-01 -n paymenthub" \
#   Utility/fd1737-variables-cutover.sh cutover kenya [--months 12] [--chunk 1000000] [--execute]
#   Utility/fd1737-variables-cutover.sh archive-old kenya --out ./archive [--chunk 5000000] [--execute]
#
# A dormant tenant (oaf) needs no pause: run with --no-importer. Progress is kept in ./fd1737-<tenant>.state,
# so an interrupted copy resumes where it stopped.
set -euo pipefail

MYSQL="${MYSQL:?set MYSQL to the mysql client command, e.g. mysql --defaults-extra-file=qa.cnf -h 127.0.0.1 -P 33306}"
KUBECTL="${KUBECTL:-kubectl -n paymenthub}"
IMPORTER="${IMPORTER:-ph-ee-importer-rdbms}"
COLS='`ID`, `WORKFLOW_INSTANCE_KEY`, `WORKFLOW_KEY`, `ZEEBE_GENERATION`, `TIMESTAMP`, `NAME`, `VALUE`'

cmd="${1:-}"; tenant="${2:-}"
[ -n "$cmd" ] && [ -n "$tenant" ] || { sed -n '2,24p' "$0"; exit 1; }
shift 2
months=12; chunk=1000000; execute=0; no_importer=0; out=./archive
while [ $# -gt 0 ]; do
  case "$1" in
    --months) months="$2"; shift 2 ;;
    --chunk) chunk="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --execute) execute=1; shift ;;
    --no-importer) no_importer=1; shift ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
state="./fd1737-${tenant}.state"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
q() { $MYSQL -D "$tenant" -N -B -e "$1"; }                 # read, always runs
x() { log "SQL: $1"; if [ $execute = 1 ]; then $MYSQL -D "$tenant" -N -B -e "$1"; else log "   (dry run)"; fi; }
k() { log "kubectl: $*"; if [ $execute = 1 ]; then $KUBECTL "$@"; else log "   (dry run)"; fi; }

# first ID whose TIMESTAMP is >= $1, by binary search on the primary key (ID follows time, never a full scan)
first_id_at() {
  local cutoff=$1 lo hi mid ts
  lo=$(q "SELECT MIN(ID) FROM variables"); hi=$(q "SELECT MAX(ID) FROM variables")
  ts=$(q "SELECT \`TIMESTAMP\` FROM variables WHERE ID >= $lo ORDER BY ID LIMIT 1")
  [ "$ts" -ge "$cutoff" ] && { echo "$lo"; return; }
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    ts=$(q "SELECT \`TIMESTAMP\` FROM variables WHERE ID >= $mid ORDER BY ID LIMIT 1")
    if [ -z "$ts" ] || [ "$ts" -ge "$cutoff" ]; then hi=$mid; else lo=$mid; fi
  done
  echo "$hi"
}

copy_range() {  # copy_range FROM_EXCLUSIVE TO_INCLUSIVE
  local lo=$1 top=$2 hi n t0
  while [ "$lo" -lt "$top" ]; do
    hi=$((lo + chunk)); [ $hi -gt "$top" ] && hi=$top
    t0=$(date +%s)
    if [ $execute = 1 ]; then
      n=$(q "INSERT INTO variables_new ($COLS) SELECT $COLS FROM variables WHERE ID > $lo AND ID <= $hi; SELECT ROW_COUNT()")
      echo "$hi" > "$state"
      log "copied ID $lo..$hi: $n rows in $(( $(date +%s) - t0 )) s"
    else
      log "would copy ID $lo..$hi (dry run)"
    fi
    lo=$hi
  done
}

# KEDA owns the replica count when its HPA exists (readable without keda.sh rights); scaling the deployment
# by hand would be undone within seconds, so pause the ScaledObject instead.
keda_managed() { $KUBECTL get hpa "keda-hpa-$IMPORTER" >/dev/null 2>&1 || $KUBECTL get scaledobject "$IMPORTER" >/dev/null 2>&1; }

importer_pause() {
  [ $no_importer = 1 ] && { log "importer not touched (--no-importer)"; return; }
  if keda_managed; then
    k annotate scaledobject "$IMPORTER" autoscaling.keda.sh/paused-replicas=0 --overwrite 2>/dev/null || {
      # No keda.sh rights: carry on only if someone with them has already paused it.
      if [ $execute = 1 ] && [ "$($KUBECTL get deploy "$IMPORTER" -o jsonpath='{.spec.replicas}')" != 0 ]; then
        log "cannot pause the KEDA ScaledObject $IMPORTER (needs keda.sh rights). Nothing swapped; rerun resumes from $state."
        log "Ask someone with KEDA rights to run: kubectl annotate scaledobject $IMPORTER autoscaling.keda.sh/paused-replicas=0 --overwrite"
        exit 1
      fi
      log "importer already at 0 replicas, paused by someone with KEDA rights"; }
  else
    if [ $execute = 1 ]; then $KUBECTL get deploy "$IMPORTER" -o jsonpath='{.spec.replicas}' > "${state}.replicas"; fi
    k scale deploy "$IMPORTER" --replicas=0
  fi
  k wait --for=delete pod -l app="$IMPORTER" --timeout=180s
  if [ $execute = 1 ]; then
    sleep 30
    replicas=$($KUBECTL get deploy "$IMPORTER" -o jsonpath='{.spec.replicas}')
    [ "$replicas" = 0 ] || { log "importer came back to $replicas replicas, something else scales it. Nothing swapped."; importer_resume; exit 1; }
    log "importer paused and stayed at 0"
  fi
}

importer_resume() {
  [ $no_importer = 1 ] && return
  if keda_managed; then
    k annotate scaledobject "$IMPORTER" autoscaling.keda.sh/paused-replicas- 2>/dev/null ||
      log "importer still paused. To resume it, ask someone with KEDA rights to run: kubectl annotate scaledobject $IMPORTER autoscaling.keda.sh/paused-replicas-"
  else
    k scale deploy "$IMPORTER" --replicas="$(cat "${state}.replicas" 2>/dev/null || echo 1)"
  fi
}

cutover() {
  log "tenant $tenant, retention $months months, chunk $chunk, execute=$execute"
  # 1. preflight
  parts=$(q "SELECT PARTITION_NAME FROM INFORMATION_SCHEMA.PARTITIONS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'variables_new' AND PARTITION_NAME IS NOT NULL ORDER BY PARTITION_ORDINAL_POSITION" | tr '\n' ' ')
  [ -n "$parts" ] || { log "variables_new is missing or not partitioned: run the operations app with V56 first"; exit 1; }
  old_parts=$(q "SELECT COUNT(*) FROM INFORMATION_SCHEMA.PARTITIONS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'variables' AND PARTITION_NAME IS NOT NULL")
  [ "$old_parts" = 0 ] || { log "variables is already partitioned: cutover done before"; exit 1; }
  cutoff=$(q "SELECT CAST(UNIX_TIMESTAMP(DATE_FORMAT(DATE_SUB(UTC_DATE(), INTERVAL $months MONTH), '%Y-%m-01')) * 1000 AS UNSIGNED)")
  cutoff_month=$(q "SELECT DATE_FORMAT(FROM_UNIXTIME($cutoff / 1000), 'p%Y_%m')")
  echo "$parts" | grep -q "$cutoff_month" || { log "no partition $cutoff_month in variables_new for the cutoff; shorten --months or add partitions"; exit 1; }
  log "partitions: $parts"
  log "retention cutoff $(q "SELECT FROM_UNIXTIME($cutoff / 1000, '%Y-%m-%d %H:%i:%s')") UTC ($cutoff), oldest kept partition $cutoff_month"
  max_id=$(q "SELECT MAX(ID) FROM variables"); log "variables: MAX(ID) $max_id, AUTO_INCREMENT will be $((max_id + 1)) or higher"
  if [ -f "$state" ]; then
    start=$(cat "$state"); log "resuming after ID $start from $state"
  else
    start=$(( $(first_id_at "$cutoff") - 1 )); log "first ID to copy: $((start + 1)) ($(( max_id - start )) IDs to walk)"
    new_rows=$(q "SELECT COUNT(*) FROM variables_new"); [ "$new_rows" = 0 ] || { log "variables_new holds $new_rows rows but no state file: clear it or restore $state"; exit 1; }
  fi
  # 2. copy while the importer runs
  copy_range "$start" "$max_id"
  # 3. pause
  importer_pause
  # 4. tail
  tail_max=$(q "SELECT MAX(ID) FROM variables"); log "tail: IDs $max_id..$tail_max"
  copy_range "$max_id" "$tail_max"
  # 5. swap
  x "ALTER TABLE variables_new AUTO_INCREMENT = $((tail_max + 1))"
  if [ $execute = 1 ]; then
    expect=$(q "SELECT COUNT(*) FROM variables WHERE ID > $start"); got=$(q "SELECT COUNT(*) FROM variables_new")
    [ "$expect" = "$got" ] || { log "row count mismatch: variables (ID > $start) $expect, variables_new $got; importer stays paused, investigate"; exit 1; }
    log "row counts match: $got"
  fi
  x "RENAME TABLE variables TO variables_old, variables_new TO variables"
  # 6. resume
  importer_resume
  [ $execute = 1 ] && rm -f "$state"
  log "done. Next: archive-old, then DROP TABLE variables_old; enable operations_app.variablesRetention once every tenant is cut over"
}

# gzip CSV files of variables_old by ID range, for upload to s3://<export bucket>/variables-archive/<tenant>/.
# --raw keeps VALUE byte for byte (without it the client escapes backslashes); values are JSON, so they hold no raw newlines.
archive_old() {
  mkdir -p "$out"
  lo=$(( $(q "SELECT MIN(ID) FROM variables_old") - 1 )); top=$(q "SELECT MAX(ID) FROM variables_old")
  log "variables_old IDs $((lo + 1))..$top, files of $chunk IDs in $out"
  while [ "$lo" -lt "$top" ]; do
    hi=$((lo + chunk)); [ $hi -gt "$top" ] && hi=$top
    f="$out/variables_old-${tenant}-$(printf '%012d' $((lo + 1)))-$(printf '%012d' $hi).csv.gz"
    if [ $execute = 1 ]; then
      t0=$(date +%s)
      { echo "ID,WORKFLOW_INSTANCE_KEY,WORKFLOW_KEY,ZEEBE_GENERATION,TIMESTAMP,NAME,VALUE"
        $MYSQL -D "$tenant" -N -B --raw --quick -e "SELECT $COLS FROM variables_old WHERE ID > $lo AND ID <= $hi" \
          | python3 -c 'import sys,csv; w=csv.writer(sys.stdout, lineterminator="\n"); [w.writerow(l.rstrip("\n").split("\t")) for l in sys.stdin]'
      } | gzip -1 > "$f"
      log "wrote $f ($(du -h "$f" | cut -f1)) in $(( $(date +%s) - t0 )) s"
    else
      log "would write $f (dry run)"
    fi
    lo=$hi
  done
  log "upload with: aws s3 cp $out s3://<export bucket>/variables-archive/$tenant/ --recursive ; then DROP TABLE variables_old"
}

case "$cmd" in
  cutover) cutover ;;
  archive-old) archive_old ;;
  *) echo "unknown command $cmd"; exit 1 ;;
esac
