#!/system/bin/sh

SMSF_LANG=${SMSF_LANG:-}
if [ -z "$SMSF_LANG" ]; then
    case "${LC_ALL:-${LANG:-}}" in
        zh*|*_CN*|*_TW*|*_HK*) SMSF_LANG=zh ;;
        en*|*_US*|*_GB*|*_AU*|*_CA*) SMSF_LANG=en ;;
        # C/POSIX carry no language information: fall through to the system locale
        ''|C|POSIX|C.*|POSIX.*)
            loc=$(getprop persist.sys.locale 2>/dev/null)
            [ -n "$loc" ] || loc=$(getprop ro.product.locale 2>/dev/null)
            case "$loc" in
                zh*) SMSF_LANG=zh ;;
                ?*)  SMSF_LANG=en ;;
                *)   SMSF_LANG=zh ;;
            esac ;;
    esac
fi

# msg KEY [ARG...] -> localized text with %s placeholders filled in order.
msg() {
    key=$1
    shift
    case "$key" in
        ''|*[!A-Za-z0-9_]*)
            # Not a catalog key (a literal string from an unconverted call site):
            # echo it instead of evaluating a malformed variable name.
            printf '%s' "$key"
            return 0 ;;
    esac
    # Quoted expansion inside eval: without the quotes the value is word-split,
    # so any multi-word message would end up as the raw key.
    eval "text=\"\${MSG_${SMSF_LANG}_${key}:-}\""
    if [ -z "$text" ]; then
        eval "text=\"\${MSG_en_${key}:-}\""
    fi
    [ -n "$text" ] || text=$key
    for arg in "$@"; do
        case "$text" in
            *%s*) text="${text%%\%s*}$arg${text#*\%s}" ;;
            *)    break ;;
        esac
    done
    printf '%s' "$text"
}

# ------------------------------------------------------------------ status / lifecycle
MSG_zh_MODULE='模块 %s'
MSG_en_MODULE='module %s'
MSG_zh_ENABLED='转发开关'
MSG_en_ENABLED='enabled'
MSG_zh_YES='是'
MSG_en_YES='yes'
MSG_zh_NO='否'
MSG_en_NO='no'
MSG_zh_DAEMON='守护进程'
MSG_en_DAEMON='daemon'
MSG_zh_RUNNING='运行中'
MSG_en_RUNNING='running'
MSG_zh_STOPPED='未运行'
MSG_en_STOPPED='stopped'
MSG_zh_WORKER='工作进程'
MSG_en_WORKER='worker'
MSG_zh_WEBHOOK='推送地址'
MSG_en_WEBHOOK='webhook'
MSG_zh_METHOD='请求方式'
MSG_en_METHOD='method'
MSG_zh_TEMPLATE='请求体模板'
MSG_en_TEMPLATE='template'
MSG_zh_HEADERS='请求头'
MSG_en_HEADERS='headers'
MSG_zh_SECRET='密钥'
MSG_en_SECRET='secret'
MSG_zh_SECRET_SET='已配置'
MSG_en_SECRET_SET='configured'
MSG_zh_SECRET_NONE='未配置'
MSG_en_SECRET_NONE='none'
MSG_zh_DEVICE='设备名称'
MSG_en_DEVICE='device'
MSG_zh_LAST_SMS_ID='最后短信 ID'
MSG_en_LAST_SMS_ID='last sms id'
MSG_zh_QUEUE='队列'
MSG_en_QUEUE='queue'
MSG_zh_PENDING='待发送'
MSG_en_PENDING='pending'
MSG_zh_FAILED='已放弃'
MSG_en_FAILED='failed'
MSG_zh_COUNTERS='计数'
MSG_en_COUNTERS='counters'
MSG_zh_SENT='已发送'
MSG_en_SENT='sent'
MSG_zh_PAYLOAD='载荷'
MSG_en_PAYLOAD='payload'
MSG_zh_LOG='日志'
MSG_en_LOG='log'
MSG_zh_FOUND='存在'
MSG_en_FOUND='found'
MSG_zh_MISSING='缺失'
MSG_en_MISSING='missing'
MSG_zh_NOT_SET='<未设置>'
MSG_en_NOT_SET='<not set>'
MSG_zh_UNSET='<未初始化>'
MSG_en_UNSET='<unset>'
MSG_zh_TRANSPORT_UNSET='未检测'
MSG_en_TRANSPORT_UNSET='unset'
MSG_zh_RULE_NAME='名称'
MSG_en_RULE_NAME='name'
MSG_zh_RESPONSE='响应校验'
MSG_en_RESPONSE='response match'
MSG_zh_FILTERS='过滤'
MSG_en_FILTERS='filters'
MSG_zh_CONFIG_FILE='配置文件'
MSG_en_CONFIG_FILE='config file'
MSG_zh_D_BOOT='启动状态'
MSG_en_D_BOOT='boot state'

