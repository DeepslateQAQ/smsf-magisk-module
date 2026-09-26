#!/usr/bin/env bash
# End-to-end tests for the Java payload against a local mock webhook.
# Runs the same classes that get packaged into classes.dex.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CP="$ROOT/build/classes"
# Per-run ports and log files: two concurrent runs (or a leftover process from an
# earlier one) must not be able to clobber each other's sockets or records.
PORT="${PORT:-$((18000 + $$ % 300))}"
LOG="${LOG:-/tmp/smsfw-requests.$$.jsonl}"
TMP="$(mktemp -d /tmp/smsfw-test.XXXXXX)"
PASS=0
FAIL=0

cleanup() {
  rm -f "$LOG" 2>/dev/null
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  [ -n "${HTTPS_PID:-}" ] && kill "$HTTPS_PID" 2>/dev/null
  [ -n "${BAD_PID:-}" ] && kill "$BAD_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

java -cp "$CP" com.smsfw.Main version >/dev/null || { echo "payload not built"; exit 1; }
rm -f "$LOG"
python3 "$HERE/mock_webhook.py" --port "$PORT" --log "$LOG" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/ping" && break
  sleep 0.1
done

run() { java -cp "$CP" com.smsfw.Main "$@"; }

ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# ---------------------------------------------------------------- fixtures
mkdir -p "$TMP/values"
printf '13800138000'   > "$TMP/values/FROM"
printf 'Your code is 1234\nsecond line "quoted" \\ back' > "$TMP/values/SMS"
printf 'CMCC'          > "$TMP/values/CARD_SLOT"
printf '1'             > "$TMP/values/CARD_SUBID"
printf '0'             > "$TMP/values/SIM_SLOT_INDEX"
printf '1700000000000' > "$TMP/values/RECEIVE_TIME_MS"
printf 'Pixel 7'       > "$TMP/values/DEVICE_NAME"
printf '1.0.0'         > "$TMP/values/APP_VERSION"
printf 'secret-key'    > "$TMP/secret"
printf 'http://127.0.0.1:%s/hook\n' "$PORT" > "$TMP/url"

last_request() { tail -n 1 "$LOG"; }
count_requests() { wc -l < "$LOG" | tr -d ' '; }
field() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d'"$2"')'; }

echo "== payload tests =="

# 1. JSON template with signing
cat > "$TMP/t_json" <<'EOF'
{"from":"{{FROM}}","content":"{{SMS}}","ts":{{TIMESTAMP}},"time":"{{RECEIVE_TIME}}","time2":"[receive_time:HH:mm]","sign":"{{SIGN}}","name":"[device_name]"}
EOF
printf 'Content-Type: application/json\n' > "$TMP/h_json"
run send --url-file "$TMP/url" --method POST --template-file "$TMP/t_json" \
  --values-dir "$TMP/values" --headers-file "$TMP/h_json" --secret-file "$TMP/secret" \
  --timestamp-ms 1700000000001 --response-file "$TMP/resp" >/dev/null 2>"$TMP/err"
check "json send exit 0" "$?" "0"
REQ="$(last_request)"
check "json content-type" "$(field "$REQ" "['headers']['Content-Type']")" "application/json"
BODY="$(field "$REQ" "['body']")"
check "json escapes newline" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["content"])' <<<"$BODY")" "$(cat "$TMP/values/SMS")"
check "json tag from" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["from"])' <<<"$BODY")" "13800138000"
check "json receive_time format" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["time2"])' <<<"$BODY")" \
  "$(python3 -c 'import time; print(time.strftime("%H:%M", time.localtime(1700000000)))')"
check "json alias device_name" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["name"])' <<<"$BODY")" "Pixel 7"
SIGN="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["sign"])' <<<"$BODY")"
EXPECT="$(python3 - <<'PY'
import base64, hashlib, hmac, urllib.parse
ts = "1700000000001"
print(urllib.parse.quote(base64.b64encode(hmac.new(b"secret-key", (ts + "\n" + "secret-key").encode(), hashlib.sha256).digest()).decode(), safe=""))
PY
)"
check "json hmac signature" "$SIGN" "$EXPECT"
check "json timestamp tag" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["ts"])' <<<"$BODY")" "1700000000001"

# 2. Default form params (no template at all)
run send --url-file "$TMP/url" --method POST --values-dir "$TMP/values" --timestamp-ms 1700000000002
check "default form exit 0" "$?" "0"
REQ="$(last_request)"
check "default form content-type" "$(field "$REQ" "['headers']['Content-Type']")" "application/x-www-form-urlencoded; charset=utf-8"
check "default form body" "$(field "$REQ" "['body']")" "from=13800138000&content=Your+code+is+1234%0Asecond+line+%22quoted%22+%5C+back&timestamp=1700000000002"

