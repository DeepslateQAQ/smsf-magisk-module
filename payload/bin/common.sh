#!/system/bin/sh
# common.sh - shared helpers for the smsfw webhook Magisk module.
# Sourced by smsfwd / smsfw. POSIX sh (Android mksh) + toybox tools only.

SMSF_DATA=${SMSF_DATA:-/data/adb/smsf}
SMSF_BIN_DIR=${SMSF_BIN_DIR:-$SMSF_DATA/bin}
SMSF_LIB=${SMSF_LIB:-$SMSF_DATA/lib}
SMSF_JAR=$SMSF_LIB/smsfw.jar
SMSF_CONF=$SMSF_DATA/config.conf
SMSF_STATE=$SMSF_DATA/state
SMSF_QUEUE=$SMSF_DATA/queue
SMSF_FAILED=$SMSF_DATA/failed
SMSF_TMP=$SMSF_DATA/tmp
SMSF_LOG_DIR=$SMSF_DATA/log
SMSF_LOG=$SMSF_LOG_DIR/smsfwd.log
SMSF_PID=$SMSF_STATE/daemon.pid
SMSF_VERSION_FILE=$SMSF_DATA/version
SMSF_RUNNER_CACHE=$SMSF_STATE/java.runner

# Binaries (overridable so the test harness can stub them on a desktop)
CONTENT_BIN=${SMSF_CONTENT_BIN:-/system/bin/content}
APP_PROCESS_BIN=${SMSF_APP_PROCESS:-/system/bin/app_process}
DALVIKVM_BIN=${SMSF_DALVIKVM:-/system/bin/dalvikvm}
GETPROP_BIN=${SMSF_GETPROP:-getprop}
DUMPSYS_BIN=${SMSF_DUMPSYS:-dumpsys}
IFCONFIG_BIN=${SMSF_IFCONFIG:-ifconfig}

SMSF_MODULE_DIR=${SMSF_MODULE_DIR:-/data/adb/modules/smsf_webhook}

# localized messages + gh-style helpers
if [ -f "$(dirname "$0")/i18n.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$(dirname "$0")/i18n.sh"
elif [ -f "$SMSF_BIN_DIR/i18n.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$SMSF_BIN_DIR/i18n.sh"
fi
if ! command -v msg >/dev/null 2>&1; then
    msg() { printf '%s' "$1"; }
fi

config_key_valid() {
    case "$1" in
        SMSFW_ENABLED|SMSFW_WEBHOOK_URL|SMSFW_METHOD|SMSFW_TEMPLATE_FILE|SMSFW_HEADERS_FILE|SMSFW_SECRET_FILE|SMSFW_DEVICE_NAME|SMSFW_RULE_TITLE|SMSFW_POLL_INTERVAL|SMSFW_DB_FULL_CHECK_INTERVAL|SMSFW_TIMEOUT|SMSFW_RETRIES|SMSFW_RETRY_DELAY|SMSFW_MAX_ATTEMPTS|SMSFW_QUEUE_LIMIT|SMSFW_FORWARD_EXISTING|SMSFW_TLS_INSECURE|SMSFW_RESPONSE_MATCH|SMSFW_FILTER_SENDER_ALLOW|SMSFW_FILTER_SENDER_BLOCK|SMSFW_FILTER_BODY_ALLOW|SMSFW_FILTER_BODY_BLOCK|SMSFW_LOG_LEVEL) return 0 ;;
        *) return 1 ;;
    esac
}

config_value() {
    raw=$1
    case "$raw" in
        \'*)
            quoted=$(printf '%s' "$raw" | sed -n "s/^'.*'[[:space:]]*#.*$/yes/p")
            if [ "$quoted" = yes ]; then
                value=$(printf '%s' "$raw" | sed -n "s/^'\\(.*\\)'[[:space:]]*#.*$/\\1/p")
            else
                value=$raw
                case "$value" in *\') value=${value#\'}; value=${value%\'} ;; esac
            fi
            printf '%s' "$value" | sed "s/'\\\\''/'/g"
            ;;
        *)
            printf '%s' "$raw" | sed 's/[[:space:]][#].*$//;s/[[:space:]]*$//'
            ;;
    esac
}

