#!/usr/bin/env bash
# Integration test: drives the real daemon/payload through a fake Android
# environment (fake content provider, fake app_process -> desktop JVM).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAKE="$HERE/fake-android"
PORT="${PORT:-$((19500 + $$ % 200))}"
LOG="${LOG:-/tmp/smsfw-daemon-requests.$$.jsonl}"
TMP="$(mktemp -d /tmp/smsfw-daemon.XXXXXX)"
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
  [ -f "$SMSF_DATA/state/daemon.pid" ] && kill "$(cat "$SMSF_DATA/state/daemon.pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# ---------------------------------------------------------------- setup

mkdir -p "$SMSF_DATA/bin" "$SMSF_DATA/lib" "$SMSF_DATA/state" "$SMSF_DATA/queue" \
         "$SMSF_DATA/failed" "$SMSF_DATA/tmp" "$SMSF_DATA/log"
# The shipped scripts use Android's #!/system/bin/sh. For this desktop harness
# keep the scripts verbatim as *.real and put tiny /bin/sh shims in front, so
# internal calls such as "$SMSF_BIN_DIR/smsfwd run" behave like on Android.
cp "$ROOT"/payload/bin/common.sh "$SMSF_DATA/bin/common.sh"
cp "$ROOT"/payload/bin/i18n.sh "$SMSF_DATA/bin/i18n.sh"
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

cat > "$SMSF_DATA/config.conf" <<EOF
SMSFW_ENABLED=1
SMSFW_WEBHOOK_URL='http://127.0.0.1:$PORT/hook'
SMSFW_METHOD='POST'
SMSFW_TEMPLATE_FILE='$SMSF_DATA/template.json'
SMSFW_HEADERS_FILE='$SMSF_DATA/headers.txt'
SMSFW_SECRET_FILE='$SMSF_DATA/secret'
SMSFW_DEVICE_NAME='MyPhone'
SMSFW_POLL_INTERVAL=1
SMSFW_TIMEOUT=5
SMSFW_RETRIES=0
SMSFW_RETRY_DELAY=1
SMSFW_MAX_ATTEMPTS=3
SMSFW_FILTER_SENDER_ALLOW=''
SMSFW_FILTER_SENDER_BLOCK=''
SMSFW_FILTER_BODY_ALLOW=''
SMSFW_FILTER_BODY_BLOCK=''
EOF
chmod 600 "$SMSF_DATA/config.conf"

cat > "$FAKE_SMS_DB" <<'EOF'
{"messages":[
  {"_id":1,"type":1,"address":"10010","body":"old message one","date":1690000000000,"sub_id":1,"service_center":"+8610"},
  {"_id":2,"type":1,"address":"10010","body":"old message two","date":1690000001000,"sub_id":1,"service_center":"+8610"}
],
 "sims":{"1":{"display_name":"TestTel","slot_index":0}}}
EOF

rm -f "$LOG"
python3 "$HERE/mock_webhook.py" --port "$PORT" --log "$LOG" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/ping" && break
  sleep 0.1
done

smsfwd() { "$SMSF_DATA/bin/smsfwd" "$@"; }
smsfw()  { "$SMSF_DATA/bin/smsfw" "$@"; }

requests() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
last() { tail -n 1 "$LOG"; }
field() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d'"$2"')'; }
cfg_get_template_path() { sed -n "s/^SMSFW_TEMPLATE_FILE='\(.*\)'\$/\1/p" "$SMSF_DATA/config.conf"; }
add_sms() { # id from body
  python3 - "$FAKE_SMS_DB" "$1" "$2" "$3" <<'PY'
import json, sys
path, mid, frm, body = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(path) as fh:
    db = json.load(fh)
db["messages"].append({"_id": mid, "type": 1, "address": frm, "body": body,
                       "date": 1700000000000 + mid, "sub_id": 1,
                       "service_center": "+8610"})
with open(path, "w") as fh:
    json.dump(db, fh)
PY
}

echo "== daemon integration tests =="
NOW_MS="$(sh -c '. "$1"; now_s() { printf %s 1790395454; }; now_ms' sh "$SMSF_DATA/bin/common.sh")"
check "now_ms avoids shell arithmetic overflow" "$NOW_MS" "1790395454000"

# 1. first poll only baselines, existing messages are not forwarded
BEFORE=$(requests)
smsfwd poll-once >/dev/null 2>&1
check "poll-once exit 0" "$?" "0"
check "baseline does not forward old sms" "$(requests)" "$BEFORE"
check "baseline stored last id" "$(cat "$SMSF_DATA/state/last_sms_id")" "2"

