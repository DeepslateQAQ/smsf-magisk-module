#!/usr/bin/env bash
# Tests for `smsfw wizard`:
#   1. full non-TTY flow: writes config/headers, sends the test push, starts daemon
#   2. step order matches SMSForwarder's sender page
#   3. invalid URL is re-asked
#   4. cancelling at the final confirmation changes nothing (config, headers,
#      template are all compared)
#   5. pasted template is stored verbatim and used
#   6. secret: written with 0600, signs the test push; a later empty run removes it
#   7. PTY: arrow-key navigation, in-place redraw (ANSI replay), bare-Esc cancel
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAKE="$HERE/fake-android"
PORT="${PORT:-$((19300 + $$ % 200))}"
LOG="${LOG:-/tmp/smsfw-wizard-requests.$$.jsonl}"
TMP="$(mktemp -d /tmp/smsfw-wizard.XXXXXX)"
export SMSF_DATA="$TMP/data"
export FAKE_SMS_DB="$TMP/sms.json"
export SMSF_CONTENT_BIN="$FAKE/content"
export SMSF_APP_PROCESS="$FAKE/app_process"
export SMSF_GETPROP="$FAKE/getprop"
export SMSF_DUMPSYS="$FAKE/dumpsys"
export SMSF_IFCONFIG="$FAKE/ifconfig"
export SMSF_LANG=en   # pin UI language so assertions are stable

PASS=0
FAIL=0
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  pid=$(cat "$SMSF_DATA/state/daemon.pid" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# ---------------------------------------------------------------- setup

mkdir -p "$SMSF_DATA/bin" "$SMSF_DATA/lib" "$SMSF_DATA/state" "$SMSF_DATA/queue" \
         "$SMSF_DATA/failed" "$SMSF_DATA/tmp" "$SMSF_DATA/log"
cp "$ROOT"/payload/bin/common.sh "$SMSF_DATA/bin/common.sh"
cp "$ROOT"/payload/bin/i18n.sh "$SMSF_DATA/bin/i18n.sh"
cp "$ROOT"/payload/bin/wizard.sh "$SMSF_DATA/bin/wizard.sh"
for s in smsfw smsfwd; do
  cp "$ROOT/payload/bin/$s" "$SMSF_DATA/bin/$s.real"
  cat > "$SMSF_DATA/bin/$s" <<EOF
#!/bin/sh
exec sh "$SMSF_DATA/bin/$s.real" "\$@"
EOF
done
cp "$ROOT/payload/lib/smsfw.jar" "$SMSF_DATA/lib/"
cp "$ROOT/payload/config/template.json" "$SMSF_DATA/template.json"
cp "$ROOT/payload/config/headers.txt" "$SMSF_DATA/headers.txt"
printf '%s' "test-build" > "$SMSF_DATA/version"
printf '%s' "1.0.0" > "$SMSF_DATA/payload.version"
chmod 755 "$SMSF_DATA/bin/"*
printf '%s\n' '{"messages":[],"sims":{}}' > "$FAKE_SMS_DB"

reset_config() {
  cat > "$SMSF_DATA/config.conf" <<EOF
SMSFW_ENABLED=1
SMSFW_WEBHOOK_URL=''
SMSFW_METHOD='POST'
SMSFW_TEMPLATE_FILE='$SMSF_DATA/template.json'
SMSFW_HEADERS_FILE='$SMSF_DATA/headers.txt'
SMSFW_SECRET_FILE='$SMSF_DATA/secret'
SMSFW_DEVICE_NAME='WizardPhone'
SMSFW_TIMEOUT=5
SMSFW_RETRIES=0
SMSFW_RETRY_DELAY=1
EOF
  chmod 600 "$SMSF_DATA/config.conf"
}
reset_config

rm -f "$LOG"
python3 "$HERE/mock_webhook.py" --port "$PORT" --log "$LOG" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/ping" && break
  sleep 0.1
done

requests() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
last() { tail -n 1 "$LOG"; }
field() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d'"$2"')'; }
cfg_line() { grep "^$1=" "$SMSF_DATA/config.conf" | tail -n 1; }
run_wizard() { "$SMSF_DATA/bin/smsfw" wizard < "$1" 2>&1; }
answer() { printf '%s\n' "$@"; }

echo "== wizard tests =="

