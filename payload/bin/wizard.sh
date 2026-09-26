#!/system/bin/sh
# wizard.sh - interactive setup wizard for smsfw, sourced by the smsfw CLI.
#
# Scope: ONLY the generic HTTP(S) webhook push (no channel presets).
#
# Prompt style follows GitHub CLI: "? question" with an arrow-key menu, a
# placeholder/default that Enter accepts, masked secret input, in-place redraw
# and a final summary. When stdin is not a TTY (adb pipe, script) every prompt
# degrades to a plain numbered/line prompt so the same flow stays scriptable.
#
# Step order mirrors SMSForwarder's sender page:
#   名称 -> 启用 -> 请求方式 -> 推送地址 -> 密钥 -> 响应校验 -> 请求参数(模板)
#   -> 请求头 -> 代理 -> 转发规则 -> 高级 -> 测试并保存
#
# Nothing is written into /data/adb/smsf until the final confirmation: headers,
# template and secret are staged in $SMSF_TMP and moved into place at the end,
# so cancelling (Esc/Ctrl-C/EOF) never destroys existing data.

# ------------------------------------------------------------------ styling

# Symbols and colours come from common.sh (gh-style, TTY-aware, SMSF_ASCII).

WIZ_TTY=0
WIZ_STAGE=''

wiz_print() { printf '%s\n' "$*" >&2; }        # raw option lists for wiz_menu
wiz_ok()   { gh_ok "$@"; }
wiz_warn() { gh_warn "$@"; }
wiz_dim()  { gh_info "$@"; }
wiz_head() { gh_head "$1"; }

# ------------------------------------------------------------------ terminal

wiz_tty_start() {
    [ "$WIZ_TTY" = "1" ] && return 0
    if [ -t 1 ] && [ -r /dev/tty ] && command -v stty >/dev/null 2>&1 &&
       stty -icanon -echo min 0 time 1 < /dev/tty 2>/dev/null; then
        WIZ_TTY=1
        # INT/TERM must restore the terminal *and* leave: dd is interrupted by
        # the signal, so simply returning would continue in cooked mode.
        trap 'wiz_tty_stop' EXIT
        trap 'wiz_tty_stop; exit 130' INT TERM
    else
        WIZ_TTY=0
    fi
}

wiz_tty_stop() {
    if [ "$WIZ_TTY" = "1" ]; then
        stty sane < /dev/tty 2>/dev/null
        WIZ_TTY=0
    fi
}

# One raw key -> up|down|enter|space|backspace|ctrl-c|esc|idle|char:X
# The tty stays in `min 0 time 1` for the whole session (set in wiz_tty_start).
#
# Bytes are read as DECIMAL CODES, never as text: command substitution strips
# trailing newlines, so `$(dd bs=1 count=1)` turns an Enter (CR -> LF via ICRNL,
# which is the default on terminals) into an empty string and the key would look
# like a timeout. 27=ESC, 91='[', 65/66/67/68=A/B/C/D, 10/13=LF/CR, 127/'8'=DEL/BS.
wiz_read_byte() {
    dd bs=1 count=1 2>/dev/null < /dev/tty | od -An -t u1 2>/dev/null | tr -d ' \n'
}

wiz_read_key() {
    b=$(wiz_read_byte)
    case "$b" in
        '')
            printf 'idle' ;;
        '10'|'13')
            printf 'enter' ;;
        '32')
            printf 'space' ;;
        '127'|'8')
            printf 'backspace' ;;
        '3')
            printf 'ctrl-c' ;;
        '27')
            b2=$(wiz_read_byte)
            if [ "$b2" = "91" ]; then
                b3=$(wiz_read_byte)
                case "$b3" in
                    65) printf 'up' ;;
                    66) printf 'down' ;;
                    67) printf 'right' ;;
                    68) printf 'left' ;;
                    *)  printf 'esc' ;;
                esac
            else
                printf 'esc'
            fi ;;
        *)
            # rebuild the byte from its octal code (format string is built here
            # on purpose); shellcheck disable=SC2059
            ch=$(printf "\\$(printf '%03o' "$b")")
            printf 'char:%s' "$ch" ;;
    esac
}