# 2. new sms is forwarded with the default json template
add_sms 3 13800138000 'hello "world"
line2'
smsfwd poll-once >/dev/null 2>&1
check "new sms forwarded" "$(( $(requests) - BEFORE ))" "1"
REQ="$(last)"
check "webhook used POST" "$(field "$REQ" "['method']")" "POST"
check "webhook content-type json" "$(field "$REQ" "['headers']['Content-Type']")" "application/json; charset=utf-8"
BODY="$(field "$REQ" "['body']")"
check "payload from" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["from"])' <<<"$BODY")" "13800138000"
check "payload content kept multiline" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["content"])' <<<"$BODY")" "$(printf 'hello "world"\nline2')"
check "payload device" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["device"])' <<<"$BODY")" "MyPhone"
check "payload card_slot from siminfo" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["card_slot"])' <<<"$BODY")" "TestTel"
check "payload card_subid" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["card_subid"])' <<<"$BODY")" "1"

# 3. re-polling does not duplicate
BEFORE=$(requests)
smsfwd poll-once >/dev/null 2>&1
check "no duplicate on re-poll" "$(requests)" "$BEFORE"

# 4. filters
python3 - "$SMSF_DATA/config.conf" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("SMSFW_FILTER_SENDER_BLOCK=''", "SMSFW_FILTER_SENDER_BLOCK='^95533$'")
s = s.replace("SMSFW_FILTER_BODY_BLOCK=''", "SMSFW_FILTER_BODY_BLOCK='spam'")
open(p, "w").write(s)
PY
add_sms 4 95533 "blocked by sender"
add_sms 5 10086 "this is spam content"
add_sms 6 10086 "a normal message"
BEFORE=$(requests)
smsfwd poll-once >/dev/null 2>&1
check "filters forward only matching sms" "$(( $(requests) - BEFORE ))" "1"
check "filtered ids still advanced" "$(cat "$SMSF_DATA/state/last_sms_id")" "6"
check "surviving message is the normal one" "$(field "$(last)" "['body']" | grep -c 'a normal message')" "1"

# 5. queue + retry when the webhook is down
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""
add_sms 7 10086 "sent while offline"
smsfwd poll-once >/dev/null 2>&1
check "offline sms stays queued" "$(ls -d "$SMSF_DATA/queue"/*/ 2>/dev/null | wc -l | tr -d ' ')" "1"
check "attempt counter written" "$(cat "$SMSF_DATA/queue"/*/attempts 2>/dev/null)" "1"
check "last id advanced while queued" "$(cat "$SMSF_DATA/state/last_sms_id")" "7"

# webhook comes back
rm -f "$LOG"
python3 "$HERE/mock_webhook.py" --port "$PORT" --log "$LOG" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/ping" && break
  sleep 0.1
done
smsfw flush >/dev/null 2>&1
check "flush drains the queue" "$(ls -d "$SMSF_DATA/queue"/*/ 2>/dev/null | wc -l | tr -d ' ')" "0"
check "queued sms delivered after reconnect" "$(requests)" "1"
check "sent counter" "$(cat "$SMSF_DATA/state/sent" 2>/dev/null)" "3"

# 6. CLI: status / set / preview / test / doctor
OUT="$(smsfw status 2>&1)"
check "status shows running config" "$(printf '%s' "$OUT" | grep -c 'http://127.0.0.1:')" "1"
check "status shows queue counts" "$(printf '%s' "$OUT" | grep -c '0 pending, 0 failed')" "1"

smsfw set poll_interval 3 >/dev/null 2>&1
check "set writes config" "$(smsfw get SMSFW_POLL_INTERVAL 2>/dev/null | tr -d '\n')" "3"

printf '{"from":"[from]","msg":"[msg]","slot":"[card_slot]","battery":"{{BATTERY_PCT}}","ip":"{{IPV4}}"}' > "$TMP/alt.json"
smsfw template set "$TMP/alt.json" >/dev/null 2>&1
check "template set copies into device-encrypted data dir" "$(cat "$SMSF_DATA/template.json")" "$(cat "$TMP/alt.json")"
check "template set repoints config" "$(cfg_get_template_path)" "$SMSF_DATA/template.json"
OUT="$(smsfw preview 10086 'preview body' 2>/dev/null)"
check "preview renders json" "$(printf '%s' "$OUT" | grep -c '"from":"10086"')" "1"
check "preview renders battery tag" "$(printf '%s' "$OUT" | grep -c '"battery":"42"')" "1"
check "preview renders ipv4 tag" "$(printf '%s' "$OUT" | grep -c '"ip":"192.168.1.23"')" "1"
check "preview renders slot" "$(printf '%s' "$OUT" | grep -c '"slot":"TEST"')" "1"

