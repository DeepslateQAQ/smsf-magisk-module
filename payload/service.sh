#!/system/bin/sh
# service.sh - late_start service: bring the forwarder up (also in BFU/direct boot).

MODDIR=${0%/*}
DATA=${SMSF_DATA:-/data/adb/smsf}

# Keep the supervisor alive across this script exiting; it handles its own
# restarts and waits for sys.boot_completed / the telephony provider itself.
if [ -x "$DATA/bin/smsfw" ]; then
    "$DATA/bin/smsfw" start >/dev/null 2>&1
else
    echo "smsf_webhook: $DATA/bin/smsfw missing, module not installed correctly" >> "$DATA/log/smsfwd.log" 2>/dev/null
fi