MSG_zh_DAEMON_STARTED='守护进程已启动（pid %s）'
MSG_en_DAEMON_STARTED='daemon started (pid %s)'
MSG_zh_DAEMON_ALREADY='守护进程已在运行（pid %s）'
MSG_en_DAEMON_ALREADY='daemon already running (pid %s)'
MSG_zh_DAEMON_STOPPED='守护进程已停止（pid %s）'
MSG_en_DAEMON_STOPPED='daemon stopped (pid %s)'
MSG_zh_DAEMON_START_FAILED='守护进程未能启动，请查看 %s'
MSG_en_DAEMON_START_FAILED='daemon did not start, check %s'
MSG_zh_REAPED_WORKER='已回收孤儿工作进程（pid %s）'
MSG_en_REAPED_WORKER='reaped orphaned worker (pid %s)'
MSG_zh_START='守护进程已启动'
MSG_en_START='daemon started'
MSG_zh_STOP='守护进程已停止'
MSG_en_STOP='daemon stopped'
MSG_zh_RESTART='守护进程已重启'
MSG_en_RESTART='daemon restarted'

# ------------------------------------------------------------------ config
MSG_zh_DATA_DIR_FAIL='数据目录不可用：%s（需要 root，或在桌面测试时设置 SMSF_DATA）'
MSG_en_DATA_DIR_FAIL='data directory is not usable: %s (needs root, or set SMSF_DATA for desktop testing)'
MSG_zh_SAVED='已保存 %s=%s（守护进程会自动重载）'
MSG_en_SAVED='saved %s=%s (daemon reloads automatically)'
MSG_zh_UNKNOWN_KEY='未知配置键：%s'
MSG_en_UNKNOWN_KEY='unknown configuration key: %s'
MSG_zh_SET_USAGE='用法：smsfw set <键> [值]'
MSG_en_SET_USAGE='usage: smsfw set <key> [value]'
MSG_zh_GET_USAGE='用法：smsfw get <键>'
MSG_en_GET_USAGE='usage: smsfw get <key>'
MSG_zh_ENABLED_MSG='转发已启用'
MSG_en_ENABLED_MSG='forwarding enabled'
MSG_zh_DISABLED_MSG='转发已关闭（守护进程继续运行）'
MSG_en_DISABLED_MSG='forwarding disabled (daemon keeps running)'

# ------------------------------------------------------------------ operations
MSG_zh_POLL_DONE='轮询完成：last id=%s，队列 %s'
MSG_en_POLL_DONE='poll done: last id=%s, queue %s'
MSG_zh_POLL_DISABLED='转发处于关闭状态，可执行 smsfw on 开启'
MSG_en_POLL_DISABLED='forwarding is disabled; run smsfw on to enable'
MSG_zh_FLUSH_DONE='队列已重试：剩余 %s，已放弃 %s'
MSG_en_FLUSH_DONE='queue flushed: %s pending, %s failed'
MSG_zh_RESET_STATE='状态已重置，下次轮询会重新基线化'
MSG_en_RESET_STATE='state reset; the next poll re-baselines the inbox'
MSG_zh_RESET_HINT='若守护进程在运行，执行 smsfw restart 后可用 smsfw poll 立即生效'
MSG_en_RESET_HINT='if the daemon is running, run smsfw restart and then smsfw poll'
MSG_zh_PROVIDER_FAIL='短信 provider 不可访问（设备是否支持短信？）'
MSG_en_PROVIDER_FAIL='SMS provider is not reachable (does this device have telephony?)'