config_set_loaded() {
    case "$1" in
        SMSFW_ENABLED) SMSFW_ENABLED=$2 ;;
        SMSFW_WEBHOOK_URL) SMSFW_WEBHOOK_URL=$2 ;;
        SMSFW_METHOD) SMSFW_METHOD=$2 ;;
        SMSFW_TEMPLATE_FILE) SMSFW_TEMPLATE_FILE=$2 ;;
        SMSFW_HEADERS_FILE) SMSFW_HEADERS_FILE=$2 ;;
        SMSFW_SECRET_FILE) SMSFW_SECRET_FILE=$2 ;;
        SMSFW_DEVICE_NAME) SMSFW_DEVICE_NAME=$2 ;;
        SMSFW_RULE_TITLE) SMSFW_RULE_TITLE=$2 ;;
        SMSFW_POLL_INTERVAL) SMSFW_POLL_INTERVAL=$2 ;;
        SMSFW_DB_FULL_CHECK_INTERVAL) SMSFW_DB_FULL_CHECK_INTERVAL=$2 ;;
        SMSFW_TIMEOUT) SMSFW_TIMEOUT=$2 ;;
        SMSFW_RETRIES) SMSFW_RETRIES=$2 ;;
        SMSFW_RETRY_DELAY) SMSFW_RETRY_DELAY=$2 ;;
        SMSFW_MAX_ATTEMPTS) SMSFW_MAX_ATTEMPTS=$2 ;;
        SMSFW_QUEUE_LIMIT) SMSFW_QUEUE_LIMIT=$2 ;;
        SMSFW_FORWARD_EXISTING) SMSFW_FORWARD_EXISTING=$2 ;;
        SMSFW_TLS_INSECURE) SMSFW_TLS_INSECURE=$2 ;;
        SMSFW_RESPONSE_MATCH) SMSFW_RESPONSE_MATCH=$2 ;;
        SMSFW_FILTER_SENDER_ALLOW) SMSFW_FILTER_SENDER_ALLOW=$2 ;;
        SMSFW_FILTER_SENDER_BLOCK) SMSFW_FILTER_SENDER_BLOCK=$2 ;;
        SMSFW_FILTER_BODY_ALLOW) SMSFW_FILTER_BODY_ALLOW=$2 ;;
        SMSFW_FILTER_BODY_BLOCK) SMSFW_FILTER_BODY_BLOCK=$2 ;;
        SMSFW_LOG_LEVEL) SMSFW_LOG_LEVEL=$2 ;;
    esac
}

load_config() {
    SMSFW_ENABLED=1
    SMSFW_WEBHOOK_URL=''
    SMSFW_METHOD='POST'
    SMSFW_TEMPLATE_FILE=$SMSF_DATA/template.json
    SMSFW_HEADERS_FILE=$SMSF_DATA/headers.txt
    SMSFW_SECRET_FILE=$SMSF_DATA/secret
    SMSFW_DEVICE_NAME=''
    SMSFW_RULE_TITLE='sms'
    SMSFW_POLL_INTERVAL=5
    SMSFW_DB_FULL_CHECK_INTERVAL=60
    SMSFW_TIMEOUT=15
    SMSFW_RETRIES=2
    SMSFW_RETRY_DELAY=5
    SMSFW_MAX_ATTEMPTS=100
    SMSFW_QUEUE_LIMIT=200
    SMSFW_FORWARD_EXISTING=0
    SMSFW_TLS_INSECURE=0
    SMSFW_RESPONSE_MATCH=''
    SMSFW_FILTER_SENDER_ALLOW=''
    SMSFW_FILTER_SENDER_BLOCK=''
    SMSFW_FILTER_BODY_ALLOW=''
    SMSFW_FILTER_BODY_BLOCK=''
    SMSFW_LOG_LEVEL='info'
    if [ -f "$SMSF_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in \#*|'') continue ;; esac
            key=${line%%=*}
            [ "$key" = "$line" ] && continue
            config_key_valid "$key" || continue
            config_set_loaded "$key" "$(config_value "${line#*=}")"
        done < "$SMSF_CONF"
    fi
    [ -n "${SMSF_DEBUG:-}" ] && SMSFW_LOG_LEVEL=debug
    case "$SMSFW_POLL_INTERVAL" in ''|*[!0-9]*) SMSFW_POLL_INTERVAL=5 ;; esac
    [ "$SMSFW_POLL_INTERVAL" -lt 1 ] && SMSFW_POLL_INTERVAL=1
}

cfg_set() { # KEY VALUE -> rewrite config line
    key=$1
    value=$2
    config_key_valid "$key" || return 1
    esc=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
    tmp="$SMSF_CONF.tmp.$$"
    if [ -f "$SMSF_CONF" ]; then
        grep -v "^$key=" "$SMSF_CONF" > "$tmp" 2>/dev/null
    else
        : > "$tmp"
    fi
    printf "%s='%s'\n" "$key" "$esc" >> "$tmp"
    mv "$tmp" "$SMSF_CONF"
    chmod 600 "$SMSF_CONF" 2>/dev/null
}

cfg_get() { # KEY -> decoded value
    key=$1
    config_key_valid "$key" || return 1
    [ -f "$SMSF_CONF" ] || return 0
    value=$(sed -n "s/^$key=//p" "$SMSF_CONF" | tail -n 1)
    config_value "$value"
}

# ------------------------------------------------------------------ output style
#
# GitHub-CLI-like presentation: ✓ success, ✗ failure, ! warning, • info, ❯ cursor.
# Colours are only emitted for a TTY, so logs, pipes and tests stay plain text.
SMSF_ASCII=${SMSF_ASCII:-0}
if [ "$SMSF_ASCII" = "1" ]; then
    S_OK='[ok]'; S_ERR='[x]'; S_WARN='[!]'; S_INFO='-'; S_BULLET='-'; S_CUR='>'
else
    S_OK='✓'; S_ERR='✗'; S_WARN='!'; S_INFO='•'; S_BULLET='•'; S_CUR='❯'
fi
if [ -t 1 ]; then
    C_RESET=$(printf '\033[0m'); C_BOLD=$(printf '\033[1m'); C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[31m'); C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m'); C_CYAN=$(printf '\033[36m')
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

# gh_ok KEY [ARGS] / gh_err / gh_warn / gh_info  -> styled, localized line
gh_ok()   { printf '%s%s%s %s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$(msg "$@")"; }
gh_err()  { printf '%s%s%s %s\n' "$C_RED" "$S_ERR" "$C_RESET" "$(msg "$@")" >&2; }
gh_warn() { printf '%s%s%s %s\n' "$C_YELLOW" "$S_WARN" "$C_RESET" "$(msg "$@")" >&2; }
gh_info() { printf '%s%s%s %s\n' "$C_DIM" "$S_INFO" "$C_RESET" "$(msg "$@")" >&2; }
gh_kv()   { printf '  %s%-14s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }
gh_head() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

# ------------------------------------------------------------------ logging

_log_symbol() { # LEVEL -> gh-style symbol
    case "$1" in
        info)  printf '%s' "$S_OK" ;;
        warn)  printf '%s' "$S_WARN" ;;
        error) printf '%s' "$S_ERR" ;;
        *)     printf '%s' "$S_INFO" ;;
    esac
}