BEFORE=$(requests)
OUT="$(smsfw test 10086 'cli test message' 2>&1)"
check "cli test exit 0" "$?" "0"
check "cli test delivered" "$(( $(requests) - BEFORE ))" "1"
check "cli test output ok" "$(printf '%s' "$OUT" | grep -c 'test push delivered')" "1"

OUT="$(smsfw doctor 2>&1)"
# The desktop harness is not uid 0, so exactly that check is expected to fail.
check "doctor fails only the root check" "$(printf '%s' "$OUT" | grep -c '✗')" "1"
check "doctor failure is the root check" "$(printf '%s' "$OUT" | grep -c '✗ running as root')" "1"

# 7. daemon start/stop lifecycle
smsfw start >/dev/null 2>&1
check "start returns success" "$?" "0"
PID1="$(cat "$SMSF_DATA/state/daemon.pid" 2>/dev/null)"
sleep 2
check "supervisor stays alive" "$(kill -0 "$PID1" 2>/dev/null && echo yes || echo no)" "yes"
smsfw stop >/dev/null 2>&1
check "stop kills supervisor" "$(kill -0 "$PID1" 2>/dev/null && echo yes || echo no)" "no"

# 8. disabled config pauses forwarding
python3 - "$SMSF_DATA/config.conf" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("SMSFW_ENABLED=1", "SMSFW_ENABLED=0")
open(p, "w").write(s)
PY
add_sms 8 10086 "must not be forwarded"
BEFORE=$(requests)
smsfwd poll-once >/dev/null 2>&1
check "poll-once ignores enabled=0" "$(( $(requests) - BEFORE ))" "0"

# 9. idle ticks must not spawn a provider query; a db change must trigger one
python3 - "$SMSF_DATA/config.conf" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("SMSFW_ENABLED=0", "SMSFW_ENABLED=1")
s = s.replace("SMSFW_RETRY_DELAY=1", "SMSFW_RETRY_DELAY=1\nSMSFW_DB_FULL_CHECK_INTERVAL='30'")
open(p, "w").write(s)
PY
printf 'x' > "$TMP/fake_mmssms.db"
: > "$TMP/provider-calls.log"
export SMSF_DB_CANDIDATES="$TMP/fake_mmssms.db"
export FAKE_SMS_CALLS="$TMP/provider-calls.log"

smsfw start >/dev/null 2>&1
sleep 4
COUNT1=$(grep -c '_id > ' "$TMP/provider-calls.log")
check "provider queried on first tick" "$([ "$COUNT1" -ge 1 ] && echo yes || echo no)" "yes"
check "unchanged db does not re-query provider" "$([ "$COUNT1" -le 2 ] && echo yes || echo no)" "yes"
touch "$TMP/fake_mmssms.db"
sleep 3
COUNT2=$(grep -c '_id > ' "$TMP/provider-calls.log")
check "db change triggers provider query" "$([ "$COUNT2" -gt "$COUNT1" ] && echo yes || echo no)" "yes"
smsfw stop >/dev/null 2>&1
unset SMSF_DB_CANDIDATES FAKE_SMS_CALLS

# 10. a message deleted between the id listing and the field read must not be
#     forwarded as the literal "No result found." sentinel
add_sms 9 10086 "will be deleted"
BEFORE=$(requests)
export FAKE_SMS_HIDE_ITEM=9
smsfwd poll-once >/dev/null 2>&1
check "deleted message is not forwarded" "$(requests)" "$BEFORE"
check "deleted message advances state" "$(cat "$SMSF_DATA/state/last_sms_id")" "9"
check "deleted message is not queued" "$(ls -d "$SMSF_DATA/queue"/*/ 2>/dev/null | wc -l | tr -d ' ')" "0"
unset FAKE_SMS_HIDE_ITEM

# 11. `content` always exits 0, so provider failures must be detected from the
#     output (stderr "Error while accessing provider:", stdout usage/[ERROR])
export FAKE_SMS_DB_BAK="$FAKE_SMS_DB"
export FAKE_SMS_DB="$TMP/does-not-exist.json"
OUT="$(smsfw doctor 2>&1)"
check "doctor detects unreachable provider" "$(printf '%s' "$OUT" | grep -c '✗ SMS provider is not reachable')" "1"
export FAKE_SMS_DB="$FAKE_SMS_DB_BAK"