# ------------------------------------------------------------------ test / preview
MSG_zh_TEST_OK='测试推送成功（%s）'
MSG_en_TEST_OK='test push delivered (%s)'
MSG_zh_TEST_FAIL='测试推送失败（rc=%s）'
MSG_en_TEST_FAIL='test push failed (rc=%s)'
MSG_zh_TEST_RESPONSE='响应'
MSG_en_TEST_RESPONSE='response'
MSG_zh_TEST_KEPT='已保留记录以便排查：%s'
MSG_en_TEST_KEPT='kept the record for inspection: %s'
MSG_zh_TEST_URL_REQUIRED='尚未配置推送地址，请先执行 smsfw wizard 或 smsfw set url <地址>'
MSG_en_TEST_URL_REQUIRED='no webhook url configured; run smsfw wizard or smsfw set url <url>'
MSG_zh_PREVIEW_URL='URL'
MSG_en_PREVIEW_URL='URL'
MSG_zh_PREVIEW_BODY='请求体'
MSG_en_PREVIEW_BODY='body'

# ------------------------------------------------------------------ queue / log
MSG_zh_QUEUE_LIST='队列：%s 条待发送（上限 %s，最多尝试 %s 次）'
MSG_en_QUEUE_LIST='queue: %s pending (limit %s, max attempts %s)'
MSG_zh_QUEUE_RETRY='已清除 %s 条记录的退避计时'
MSG_en_QUEUE_RETRY='cleared backoff for %s record(s)'
MSG_zh_QUEUE_CLEAR='待发送记录已移入 %s'
MSG_en_QUEUE_CLEAR='pending records moved to %s'
MSG_zh_QUEUE_FAILED_COUNT='%s 条位于 %s'
MSG_en_QUEUE_FAILED_COUNT='%s in %s'
MSG_zh_QUEUE_USAGE='用法：smsfw queue [list|retry|clear]'
MSG_en_QUEUE_USAGE='usage: smsfw queue [list|retry|clear]'
MSG_zh_NO_LOG='暂无日志：%s'
MSG_en_NO_LOG='no log yet at %s'
MSG_zh_ATTEMPTS='尝试'
MSG_en_ATTEMPTS='attempts'
MSG_zh_NEXT='下次'
MSG_en_NEXT='next'

# ------------------------------------------------------------------ template / headers / secret
MSG_zh_TEMPLATE_USAGE='用法：smsfw template [cat|set <文件>]'
MSG_en_TEMPLATE_USAGE='usage: smsfw template [cat|set <file>]'
MSG_zh_TEMPLATE_NO_FILE='找不到文件：%s'
MSG_en_TEMPLATE_NO_FILE='no such file: %s'
MSG_zh_TEMPLATE_SET='模板已复制到 %s'
MSG_en_TEMPLATE_SET='template copied to %s'
MSG_zh_HEADERS_USAGE='用法：smsfw headers [cat|set <文件>]'
MSG_en_HEADERS_USAGE='usage: smsfw headers [cat|set <file>]'
MSG_zh_HEADERS_SET='请求头已复制到 %s'
MSG_en_HEADERS_SET='headers copied to %s'
MSG_zh_SECRET_SHOW='密钥已设置（%s）'
MSG_en_SECRET_SHOW='secret is set (%s)'
MSG_zh_SECRET_CLEAR='密钥已清除'
MSG_en_SECRET_CLEAR='secret cleared'
MSG_zh_SECRET_SET_MSG='密钥已更新'
MSG_en_SECRET_SET_MSG='secret updated'
MSG_zh_SECRET_USAGE='用法：smsfw secret [show|clear|set <文件>]'
MSG_en_SECRET_USAGE='usage: smsfw secret [show|clear|set <file>]'