# Wait for a real key. EOF (piped input exhausted) or a long silence aborts
# instead of silently accepting a default.
wiz_wait_key() {
    idle=0
    while :; do
        key=$(wiz_read_key)
        case "$key" in
            idle)
                idle=$((idle + 1))
                if [ "$idle" -ge 50 ]; then
                    printf 'abort'
                    return 0
                fi
                sleep 0.05 2>/dev/null || sleep 1
                continue ;;
            *)
                printf '%s' "$key"
                return 0 ;;
        esac
    done
}

# ------------------------------------------------------------------ prompts

# Terminal width in columns (0 when unknown). Used to keep a menu row from
# wrapping: with wrapping, "move up n rows" would no longer line up.
wiz_cols() {
    size=$(stty size < /dev/tty 2>/dev/null)
    cols=${size##* }
    case "$cols" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "$cols" ;;
    esac
}

# Truncate TEXT so it cannot wrap: at most MAX display columns. With a UTF-8
# locale this peels whole characters and counts non-ASCII as two columns; without
# one it falls back to a byte budget (every column needs at least one byte, so a
# byte-limited line can never exceed MAX columns). Android shells usually have no
# locale set, so the fallback is the path that matters there.
wiz_fit() { # TEXT MAX
    text=$1
    max=$2
    case "$max" in
        ''|*[!0-9]*) printf '%s' "$text"; return 0 ;;
    esac
    [ "$max" -ge 1 ] || { printf '%s' "$text"; return 0; }
    out=''
    case "${LC_ALL:-${LANG:-}}" in
        *UTF-8*|*utf8*|*UTF8*)
            used=0
            while [ -n "$text" ]; do
                ch=${text%"${text#?}"}
                text=${text#?}
                case "$ch" in
                    [!-~]*) w=2 ;;
                    *)      w=1 ;;
                esac
                [ $((used + w)) -gt "$max" ] && break
                out="$out$ch"
                used=$((used + w))
            done ;;
        *)
            while [ -n "$text" ]; do
                ch=${text%"${text#?}"}
                [ $(( ${#out} + ${#ch} )) -gt "$max" ] && break
                out="$out$ch"
                text=${text#?}
            done ;;
    esac
    printf '%s' "$out"
}

# wiz_menu PROMPT DEFAULT_INDEX OPTIONS_NEWLINE -> prints chosen index
wiz_menu() {
    prompt=$1
    idx=$2
    opts=$3
    n=0
    old_ifs=$IFS
    IFS='
'
    for o in $opts; do
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || { IFS=$old_ifs; return 1; }
    [ "$idx" -ge "$n" ] && idx=$((n - 1))
    [ "$idx" -lt 0 ] && idx=0

    if [ "$WIZ_TTY" != "1" ]; then
        wiz_print "$prompt"
        i=0
        for o in $opts; do
            printf '  %d) %s\n' "$((i + 1))" "$o" >&2
            i=$((i + 1))
        done
        bad=0
        while :; do
            printf '选择 [%d]: ' "$((idx + 1))" >&2
            IFS= read -r answer || { IFS=$old_ifs; return 1; }
            IFS=$old_ifs
            case "$answer" in
                '')
                    printf '%s' "$idx"
                    return 0 ;;
                *[!0-9]*)
                    i=0
                    for o in $opts; do
                        if [ "$o" = "$answer" ]; then
                            printf '%s' "$i"
                            return 0
                        fi
                        i=$((i + 1))
                    done
                    bad=$((bad + 1))
                    if [ "$bad" -ge 3 ]; then
                        wiz_warn W_ABORT
                        return 130
                    fi
                    wiz_warn W_UNKNOWN "$answer" "$n"
                    continue ;;
                *)
                    if [ "$answer" -ge 1 ] && [ "$answer" -le "$n" ]; then
                        printf '%s' "$((answer - 1))"
                        return 0
                    fi
                    bad=$((bad + 1))
                    if [ "$bad" -ge 3 ]; then
                        wiz_warn W_ABORT
                        return 130
                    fi
                    wiz_warn W_UNKNOWN "$answer" "$n"
                    continue ;;
            esac
        done
    fi

    chosen=''
    cols=$(wiz_cols)
    # Fit the prompt and the labels into the terminal width so every entry stays
    # exactly one screen row; moving the cursor up by "rows printed" then always
    # lands on the block start. (CSI save/restore would be simpler but is ignored
    # by some terminals, which makes the menu repeat on every keypress.)
    if [ "$cols" -gt 6 ]; then
        prompt_show=$(wiz_fit "$prompt" $((cols - 4)))
    else
        prompt_show=$prompt
    fi
    rows=0
    while :; do
        if [ "$rows" -gt 0 ]; then
            printf '\033[%dA' "$rows" >&2
        fi
        printf '\r\033[K%s %s\n' "$C_CYAN?$C_RESET" "$prompt_show" >&2
        i=0
        IFS='
'
        for o in $opts; do
            if [ "$cols" -gt 6 ]; then
                label=$(wiz_fit "$o" $((cols - 4)))
            else
                label=$o
            fi
            if [ "$i" = "$idx" ]; then
                printf '%s\r\033[K%s %s%s%s\n' "$C_RESET" "$C_CYAN$S_CUR$C_RESET" "$C_BOLD" "$label" "$C_RESET" >&2
            else
                printf '%s\r\033[K%s %s\n' "$C_RESET" " " "$label" >&2
            fi
            i=$((i + 1))
        done
        IFS=$old_ifs
        rows=$((n + 1))
        key=$(wiz_wait_key)
        case "$key" in
            up|char:k)
                idx=$((idx - 1))
                [ "$idx" -lt 0 ] && idx=$((n - 1)) ;;
            down|char:j|space)
                idx=$((idx + 1))
                [ "$idx" -ge "$n" ] && idx=0 ;;
            enter)
                break ;;
            ctrl-c|esc|abort)
                [ "$rows" -gt 0 ] && printf '\033[%dA\033[J' "$rows" >&2
                return 130 ;;
            *) : ;;
        esac
    done
    [ "$rows" -gt 0 ] && printf '\033[%dA\033[J' "$rows" >&2
    IFS='