OUT="$(smsfw doctor 2>&1)"
check "doctor recovers with provider back" "$(printf '%s' "$OUT" | grep -c '✗ SMS provider is not reachable')" "0"

# 12. an old/odd build whose content rejects our flags (usage + [ERROR], exit 0)
#     must also be detected instead of looking healthy
cat > "$TMP/content-old" <<'EOF'
#!/bin/sh
echo "usage: adb shell content query --uri <URI>"
echo "[ERROR] Unsupported argument: --sort"
exit 0
EOF
chmod +x "$TMP/content-old"
OUT="$(env SMSF_CONTENT_BIN="$TMP/content-old" "$SMSF_DATA/bin/smsfw" doctor 2>&1)"
check "doctor detects unsupported content flags" "$(printf '%s' "$OUT" | grep -c '✗ SMS provider is not reachable')" "1"

# 13. harmless stderr noise (ART/linker warnings) must not make a good query
#     look failed - stdout and stderr are validated separately
cat > "$TMP/content-noisy" <<'EOF'
#!/bin/sh
echo "W app_process: some harmless ART warning" >&2
echo "Row: 0 _id=1"
EOF
chmod +x "$TMP/content-noisy"
OUT="$(env SMSF_CONTENT_BIN="$TMP/content-noisy" "$SMSF_DATA/bin/smsfw" doctor 2>&1)"
check "stderr noise does not break queries" "$(printf '%s' "$OUT" | grep -c '✗ SMS provider is not reachable')" "0"
check "noisy provider still parses rows" "$(printf '%s' "$OUT" | grep -c 'provider row format understood')" "1"

# 14. stderr noise during the real poll path must not block delivery.
# Tests 14/15 install their own template so the assertions do not depend on the
# template left active by test 6.
printf '{"from":"{{FROM}}","content":"{{SMS}}"}' > "$TMP/marker-template.json"
smsfw template set "$TMP/marker-template.json" >/dev/null 2>&1
cat > "$TMP/content-noisy-live" <<EOF
#!/bin/sh
echo "W linker: harmless warning on stderr" >&2
exec "$FAKE/content" "\$@"
EOF
chmod +x "$TMP/content-noisy-live"
add_sms 12 10086 "delivered despite stderr noise"
BEFORE=$(requests)
env SMSF_CONTENT_BIN="$TMP/content-noisy-live" "$SMSF_DATA/bin/smsfwd" poll-once >/dev/null 2>&1
check "noisy stderr message delivered" "$(( $(requests) - BEFORE ))" "1"
check "noisy stderr body intact" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["content"])' <<<"$(field "$(last)" "['body']")")" "delivered despite stderr noise"

# 15. a body that looks like CLI output must still be delivered verbatim
#     (shape-based classification, never substring scanning)
MARKER_BODY='usage: adb shell content query --uri <URI>
[ERROR] Unsupported argument: --sort
Error while accessing provider:com.android.providers.telephony
No result found.
Row: 999 _id=1, body=fake'
add_sms 13 10086 "$MARKER_BODY"
BEFORE=$(requests)
smsfwd poll-once >/dev/null 2>&1
check "marker-laden body delivered" "$(( $(requests) - BEFORE ))" "1"
check "marker-laden body verbatim" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["content"])' <<<"$(field "$(last)" "['body']")")" "$MARKER_BODY"

# 16. `smsfw poll` must delegate to the daemon worker (it used to call
#     poll_once/drain_queue which only exist in smsfwd)
add_sms 14 10086 "cli poll path"
BEFORE=$(requests)
OUT="$("$SMSF_DATA/bin/smsfw" poll 2>&1)"
check "cli poll exits 0" "$?" "0"
check "cli poll has no missing-command noise" "$(printf '%s' "$OUT" | grep -c 'not found\|未找到')" "0"
check "cli poll forwarded the sms" "$(( $(requests) - BEFORE ))" "1"

# 17. a failing record dir must abort cleanly and never write outside the
#     data dir (an empty $rec used to produce "/values/..." paths)
mv "$SMSF_DATA/tmp" "$SMSF_DATA/tmp.bak"
printf 'block\n' > "$SMSF_DATA/tmp"
OUT="$("$SMSF_DATA/bin/smsfw" test 2>&1)"
rc=$?
check "unusable record dir exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "unusable record dir reports the cause" "$(printf '%s' "$OUT" | grep -c 'not usable')" "1"
check "no root-level path is attempted" "$(printf '%s' "$OUT" | grep -c '/values')" "0"
rm -f "$SMSF_DATA/tmp"
mv "$SMSF_DATA/tmp.bak" "$SMSF_DATA/tmp"