# ------------------------------------------------------------------ doctor
MSG_zh_DOCTOR_TITLE='smsfw 自检'
MSG_en_DOCTOR_TITLE='smsfw doctor'
MSG_zh_D_ROOT='以 root 运行（读取短信库所需）'
MSG_en_D_ROOT='running as root (needed for SMS provider access)'
MSG_zh_D_DATA='数据目录可写'
MSG_en_D_DATA='data dir is writable'
MSG_zh_D_PAYLOAD='载荷文件存在'
MSG_en_D_PAYLOAD='payload exists'
MSG_zh_D_RUNNER='Java 运行器可用：%s'
MSG_en_D_RUNNER='java runner works: %s'
MSG_zh_D_RUNNER_FAIL='Java 运行器（app_process/dalvikvm）不可用'
MSG_en_D_RUNNER_FAIL='java runner (app_process/dalvikvm) is not usable'
MSG_zh_D_CONTENT='content 命令存在'
MSG_en_D_CONTENT='content binary present'
MSG_zh_D_PROVIDER='短信 provider 可访问（user %s，sub_id=%s）'
MSG_en_D_PROVIDER='SMS provider reachable (user %s, sub_id=%s)'
MSG_zh_D_PROVIDER_FAIL='短信 provider 不可访问'
MSG_en_D_PROVIDER_FAIL='SMS provider is not reachable'
MSG_zh_D_ROWS='provider 输出格式可解析'
MSG_en_D_ROWS='provider row format understood'
MSG_zh_D_SAMPLE='采样'
MSG_en_D_SAMPLE='sample'
MSG_zh_D_NO_ROWS='收件箱为空或输出格式异常（无法验证解析）'
MSG_en_D_NO_ROWS='inbox is empty or row format unexpected (cannot verify parsing)'
MSG_zh_D_SIMINFO='siminfo 采样'
MSG_en_D_SIMINFO='siminfo sample'
MSG_zh_D_NO_SIMINFO='siminfo 查询无结果（卡槽名会退回 sub_id）'
MSG_en_D_NO_SIMINFO='siminfo returned nothing (SIM label falls back to the sub id)'
MSG_zh_D_URL='SMSFW_WEBHOOK_URL 已配置'
MSG_en_D_URL='SMSFW_WEBHOOK_URL is set'
MSG_zh_D_URL_FAIL='SMSFW_WEBHOOK_URL 未配置'
MSG_en_D_URL_FAIL='SMSFW_WEBHOOK_URL is not set'
MSG_zh_D_TEMPLATE='模板文件存在'
MSG_en_D_TEMPLATE='template file exists'
MSG_zh_D_HEADERS='请求头文件存在'
MSG_en_D_HEADERS='headers file exists'
MSG_zh_D_NO_TEMPLATE='未配置模板：将发送默认 from/content/timestamp 表单参数'
MSG_en_D_NO_TEMPLATE='no template file: default from/content/timestamp params will be used'
MSG_zh_D_CLI='CLI 已挂载到 /system/bin（重启后生效）'
MSG_en_D_CLI='CLI is mounted into /system/bin (after reboot)'
MSG_zh_D_CLI_FAIL='CLI 未在 PATH 中（重启后生效，或使用绝对路径）'
MSG_en_D_CLI_FAIL='CLI is not on PATH (takes effect after reboot; use the absolute path)'
MSG_zh_D_RESULT='结果：%s 项失败，%s 项警告'
MSG_en_D_RESULT='result: %s failure(s), %s warning(s)'
MSG_zh_DEVICE_OVERRIDE='已自定义设备名称：%s'
MSG_en_DEVICE_OVERRIDE='device name override: %s'

