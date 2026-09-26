#!/system/bin/sh
# uninstall.sh - stop the daemon; user config/state is intentionally preserved.

DATA=${SMSF_DATA:-/data/adb/smsf}

if [ -x "$DATA/bin/smsfw" ]; then
    "$DATA/bin/smsfw" stop >/dev/null 2>&1
else
    for f in "$DATA/state/daemon.pid" "$DATA/state/worker.pid"; do
        [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null
    done
fi
rm -f "$DATA/state/daemon.pid" "$DATA/state/worker.pid" 2>/dev/null
rm -rf "$DATA/tmp/"* 2>/dev/null

echo "smsf_webhook uninstalled."
echo "Configuration and queued messages were kept in $DATA."
echo "Remove them with: rm -rf $DATA"
