#!/system/bin/sh
# customize.sh - Magisk/KernelSU/APatch installer for smsf_webhook.

SKIPUNZIP=0

# SMSF_DATA is only set when testing this installer on a desktop; on device the
# standard layout under /data/adb is used.
DATA=${SMSF_DATA:-/data/adb/smsf}
BIN_DIR=$DATA/bin
LIB_DIR=$DATA/lib
APP_PROCESS=${SMSF_APP_PROCESS:-/system/bin/app_process}
DALVIKVM=${SMSF_DALVIKVM:-/system/bin/dalvikvm}

ui_print " "
ui_print "****************************************"
ui_print "  SMS Webhook Forwarder $(sed -n 's/^version=//p' "$MODPATH/module.prop")"
ui_print "  root-based, app-free, BFU-safe"
ui_print "****************************************"
ui_print " "

mkdir -p "$DATA" "$BIN_DIR" "$LIB_DIR" "$DATA/state" "$DATA/queue" \
         "$DATA/failed" "$DATA/tmp" "$DATA/log" 2>/dev/null
chmod 700 "$DATA" 2>/dev/null

# --- runtime code (replaced on every install/update) ------------------------
cp -f "$MODPATH/bin/"* "$BIN_DIR/" 2>/dev/null
cp -f "$MODPATH/lib/"* "$LIB_DIR/" 2>/dev/null
chmod 755 "$BIN_DIR/"* 2>/dev/null
chmod 644 "$LIB_DIR/"* 2>/dev/null

# --- user config (never overwritten once it exists) -------------------------
for f in config.conf template.json headers.txt; do
    if [ ! -f "$DATA/$f" ]; then
        cp -f "$MODPATH/config/$f" "$DATA/$f" 2>/dev/null
        ui_print "- installed default $f"
    else
        ui_print "- kept existing $f"
    fi
done
chmod 600 "$DATA/config.conf" 2>/dev/null
[ -f "$DATA/secret" ] && chmod 600 "$DATA/secret"

# --- version stamps ---------------------------------------------------------
VERSION=$(sed -n 's/^version=//p' "$MODPATH/module.prop" | head -n 1)
printf '%s' "$VERSION" > "$DATA/version"

# Probe the DEX payload now so a broken transport is visible in the install log.
PAYLOAD_PROBED=""
if [ -f "$LIB_DIR/smsfw.jar" ]; then
    PAYLOAD_PROBED=$(CLASSPATH="$LIB_DIR/smsfw.jar" "$APP_PROCESS" /system/bin \
        com.smsfw.Main version 2>/dev/null | head -n 1)
    if [ -z "$PAYLOAD_PROBED" ]; then
        PAYLOAD_PROBED=$("$DALVIKVM" -cp "$LIB_DIR/smsfw.jar" com.smsfw.Main version 2>/dev/null | head -n 1)
    fi
fi

if [ -n "$PAYLOAD_PROBED" ]; then
    PAYLOAD_VERSION="$PAYLOAD_PROBED"
    ui_print "- payload $PAYLOAD_VERSION ready"
elif [ "$BOOTMODE" = "true" ]; then
    PAYLOAD_VERSION="$VERSION"
    ui_print "- WARNING: app_process/dalvikvm could not run the payload."
    ui_print "  If pushes fail after reboot, run: $BIN_DIR/smsfw doctor"
else
    PAYLOAD_VERSION="$VERSION"
    ui_print "- payload not probed (recovery install), verified on boot"
fi
printf '%s' "$PAYLOAD_VERSION" > "$DATA/payload.version"

# The module dir keeps only the lifecycle scripts; the runtime lives in $DATA.
rm -rf "${MODPATH:?}/bin" "${MODPATH:?}/lib" "${MODPATH:?}/config" 2>/dev/null

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
# systemless CLI: mounted into /system/bin by Magic Mount / KernelSU overlay
if [ -f "$MODPATH/system/bin/smsfw" ]; then
    set_perm "$MODPATH/system/bin/smsfw" 0 0 0755
fi

ui_print " "
ui_print "- Configure and test:"
ui_print "    smsfw wizard        # interactive setup (available after reboot)"
ui_print "    $BIN_DIR/smsfw wizard   # ... or right now via the absolute path"
ui_print "- The daemon starts automatically on boot (also before first unlock)."
ui_print "- Verbose help: smsfw help"
ui_print " "