# ------------------------------------------------------------------ daemon log
MSG_zh_QUEUED='已入队 id=%s 来自 %s 卡槽=%s（%s）'
MSG_en_QUEUED='queued id=%s from %s sim=%s (%s)'
MSG_zh_SENT_LINE='已发送 %s（%s）'
MSG_en_SENT_LINE='sent %s (%s)'
MSG_zh_SEND_RETRY='第 %s 次发送失败（rc=%s），%s 秒后重试：%s'
MSG_en_SEND_RETRY='send attempt %s failed (rc=%s), retrying in %ss: %s'
MSG_zh_GIVING_UP='放弃 %s：已尝试 %s 次（rc=%s）'
MSG_en_GIVING_UP='giving up on %s after %s attempts (rc=%s)'
MSG_zh_QUEUE_DROP='队列已满，丢弃最旧记录 %s'
MSG_en_QUEUE_DROP='queue full: dropped oldest record %s'
MSG_zh_SKIP_FILTERED='跳过 id=%s 来自 %s（被过滤规则命中）'
MSG_en_SKIP_FILTERED='skip id=%s from %s (filtered)'
MSG_zh_SKIP_NO_URL='跳过 id=%s 来自 %s：未配置推送地址'
MSG_en_SKIP_NO_URL='skip id=%s from %s: webhook url not configured'
MSG_zh_MSG_GONE='消息 id=%s 在读取前已被删除'
MSG_en_MSG_GONE='message id=%s disappeared before it could be read'
MSG_zh_BASELINE='基线：最后收件箱 id=%s（不回补历史短信）'
MSG_en_BASELINE='baseline: last inbox id is %s (existing messages are not forwarded)'
MSG_zh_BASELINE_ALL='基线：将转发已存在的历史短信（FORWARD_EXISTING=1）'
MSG_en_BASELINE_ALL='baseline: forwarding existing inbox messages (FORWARD_EXISTING=1)'
MSG_zh_WAIT_BOOT='等待系统启动完成（sys.boot_completed）'
MSG_en_WAIT_BOOT='waiting for boot (sys.boot_completed)'
MSG_zh_BOOT_TIMEOUT='等待启动超时，仍然尝试访问 provider'
MSG_en_BOOT_TIMEOUT='sys.boot_completed still unset after 600s, trying the provider anyway'
MSG_zh_WAIT_PROVIDER='等待短信 provider 就绪'
MSG_en_WAIT_PROVIDER='waiting for the SMS provider'
MSG_zh_PROVIDER_READY='短信 provider 就绪（user=%s sub_id=%s crypto=%s）'
MSG_en_PROVIDER_READY='SMS provider ready (user=%s sub_id=%s crypto=%s)'
MSG_zh_PROVIDER_DOWN='短信 provider 暂不可用，稍后重试'
MSG_en_PROVIDER_DOWN='SMS provider is not reachable; will keep retrying'
MSG_zh_WORKER_START='工作进程启动（pid %s）'
MSG_en_WORKER_START='worker start (pid %s)'
MSG_zh_WORKER_EXIT='工作进程退出 rc=%s，%s 秒后重启'
MSG_en_WORKER_EXIT='worker exited rc=%s; restarting in %ss'
MSG_zh_SUPERVISOR_START='守护进程启动（pid %s，模块 %s，载荷 %s）'
MSG_en_SUPERVISOR_START='supervisor start (pid %s, module %s, payload %s)'
MSG_zh_SUPERVISOR_GONE='守护进程已退出，工作进程随之退出'
MSG_en_SUPERVISOR_GONE='supervisor is gone, worker exiting'
MSG_zh_WATCH_DB='监听短信数据库：%s'
MSG_en_WATCH_DB='watching telephony db: %s'
MSG_zh_NO_DB='未找到短信数据库，将每 %s 秒查询一次 provider'
MSG_en_NO_DB='telephony db not found, falling back to a provider query every %ss'
MSG_zh_LOG_ROTATED='日志已轮转'
MSG_en_LOG_ROTATED='log rotated'
MSG_zh_SUSPEND_GAP='检测到 %s 秒休眠间隔，进入快速轮询'
MSG_en_SUSPEND_GAP='suspend gap %ss detected, entering fast poll mode'
MSG_zh_RUNNER_MISSING='没有可用的 Java 运行器（app_process/dalvikvm）：%s'
MSG_en_RUNNER_MISSING='no usable java runner (app_process/dalvikvm) for %s'
MSG_zh_RECORD_NO_URL='记录缺少 url：%s'
MSG_en_RECORD_NO_URL='record has no url: %s'
MSG_zh_RECORD_DIR_FAIL='无法创建记录目录'
MSG_en_RECORD_DIR_FAIL='cannot create the record directory'
MSG_zh_ENQUEUE_FAIL='无法把 id=%s 加入队列'
MSG_en_ENQUEUE_FAIL='cannot enqueue a record for id=%s'