# ---------------------------------------------------------------- 1. happy path
# prompts: mode, name, enabled, method, url, secret, response, template,
#          headers, header-name, header-value, header-end, filters,
#          sender-allow, sender-block, body-allow, body-block, advanced, final
reset_config
answer "1" "mytest" "" "" "http://127.0.0.1:$PORT/hook" "" "" "" \
       "2" "X-Api-Key" "sekret" "" \
       "2" "10086" "95533" "" "" \
       "" "" > "$TMP/a1"
OUT="$(run_wizard "$TMP/a1")"
check "wizard exits 0" "$?" "0"
check "wizard wrote url" "$(cfg_line SMSFW_WEBHOOK_URL)" "SMSFW_WEBHOOK_URL='http://127.0.0.1:$PORT/hook'"
check "wizard wrote rule title" "$(cfg_line SMSFW_RULE_TITLE)" "SMSFW_RULE_TITLE='mytest'"
check "wizard kept POST" "$(cfg_line SMSFW_METHOD)" "SMSFW_METHOD='POST'"
check "wizard wrote sender block" "$(cfg_line SMSFW_FILTER_SENDER_BLOCK)" "SMSFW_FILTER_SENDER_BLOCK='95533'"
check "wizard wrote sender allow" "$(cfg_line SMSFW_FILTER_SENDER_ALLOW)" "SMSFW_FILTER_SENDER_ALLOW='10086'"
check "wizard wrote headers" "$(grep -c '^X-Api-Key: sekret$' "$SMSF_DATA/headers.txt")" "1"
check "wizard sent one test push" "$(requests)" "1"
check "test push content-type" "$(field "$(last)" "['headers']['Content-Type']")" "application/json; charset=utf-8"
check "test push sender" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["from"])' <<<"$(field "$(last)" "['body']")")" "10086"
check "wizard started the daemon" "$([ -n "$(cat "$SMSF_DATA/state/daemon.pid" 2>/dev/null)" ] && echo yes || echo no)" "yes"
check "status reports enabled" "$("$SMSF_DATA/bin/smsfw" status 2>/dev/null | grep -c 'yes  daemon:')" "1"
"$SMSF_DATA/bin/smsfw" stop >/dev/null 2>&1

# ---------------------------------------------------------------- 2. step order
ACTUAL_STEPS="$(printf '%s\n' "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/^\[[0-9][0-9]*\/10\] \(.*\)$/\1/p' | sed 's/[[:space:]]*$//')"
EXPECTED_STEPS="$(answer \
  'Name (template tag {{RULE_TITLE}})' \
  'Enabled' \
  'Request method' \
  'Webhook URL' \
  'Secret (HMAC-SHA256 signing, optional)' \
  'Response match keyword (optional)' \
  'Request body / template' \
  'Headers (Content-Type is inferred from the template)' \
  'Rules (match fields, POSIX ERE regex, empty = no limit)' \
  'Advanced')"
check "wizard step order matches upstream" "$ACTUAL_STEPS" "$EXPECTED_STEPS"

# ---------------------------------------------------------------- 3. invalid url
reset_config
answer "1" "" "" "" "not-a-url" "http://127.0.0.1:$PORT/hook2" "" "" "" \
       "" "" "" "" > "$TMP/a2"
OUT="$(run_wizard "$TMP/a2")"
check "invalid url is re-asked" "$(printf '%s' "$OUT" | grep -c 'must start with http')" "1"
check "url after retry stored" "$(cfg_line SMSFW_WEBHOOK_URL)" "SMSFW_WEBHOOK_URL='http://127.0.0.1:$PORT/hook2'"
"$SMSF_DATA/bin/smsfw" stop >/dev/null 2>&1

# ---------------------------------------------------------------- 4. cancel keeps everything
reset_config
printf '%s\n' '{"keep":"me"}' > "$SMSF_DATA/template.json"
printf '%s\n' '# keep this header' 'X-Keep: yes' > "$SMSF_DATA/headers.txt"
cp "$SMSF_DATA/config.conf" "$TMP/config.before"
cp "$SMSF_DATA/template.json" "$TMP/template.before"
cp "$SMSF_DATA/headers.txt" "$TMP/headers.before"
# mode, name, enabled, method, url, template(paste), pasted, headers(edit: yes),
# name/value/end, filters(no), advanced(no), final = NO
answer "1" "" "" "" "http://127.0.0.1:$PORT/hook3" "" "" "2" '{"cancelled":"yes"}' \
       "2" "X-New" "v" "" \
       "" "" "2" > "$TMP/a3"