'
    i=0
    for o in $opts; do
        if [ "$i" = "$idx" ]; then
            chosen=$o
            break
        fi
        i=$((i + 1))
    done
    IFS=$old_ifs
    printf '%s%s%s %s %s%s%s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$prompt" "$C_DIM" "$chosen" "$C_RESET" >&2
    printf '%s' "$idx"
    return 0
}

# wiz_text PROMPT DEFAULT [mask] -> prints the value (Enter keeps DEFAULT)
wiz_text() {
    prompt=$1
    def=$2
    mask=${3:-0}

    if [ "$WIZ_TTY" != "1" ]; then
        if [ -n "$def" ]; then
            printf '? %s [%s]: ' "$prompt" "$def" >&2
        else
            printf '? %s: ' "$prompt" >&2
        fi
        IFS= read -r line || return 1
        [ -n "$line" ] || line=$def
        printf '%s' "$line"
        return 0
    fi

    buf=''
    while :; do
        if [ -n "$buf" ]; then
            if [ "$mask" = "1" ]; then
                shown=$(printf '%s' "$buf" | sed 's/./*/g')
            else
                shown=$buf
            fi
            printf '\r\033[K%s %s %s%s%s' "$C_CYAN?$C_RESET" "$prompt" "$C_CYAN" "$shown" "$C_RESET" >&2
        else
            printf '\r\033[K%s %s %s%s%s' "$C_CYAN?$C_RESET" "$prompt" "$C_DIM" "$def" "$C_RESET" >&2
        fi
        key=$(wiz_wait_key)
        case "$key" in
            enter)
                break ;;
            backspace)
                buf=${buf%?} ;;
            ctrl-c|esc|abort)
                printf '\r\033[K' >&2
                return 130 ;;
            char:*)
                buf="$buf${key#char:}" ;;
            *) : ;;
        esac
    done
    printf '\r\033[K' >&2
    [ -n "$buf" ] || buf=$def
    printf '%s' "$buf"
    return 0
}

