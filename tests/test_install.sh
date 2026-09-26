#!/usr/bin/env bash
# Installer test: runs payload/customize.sh and payload/uninstall.sh with the
# Magisk installer helpers stubbed out, then checks the on-device layout.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d /tmp/smsfw-install.XXXXXX)"
export SMSF_DATA="$TMP/data"
export SMSF_APP_PROCESS="$HERE/fake-android/app_process"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Magisk installer helpers (stubbed) + a fake module tree
cat > "$TMP/stubs.sh" <<'EOF'
ui_print() { echo "$*"; }
set_perm() { chmod "$4" "$1" 2>/dev/null; }
set_perm_recursive() {
    find "$1" -type d -exec chmod "$4" {} + 2>/dev/null
    find "$1" -type f -exec chmod "$5" {} + 2>/dev/null
}
EOF

MODPATH="$TMP/module"
mkdir -p "$MODPATH"
cp -r "$ROOT/payload/." "$MODPATH/"
export MODPATH BOOTMODE=true

run_script() { # SCRIPT
    bash -c '. "$1"; . "$2"' _ "$TMP/stubs.sh" "$1" 2>&1
}

echo "== installer tests =="

OUT="$(run_script "$MODPATH/customize.sh")"
check "installer exits 0" "$?" "0"
check "installer reports payload ready" "$(printf '%s' "$OUT" | grep -c 'payload .* ready')" "1"

check "bin installed" "$([ -x "$SMSF_DATA/bin/smsfw" ] && [ -x "$SMSF_DATA/bin/smsfwd" ] && [ -f "$SMSF_DATA/bin/common.sh" ] && echo yes || echo no)" "yes"
check "payload jar installed" "$([ -f "$SMSF_DATA/lib/smsfw.jar" ] && echo yes || echo no)" "yes"
check "config installed" "$([ -f "$SMSF_DATA/config.conf" ] && echo yes || echo no)" "yes"
check "config is private" "$(stat -c '%a' "$SMSF_DATA/config.conf")" "600"
check "template installed" "$([ -f "$SMSF_DATA/template.json" ] && echo yes || echo no)" "yes"
check "headers installed" "$([ -f "$SMSF_DATA/headers.txt" ] && echo yes || echo no)" "yes"
check "wizard installed" "$([ -f "$SMSF_DATA/bin/wizard.sh" ] && echo yes || echo no)" "yes"
check "i18n catalog installed" "$([ -f "$SMSF_DATA/bin/i18n.sh" ] && echo yes || echo no)" "yes"
check "systemless CLI shipped" "$([ -f "$MODPATH/system/bin/smsfw" ] && echo yes || echo no)" "yes"
check "systemless CLI executable" "$([ -x "$MODPATH/system/bin/smsfw" ] && echo yes || echo no)" "yes"
check "webui shipped" "$([ -f "$MODPATH/webroot/index.html" ] && [ -f "$MODPATH/webroot/style.css" ] && [ -f "$MODPATH/webroot/app.js" ] && echo yes || echo no)" "yes"
check "webui index references assets" "$([ "$(grep -c 'style.css' "$MODPATH/webroot/index.html")" -ge 1 ] && [ "$(grep -c 'app.js' "$MODPATH/webroot/index.html")" -ge 1 ] && echo yes || echo no)" "yes"
check "webui uses the ksu bridge" "$([ "$(grep -c 'kernelsu' "$MODPATH/webroot/app.js")" -ge 1 ] && echo yes || echo no)" "yes"
check "webui reads json status" "$([ "$(grep -c 'status --json' "$MODPATH/webroot/app.js")" -ge 1 ] && echo yes || echo no)" "yes"
check "version stamped" "$(cat "$SMSF_DATA/version")" "v1.0.0"
check "payload version stamped" "$(cat "$SMSF_DATA/payload.version")" "1.0.0"
check "runtime dirs created" "$([ -d "$SMSF_DATA/queue" ] && [ -d "$SMSF_DATA/state" ] && [ -d "$SMSF_DATA/log" ] && echo yes || echo no)" "yes"
check "module dir keeps lifecycle scripts" "$([ -f "$MODPATH/service.sh" ] && [ -f "$MODPATH/module.prop" ] && echo yes || echo no)" "yes"
check "module dir drops runtime copies" "$([ -d "$MODPATH/bin" ] && echo yes || echo no)" "no"

# user config must survive an update
printf '%s\n' "SMSFW_WEBHOOK_URL='https://example.test/hook'" > "$SMSF_DATA/config.conf"
printf '%s\n' '{"custom":true}' > "$SMSF_DATA/template.json"
rm -rf "$MODPATH"
mkdir -p "$MODPATH"
cp -r "$ROOT/payload/." "$MODPATH/"
run_script "$MODPATH/customize.sh" >/dev/null 2>&1
check "update keeps user config" "$(cat "$SMSF_DATA/config.conf")" "SMSFW_WEBHOOK_URL='https://example.test/hook'"
check "update keeps user template" "$(cat "$SMSF_DATA/template.json")" '{"custom":true}'
check "update refreshes runtime" "$([ -x "$SMSF_DATA/bin/smsfw" ] && echo yes || echo no)" "yes"

# uninstall stops the daemon and preserves data
mkdir -p "$SMSF_DATA/state"
printf '%s' "999999" > "$SMSF_DATA/state/daemon.pid"
printf '%s' "999998" > "$SMSF_DATA/state/worker.pid"
printf '' > "$SMSF_DATA/config.conf"
OUT="$(run_script "$MODPATH/uninstall.sh")"
check "uninstall exits 0" "$?" "0"
check "uninstall removes pid files" "$([ -f "$SMSF_DATA/state/daemon.pid" ] && echo yes || echo no)" "no"
check "uninstall keeps config" "$([ -f "$SMSF_DATA/config.conf" ] && echo yes || echo no)" "yes"

echo
echo "installer tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