OUT="$(run_wizard "$TMP/a3")"
check "cancellation is reported" "$(printf '%s' "$OUT" | grep -c 'Cancelled')" "1"
check "cancelled run keeps config" "$(cmp -s "$TMP/config.before" "$SMSF_DATA/config.conf" && echo same || echo changed)" "same"
check "cancelled run keeps template" "$(cmp -s "$TMP/template.before" "$SMSF_DATA/template.json" && echo same || echo changed)" "same"
check "cancelled run keeps headers" "$(cmp -s "$TMP/headers.before" "$SMSF_DATA/headers.txt" && echo same || echo changed)" "same"
check "cancelled run leaves no staging" "$(ls -d "$SMSF_DATA/tmp/wizard."* 2>/dev/null | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------- 5. paste template
reset_config
answer "1" "" "" "" "http://127.0.0.1:$PORT/hook4" "" "" "2" \
       '{"from":"{{FROM}}","body":"{{SMS}}"}' \
       "" "" "" "" > "$TMP/a4"
OUT="$(run_wizard "$TMP/a4")"
check "pasted template stored verbatim" "$(cat "$SMSF_DATA/template.json")" '{"from":"{{FROM}}","body":"{{SMS}}"}'
check "pasted template used for test push" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["body"])' <<<"$(field "$(last)" "['body']")" | cut -c1-18)" "smsfw test message"
"$SMSF_DATA/bin/smsfw" stop >/dev/null 2>&1

# ---------------------------------------------------------------- 6. secret + signing
reset_config
printf '%s\n' '{"from":"{{FROM}}","sign":"{{SIGN}}"}' > "$SMSF_DATA/template.json"
BEFORE=$(requests)
answer "1" "" "" "" "http://127.0.0.1:$PORT/hook5" "topsecret" "" "" \
       "" "" "" "" > "$TMP/a5"
OUT="$(run_wizard "$TMP/a5")"
check "secret written" "$(cat "$SMSF_DATA/secret" 2>/dev/null)" "topsecret"
check "secret file mode is 600" "$(stat -c '%a' "$SMSF_DATA/secret" 2>/dev/null)" "600"
check "secret run pushed once" "$(( $(requests) - BEFORE ))" "1"
SIGN="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["sign"])' <<<"$(field "$(last)" "['body']")")"
check "test push carries a signature" "$([ ${#SIGN} -gt 20 ] && echo yes || echo no)" "yes"
"$SMSF_DATA/bin/smsfw" stop >/dev/null 2>&1

# empty answer on the "clear existing secret?" confirm must delete it
answer "1" "" "" "" "http://127.0.0.1:$PORT/hook5" "2" "" "" \
       "" "" "" "" > "$TMP/a6"
OUT="$(run_wizard "$TMP/a6")"
check "empty secret removes the file" "$([ -f "$SMSF_DATA/secret" ] && echo yes || echo no)" "no"
check "signed run still reports success" "$(printf '%s' "$OUT" | grep -c 'test succeeded')" "1"
"$SMSF_DATA/bin/smsfw" stop >/dev/null 2>&1

# ---------------------------------------------------------------- 7. PTY cases
if command -v script >/dev/null 2>&1; then
  reset_config
  OUT="$( { printf '\033[B\033[B\r'; sleep 1; } | script -qec "$SMSF_DATA/bin/smsfw wizard" /dev/null 2>&1 )"
  # raw markers: the cursor glyph and the save/restore sequences only exist on the TTY path
  check "pty used the raw-mode renderer" "$([ "$(printf '%s' "$OUT" | grep -c '❯')" -ge 1 ] && echo yes || echo no)" "yes"
  check "pty redraw moves the cursor up" "$([ "$(printf '%s' "$OUT" | grep -cE "$(printf '\033')\[[0-9]+A")" -ge 1 ] && echo yes || echo no)" "yes"
  # assertions on rendered output must go through the replay: the raw stream
  # contains colour sequences between "✓" and the text
  SCREEN="$(printf '%s' "$OUT" | python3 "$HERE/ansi_screen.py")"
  check "pty arrow keys select third entry" "$(printf '%s\n' "$SCREEN" | grep -c '✓ module')" "1"
  check "menu prompt occupies one screen line" "$(printf '%s\n' "$SCREEN" | grep -c 'What do you want to do?')" "1"
  check "chosen answer summarised on one line" "$(printf '%s\n' "$SCREEN" | grep -c '✓ What do you want to do? Show the current configuration')" "1"
  check "menu block cleared after selection" "$(printf '%s\n' "$SCREEN" | grep -c '❯')" "0"

  # a bare Esc must cancel instead of blocking for escape-sequence bytes
  OUT="$( { printf '\033'; sleep 2; } | script -qec "$SMSF_DATA/bin/smsfw wizard" /dev/null 2>&1 )"
  check "pty bare esc cancels" "$(printf '%s' "$OUT" | grep -c 'Cancelled')" "1"
