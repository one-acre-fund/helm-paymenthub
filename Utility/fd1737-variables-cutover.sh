#!/usr/bin/env bash
# FD-1737: swap one tenant's variables table for the partitioned variables_new created by the operations-app
# migration V56. Rehearsed on minikube (helm-paymenthub .claude/plans/2026-11-04-fd1737-*.html, appendix C).
# Everything is printed before it runs; without --execute nothing is changed. Needs only MySQL access: the
# importer keeps running throughout, nothing in Kubernetes is touched.
#
# Steps, per tenant:
#   1. preflight    variables_new exists, is empty and partitioned; a partition covers the retention cutoff
#   2. copy         rows of the last N months into variables_new, by ID range, importer writing meanwhile
#   3. tail         rows written during step 2, seconds
#   4. swap         AUTO_INCREMENT of variables_new = MAX(ID) + GAP, then the atomic RENAME. RENAME waits for open
#                   importer transactions on the old table, and every later write goes to the new table.
#   5. stragglers   rows that reached the old table between steps 3 and 4 are copied over; the GAP keeps their
#                   IDs clear of the ones the importer hands out after the swap. Row counts are checked.
# Afterwards: archive variables_old with the "archive-old" command, then DROP TABLE variables_old by hand.
#
# Usage:
#   MYSQL="mysql --defaults-extra-file=qa.cnf -h 127.0.0.1 -P 33306" \
#   Utility/fd1737-variables-cutover.sh cutover kenya [--months 12] [--chunk 1000000] [--execute]
#   Utility/fd1737-variables-cutover.sh archive-old kenya --out ./archive [--chunk 5000000] [--execute]
#
# Progress is kept in ./fd1737-<tenant>.state, so an interrupted copy resumes where it stopped.
set -euo pipefail

MYSQL="${MYSQL:?set MYSQL to the mysql client command, e.g. mysql --defaults-extra-file=qa.cnf -h 127.0.0.1 -P 33306}"
# IDs left free above the old table's maximum for rows written between the tail copy and the RENAME
GAP="${GAP:-1000000}"
COLS='`ID`, `WORKFLOW_INSTANCE_KEY`, `WORKFLOW_KEY`, `ZEEBE_GENERATION`, `TIMESTAMP`, `NAME`, `VALUE`, `created_date`, `last_modified_date`, `created_by`, `last_modified_by`'

cmd="${1:-}"; tenant="${2:-}"
[ -n "$cmd" ] && [ -n "$tenant" ] || { sed -n '2,23p' "$0"; exit 1; }
shift 2
months=12; chunk=1000000; execute=0; out=./archive
while [ $# -gt 0 ]; do
  case "$1" in
    --months) months="$2"; shift 2 ;;
    --chunk) chunk="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --execute) execute=1; shift ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
state="./fd1737-${tenant}.state"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
q() { $MYSQL -D "$tenant" -N -B -e "$1"; }                 # read, always runs
x() { log "SQL: $1"; if [ $execute = 1 ]; then $MYSQL -D "$tenant" -N -B -e "$1"; else log "   (dry run)"; fi; }

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

cutover() {
  log "tenant $tenant, retention $months months, chunk $chunk, execute=$execute"
  # 1. preflight
  parts=$(q "SELECT PARTITION_NAME FROM INFORMATION_SCHEMA.PARTITIONS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'variables_new' AND PARTITION_NAME IS NOT NULL ORDER BY PARTITION_ORDINAL_POSITION" | tr '\n' ' ')
  [ -n "$parts" ] || { log "variables_new is missing or not partitioned: run the operations app with V56 first"; exit 1; }
  old_parts=$(q "SELECT COUNT(*) FROM INFORMATION_SCHEMA.PARTITIONS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'variables' AND PARTITION_NAME IS NOT NULL")
  [ "$old_parts" = 0 ] || { log "variables is already partitioned: cutover done before"; exit 1; }
  # transaction_requests_id is left out on purpose by V56: no entity maps it and it is NULL in every QA tenant
  cols() { q "SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY COLUMN_NAME) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '$1' AND COLUMN_NAME <> 'transaction_requests_id'"; }
  [ "$(cols variables)" = "$(cols variables_new)" ] || { log "columns differ (the operations app maps every column of variables): variables $(cols variables) / variables_new $(cols variables_new). Deploy the operations app with V57 first"; exit 1; }
  cutoff=$(q "SELECT CAST(UNIX_TIMESTAMP(DATE_FORMAT(DATE_SUB(UTC_DATE(), INTERVAL $months MONTH), '%Y-%m-01')) * 1000 AS UNSIGNED)")
  cutoff_month=$(q "SELECT DATE_FORMAT(FROM_UNIXTIME($cutoff / 1000), 'p%Y_%m')")
  echo "$parts" | grep -q "$cutoff_month" || { log "no partition $cutoff_month in variables_new for the cutoff; shorten --months or add partitions"; exit 1; }
  log "partitions: $parts"
  log "retention cutoff $(q "SELECT FROM_UNIXTIME($cutoff / 1000, '%Y-%m-%d %H:%i:%s')") UTC ($cutoff), oldest kept partition $cutoff_month"
  max_id=$(q "SELECT COALESCE(MAX(ID), 0) FROM variables"); log "variables: MAX(ID) $max_id, AUTO_INCREMENT will be $((max_id + 1)) or higher"
  if [ -f "$state" ]; then
    start=$(cat "$state"); log "resuming after ID $start from $state"
  elif [ "$max_id" = 0 ]; then
    start=0; log "variables is empty, nothing to copy"
  else
    start=$(( $(first_id_at "$cutoff") - 1 )); log "first ID to copy: $((start + 1)) ($(( max_id - start )) IDs to walk)"
    new_rows=$(q "SELECT COUNT(*) FROM variables_new"); [ "$new_rows" = 0 ] || { log "variables_new holds $new_rows rows but no state file: clear it or restore $state"; exit 1; }
  fi
  # 2. copy while the importer runs
  copy_range "$start" "$max_id"
  # 3. tail
  tail_max=$(q "SELECT COALESCE(MAX(ID), 0) FROM variables"); log "tail: IDs $max_id..$tail_max"
  copy_range "$max_id" "$tail_max"
  # 4. swap; lock_wait_timeout bounds the wait for open importer transactions
  x "ALTER TABLE variables_new AUTO_INCREMENT = $((tail_max + GAP))"
  x "SET SESSION lock_wait_timeout = 60; RENAME TABLE variables TO variables_old, variables_new TO variables"
  # 5. stragglers
  x "INSERT INTO variables ($COLS) SELECT $COLS FROM variables_old WHERE ID > $tail_max; SELECT CONCAT(ROW_COUNT(), ' straggler rows copied')"
  if [ $execute = 1 ]; then
    expect=$(q "SELECT COUNT(*) FROM variables_old WHERE ID > $start")
    got=$(q "SELECT COUNT(*) FROM variables WHERE ID < $((tail_max + GAP))")
    [ "$expect" = "$got" ] || { log "ROW COUNT MISMATCH after the swap: variables_old (ID > $start) $expect, variables (ID < $((tail_max + GAP))) $got. Rerun the straggler INSERT above for the missing IDs."; exit 1; }
    log "row counts match: $got rows from the old table, new rows start at ID $((tail_max + GAP))"
    rm -f "$state"
  fi
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
      { echo "ID,WORKFLOW_INSTANCE_KEY,WORKFLOW_KEY,ZEEBE_GENERATION,TIMESTAMP,NAME,VALUE,created_date,last_modified_date,created_by,last_modified_by"
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