_log_write() { # LEVEL TEXT
    # A failed redirection would print a shell error of its own, so check first
    # (the data dir may be read-only or not created yet).
    [ -d "$SMSF_LOG_DIR" ] && [ -w "$SMSF_LOG_DIR" ] || return 0
    printf '%s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(_log_symbol "$1")" "$2" >> "$SMSF_LOG" 2>/dev/null
}

log_at() { # LEVEL KEY ARGS...
    lvl=$1
    shift
    if [ "$lvl" = "debug" ] && [ "$SMSFW_LOG_LEVEL" != "debug" ]; then
        return 0
    fi
    _log_write "$lvl" "$(msg "$@")"
}

# Literal (untranslated) line - used for verbose diagnostics.
log_raw() { # LEVEL TEXT...
    lvl=$1
    shift
    if [ "$lvl" = "debug" ] && [ "$SMSFW_LOG_LEVEL" != "debug" ]; then
        return 0
    fi
    _log_write "$lvl" "$*"
}

log_debug() { log_at debug "$@"; }
log_info()  { log_at info "$@"; }
log_warn()  { log_at warn "$@"; }
log_error() { log_at error "$@"; }

rotate_log() {
    size=$(wc -c < "$SMSF_LOG" 2>/dev/null | tr -d ' ')
    case "$size" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ "$size" -gt 1048576 ]; then
        mv "$SMSF_LOG" "$SMSF_LOG.1" 2>/dev/null
        log_info LOG_ROTATED
    fi
}

# ------------------------------------------------------------------ system

now_s() { date +%s; }
# Android mksh arithmetic is 32-bit; append milliseconds instead of multiplying seconds.
now_ms() { printf '%s000' "$(now_s)"; }

ensure_dirs() {
    case "$SMSF_DATA" in
        ''|/) return 1 ;;
    esac
    for d in "$SMSF_DATA" "$SMSF_BIN_DIR" "$SMSF_LIB" "$SMSF_STATE" "$SMSF_QUEUE" \
             "$SMSF_FAILED" "$SMSF_TMP" "$SMSF_LOG_DIR"; do
        [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
    done
    chmod 700 "$SMSF_DATA" "$SMSF_STATE" "$SMSF_QUEUE" "$SMSF_FAILED" "$SMSF_TMP" 2>/dev/null
    [ -d "$SMSF_DATA" ]
}

module_version() {
    if [ -f "$SMSF_VERSION_FILE" ]; then
        cat "$SMSF_VERSION_FILE"
    elif [ -f "$SMSF_MODULE_DIR/module.prop" ]; then
        sed -n 's/^version=//p' "$SMSF_MODULE_DIR/module.prop" | head -n 1
    else
        echo "unknown"
    fi
}

