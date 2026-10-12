#!/usr/bin/env bash
# Manually simulate the asynchronous callback Airtel POSTs to the registered callback URL
# once a customer approves (or rejects) a collection request on their phone.
#
# The paymenthub-wiremock stub (airtel-02-collection-request.json) already fires this
# automatically, via a WireMock webhook, a few seconds after every collection request — so
# under normal testing you don't need this script. It exists for replaying a callback by
# hand: to test a specific status/message, to re-send a callback that arrived before the
# connector was ready for it, or to test the connector's /collections/callback endpoint
# directly without the wiremock stack running at all.
#
# Usage:
#   ./simulate-airtel-callback.sh <callback-url> <transaction-id> [status-code] [message] [airtel-money-id]
#
# <transaction-id> is what the connector correlates on — it must match the transaction.id
# sent in the collection request body (the payment hub transactionId), which is also the
# key Airtel's payment enquiry endpoint is looked up by.
#
# Example (port-forward the connector first: kubectl port-forward svc/ph-ee-connector-airtel 5000:80):
#   ./simulate-airtel-callback.sh http://localhost:5000/collections/callback oaf-e355071b6187HcEbkCLa TS
#
# Example simulating a failed payment (no airtel_money_id, matching what Airtel sends for a
# TF status) — the message below is picked automatically from the status code (see the case
# statement); pass it explicitly as the 4th argument for anything else:
#   ./simulate-airtel-callback.sh http://localhost:5000/collections/callback oaf-e355071b6187HcEbkCLa TF

set -euo pipefail

CALLBACK_URL="${1:?Usage: $0 <callback-url> <transaction-id> [status-code] [message] [airtel-money-id]}"
TRANSACTION_ID="${2:?Missing transaction-id (the transaction.id sent in the collection request body)}"
STATUS_CODE="${3:-TS}"
MESSAGE_OVERRIDE="${4:-}"
AIRTEL_MONEY_ID="${5:-MP${TRANSACTION_ID}}"

# Airtel's transaction status codes: TS = success, TF = failed, TA = ambiguous,
# TIP = in progress. The connector only branches on TS and TF — anything else leaves the
# transaction pending, to be resolved by a later payment enquiry.
case "$STATUS_CODE" in
  TS) MESSAGE="Paid RWF 250 to One Acre Fund." ;;
  TF) MESSAGE="Transaction Failed. Not enough balance" ;;
  TA) MESSAGE="Transaction is ambiguous" ;;
  *)  MESSAGE="Transaction is in progress" ;;
esac
if [ -n "$MESSAGE_OVERRIDE" ]; then
  MESSAGE="$MESSAGE_OVERRIDE"
fi

EXTRA=""
if [ "$STATUS_CODE" = "TS" ]; then
  EXTRA=",
    \"airtel_money_id\": \"${AIRTEL_MONEY_ID}\""
fi

BODY=$(cat <<EOF
{
  "transaction": {
    "id": "${TRANSACTION_ID}",
    "message": "${MESSAGE}",
    "status_code": "${STATUS_CODE}"${EXTRA}
  },
  "hash": "mock-hash-not-a-real-hmac"
}
EOF
)

echo "POST ${CALLBACK_URL}"
echo "${BODY}"
echo
curl -sS -X POST "${CALLBACK_URL}" -H "Content-Type: application/json" -d "${BODY}"
echo