else
  echo "  skip - util-linux 'script' not available, PTY cases skipped"
fi

# 9. i18n: the wizard follows SMSF_LANG too
OUT="$(env SMSF_LANG=zh "$SMSF_DATA/bin/smsfw" wizard < /dev/null 2>&1)"
check "zh wizard header" "$(printf '%s' "$OUT" | grep -c '配置向导')" "1"
OUT="$(env SMSF_LANG=en "$SMSF_DATA/bin/smsfw" wizard < /dev/null 2>&1)"
check "en wizard header" "$(printf '%s' "$OUT" | grep -c 'setup wizard')" "1"

# ---------------------------------------------------------------- 10. heuristics
# a) no tty: bare `smsfw` must not block, it prints help
OUT="$(printf '' | "$SMSF_DATA/bin/smsfw" 2>&1)"
check "bare smsfw (non-tty) prints help" "$(printf '%s' "$OUT" | grep -c 'interactive setup wizard')" "1"

# b) no url configured -> offers the wizard; Esc falls back to help
reset_config
OUT="$( { printf '\033'; sleep 1; } | script -qec "$SMSF_DATA/bin/smsfw" /dev/null 2>&1 )"
SCREEN="$(printf '%s' "$OUT" | python3 "$HERE/ansi_screen.py")"
# the prompt is erased from the screen when the menu is cleared on ESC, so
# the raw stream is where it can be asserted
check "bare smsfw offers the wizard" "$(printf '%s' "$OUT" | grep -c 'Run the setup wizard now?')" "1"
check "declining shows help" "$(printf '%s\n' "$SCREEN" | grep -c 'interactive setup wizard')" "1"

# c) configured and tested -> offers status
cat > "$SMSF_DATA/config.conf" <<EOF
SMSFW_ENABLED=1
SMSFW_WEBHOOK_URL='http://127.0.0.1:$PORT/hook-auto'
SMSFW_METHOD='POST'
SMSFW_TEMPLATE_FILE='$SMSF_DATA/template.json'
SMSFW_HEADERS_FILE='$SMSF_DATA/headers.txt'
SMSFW_SECRET_FILE='$SMSF_DATA/secret'
SMSFW_TIMEOUT=5
SMSFW_RETRIES=0
EOF
chmod 600 "$SMSF_DATA/config.conf"
CHECK_TEST_OUT="$("$SMSF_DATA/bin/smsfw" test 2>&1)"
check "heuristic test push succeeded" "$(printf '%s' "$CHECK_TEST_OUT" | grep -c 'test push delivered')" "1"
check "successful test marks the config tested" "$([ -f "$SMSF_DATA/state/tested.fingerprint" ] && echo yes || echo no)" "yes"
OUT="$( { printf '\n'; sleep 1; } | script -qec "$SMSF_DATA/bin/smsfw" /dev/null 2>&1 )"
SCREEN="$(printf '%s' "$OUT" | python3 "$HERE/ansi_screen.py")"
check "tested config offers status" "$(printf '%s\n' "$SCREEN" | grep -c 'Show the current status?')" "1"
check "accepting shows the status" "$(printf '%s\n' "$SCREEN" | grep -c '✓ module')" "1"

# d) config changed after a test -> offers a test push again
sed -i 's|/hook-auto|/hook-auto-changed|' "$SMSF_DATA/config.conf"
OUT="$( { printf '\n'; sleep 2; } | script -qec "$SMSF_DATA/bin/smsfw" /dev/null 2>&1 )"
SCREEN="$(printf '%s' "$OUT" | python3 "$HERE/ansi_screen.py")"
check "changed config offers a test" "$(printf '%s\n' "$SCREEN" | grep -c 'Send a test push now?')" "1"

echo
echo "wizard tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