# 3. GET with lowercase tags
printf 'from=[from]&msg=[content]&t=[timestamp]' > "$TMP/t_get"
run send --url-file "$TMP/url" --method GET --template-file "$TMP/t_get" --values-dir "$TMP/values" --timestamp-ms 1700000000003
check "get exit 0" "$?" "0"
check "get query" "$(field "$(last_request)" "['path']")" "/hook?from=13800138000&msg=Your+code+is+1234%0Asecond+line+%22quoted%22+%5C+back&t=1700000000003"

# 4. text/plain keeps values raw
printf 'Content-Type: text/plain; charset=utf-8\n' > "$TMP/h_text"
printf 'MSG=[msg]' > "$TMP/t_text"
run send --url-file "$TMP/url" --method PUT --template-file "$TMP/t_text" --values-dir "$TMP/values" \
  --headers-file "$TMP/h_text" --timestamp-ms 1700000000004
check "text send exit 0" "$?" "0"
check "text raw body" "$(field "$(last_request)" "['body']")" "MSG=$(cat "$TMP/values/SMS")"

# 5. response-match
printf 'http://127.0.0.1:%s/match/EXPECTED\n' "$PORT" > "$TMP/url_match"
run send --url-file "$TMP/url_match" --method POST --values-dir "$TMP/values" --response-match EXPECTED
check "response-match hit" "$?" "0"
printf 'http://127.0.0.1:%s/match/other\n' "$PORT" > "$TMP/url_nomatch"
run send --url-file "$TMP/url_nomatch" --method POST --values-dir "$TMP/values" --response-match EXPECTED 2>/dev/null
check "response-match miss" "$?" "10"

# 6. retry on 500 then success
BEFORE="$(count_requests)"
printf 'http://127.0.0.1:%s/flaky/2\n' "$PORT" > "$TMP/url_flaky"
run send --url-file "$TMP/url_flaky" --method POST --values-dir "$TMP/values" --retries 3 --retry-delay 1
check "retry eventually succeeds" "$?" "0"
check "retry used 3 attempts" "$(( $(count_requests) - BEFORE ))" "3"

# 7. network failure exit code
printf 'http://127.0.0.1:1/hook\n' > "$TMP/url_dead"
run send --url-file "$TMP/url_dead" --method POST --values-dir "$TMP/values" --retries 0 >/dev/null 2>&1
check "network failure exit 11" "$?" "11"

# 8. unknown tags are preserved, basic auth from url userinfo
printf 'http://user:pass@127.0.0.1:%s/auth\n' "$PORT" > "$TMP/url_auth"
printf 'x={{UNKNOWN}}' > "$TMP/t_unknown"
run send --url-file "$TMP/url_auth" --method POST --template-file "$TMP/t_unknown" --values-dir "$TMP/values"
check "basic auth exit 0" "$?" "0"
REQ="$(last_request)"
check "basic auth header" "$(field "$REQ" "['headers']['Authorization']")" "Basic dXNlcjpwYXNz"
check "basic auth stripped from url" "$(field "$REQ" "['path']")" "/auth"
check "unknown tag kept" "$(field "$REQ" "['body']")" "x={{UNKNOWN}}"
# 8b. cross-origin 307 redirects preserve representation headers but remove credentials
printf 'http://127.0.0.1:%s/redir307-localhost\n' "$PORT" > "$TMP/url_redir"
printf '{"content":"{{SMS}}"}' > "$TMP/t_redir"
printf 'Content-Type: application/json\nAuthorization: Bearer secret\nX-Api-Key: api-secret\nAccept: application/json\n' > "$TMP/h_redir"
run send --url-file "$TMP/url_redir" --method POST --template-file "$TMP/t_redir" \
  --values-dir "$TMP/values" --headers-file "$TMP/h_redir" --retries 0
check "cross-origin redirect send exit 0" "$?" "0"
REQ="$(last_request)"
check "cross-origin redirect reaches final path" "$(field "$REQ" "['path']")" "/final"
check "cross-origin redirect keeps content type" "$(field "$REQ" "['headers'].get('Content-Type','')")" "application/json"
check "cross-origin redirect keeps accept" "$(field "$REQ" "['headers'].get('Accept','')")" "application/json"
check "cross-origin redirect strips authorization" "$(field "$REQ" "['headers'].get('Authorization','')")" ""
check "cross-origin redirect strips api key" "$(field "$REQ" "['headers'].get('X-Api-Key','')")" ""
check "cross-origin redirect resends body" "$(printf '%s' "$REQ" | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["body"])["content"])')" "$(cat "$TMP/values/SMS")"

# 9. bare time tags must use the default format (SMSForwarder behaviour),
#    while {{TIMESTAMP}} stays in epoch millis
printf '{"rt":"{{RECEIVE_TIME}}","rt2":"[receive_time]","ct":"{{CURRENT_TIME}}","ts":{{TIMESTAMP}}}' > "$TMP/t_time"
run send --url-file "$TMP/url" --method POST --template-file "$TMP/t_time" --values-dir "$TMP/values" \
  --headers-file "$TMP/h_json" --timestamp-ms 1700000000005