# ------------------------------------------------------------------ wizard
MSG_zh_W_HEADER='smsfw Webhook 配置向导'
MSG_en_W_HEADER='smsfw webhook setup wizard'
MSG_zh_W_HINT='（↑/↓ 选择，Enter 确认，Esc 取消）'
MSG_en_W_HINT='(↑/↓ to move, Enter to confirm, Esc to cancel)'
MSG_zh_W_CURRENT='当前配置：%s'
MSG_en_W_CURRENT='current: %s'
MSG_zh_W_NO_URL='尚未配置推送地址'
MSG_en_W_NO_URL='no webhook url configured yet'
MSG_zh_W_MODE='要做什么？'
MSG_en_W_MODE='What do you want to do?'
MSG_zh_W_MODE_FULL='配置 Webhook 推送（完整向导）'
MSG_en_W_MODE_FULL='Configure webhook push (full wizard)'
MSG_zh_W_MODE_TEST='仅测试当前配置'
MSG_en_W_MODE_TEST='Send a test with the current config'
MSG_zh_W_MODE_STATUS='查看当前配置'
MSG_en_W_MODE_STATUS='Show the current configuration'
MSG_zh_W_CANCELLED='已取消，未修改任何配置。'
MSG_en_W_CANCELLED='Cancelled, nothing was changed.'
MSG_zh_W_STAGE_FAIL='无法创建暂存目录 %s'
MSG_en_W_STAGE_FAIL='cannot create staging dir %s'
MSG_zh_W_SUMMARY='即将写入的配置'
MSG_en_W_SUMMARY='About to write'
MSG_zh_W_CONFIRM='写入配置并测试推送？'
MSG_en_W_CONFIRM='Write the configuration and send a test?'
MSG_zh_W_WRITTEN='配置已写入 %s'
MSG_en_W_WRITTEN='configuration written to %s'
MSG_zh_W_TEST_HEAD='测试推送'
MSG_en_W_TEST_HEAD='Test push'
MSG_zh_W_TEST_OK='测试成功'
MSG_en_W_TEST_OK='test succeeded'
MSG_zh_W_TEST_FAIL='测试失败，请检查地址/模板；可用 smsfw doctor 进一步排查'
MSG_en_W_TEST_FAIL='test failed; check url/template, or run smsfw doctor'
MSG_zh_W_DAEMON_ON='转发已启用，守护进程运行中'
MSG_en_W_DAEMON_ON='forwarding enabled, daemon is running'
MSG_zh_W_DAEMON_OFF='转发处于关闭状态，随时可用 smsfw on 开启'
MSG_en_W_DAEMON_OFF='forwarding is off; run smsfw on any time'
MSG_zh_W_DONE='配置完成'
MSG_en_W_DONE='Setup complete'
MSG_zh_W_NOT_RUNNING='未运行'
MSG_en_W_NOT_RUNNING='not running'
MSG_zh_W_STAGE_FAIL='无法创建暂存目录 %s'
MSG_en_W_STAGE_FAIL='cannot create staging dir %s'
MSG_zh_W_WRITE_FAIL='写入失败：%s'
MSG_en_W_WRITE_FAIL='write failed: %s'
MSG_zh_W_HELP='帮助'
MSG_en_W_HELP='help'
MSG_zh_W_UNKNOWN='无法识别的选择 %s，请输入 1-%s'
MSG_en_W_UNKNOWN='unrecognised choice %s, expected 1-%s'
MSG_zh_W_ABORT='连续多次无法识别，已中止以免写出错误配置'
MSG_en_W_ABORT='too many unrecognised answers, aborting to avoid writing a wrong config'