# ------------------------------------------------------------------ content provider
#
# `/system/bin/content` NEVER exits non-zero (AOSP cmds/content/Content.java:
# main() just calls parseCommand()/execute() and execute() catches errors), so
# nothing may be gated on $?. The observable contract is:
#   * one stdout line per row: "Row: <index> <col>=<value>, <col>=<value>"
#     (values appended verbatim, no newline escaping)
#   * empty result set: stdout "No result found."
#   * NULL column value: the literal string "NULL"
#   * bad/unsupported argument: stdout "usage: ..." + "[ERROR] <msg>"
#   * provider failure: stderr "Error while accessing provider:" + stack trace
#   * --user <n> exists but every parse*Command() already defaults userId to
#     UserHandle.USER_SYSTEM, so pinning user 0 is unnecessary.
# Validation below therefore inspects the output, never the exit status.
SMSF_HAS_SUB_ID=1

# Stdout carries rows (or "No result found."); stderr carries provider failures
# and ART noise. Returns rc=1 only when the query really failed.
content_fetch() { # URI PROJECTION [WHERE] [SORT] -> stdout rows, rc=1 on error
    uri=$1
    proj=$2
    where=${3:-}
    sort=${4:-}
    if [ -d "$SMSF_TMP" ] || mkdir -p "$SMSF_TMP" 2>/dev/null; then
        errf="$SMSF_TMP/content.err"
        if [ -n "$where" ] && [ -n "$sort" ]; then
            out=$($CONTENT_BIN query --uri "$uri" --projection "$proj" --where "$where" --sort "$sort" 2>"$errf")
        elif [ -n "$where" ]; then
            out=$($CONTENT_BIN query --uri "$uri" --projection "$proj" --where "$where" 2>"$errf")
        elif [ -n "$sort" ]; then
            out=$($CONTENT_BIN query --uri "$uri" --projection "$proj" --sort "$sort" 2>"$errf")
        else
            out=$($CONTENT_BIN query --uri "$uri" --projection "$proj" 2>"$errf")
        fi
        err=$(cat "$errf" 2>/dev/null)
    else
        # No scratch dir: never merge the streams. Provider/ART messages on
        # stderr would be indistinguishable from row data in either direction.
        if [ -n "$where" ] && [ -n "$sort" ]; then
            out=$($CONTENT_BIN query --uri "$uri" --projection "$proj" --where "$where" --sort "$sort" 2>/dev/null)
        elif [ -n "$where" ]; then
            out=$($CONTENT_BIN query --uri "$uri" --projection "$proj" --where "$where" 2>/dev/null)
        elif [ -n "$sort" ]; then
            out=$($CONTENT_BIN query --uri "$uri" --projection "$proj" --sort "$sort" 2>/dev/null)
        else
            out=$($CONTENT_BIN query --uri "$uri" --projection "$proj" 2>/dev/null)
        fi
        err=''
    fi

    # Classify strictly by the SHAPE of stdout. An SMS body is arbitrary text:
    # it may contain "usage:", "[ERROR]" or "Error while accessing provider:"
    # (bank/technical messages do), so row content must never influence the
    # verdict. A body query always starts with "Row: " because the value follows
    # the "Row: <n> <col>=" prefix on the same line.
    case "$out" in
        'Row: '*) printf '%s' "$out"; return 0 ;;
        'No result found.') return 0 ;;
        '')
            # Empty stdout is the one ambiguous shape: a successful empty result
            # prints the sentinel above, so empty output plus a provider failure
            # on stderr means the provider is not reachable. stderr is consulted
            # only here, never for outputs that qualify as data.
            case "$err" in
                *"Error while accessing provider"*|*"[ERROR]"*|*"usage:"*|*"not found"*)
                    log_raw debug "content query failed ($uri): $(printf '%s' "$err" | head -n 1)"
                    return 1 ;;
            esac
            return 0 ;;
        *)
            log_raw debug "unexpected content output ($uri): $(printf '%s' "$out" | head -n 1)"
            return 1 ;;
    esac
}

probe_content() {
    content_fetch content://sms/inbox _id '_id < 0' >/dev/null || return 1
    if ! content_fetch content://sms/inbox _id:sub_id '_id < 0' >/dev/null; then
        SMSF_HAS_SUB_ID=0
    fi
    return 0
}

# The telephony provider lives on a device-encrypted (user_de) database, which
# exists before first unlock. `content query` starts a whole ART VM, so the
# daemon only asks the provider when one of these files actually changed.
SMSF_DB_CANDIDATES=${SMSF_DB_CANDIDATES:-/data/user_de/0/com.android.providers.telephony/databases/mmssms.db /data/data/com.android.providers.telephony/databases/mmssms.db}

sms_db_path() {
    for base in $SMSF_DB_CANDIDATES; do
        if [ -f "$base" ]; then
            printf '%s' "$base"
            return 0
        fi
    done
    return 1
}