check "bare time tags send exit 0" "$?" "0"
BODY="$(field "$(last_request)" "['body']")"
EXPECT_TIME="$(python3 -c 'import time; print(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(1700000000)))')"
check "bare {{RECEIVE_TIME}} formatted" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["rt"])' <<<"$BODY")" "$EXPECT_TIME"
check "bare [receive_time] formatted" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["rt2"])' <<<"$BODY")" "$EXPECT_TIME"
check "bare {{CURRENT_TIME}} formatted" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["ct"])' <<<"$BODY")" "$EXPECT_TIME"
check "{{TIMESTAMP}} stays millis" "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["ts"])' <<<"$BODY")" "1700000000005"

# 10. the signature is URL-encoded exactly once (Signer does it, Template must
#     not encode it again) for form bodies and GET query strings
printf 'http://127.0.0.1:%s/sign\n' "$PORT" > "$TMP/url_sign"
run send --url-file "$TMP/url_sign" --method POST --values-dir "$TMP/values" \
  --secret-file "$TMP/secret" --timestamp-ms 1700000000006
check "signed form send exit 0" "$?" "0"
BODY="$(field "$(last_request)" "['body']")"
EXPECT_SIGN="$(python3 - <<'PY'
import base64, hashlib, hmac, urllib.parse
ts = "1700000000006"
print(urllib.parse.quote(base64.b64encode(hmac.new(b"secret-key", (ts + "\n" + "secret-key").encode(), hashlib.sha256).digest()).decode(), safe=""))
PY
)"
check "form sign single-encoded" "${BODY##*&sign=}" "$EXPECT_SIGN"

printf 'from=[from]&sign=[sign]' > "$TMP/t_sign"
run send --url-file "$TMP/url_sign" --method GET --template-file "$TMP/t_sign" --values-dir "$TMP/values" \
  --secret-file "$TMP/secret" --timestamp-ms 1700000000007
check "signed get send exit 0" "$?" "0"
EXPECT_SIGN7="$(python3 - <<'PY'
import base64, hashlib, hmac, urllib.parse
ts = "1700000000007"
print(urllib.parse.quote(base64.b64encode(hmac.new(b"secret-key", (ts + "\n" + "secret-key").encode(), hashlib.sha256).digest()).decode(), safe=""))
PY
)"
check "get sign single-encoded" "$(field "$(last_request)" "['path']" | sed 's/.*&sign=//')" "$EXPECT_SIGN7"

# 15. SMSForwarder webhook placeholder parity: every documented tag must render
#     (the wiki list for POST/GET/PUT/PATCH bodies). Guards against a rename or a
#     dropped alias in Main.loadValues().
printf '%s' '[from]|[content]|[msg]|[org_content]|[receive_time]|[timestamp]|[sign]|[device_mark]|[app_version]|[card_slot]|[title]' > "$TMP/t_parity"
printf 'http://127.0.0.1:%s/parity\n' "$PORT" > "$TMP/url_parity"
run send --url-file "$TMP/url_parity" --method POST --template-file "$TMP/t_parity" \
  --headers-file "$TMP/h_json" --values-dir "$TMP/values" --secret-file "$TMP/secret" \
  --timestamp-ms 1700000000009 >/dev/null 2>&1
check "upstream placeholder template sends" "$?" "0"
PARITY="$(field "$(last_request)" "['body']")"
# the loop below can only be trusted if the body really arrived
check "parity body is rendered and non-empty" "$(python3 -c '
import json, sys
body = json.loads(open(sys.argv[1]).readline())["body"]
print("clean" if body and "[" not in body and "]" not in body and "13800138000" in body else "body=" + body[:90])' "$LOG")" "clean"
for tag in from content msg org_content receive_time timestamp sign device_mark app_version card_slot title; do
  case "$PARITY" in
    *"[$tag]"*) bad "placeholder [$tag] was left unrendered" ;;
    *) ok "placeholder [$tag] rendered" ;;
  esac
done

# 16. md5(...) expressions, like SMSForwarder's replaceMd5Template()
printf '%s' '{"digest":"md5([from]+[content]+'"'"'salt'"'"')"}' > "$TMP/t_md5"
printf 'http://127.0.0.1:%s/md5\n' "$PORT" > "$TMP/url_md5"
EXPECT_MD5="$(python3 -c '
import hashlib, sys
v = sys.argv[1]
print(hashlib.md5((open(v + "/FROM").read().rstrip("\n") + open(v + "/SMS").read().rstrip("\n") + "salt").encode()).hexdigest())' "$TMP/values")"
run send --url-file "$TMP/url_md5" --method POST --template-file "$TMP/t_md5" \
  --headers-file "$TMP/h_json" --values-dir "$TMP/values" >/dev/null 2>&1
check "md5() template sends" "$?" "0"
check "md5() hashes the concatenated tags" "$(field "$(last_request)" "['body']")" "{\"digest\":\"$EXPECT_MD5\"}"

echo
echo "payload tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
