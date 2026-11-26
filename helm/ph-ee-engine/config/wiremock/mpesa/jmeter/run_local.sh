#!/usr/bin/env bash
# Local version of the release pipeline's load test: run the plan, build JMeter's HTML
# dashboard, then cross-check the transactions against the operations app.
#
#   OPS_USERNAME=... OPS_PASSWORD=... ./run_local.sh            # or OPS_TOKEN=...
#   LOADTEST_DURATION_SECONDS=60 RECONCILE_WAIT_SECONDS=600 ./run_local.sh -JMTN_THREADS=0
#
# Extra arguments go straight to JMeter (any -J override from README.md).
# Exit code is reconcile_with_ops.py's: 0 all match, 1 needs attention, 2 could not check.
set -euo pipefail

LOADTEST_HOST="${LOADTEST_HOST:-paymenthub.qa.oneacrefund.org}"
LOADTEST_DURATION_SECONDS="${LOADTEST_DURATION_SECONDS:-300}"
RECONCILE_WAIT_SECONDS="${RECONCILE_WAIT_SECONDS:-900}"
RECONCILE_POLL_SECONDS="${RECONCILE_POLL_SECONDS:-30}"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

command -v jmeter >/dev/null || { echo "jmeter not found: brew install jmeter"; exit 2; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' \
  || { echo "python3 3.9+ needed (zoneinfo)"; exit 2; }

# Ask for credentials up front so the run doesn't stall on them afterwards.
if [ -z "${OPS_TOKEN:-}" ]; then
  [ -n "${OPS_USERNAME:-}" ] || read -rp "Ops username: " OPS_USERNAME
  [ -n "${OPS_PASSWORD:-}" ] || { read -rsp "Ops password: " OPS_PASSWORD; echo; }
  export OPS_USERNAME OPS_PASSWORD
fi

echo "Load test: $LOADTEST_HOST for ${LOADTEST_DURATION_SECONDS}s, output in $OUT"
cd "$HERE"
jmeter -n -t mpesa-scenario-load-test.jmx \
  -l "$OUT/results.jtl" \
  -j "$OUT/jmeter.log" \
  -e -o "$OUT/report" \
  -JHOST="$LOADTEST_HOST" \
  -JDURATION_SECONDS="$LOADTEST_DURATION_SECONDS" \
  -JMANIFEST_FILE="$OUT/transactions-manifest.csv" \
  "$@"

set +e
python3 -u reconcile_with_ops.py "$OUT/transactions-manifest.csv" \
  --wait-seconds "$RECONCILE_WAIT_SECONDS" \
  --poll-seconds "$RECONCILE_POLL_SECONDS" \
  --details-out "$OUT/needs-attention.csv" | tee "$OUT/reconcile.out"
RC=${PIPESTATUS[0]}
set -e

echo
echo "JMeter dashboard:  $OUT/report/index.html"
echo "Cross-check:       $OUT/reconcile.out"
echo "Needs attention:   $OUT/needs-attention.csv"
[ "$(uname)" = Darwin ] && open "$OUT/report/index.html"
exit $RC