# wiz_confirm PROMPT DEFAULT_YES -> 0 yes / 1 no
wiz_confirm() {
    prompt=$1
    def=$2
    if [ "$def" = "1" ]; then
        opts='是
否'
        yes_idx=0
    else
        opts='否
是'
        yes_idx=1
    fi
    sel=$(wiz_menu "$prompt" 0 "$opts") || return $?
    [ "$sel" = "$yes_idx" ]
}

# ------------------------------------------------------------------ helpers

wiz_step() { # N TOTAL TITLE
    printf '\n%s[%s/%s]%s %s%s%s\n' "$C_DIM" "$1" "$2" "$C_RESET" "$C_BOLD" "$3" "$C_RESET" >&2
}

wiz_cancel() {
    wiz_tty_stop
    [ -n "$WIZ_STAGE" ] && rm -rf "$WIZ_STAGE" 2>/dev/null
    printf '\n%s%s%s\n' "$C_YELLOW" "$(msg W_CANCELLED)" "$C_RESET" >&2
    exit 130
}

wiz_summary_line() { # LABEL VALUE
    gh_kv "$1" "$2"
}

# Pending values are collected first and only written after confirmation.
# Accepts both `wiz_set NAME VALUE` and `wiz_set NAME=VALUE` so a shell-style
# call cannot leave the value unset (which used to abort under set -u).
wiz_set() { # NAME VALUE | NAME=VALUE
    case "$1" in
        *=*) name=${1%%=*}; value=${1#*=} ;;
        *)   name=$1; value=${2:-} ;;
    esac
    eval "WIZ_$name=\"\$value\""
}

wiz_get() { # NAME
    eval "printf '%s' \"\${WIZ_$1:-}\""
}

# Heuristic entry point for a bare `smsfw`:
#   no url yet            -> offer the wizard
#   url, config untested  -> offer a test push
#   tested                -> offer status
# Returns 1 when the user declines (caller prints help).
wiz_auto() {
    load_config
    ensure_dirs
    wiz_tty_start
    if [ -z "$SMSFW_WEBHOOK_URL" ]; then
        question=$(msg AUTO_CONFIGURE)
    elif config_was_tested; then
        question=$(msg AUTO_STATUS)
    else
        question=$(msg AUTO_TEST)
    fi
    if ! wiz_confirm "$question $(msg AUTO_HINT)" 1; then
        wiz_tty_stop
        return 1
    fi
    if [ -z "$SMSFW_WEBHOOK_URL" ]; then
        wiz_run
        return 0
    fi
    if config_was_tested; then
        wiz_tty_stop
        cmd_status
        return 0
    fi
    wiz_tty_stop
    cmd_test
    return $?
}

# ------------------------------------------------------------------ wizard