# 18. WebUI contract: `smsfw status --json` is valid JSON with stable keys
JSON_OUT="$("$SMSF_DATA/bin/smsfw" status --json 2>/dev/null)"
check "status --json parses" "$(printf '%s' "$JSON_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("webhook") is not None else "bad")' 2>/dev/null)" "ok"
check "status --json stays on one line" "$(printf '%s\n' "$JSON_OUT" | wc -l | tr -d ' ')" "1"
check "status --json exposes the webui fields" "$(printf '%s' "$JSON_OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
need = ["module_version","payload_version","runner","enabled","tested","daemon_running",
        "daemon_pid","webhook","method","template","template_exists","headers",
        "headers_exist","secret_set","response_match",
        "tls_insecure","device","rule_title","last_sms_id","queue_pending","queue_failed",
        "counter_sent","counter_failed","timeout","retries","retry_delay","poll_interval","db_check","queue_limit",
        "filter_sender_allow","filter_sender_block","filter_body_allow","filter_body_block",
        "config_path","log_path","lang"]
missing = [k for k in need if k not in d]
print("ok" if not missing else "missing:" + ",".join(missing))')" "ok"
check "status --json types are sane" "$(printf '%s' "$JSON_OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ok = (isinstance(d["enabled"], bool) and isinstance(d["queue_pending"], int)
      and isinstance(d["timeout"], int) and isinstance(d["webhook"], str))
print("ok" if ok else "bad")')" "ok"
"$SMSF_DATA/bin/smsfw" on >/dev/null 2>&1
check "status --json reflects on" "$("$SMSF_DATA/bin/smsfw" status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["enabled"])')" "True"
"$SMSF_DATA/bin/smsfw" off >/dev/null 2>&1
check "status --json reflects off" "$("$SMSF_DATA/bin/smsfw" status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["enabled"])')" "False"

# 20. CLI smoke: every documented verb runs without missing-command noise
SMOKE_VERBS="status show get queue log template headers secret version help on off preview test flush poll reset-state"
SMOKE_BAD=0
for verb in $SMOKE_VERBS; do
    case "$verb" in
        get)      out="$("$SMSF_DATA/bin/smsfw" get SMSFW_METHOD 2>&1)" ;;
        queue)    out="$("$SMSF_DATA/bin/smsfw" queue list 2>&1)" ;;
        log)      out="$("$SMSF_DATA/bin/smsfw" log -n 5 2>&1)" ;;
        template) out="$("$SMSF_DATA/bin/smsfw" template cat 2>&1)" ;;
        headers)  out="$("$SMSF_DATA/bin/smsfw" headers cat 2>&1)" ;;
        secret)   out="$("$SMSF_DATA/bin/smsfw" secret show 2>&1)" ;;
        *)        out="$("$SMSF_DATA/bin/smsfw" $verb 2>&1)" ;;
    esac
    case "$out" in
        *"not found"*|*"未找到命令"*) SMOKE_BAD=$((SMOKE_BAD + 1)) ;;
    esac
done
check "no CLI verb reports a missing command" "$SMOKE_BAD" "0"

# 21. an unusable data dir must fail loudly (never derive paths from an empty base)
OUT="$(env SMSF_DATA=/proc/smsfw-nope SMSF_LANG=en sh "$SMSF_DATA/bin/smsfw.real" test 2>&1)"
rc=$?
check "unusable data dir exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "unusable data dir reports the cause" "$(printf '%s' "$OUT" | grep -c 'not usable')" "1"
check "unusable data dir attempts nothing outside itself" "$(printf '%s' "$OUT" | grep -c '/values')" "0"

# 22. i18n: SMSF_LANG selects the message catalog (zh/en)
check "en help is English" "$(env SMSF_LANG=en "$SMSF_DATA/bin/smsfw" help 2>/dev/null | grep -c 'interactive setup wizard')" "1"
check "zh help is Chinese" "$(env SMSF_LANG=zh "$SMSF_DATA/bin/smsfw" help 2>/dev/null | grep -c '交互式配置向导')" "1"
check "en status is English" "$(env SMSF_LANG=en "$SMSF_DATA/bin/smsfw" status 2>/dev/null | grep -c 'enabled')" "1"
check "zh status is Chinese" "$(env SMSF_LANG=zh "$SMSF_DATA/bin/smsfw" status 2>/dev/null | grep -c '转发开关')" "1"
check "locale env selects language" "$(env -u SMSF_LANG LANG=zh_CN.UTF-8 "$SMSF_DATA/bin/smsfw" status 2>/dev/null | grep -c '转发开关')" "1"

