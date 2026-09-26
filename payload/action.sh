#!/system/bin/sh
# action.sh - Magisk "Action" button: status + live webhook test.

DATA=${SMSF_DATA:-/data/adb/smsf}
[ -x "$DATA/bin/smsfw" ] || { echo "smsf_webhook is not installed correctly"; exit 1; }

"$DATA/bin/smsfw" status
echo
echo "--- test webhook ---"
"$DATA/bin/smsfw" test