MSG_zh_W_S1='名称（模板标签 {{RULE_TITLE}}）'
MSG_en_W_S1='Name (template tag {{RULE_TITLE}})'
MSG_zh_W_S1_Q='规则名称'
MSG_en_W_S1_Q='rule name'
MSG_zh_W_S2='启用'
MSG_en_W_S2='Enabled'
MSG_zh_W_S2_Q='收到短信后立即转发？'
MSG_en_W_S2_Q='Forward incoming SMS immediately?'
MSG_zh_W_S3='请求方式'
MSG_en_W_S3='Request method'
MSG_zh_W_S3_Q='请求方式'
MSG_en_W_S3_Q='request method'
MSG_zh_W_S4='推送地址'
MSG_en_W_S4='Webhook URL'
MSG_zh_W_S4_Q='Webhook 地址'
MSG_en_W_S4_Q='webhook url'
MSG_zh_W_S4_BAD='地址必须以 http:// 或 https:// 开头'
MSG_en_W_S4_BAD='the url must start with http:// or https://'
MSG_zh_W_S4_AUTH='检测到 URL 内嵌账号密码，将按 HTTP Basic 认证发送'
MSG_en_W_S4_AUTH='url contains credentials; HTTP Basic auth will be used'
MSG_zh_W_S5='密钥（HMAC-SHA256 签名，可留空）'
MSG_en_W_S5='Secret (HMAC-SHA256 signing, optional)'
MSG_zh_W_S5_HINT='配置后模板里的 {{SIGN}} / [sign] 会带上签名与时间戳'
MSG_en_W_S5_HINT='{{SIGN}} / [sign] will carry a signature and timestamp'
MSG_zh_W_S5_Q='密钥（留空不启用）'
MSG_en_W_S5_Q='secret (empty to disable)'
MSG_zh_W_S5_CLEAR='已存在密钥，是否清除？'
MSG_en_W_S5_CLEAR='A secret exists - clear it?'
MSG_zh_W_S6='响应校验关键字（可留空）'
MSG_en_W_S6='Response match keyword (optional)'
MSG_zh_W_S6_Q='响应体需包含'
MSG_en_W_S6_Q='response body must contain'
MSG_zh_W_S7='请求参数 / 请求体模板'
MSG_en_W_S7='Request body / template'
MSG_zh_W_S7_HINT='模板里可直接使用 {{FROM}} {{SMS}} {{RECEIVE_TIME}} 等标签'
MSG_en_W_S7_HINT='tags such as {{FROM}} {{SMS}} {{RECEIVE_TIME}} are available'
MSG_zh_W_S7_Q='请求体模板'
MSG_en_W_S7_Q='request body template'
MSG_zh_W_S7_KEEP='保持当前模板'
MSG_en_W_S7_KEEP='keep the current template'
MSG_zh_W_S7_PASTE='粘贴模板内容（原样写入，单行）'
MSG_en_W_S7_PASTE='paste a template (written verbatim, single line)'
MSG_zh_W_S7_FILE='从文件导入（复制进 /data/adb/smsf/）'
MSG_en_W_S7_FILE='import from a file (copied into /data/adb/smsf/)'
MSG_zh_W_S7_DEFAULT='使用默认 from/content/timestamp 表单参数'
MSG_en_W_S7_DEFAULT='use default from/content/timestamp form params'
MSG_zh_W_S7_PASTE_Q='粘贴模板内容（原样写入，不解释转义）'
MSG_en_W_S7_PASTE_Q='paste template (verbatim, no escape processing)'
MSG_zh_W_S7_EMPTY='内容为空，保留原模板'
MSG_en_W_S7_EMPTY='empty, keeping the current template'
MSG_zh_W_S7_PATH_Q='文件路径'
MSG_en_W_S7_PATH_Q='file path'
MSG_zh_W_S7_COPY_FAIL='复制失败'
MSG_en_W_S7_COPY_FAIL='copy failed'
MSG_zh_W_S7_NO_FILE='文件不存在：%s（保留原模板）'
MSG_en_W_S7_NO_FILE='no such file: %s (keeping the current template)'
MSG_zh_W_S8='请求头（Content-Type 会根据模板自动推断）'
MSG_en_W_S8='Headers (Content-Type is inferred from the template)'
MSG_zh_W_S8_Q='需要添加自定义请求头吗？'
MSG_en_W_S8_Q='Add custom headers?'
MSG_zh_W_S8_NAME='请求头名（留空结束）'
MSG_en_W_S8_NAME='header name (empty to finish)'
MSG_zh_W_S8_ADDED='已添加 %s'
MSG_en_W_S8_ADDED='added %s'
MSG_zh_W_S10='转发规则（匹配字段，POSIX ERE 正则，留空不限制）'
MSG_en_W_S10='Rules (match fields, POSIX ERE regex, empty = no limit)'
MSG_zh_W_S10_Q='需要设置过滤规则吗？'
MSG_en_W_S10_Q='Configure filtering rules?'
MSG_zh_W_S10_ALLOW='只转发这些号码（白名单）'
MSG_en_W_S10_ALLOW='only forward these senders (allow)'
MSG_zh_W_S10_BLOCK='不转发这些号码（黑名单）'
MSG_en_W_S10_BLOCK='never forward these senders (block)'
MSG_zh_W_S10_BALLOW='只转发包含该内容（白名单）'
MSG_en_W_S10_BALLOW='only forward bodies matching this (allow)'
MSG_zh_W_S10_BBLOCK='不转发包含该内容（黑名单）'
MSG_en_W_S10_BBLOCK='never forward bodies matching this (block)'
MSG_zh_W_S11='高级设置'
MSG_en_W_S11='Advanced'
MSG_zh_W_S11_Q='修改设备名称/超时/重试/轮询等参数吗？'
MSG_en_W_S11_Q='Tune device name / timeouts / retries / polling?'
MSG_zh_W_S11_DEVICE='设备名称（模板标签 {{DEVICE_NAME}}）'
MSG_en_W_S11_DEVICE='device name ({{DEVICE_NAME}})'
MSG_zh_W_S11_TIMEOUT='HTTP 超时（秒）'
MSG_en_W_S11_TIMEOUT='HTTP timeout (seconds)'
MSG_zh_W_S11_RETRIES='失败重试次数'
MSG_en_W_S11_RETRIES='send retries'
MSG_zh_W_S11_POLL='轮询间隔（秒）'
MSG_en_W_S11_POLL='poll interval (seconds)'
MSG_zh_W_S11_QUEUE='队列上限'
MSG_en_W_S11_QUEUE='queue limit'
MSG_zh_W_S11_DBCHECK='数据库兜底检查间隔（秒）'
MSG_en_W_S11_DBCHECK='db fallback check interval (seconds)'
MSG_zh_W_S11_TLS='跳过 HTTPS 证书校验？'
MSG_en_W_S11_TLS='Skip HTTPS certificate verification?'