# 23. inline setters (the WebUI save path): content arrives as one shell argument,
#     so it must survive newlines, single quotes and '%' verbatim.
TPL='first line
{"msg":"it'"'"'s 100% [from]","n":1}'
"$SMSF_DATA/bin/smsfw" template put "$TPL" >/dev/null 2>&1
GOT="$(env SMSF_LANG=en "$SMSF_DATA/bin/smsfw" template cat 2>/dev/null)"
check "template put keeps the payload" "$(printf '%s' "$GOT" | grep -c '100% \[from\]')" "1"
check "template put keeps the single quote" "$(printf '%s' "$GOT" | grep -c "it's")" "1"
check "template put keeps the json body" "$(printf '%s' "$GOT" | grep -c '"'msg'"')" "1"
check "template put keeps the first line" "$(printf '%s' "$GOT" | grep -c '^first line$')" "1"
"$SMSF_DATA/bin/smsfw" headers put 'X-One: 1
X-Two: 2' >/dev/null 2>&1
check "headers put keeps both lines" "$(env SMSF_LANG=en "$SMSF_DATA/bin/smsfw" headers cat 2>/dev/null | grep -c '^X-')" "2"
TEMPLATE64="$(env SMSF_LANG=en "$SMSF_DATA/bin/smsfw" template cat --base64 2>/dev/null)"
check "template base64 stays on one line" "$(printf '%s\n' "$TEMPLATE64" | wc -l | tr -d ' ')" "1"
check "template base64 round-trips" "$(printf '%s' "$TEMPLATE64" | base64 -d)" "$TPL"
HEADERS64="$(env SMSF_LANG=en "$SMSF_DATA/bin/smsfw" headers cat --base64 2>/dev/null)"
check "headers base64 stays on one line" "$(printf '%s\n' "$HEADERS64" | wc -l | tr -d ' ')" "1"
check "headers base64 round-trips" "$(printf '%s' "$HEADERS64" | base64 -d)" "$(env SMSF_LANG=en "$SMSF_DATA/bin/smsfw" headers cat 2>/dev/null)"
"$SMSF_DATA/bin/smsfw" secret put 'sk-100%_secret'"'"'s' >/dev/null 2>&1
check "secret put stores the secret" "$([ -s "$SMSF_DATA/secret" ] && echo yes || echo no)" "yes"
check "secret show does not print it" "$(env SMSF_LANG=en "$SMSF_DATA/bin/smsfw" secret show 2>/dev/null | grep -c 'sk-100')" "0"
PUT_UNKNOWN=0
for verb in "template put" "headers put" "secret put"; do
    out="$("$SMSF_DATA/bin/smsfw" $verb 2>&1)" || true
    case "$out" in
        *"not found"*|*"未找到"*) PUT_UNKNOWN=$((PUT_UNKNOWN + 1)) ;;
    esac
done
check "put verbs are known to the CLI" "$PUT_UNKNOWN" "0"

# 24. config parsing preserves quoted apostrophes, strips inline comments, and
# never evaluates unknown lines.
CONFIG_MARKER="$TMP/config-executed"
python3 - "$SMSF_DATA/config.conf" "$CONFIG_MARKER" <<'PY'
import sys
config, marker = sys.argv[1:]
with open(config, 'w', encoding='utf-8') as fh:
    fh.write("SMSFW_WEBHOOK_URL='http://example.test/hook'  # inline note\n")
    fh.write("SMSFW_DEVICE_NAME='O'\\''K'\n")
    fh.write("$(touch %s)\n" % marker)
PY
check "config parser strips inline comments" "$("$SMSF_DATA/bin/smsfw" get webhook_url 2>/dev/null | tr -d '\n')" "http://example.test/hook"
check "config parser unescapes apostrophes" "$("$SMSF_DATA/bin/smsfw" get device_name 2>/dev/null | tr -d '\n')" "O'K"
OUT="$($SMSF_DATA/bin/smsfw set poll_intervalX 7 2>&1)"
rc=$?
check "unknown config key exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "unknown config line is not executed" "$([ -e "$CONFIG_MARKER" ] && echo yes || echo no)" "no"

echo
echo "daemon tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]