sms_db_fingerprint() {
    base=$(sms_db_path) || return 1
    fp=''
    # WAL mode: an SMS insert lands in the -wal file (created on the first write
    # after a checkpoint). -shm is deliberately NOT fingerprinted: readers update
    # its read-mark slots, so its mtime changes even when no message arrived and
    # the gate would never close. -journal only exists in rollback mode, where
    # the main db file itself changes.
    for suffix in '' '-wal'; do
        f="$base$suffix"
        [ -f "$f" ] || continue
        st=$(stat -c '%s:%Y' "$f" 2>/dev/null)
        [ -n "$st" ] && fp="$fp|$st"
    done
    [ -n "$fp" ] || return 1
    printf '%s' "$fp"
}

ids_after() { # LAST_ID -> one inbox message id per line, ascending
    rows=$(content_fetch content://sms/inbox _id "_id > $1" '_id ASC') || return 1
    printf '%s' "$rows" | sed -n 's/^Row: [0-9][0-9]* _id=\([0-9][0-9]*\).*$/\1/p'
}

max_inbox_id() {
    rows=$(content_fetch content://sms/inbox _id '' '_id DESC') || return 1
    printf '%s' "$rows" | sed -n 's/^Row: [0-9][0-9]* _id=\([0-9][0-9]*\).*$/\1/p' | head -n 1
}

sms_field() { # ID COLUMN -> value (multi-line preserved), rc=1 when unavailable
    out=$(content_fetch "content://sms/$1" "$2") || return 1
    case "$out" in
        'Row: '*) ;;
        *) return 1 ;;
    esac
    value=$(printf '%s' "${out#Row: }" | sed '1s/^[0-9][0-9]* [A-Za-z_][A-Za-z_0-9]*=//')
    [ "$value" = "NULL" ] && value=''
    printf '%s' "$value"
}

sim_lookup() { # SUB_ID -> "display_name|slot_index" (best effort)
    sub_id=$1
    [ -n "$sub_id" ] || return 1
    out=$(content_fetch content://telephony/siminfo 'display_name:slot_index' "_id=$sub_id") || out=''
    name=$(printf '%s\n' "$out" | sed -n 's/^Row: [0-9][0-9]* display_name=\(.*\), slot_index=[0-9-]*$/\1/p' | head -n 1)
    slot=$(printf '%s\n' "$out" | sed -n 's/^Row: [0-9][0-9]* display_name=.*, slot_index=\([0-9-]*\)$/\1/p' | head -n 1)
    if [ -z "$name" ] && [ -z "$slot" ]; then
        out=$(content_fetch content://telephony/siminfo 'display_name' "_id=$sub_id") || out=''
        name=$(printf '%s\n' "$out" | sed -n 's/^Row: [0-9][0-9]* display_name=//p' | head -n 1)
    fi
    [ "$name" = "NULL" ] && name=''
    [ "$slot" = "NULL" ] && slot=''
    [ -n "$name" ] || [ -n "$slot" ] || return 1
    printf '%s|%s' "$name" "$slot"
}

battery_info() { # -> "level|status_text"
    out=$($DUMPSYS_BIN battery 2>/dev/null)
    level=$(printf '%s\n' "$out" | sed -n 's/^ *level: *//p' | head -n 1)
    status=$(printf '%s\n' "$out" | sed -n 's/^ *status: *//p' | head -n 1)
    case "$status" in
        2) status=charging ;;
        3) status=discharging ;;
        4) status=not-charging ;;
        5) status=full ;;
        1|'') status=unknown ;;
    esac
    [ -n "$level" ] || level=''
    printf '%s|%s' "$level" "$status"
}

ipv4_address() {
    $IFCONFIG_BIN 2>/dev/null | sed -n 's/^ *inet addr:\([0-9][0-9.]*\).*/\1/p
                                      s/^ *inet \([0-9][0-9.]*\).*/\1/p' \
        | grep -v '^127\.' | head -n 1
}

device_name() {
    if [ -n "$SMSFW_DEVICE_NAME" ]; then
        printf '%s' "$SMSFW_DEVICE_NAME"
        return 0
    fi
    model=$($GETPROP_BIN ro.product.model 2>/dev/null || true)
    brand=$($GETPROP_BIN ro.product.brand 2>/dev/null || true)
    if [ -n "$brand" ] && [ -n "$model" ]; then
        printf '%s %s' "$brand" "$model"
    elif [ -n "$model" ]; then
        printf '%s' "$model"
    else
        hostname 2>/dev/null || uname -n 2>/dev/null || echo Android
    fi
}

# ------------------------------------------------------------------ filters

regex_match() { # VALUE REGEX
    [ -n "$2" ] || return 1
    printf '%s' "$1" | grep -Eq -- "$2"
}

