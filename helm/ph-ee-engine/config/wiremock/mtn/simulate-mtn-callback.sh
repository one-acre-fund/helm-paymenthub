#!/usr/bin/env bash
# Manually simulate the asynchronous MoMo Collection callback MTN POSTs to the
# X-Callback-Url once a customer approves (or rejects) a request-to-pay on their phone.
#
# The paymenthub-wiremock stub (mtn-02-request-to-pay.json) already fires this automatically,
# via a WireMock webhook, a few seconds after every request-to-pay — so under normal
# testing you don't need this script. It exists for replaying a callback by hand: to test
# a specific reason code, to re-send a callback that arrived before the connector was
# ready for it, or to test the connector's /buygoods/callback endpoint directly without
# the wiremock stack running at all.
#
# Usage:
#   ./simulate-mtn-callback.sh <callback-url> <external-id> [status] [reason] [amount] [currency] [msisdn] [financial-transaction-id]
#
# <external-id> is what the connector correlates on — it must match the externalId sent in
# the request-to-pay body (the payment hub transactionId), NOT the X-Reference-Id.
#
# Example (port-forward the connector first: kubectl port-forward svc/ph-ee-connector-ams-mtn-rw 5000:80):
#   ./simulate-mtn-callback.sh http://localhost:5000/buygoods/callback tx-0001 SUCCESSFUL
#
# Example simulating a failed payment (no financialTransactionId, matching what MTN sends
# for a non-SUCCESSFUL status) — the reason below is picked automatically from the status
# (see the case statement); pass it explicitly as the 4th argument for anything else:
#   ./simulate-mtn-callback.sh http://localhost:5000/buygoods/callback tx-0001 FAILED NOT_ENOUGH_FUNDS

set -euo pipefail

CALLBACK_URL="${1:?Usage: $0 <callback-url> <external-id> [status] [reason] [amount] [currency] [msisdn] [financial-transaction-id]}"
EXTERNAL_ID="${2:?Missing external-id (the externalId sent in the request-to-pay body)}"
STATUS="${3:-SUCCESSFUL}"
REASON_OVERRIDE="${4:-}"
AMOUNT="${5:-250}"
CURRENCY="${6:-RWF}"
MSISDN="${7:-250788111222}"
FINANCIAL_TRANSACTION_ID="${8:-1308275464}"

EXTRA=""
if [ "$STATUS" = "SUCCESSFUL" ]; then
  EXTRA=",
  \"financialTransactionId\": \"${FINANCIAL_TRANSACTION_ID}\""
else
  # Well-known MoMo Collection failure reasons (same set used by the wiremock stubs in
  # mappings/mtn-02-request-to-pay-callback-*.json). PENDING carries no reason at all.
  case "$STATUS" in
    FAILED)  REASON="INTERNAL_PROCESSING_ERROR" ;;
    PENDING) REASON="" ;;
    *)       REASON="INTERNAL_PROCESSING_ERROR" ;;
  esac
  if [ -n "$REASON_OVERRIDE" ]; then
    REASON="$REASON_OVERRIDE"
  fi
  if [ -n "$REASON" ]; then
    EXTRA=",
  \"reason\": \"${REASON}\""
  fi
fi

BODY=$(cat <<EOF
{
  "externalId": "${EXTERNAL_ID}",
  "amount": "${AMOUNT}",
  "currency": "${CURRENCY}",
  "payer": {
    "partyIdType": "MSISDN",
    "partyId": "${MSISDN}"
  },
  "payerMessage": "Payment for ${EXTERNAL_ID}",
  "payeeNote": "Payment for ${EXTERNAL_ID}",
  "status": "${STATUS}"${EXTRA}
}
EOF
)

echo "POST ${CALLBACK_URL}"
echo "${BODY}"
echo
curl -sS -X POST "${CALLBACK_URL}" -H "Content-Type: application/json" -d "${BODY}"
echo