wiz_run() {
    load_config
    ensure_dirs
    wiz_tty_start
    WIZ_STAGE="$SMSF_TMP/wizard.$$"
    rm -rf "$WIZ_STAGE"
    mkdir -p "$WIZ_STAGE" || { wiz_warn W_STAGE_FAIL "$WIZ_STAGE"; return 1; }

    wiz_head "$(msg W_HEADER) $(msg W_HINT)"
    if [ -n "$SMSFW_WEBHOOK_URL" ]; then
        wiz_dim W_CURRENT "$SMSFW_WEBHOOK_URL"
    else
        wiz_dim W_NO_URL
    fi

    mode_opts="$(msg W_MODE_FULL)
$(msg W_MODE_TEST)
$(msg W_MODE_STATUS)"
    mode=$(wiz_menu "$(msg W_MODE)" 0 "$mode_opts") || wiz_cancel
    case "$mode" in
        0) : ;;
        1) wiz_tty_stop; cmd_test; return $? ;;
        2) wiz_tty_stop; cmd_status; return 0 ;;
        *) wiz_cancel ;;
    esac

    total=10

    # ---------------------------------------------------------- 1. 名称
    wiz_step 1 $total "$(msg W_S1)"
    v=$(wiz_text "$(msg W_S1_Q)" "${SMSFW_RULE_TITLE:-sms}") || wiz_cancel
    wiz_set RULE_TITLE "$v"

    # ---------------------------------------------------------- 2. 启用
    wiz_step 2 $total "$(msg W_S2)"
    if wiz_confirm "$(msg W_S2_Q)" "$([ "$SMSFW_ENABLED" = "1" ] && echo 1 || echo 0)"; then
        wiz_set ENABLED 1
    else
        wiz_set ENABLED 0
    fi

    # ---------------------------------------------------------- 3. 请求方式
    wiz_step 3 $total "$(msg W_S3)"
    mopts='POST — JSON / form body (recommended)
PUT
PATCH
GET — query string'
    midx=0
    case "$SMSFW_METHOD" in
        PUT)   midx=1 ;;
        PATCH) midx=2 ;;
        GET)   midx=3 ;;
        *)     midx=0 ;;
    esac
    sel=$(wiz_menu "$(msg W_S3_Q)" "$midx" "$mopts") || wiz_cancel
    case "$sel" in
        1) method=PUT ;;
        2) method=PATCH ;;
        3) method=GET ;;
        *) method=POST ;;
    esac
    wiz_set METHOD "$method"

    # ---------------------------------------------------------- 4. 推送地址
    wiz_step 4 $total "$(msg W_S4)"
    while :; do
        v=$(wiz_text "$(msg W_S4_Q)" "$SMSFW_WEBHOOK_URL") || wiz_cancel
        case "$v" in
            http://*|https://*) break ;;
            *) wiz_warn W_S4_BAD ;;
        esac
    done
    wiz_set URL "$v"
    case "$v" in
        *://*:*@*) wiz_dim W_S4_AUTH ;;
    esac

    # ---------------------------------------------------------- 5. 密钥
    wiz_step 5 $total "$(msg W_S5)"
    wiz_dim W_S5_HINT
    cur_secret=''
    [ -f "$SMSFW_SECRET_FILE" ] && cur_secret=$(cat "$SMSFW_SECRET_FILE" 2>/dev/null)
    if [ -n "$cur_secret" ]; then
        if wiz_confirm "$(msg W_S5_CLEAR)" 0; then
            wiz_set SECRET ''
        else
            wiz_set SECRET "$cur_secret"
        fi
    else
        v=$(wiz_text "$(msg W_S5_Q)" '' 1) || wiz_cancel
        wiz_set SECRET "$v"
    fi

    # ---------------------------------------------------------- 6. 响应校验
    wiz_step 6 $total "$(msg W_S6)"
    v=$(wiz_text "$(msg W_S6_Q)" "$SMSFW_RESPONSE_MATCH") || wiz_cancel
    wiz_set RESPONSE_MATCH "$v"

    # ---------------------------------------------------------- 7. 请求参数
    wiz_step 7 $total "$(msg W_S7)"
    wiz_dim W_S7_HINT
    topts="$(msg W_S7_KEEP)