passes_filters() { # SENDER BODY
    sender=$1
    body=$2
    if [ -n "$SMSFW_FILTER_SENDER_ALLOW" ] && ! regex_match "$sender" "$SMSFW_FILTER_SENDER_ALLOW"; then
        log_raw debug "filtered: sender=$sender reason=not-allowed"
        return 1
    fi
    if [ -n "$SMSFW_FILTER_SENDER_BLOCK" ] && regex_match "$sender" "$SMSFW_FILTER_SENDER_BLOCK"; then
        log_raw debug "filtered: sender=$sender reason=blocked"
        return 1
    fi
    if [ -n "$SMSFW_FILTER_BODY_ALLOW" ] && ! regex_match "$body" "$SMSFW_FILTER_BODY_ALLOW"; then
        log_raw debug "filtered: body reason=not-allowed"
        return 1
    fi
    if [ -n "$SMSFW_FILTER_BODY_BLOCK" ] && regex_match "$body" "$SMSFW_FILTER_BODY_BLOCK"; then
        log_raw debug "filtered: body reason=blocked"
        return 1
    fi
    return 0
}

template_uses_tag() { # TAG
    tag=$1
    for f in "$SMSFW_TEMPLATE_FILE" "$SMSFW_HEADERS_FILE"; do
        [ -f "$f" ] || continue
        if grep -qi "{{$tag" "$f" 2>/dev/null || grep -qi "\[$tag" "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------ payload runner

# Hard kill-switch so a wedged ART/HTTP call can never freeze the daemon.
if command -v timeout >/dev/null 2>&1; then
    SMSF_TIMEOUT_CMD="timeout 180"
else
    SMSF_TIMEOUT_CMD=""
fi

# SMSF_TIMEOUT_CMD is intentionally unquoted: "" or "timeout 180".
# Invocation shape (app_main.cpp): app_process [vm-opts] <parent-dir> [--nice-name=N] <class> [args...]
#   * VM options must come FIRST (the loop feeds leading '-' args to the VM),
#   * the "parent dir" is skipped with `++i`,
#   * --nice-name= is parsed AFTER that skip, so it must sit after <parent-dir>
#     (putting it before would make the parent dir be taken as the class name).
# AOSP's own /system/bin/content uses the CLASSPATH env form; Shizuku-style
# tools use the -Djava.class.path form which is kept as the fallback.
# shellcheck disable=SC2086
payload_version() { # RUNNER
    case "$1" in
        app_process)
            $SMSF_TIMEOUT_CMD env CLASSPATH=$SMSF_JAR $APP_PROCESS_BIN /system/bin --nice-name=smsfw com.smsfw.Main version 2>/dev/null
            ;;
        app_process_d)
            $SMSF_TIMEOUT_CMD $APP_PROCESS_BIN -Djava.class.path="$SMSF_JAR" /system/bin --nice-name=smsfw com.smsfw.Main version 2>/dev/null
            ;;
        dalvikvm)
            $SMSF_TIMEOUT_CMD $DALVIKVM_BIN -cp "$SMSF_JAR" com.smsfw.Main version 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

probe_runner() {
    [ -f "$SMSF_JAR" ] || { echo none; return 0; }
    for r in app_process app_process_d dalvikvm; do
        if [ -n "$(payload_version $r)" ]; then
            echo "$r"
            return 0
        fi
    done
    echo none
}

# shellcheck disable=SC2086
run_payload() { # ARGS...
    runner=$(cat "$SMSF_RUNNER_CACHE" 2>/dev/null)
    if [ -z "$runner" ] || [ "$runner" = "none" ]; then
        runner=$(probe_runner)
        printf '%s\n' "$runner" > "$SMSF_RUNNER_CACHE" 2>/dev/null
    fi
    case "$runner" in
        app_process)
            $SMSF_TIMEOUT_CMD env CLASSPATH=$SMSF_JAR $APP_PROCESS_BIN /system/bin --nice-name=smsfw com.smsfw.Main "$@"
            ;;
        app_process_d)
            $SMSF_TIMEOUT_CMD $APP_PROCESS_BIN -Djava.class.path="$SMSF_JAR" /system/bin --nice-name=smsfw com.smsfw.Main "$@"
            ;;
        dalvikvm)
            $SMSF_TIMEOUT_CMD $DALVIKVM_BIN -cp "$SMSF_JAR" com.smsfw.Main "$@"
            ;;
        *)
            log_error RUNNER_MISSING "$SMSF_JAR"
            return 3
            ;;
    esac
}

# ------------------------------------------------------------------ sending

