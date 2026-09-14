#!/usr/bin/env bash
# Manually simulate the asynchronous STK Push callback Safaricom sends once a customer
# completes (or rejects) a buygoods payment on their phone.
#
# The paymenthub-wiremock stub (mpesa-02-stk-push-initiate.json) already fires this automatically,
# via a WireMock webhook, a few seconds after every STK push initiate request — so under
# normal testing you don't need this script. It exists for replaying a callback by hand:
# to test a specific ResultCode (e.g. insufficient funds, user cancelled), to re-send a
# callback that arrived before the connector was ready for it, or to test the connector's
# /buygoods/callback endpoint directly without the wiremock stack running at all.
#
# Usage:
#   ./simulate-safaricom-callback.sh <callback-url> <checkout-request-id> [result-code] [amount] [phone-number] [mpesa-receipt-number]
#
# Example (port-forward the connector first: kubectl port-forward svc/ph-ee-connector-mpesa 5000:80):
#   ./simulate-safaricom-callback.sh http://localhost:5000/buygoods/callback ws_CO_20260831190500 0 250 254712345678 NLJ7RT61SV
#
# Example simulating a failed payment (no CallbackMetadata, matching what Safaricom sends
# for a non-zero ResultCode):
#   ./simulate-safaricom-callback.sh http://localhost:5000/buygoods/callback ws_CO_20260831190500 1032

set -euo pipefail

CALLBACK_URL="${1:?Usage: $0 <callback-url> <checkout-request-id> [result-code] [amount] [phone-number] [mpesa-receipt-number]}"
CHECKOUT_REQUEST_ID="${2:?Missing checkout-request-id (the CheckoutRequestID returned by the STK push initiate call)}"
RESULT_CODE="${3:-0}"
AMOUNT="${4:-250}"
PHONE_NUMBER="${5:-254712345678}"
MPESA_RECEIPT_NUMBER="${6:-NLJ7RT61SV}"

CALLBACK_METADATA=""
if [ "$RESULT_CODE" = "0" ]; then
  RESULT_DESC="The service request is processed successfully."
  CALLBACK_METADATA=$(cat <<EOF
,
      "CallbackMetadata": {
        "Item": [
          {"Name": "Amount", "Value": ${AMOUNT}},
          {"Name": "MpesaReceiptNumber", "Value": "${MPESA_RECEIPT_NUMBER}"},
          {"Name": "TransactionDate", "Value": $(date +%Y%m%d%H%M%S)},
          {"Name": "PhoneNumber", "Value": ${PHONE_NUMBER}}
        ]
      }
EOF
)
else
  RESULT_DESC="Request cancelled by user."
fi

BODY=$(cat <<EOF
{
  "Body": {
    "stkCallback": {
      "MerchantRequestID": "29115-34620561-1",
      "CheckoutRequestID": "${CHECKOUT_REQUEST_ID}",
      "ResultCode": ${RESULT_CODE},
      "ResultDesc": "${RESULT_DESC}"${CALLBACK_METADATA}
    }
  }
}
EOF
)

echo "POST ${CALLBACK_URL}"
echo "${BODY}"
echo
curl -sS -X POST "${CALLBACK_URL}" -H "Content-Type: application/json" -d "${BODY}"
echo