# ------------------------------------------------------------------ help
MSG_en_HELP='smsfw - SMS webhook forwarder (Magisk module)

  wizard                  interactive setup wizard (recommended first step)
  status                  show configuration + daemon state
  start | stop | restart  control the daemon (auto-starts on boot)
  on | off                enable/disable forwarding (live, no restart)
  doctor                  diagnose provider/payload/transport problems

  set <key> <value>       change a setting (see keys below)
  get <key>               print a setting
  show                    print config.conf

  url <https://...>       shortcut for: set url
  template [cat|set F]    show or replace the request body template
  headers [cat|set F]     show or replace extra HTTP headers
  secret [clear|set F]    show, clear or replace the HMAC secret

  test [from] [body]      send a real test webhook now
  preview [from] [body]   render the request without sending
  poll                    run one poll cycle immediately
  flush                   retry the whole queue now (ignores backoff)
  queue [list|retry|clear] inspect/retry/drop pending messages
  reset-state             re-baseline the inbox scan
  log [-n N] [-f]         show/follow the daemon log
  version | help

Config keys (also usable with the SMSFW_ prefix):
  url method template headers secret device poll db_check timeout retries
  retry_delay max_attempts queue_limit forward_existing tls_insecure
  response_match sender_allow sender_block body_allow body_block
  rule_title log_level

Scope: webhook push only. Language: SMSF_LANG=zh|en (auto-detected).

Examples:
  smsfw wizard
  smsfw set url https://example.com/sms
  smsfw test 10086 "hello from smsfw"'

MSG_zh_HELP='smsfw —— 短信 Webhook 转发模块（Magisk/KernelSU/APatch）

  wizard                  交互式配置向导（推荐首先执行）
  status                  查看配置与守护进程状态
  start | stop | restart  控制守护进程（开机自动启动）
  on | off                开关转发（即时生效，无需重启）
  doctor                  自检 provider / 载荷 / 传输

  set <键> <值>           修改配置项（键名见下）
  get <键>                读取配置项
  show                    打印 config.conf

  url <https://...>       set url 的快捷方式
  template [cat|set 文件]  查看或替换请求体模板
  headers [cat|set 文件]   查看或替换附加请求头
  secret [clear|set 文件]  查看、清除或替换 HMAC 密钥

  test [号码] [内容]       立即发送一条真实测试推送
  preview [号码] [内容]    只渲染请求，不发送
  poll                    立即执行一次轮询
  flush                   忽略退避，立即重试整个队列
  queue [list|retry|clear] 查看/重试/放弃待发送记录
  reset-state             重新基线化收件箱扫描
  log [-n 行数] [-f]       查看/跟踪守护进程日志
  version | help

配置键（也可使用 SMSFW_ 前缀的全名）：
  url method template headers secret device poll db_check timeout retries
  retry_delay max_attempts queue_limit forward_existing tls_insecure
  response_match sender_allow sender_block body_allow body_block
  rule_title log_level

范围：仅实现 Webhook 推送。语言：SMSF_LANG=zh|en（自动识别）。

示例：
  smsfw wizard
  smsfw set url https://example.com/sms
  smsfw test 10086 "hello from smsfw"'
MSG_zh_AUTO_CONFIGURE='尚未配置推送地址，现在运行配置向导吗？'
MSG_en_AUTO_CONFIGURE='No webhook url configured. Run the setup wizard now?'
MSG_zh_AUTO_TEST='配置有更新，现在发送一条测试推送吗？'
MSG_en_AUTO_TEST='Configuration changed since the last test. Send a test push now?'
MSG_zh_AUTO_STATUS='配置已就绪，要查看当前状态吗？'
MSG_en_AUTO_STATUS='Configuration is ready. Show the current status?'
MSG_zh_AUTO_HINT='（选择“否”或按 Esc 查看帮助）'
MSG_en_AUTO_HINT='(choose No or press Esc for help)'