send_record() { # RECORD_DIR -> 0 ok, 10 http, 11 network, other error
    d=$1
    [ -f "$d/url" ] || { log_error RECORD_NO_URL "$d"; return 3; }
    method=$(cat "$d/method" 2>/dev/null)
    [ -n "$method" ] || method=POST
    timeout_s=$(cat "$d/timeout" 2>/dev/null)
    [ -n "$timeout_s" ] || timeout_s=$SMSFW_TIMEOUT
    retries=$(cat "$d/retries" 2>/dev/null)
    [ -n "$retries" ] || retries=$SMSFW_RETRIES
    retry_delay=$(cat "$d/retry_delay" 2>/dev/null)
    [ -n "$retry_delay" ] || retry_delay=$SMSFW_RETRY_DELAY
    insecure=$(cat "$d/insecure" 2>/dev/null)
    expected=$(cat "$d/expected" 2>/dev/null)

    set -- send --url-file "$d/url" --method "$method" --values-dir "$d/values" \
        --timeout "$timeout_s" --retries "$retries" --retry-delay "$retry_delay" \
        --response-file "$d/response"
    [ -f "$d/template" ] && set -- "$@" --template-file "$d/template"
    [ -f "$d/headers" ] && set -- "$@" --headers-file "$d/headers"
    [ -f "$d/secret" ] && set -- "$@" --secret-file "$d/secret"
    [ -n "$expected" ] && set -- "$@" --response-match "$expected"
    [ "$insecure" = "1" ] && set -- "$@" --insecure

    run_payload "$@" >>"$SMSF_LOG" 2>&1
    return $?
}

# ------------------------------------------------------------------ records

new_record_dir() { # NAME -> path (rc=1 and no output when it cannot be created)
    # Guard against an empty/unset base: an empty $SMSF_TMP would make the
    # derived paths absolute ("/values/...") and write outside the module.
    case "$SMSF_TMP" in
        ''|/) return 1 ;;
    esac
    [ -n "$1" ] || return 1
    if [ ! -d "$SMSF_TMP" ] && ! mkdir -p "$SMSF_TMP" 2>/dev/null; then
        return 1
    fi
    dir="$SMSF_TMP/$1.$$.$(now_s)"
    rm -rf "$dir"
    mkdir -p "$dir/values" || return 1
    printf '%s' "$dir"
}

# Every command that writes into the data dir goes through this first.
require_data_dir() {
    case "$SMSF_DATA" in
        ''|/) return 1 ;;
    esac
    [ -d "$SMSF_DATA" ] && [ -w "$SMSF_DATA" ]
}

# Capture the current webhook config into a record so queued messages keep
# using the settings that were active when the SMS arrived.
snapshot_config_into() { # RECORD_DIR
    d=$1
    [ -n "$d" ] || return 1
    printf '%s' "$SMSFW_WEBHOOK_URL" > "$d/url"
    printf '%s' "${SMSFW_METHOD:-POST}" > "$d/method"
    printf '%s' "$SMSFW_TIMEOUT" > "$d/timeout"
    printf '%s' "$SMSFW_RETRIES" > "$d/retries"
    printf '%s' "$SMSFW_RETRY_DELAY" > "$d/retry_delay"
    printf '%s' "$SMSFW_TLS_INSECURE" > "$d/insecure"
    printf '%s' "$SMSFW_RESPONSE_MATCH" > "$d/expected"
    [ -f "$SMSFW_TEMPLATE_FILE" ] && cp "$SMSFW_TEMPLATE_FILE" "$d/template"
    [ -f "$SMSFW_HEADERS_FILE" ] && cp "$SMSFW_HEADERS_FILE" "$d/headers"
    [ -f "$SMSFW_SECRET_FILE" ] && cp "$SMSFW_SECRET_FILE" "$d/secret"
    return 0
}

enqueue_record() { # RECORD_DIR -> queued path
    d=$1
    base=$(basename "$d")
    stamp=$(printf '%010d' "$(now_s)")
    name="$stamp-$$-$base"
    # Two records created in the same second with the same pid and name would
    # collide, and a bare `mv` into an existing directory would nest the second
    # record inside the first (silently losing it). Keep names unique.
    n=0
    while [ -e "$SMSF_QUEUE/$name" ]; do
        # Tie-breaker for the (already unlikely) same-second, same-pid, same-name
        # case. A counter guarantees the loop terminates; a random fallback could
        # in principle repeat forever.
        n=$((n + 1))
        name="$stamp-$$-$n-$base"
    done
    target="$SMSF_QUEUE/$name"
    mv "$d" "$target" || return 1
    printf '%s' "$target"
}

# Queue entry names are generated by this module (<digits>-<pid>-<name>), so
# parsing ls output is safe here and cheaper than find on toybox.
# shellcheck disable=SC2012
queue_dirs() {
    ls -d "$SMSF_QUEUE"/*/ 2>/dev/null | LC_ALL=C sort
}

# shellcheck disable=SC2012
queue_count() {
    ls -d "$SMSF_QUEUE"/*/ 2>/dev/null | wc -l | tr -d ' '
}