$(msg W_S7_PASTE)
$(msg W_S7_FILE)
$(msg W_S7_DEFAULT)"
    tidx=0
    [ -f "$SMSFW_TEMPLATE_FILE" ] || tidx=3
    tsel=$(wiz_menu "$(msg W_S7_Q)" "$tidx" "$topts") || wiz_cancel
    case "$tsel" in
        0) wiz_set TEMPLATE "$SMSFW_TEMPLATE_FILE" ;;
        1)
            body=$(wiz_text "$(msg W_S7_PASTE_Q)" '') || wiz_cancel
            if [ -n "$body" ]; then
                printf '%s\n' "$body" > "$WIZ_STAGE/template.json"
                wiz_set TEMPLATE "$WIZ_STAGE/template.json"
                wiz_set TEMPLATE_DEST "$SMSF_DATA/template.json"
            else
                wiz_warn W_S7_EMPTY
                wiz_set TEMPLATE "$SMSFW_TEMPLATE_FILE"
            fi ;;
        2)
            file=$(wiz_text "$(msg W_S7_PATH_Q)" '') || wiz_cancel
            if [ -f "$file" ]; then
                cp -f "$file" "$WIZ_STAGE/template.json" || wiz_warn W_S7_COPY_FAIL
                wiz_set TEMPLATE "$WIZ_STAGE/template.json"
                wiz_set TEMPLATE_DEST "$SMSF_DATA/template.json"
            else
                wiz_warn W_S7_NO_FILE "$file"
                wiz_set TEMPLATE "$SMSFW_TEMPLATE_FILE"
            fi ;;
        3)
            wiz_set TEMPLATE "$SMSF_DATA/template.json"
            wiz_set TEMPLATE_RESET 1 ;;
    esac

    # ---------------------------------------------------------- 8. 请求头
    wiz_step 8 $total "$(msg W_S8)"
    if wiz_confirm "$(msg W_S8_Q)" 0; then
        : > "$WIZ_STAGE/headers.txt"
        while :; do
            hname=$(wiz_text "$(msg W_S8_NAME)" '') || wiz_cancel
            [ -n "$hname" ] || break
            hvalue=$(wiz_text "$hname 的值" '') || wiz_cancel
            printf '%s: %s\n' "$hname" "$hvalue" >> "$WIZ_STAGE/headers.txt"
            wiz_ok W_S8_ADDED "$hname"
        done
        wiz_set HEADERS "$WIZ_STAGE/headers.txt"
    fi

    # ---------------------------------------------------------- 9. 转发规则
    wiz_step 9 $total "$(msg W_S10)"
    cur_filters="$SMSFW_FILTER_SENDER_ALLOW$SMSFW_FILTER_SENDER_BLOCK$SMSFW_FILTER_BODY_ALLOW$SMSFW_FILTER_BODY_BLOCK"
    if wiz_confirm "$(msg W_S10_Q)" "$([ -n "$cur_filters" ] && echo 1 || echo 0)"; then
        v=$(wiz_text "$(msg W_S10_ALLOW)" "$SMSFW_FILTER_SENDER_ALLOW") || wiz_cancel
        wiz_set FILTER_SENDER_ALLOW "$v"
        v=$(wiz_text "$(msg W_S10_BLOCK)" "$SMSFW_FILTER_SENDER_BLOCK") || wiz_cancel
        wiz_set FILTER_SENDER_BLOCK "$v"
        v=$(wiz_text "$(msg W_S10_BALLOW)" "$SMSFW_FILTER_BODY_ALLOW") || wiz_cancel
        wiz_set FILTER_BODY_ALLOW "$v"
        v=$(wiz_text "$(msg W_S10_BBLOCK)" "$SMSFW_FILTER_BODY_BLOCK") || wiz_cancel
        wiz_set FILTER_BODY_BLOCK "$v"
    fi

    # ---------------------------------------------------------- 10. 高级
    wiz_step 10 $total "$(msg W_S11)"
    if wiz_confirm "$(msg W_S11_Q)" 0; then
        v=$(wiz_text "$(msg W_S11_DEVICE)" "${SMSFW_DEVICE_NAME:-$(device_name)}") || wiz_cancel
        wiz_set DEVICE_NAME "$v"
        v=$(wiz_text "$(msg W_S11_TIMEOUT)" "$SMSFW_TIMEOUT") || wiz_cancel
        wiz_set TIMEOUT "$v"
        v=$(wiz_text "$(msg W_S11_RETRIES)" "$SMSFW_RETRIES") || wiz_cancel
        wiz_set RETRIES "$v"
        v=$(wiz_text "$(msg W_S11_POLL)" "$SMSFW_POLL_INTERVAL") || wiz_cancel
        wiz_set POLL_INTERVAL "$v"
        v=$(wiz_text "$(msg W_S11_QUEUE)" "$SMSFW_QUEUE_LIMIT") || wiz_cancel
        wiz_set QUEUE_LIMIT "$v"
        v=$(wiz_text "$(msg W_S11_DBCHECK)" "$SMSFW_DB_FULL_CHECK_INTERVAL") || wiz_cancel
        wiz_set DB_FULL_CHECK_INTERVAL "$v"
        if wiz_confirm "$(msg W_S11_TLS)" "$([ "$SMSFW_TLS_INSECURE" = "1" ] && echo 1 || echo 0)"; then
            wiz_set TLS_INSECURE 1
        else
            wiz_set TLS_INSECURE 0
        fi
    fi

    # ---------------------------------------------------------- 汇总 + 写入
    wiz_head "$(msg W_SUMMARY)"
    wiz_summary_line "$(msg RULE_NAME)" "$(wiz_get RULE_TITLE)"
    wiz_summary_line "$(msg ENABLED)" "$([ "$(wiz_get ENABLED)" = "1" ] && msg YES || msg NO)"
    wiz_summary_line "$(msg METHOD)" "$(wiz_get METHOD)"
    wiz_summary_line "$(msg WEBHOOK)" "$(wiz_get URL)"
    wiz_summary_line "$(msg SECRET)" "$([ -n "$(wiz_get SECRET)" ] && msg SECRET_SET || msg SECRET_NONE)"
    wiz_summary_line "$(msg RESPONSE)" "$(wiz_get RESPONSE_MATCH)"
    if [ -f "$WIZ_STAGE/headers.txt" ]; then
        hcount=$(grep -cv '^#' "$WIZ_STAGE/headers.txt" 2>/dev/null)
        case "$hcount" in ''|*[!0-9]*) hcount=0 ;; esac
    else
        hcount=$(grep -cv '^#' "$SMSFW_HEADERS_FILE" 2>/dev/null)
        case "$hcount" in ''|*[!0-9]*) hcount=0 ;; esac
    fi
    wiz_summary_line "$(msg HEADERS)" "$hcount"
    wiz_summary_line "$(msg FILTERS)" "$(wiz_get FILTER_SENDER_BLOCK)$(wiz_get FILTER_BODY_BLOCK)"
    [ -n "$(wiz_get DEVICE_NAME)" ] && wiz_summary_line "$(msg DEVICE)" "$(wiz_get DEVICE_NAME)"
    printf '\n' >&2
    if ! wiz_confirm "$(msg W_CONFIRM)" 1; then
        wiz_cancel
    fi

    # ---------------------------------------------------------- apply (staged)
    tfile=$(wiz_get TEMPLATE)
    if [ -n "$(wiz_get TEMPLATE_RESET)" ]; then
        rm -f "$SMSF_DATA/template.json" 2>/dev/null
        cfg_set SMSFW_TEMPLATE_FILE "$SMSF_DATA/template.json"
    elif [ -n "$(wiz_get TEMPLATE_DEST)" ] && [ -f "$tfile" ]; then
        cp -f "$tfile" "$SMSF_DATA/template.json" || wiz_warn W_WRITE_FAIL "$SMSF_DATA/template.json"
        cfg_set SMSFW_TEMPLATE_FILE "$SMSF_DATA/template.json"
    elif [ -n "$tfile" ]; then
        cfg_set SMSFW_TEMPLATE_FILE "$tfile"
    fi
    if [ -f "$WIZ_STAGE/headers.txt" ]; then
        cp -f "$WIZ_STAGE/headers.txt" "$SMSF_DATA/headers.txt" || wiz_warn W_WRITE_FAIL "$SMSF_DATA/headers.txt"
        cfg_set SMSFW_HEADERS_FILE "$SMSF_DATA/headers.txt"
    fi
    sec=$(wiz_get SECRET)
    if [ -n "$sec" ]; then
        printf '%s' "$sec" > "$SMSFW_SECRET_FILE"
        chmod 600 "$SMSFW_SECRET_FILE" 2>/dev/null
        cfg_set SMSFW_SECRET_FILE "$SMSFW_SECRET_FILE"
    else
        rm -f "$SMSFW_SECRET_FILE" 2>/dev/null
    fi

    cfg_set SMSFW_RULE_TITLE "$(wiz_get RULE_TITLE)"
    cfg_set SMSFW_ENABLED "$(wiz_get ENABLED)"
    cfg_set SMSFW_WEBHOOK_URL "$(wiz_get URL)"
    cfg_set SMSFW_METHOD "$(wiz_get METHOD)"
    cfg_set SMSFW_RESPONSE_MATCH "$(wiz_get RESPONSE_MATCH)"
    if [ -n "$(wiz_get FILTER_SENDER_ALLOW)$(wiz_get FILTER_SENDER_BLOCK)$(wiz_get FILTER_BODY_ALLOW)$(wiz_get FILTER_BODY_BLOCK)" ]; then
        cfg_set SMSFW_FILTER_SENDER_ALLOW "$(wiz_get FILTER_SENDER_ALLOW)"
        cfg_set SMSFW_FILTER_SENDER_BLOCK "$(wiz_get FILTER_SENDER_BLOCK)"
        cfg_set SMSFW_FILTER_BODY_ALLOW "$(wiz_get FILTER_BODY_ALLOW)"
        cfg_set SMSFW_FILTER_BODY_BLOCK "$(wiz_get FILTER_BODY_BLOCK)"
    fi
    [ -n "$(wiz_get DEVICE_NAME)" ] && cfg_set SMSFW_DEVICE_NAME "$(wiz_get DEVICE_NAME)"
    [ -n "$(wiz_get TIMEOUT)" ] && cfg_set SMSFW_TIMEOUT "$(wiz_get TIMEOUT)"
    [ -n "$(wiz_get RETRIES)" ] && cfg_set SMSFW_RETRIES "$(wiz_get RETRIES)"
    [ -n "$(wiz_get POLL_INTERVAL)" ] && cfg_set SMSFW_POLL_INTERVAL "$(wiz_get POLL_INTERVAL)"
    [ -n "$(wiz_get QUEUE_LIMIT)" ] && cfg_set SMSFW_QUEUE_LIMIT "$(wiz_get QUEUE_LIMIT)"
    [ -n "$(wiz_get DB_FULL_CHECK_INTERVAL)" ] && cfg_set SMSFW_DB_FULL_CHECK_INTERVAL "$(wiz_get DB_FULL_CHECK_INTERVAL)"
    [ -n "$(wiz_get TLS_INSECURE)" ] && cfg_set SMSFW_TLS_INSECURE "$(wiz_get TLS_INSECURE)"
    rm -rf "$WIZ_STAGE" 2>/dev/null
    wiz_ok W_WRITTEN "$SMSF_CONF"

    wiz_head "$(msg W_TEST_HEAD)"
    load_config
    if cmd_test; then
        wiz_ok W_TEST_OK
    else
        wiz_warn W_TEST_FAIL
    fi

    if [ "$(wiz_get ENABLED)" = "1" ]; then
        start_daemon && wiz_ok W_DAEMON_ON
    else
        wiz_dim W_DAEMON_OFF
    fi

    wiz_tty_stop
    printf '\n%s%s %s%s\n' "$C_GREEN" "$S_OK" "$(msg W_DONE)" "$C_RESET" >&2
    wiz_summary_line "$(msg DAEMON)" "$([ -n "$(daemon_pid)" ] && msg RUNNING || msg W_NOT_RUNNING)"
    wiz_summary_line "$(msg LOG)" "$SMSF_LOG"
    wiz_summary_line "$(msg W_HELP)" "$SMSF_BIN_DIR/smsfw help"
    return 0
}