# shellcheck disable=SC2012
failed_count() {
    ls -d "$SMSF_FAILED"/*/ 2>/dev/null | wc -l | tr -d ' '
}

# ------------------------------------------------------------------ counters

counter_get() { # NAME
    cat "$SMSF_STATE/$1" 2>/dev/null | tr -dc '0-9'
}

counter_add() { # NAME DELTA
    name=$1
    delta=$2
    cur=$(counter_get "$name")
    [ -n "$cur" ] || cur=0
    printf '%s' "$((cur + delta))" > "$SMSF_STATE/$name"
}

json_num() {
    case "$1" in
        ''|*[!0-9]*) printf '%s' "${2:-0}" ;;
        *)           printf '%s' "$1" ;;
    esac
}

# Minimal JSON string escaping for single-line values (urls, paths, names).
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'
}

# ------------------------------------------------------------------ tested state

SMSF_TESTED=$SMSF_STATE/tested.fingerprint

config_fingerprint() {
    fp="$SMSFW_WEBHOOK_URL|$SMSFW_METHOD|$SMSFW_RESPONSE_MATCH|$SMSFW_TLS_INSECURE"
    for f in "$SMSFW_TEMPLATE_FILE" "$SMSFW_HEADERS_FILE" "$SMSFW_SECRET_FILE"; do
        if [ -f "$f" ]; then
            fp="$fp|$f=$(stat -c '%s:%Y' "$f" 2>/dev/null)"
        else
            fp="$fp|$f=-"
        fi
    done
    printf '%s' "$fp" | md5sum 2>/dev/null | tr -d ' -'
}

mark_config_tested() {
    case "$SMSF_STATE" in
        ''|/) return 1 ;;
    esac
    [ -d "$SMSF_STATE" ] || return 1
    config_fingerprint > "$SMSF_TESTED" 2>/dev/null
}

config_was_tested() {
    [ -f "$SMSF_TESTED" ] || return 1
    [ "$(config_fingerprint)" = "$(cat "$SMSF_TESTED" 2>/dev/null)" ]
}

# ------------------------------------------------------------------ daemon control

# A pid file survives reboot and Android can reuse low PIDs, so kill -0 alone
# is not proof that the process belongs to this daemon.
pid_is_ours() { # PID
    pid=$1
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    case "$cmd" in
        *smsfwd*) return 0 ;;
        *) return 1 ;;
    esac
}

_pid_from_file() { # FILE
    [ -f "$1" ] || return 1
    pid=$(cat "$1" 2>/dev/null)
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    pid_is_ours "$pid" || return 1
    printf '%s' "$pid"
}

daemon_pid() { _pid_from_file "$SMSF_PID"; }

worker_pid() { _pid_from_file "$SMSF_STATE/worker.pid"; }

start_daemon() {
    ensure_dirs
    pid=$(daemon_pid)
    if [ -n "$pid" ]; then
        log_info DAEMON_ALREADY "$pid"
        return 0
    fi
    # A worker without its supervisor would keep polling and racing a new daemon.
    stale=$(worker_pid)
    if [ -n "$stale" ]; then
        log_info REAPED_WORKER "$stale"
        kill "$stale" 2>/dev/null
        sleep 1
        kill -9 "$stale" 2>/dev/null
    fi
    rm -f "$SMSF_PID" "$SMSF_STATE/worker.pid"
    rotate_log
    if command -v setsid >/dev/null 2>&1; then
        setsid "$SMSF_BIN_DIR/smsfwd" supervise >>"$SMSF_LOG" 2>&1 &
    elif command -v nohup >/dev/null 2>&1; then
        nohup "$SMSF_BIN_DIR/smsfwd" supervise >>"$SMSF_LOG" 2>&1 &
    else
        "$SMSF_BIN_DIR/smsfwd" supervise >>"$SMSF_LOG" 2>&1 &
    fi
    # setsid/nohup may fork before publishing the supervisor PID.
    i=0
    while [ "$i" -lt 30 ]; do
        pid=$(daemon_pid)
        if [ -n "$pid" ]; then
            log_info DAEMON_STARTED "$pid"
            return 0
        fi
        sleep 0.2 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    log_warn DAEMON_START_FAILED "$SMSF_LOG"
    return 1
}

stop_daemon() {
    supervisor=$(daemon_pid)
    worker=$(worker_pid)
    if [ -n "$supervisor" ]; then
        kill "$supervisor" 2>/dev/null
    fi
    if [ -n "$worker" ]; then
        kill "$worker" 2>/dev/null
    fi
    i=0
    while [ "$i" -lt 20 ]; do
        alive=0
        [ -n "$supervisor" ] && kill -0 "$supervisor" 2>/dev/null && alive=1
        [ -n "$worker" ] && kill -0 "$worker" 2>/dev/null && alive=1
        [ "$alive" = "0" ] && break
        sleep 1
        i=$((i + 1))
    done
    [ -n "$supervisor" ] && kill -9 "$supervisor" 2>/dev/null
    [ -n "$worker" ] && kill -9 "$worker" 2>/dev/null
    [ -n "$supervisor" ] && log_info DAEMON_STOPPED "$supervisor"
    rm -f "$SMSF_PID" "$SMSF_STATE/worker.pid"
}
