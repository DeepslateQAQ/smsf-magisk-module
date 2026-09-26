# SMSF Webhook — Magisk 短信 Webhook 转发模块
> [!WARNING]
> 本项目属于「岩酱的奇思妙想」系列，代码主要由人工智能生成并维护。请在使用前自行评估安全性、可靠性与适用性，谨慎用于生产环境。

一个 **root 级**（Magisk / KernelSU / APatch）短信转发模块：收到短信后，按自定义模板把内容 POST/PUT/PATCH/GET 到任意 HTTP(S) Webhook。

只做「短信 → Webhook」这一件事，**不需要安装 APK，不需要把任何应用设为默认短信应用**，不注入、不 hook 系统进程。模板语法、标签名与签名算法与 [pppscn/SMSForwarder](https://github.com/pppscn/SMSForwarder) 的 Webhook 通道保持一致，迁移时原有 `webParams` 模板几乎可以直接使用。

```
短信到达 → 内核唤醒 → 守护进程发现信道数据库变化 → content provider 读取短信
        → 过滤 → 套用模板 → 签名 → HTTP(S) 推送 → 失败进入队列重试
```

## 特性

| 特性 | 说明 |
| --- | --- |
| 无 APK | 纯 root 方案，不占系统应用位，不影响默认短信应用 |
| BFU 可用 | 配置/状态在 `/data/adb`（设备加密存储），短信库在 `user_de`，**首次解锁前即可转发**，适用于无人值守自动重启的场景 |
| 兼容 SMSForwarder | `{{FROM}}`/`{{SMS}}`/`[content]` 等标签、JSON/URL/文本三种转义、HMAC-SHA256 签名、`from/content/timestamp` 默认参数 |
| 省电 | 只比对短信库 `mmssms.db` 与其 `-wal` 的大小/mtime 指纹，文件变化时才启动 ART 查询 provider（空闲时几乎零开销；`-shm` 因读操作也会变更而被刻意排除） |
| 断网队列 | 失败自动入队，指数退避重试，重启不丢；队列上限与最大尝试次数可配 |
| 多卡 | 读取 `sub_id` 并从 `siminfo` 解析卡槽序号与运营商名称 |
| 过滤 | 发送方/内容黑白名单（POSIX ERE 正则） |
| 独立控制 | `smsfw` 命令行：状态、开关、模板预览、真实测试、队列管理、日志、`doctor` 自检 |
| 交互式向导 | `smsfw wizard`：GitHub CLI 风格 TUI（↑/↓ 选择、占位默认值、密钥掩码、就地重绘），按上游 SMSForwarder 表单字段顺序引导配置，非 TTY 自动降级为可脚本化的行输入 |
| 中英双语 | 全部 CLI / 向导 / 守护进程日志走同一个消息目录，按 `SMSF_LANG` → `LANG` → `persist.sys.locale` 自动选择；`SMSF_ASCII=1` 可强制 ASCII 符号 |
| 免刷写挂载 | `system/bin/smsfw` 经 Magisk Magic Mount（或 KernelSU/APatch 的系统覆盖，KernelSU 通常需要 meta-overlayfs 之类的元模块）挂载到 `/system/bin`；实现仍在 `/data/adb/smsf`，升级无需触碰 /system。`doctor` 对未挂载的情况只给警告 |
| KSU Web UI | `webroot/` 提供 Material You 风格的管理器内网页（官方 `@material/web` 组件 + Material 3 调色板，见下）：状态卡片、配置表单、测试/预览/轮询/重试/日志，全部通过 `kernelsu.exec` 调用同一套 `smsfw` 命令 |
| 跨架构 | 载荷是与架构无关的 DEX，通过系统 `app_process` 运行（与 `/system/bin/am`、`/system/bin/content` 相同的机制） |

## 环境要求

* Magisk ≥ 20.4 / KernelSU / APatch（任一即可），已获取 root
* Android 5.0+（API 21+，需要 `content` 命令与 ART）
* 手机具备短信能力（平板/无基带设备无法读取短信）
* 设备默认时区正确（模板中的时间按设备本地时区格式化）

> 只支持短信（SMS）；MMS、来电、应用通知不在此模块范围内。

## 安装

1. 下载或自行构建模块 zip：

   ```bash
   git clone <this repo> && cd smsf-magisk-module
   ./build.sh            # 产物：dist/smsf_webhook-v1.0.0.zip
   # 或者用 Nix 提供工具链： nix-shell shell.nix --run './build.sh test'
   ```

2. 在 Magisk / KernelSU / APatch 中刷入 zip，重启（Magisk 会打印后续步骤）。

3. 配置 Webhook 并测试：

   ```bash
   su
   /data/adb/smsf/bin/smsfw set url 'https://example.com/sms/hook'
   /data/adb/smsf/bin/smsfw test          # 立即发送一条真实测试推送
   /data/adb/smsf/bin/smsfw doctor        # 自检：provider、载荷、网络、配置
   ```

4. 重启后守护进程自动运行（也可 `smsfw start` 立即启动），并且 `smsfw` 已挂载到 `/system/bin`，
   可直接执行（重启前请用绝对路径 `/data/adb/smsf/bin/smsfw`）。之后收到的短信会自动转发。

> 建议把命令加个习惯写法：`alias smsfw=/data/adb/smsf/bin/smsfw`（需在 root shell 中执行）。

## 常用命令

```
smsfw                        不带参数时按需引导：未配置→询问是否运行向导；
                             配置有变更→询问是否测试；已测试→询问是否查看状态
                             （选择“否”或 Esc 则显示帮助；非 TTY 直接显示帮助）
smsfw wizard                 交互式配置向导（推荐首次使用）
smsfw status                  查看配置与运行状态
smsfw doctor                  环境自检（出问题时先跑这个）
smsfw test [号码] [内容]       立即发送一条测试推送
smsfw preview [号码] [内容]    只渲染请求，不发送（调试模板）
smsfw set url https://...     修改任意配置键
smsfw get poll                读取配置
smsfw template set /sdcard/t.json   复制到 /data/adb/smsf/template.json 并启用
smsfw headers set /sdcard/h.txt     复制到 /data/adb/smsf/headers.txt 并启用
smsfw secret set /sdcard/secret.txt     # 启用 HMAC-SHA256 签名（同样复制进 /data/adb）
smsfw on | off                开关转发（即时生效，无需重启）
smsfw start | stop | restart  控制守护进程
smsfw queue [list|retry|clear] 查看/重试/放弃待发队列
smsfw reset-state             重新基线化（例如短信库被恢复后）
smsfw poll                    立即执行一次轮询
smsfw flush                   忽略退避，立即重试整个队列
smsfw log -n 100 -f           查看/跟踪日志
smsfw help
```

## 配置项

配置文件为 `/data/adb/smsf/config.conf`，使用受限的 `KEY=VALUE` 行格式；值可用单引号包裹，行尾可带 `#` 注释，未知键和非赋值行会忽略。推荐用 `smsfw set` 修改，守护进程每轮都会重新读取，**改完即时生效**。

| 键（`smsfw set` 简写） | 默认 | 说明 |
| --- | --- | --- |
| `url` | 空 | Webhook 地址，支持 `https://user:pass@host/path` 形式的基础认证 |
| `method` | `POST` | `POST` / `PUT` / `PATCH` / `GET` |
| `template` | `/data/adb/smsf/template.json` | 请求体模板文件，留空/不存在时使用默认 `from=..&content=..&timestamp=..` |
| `headers` | `/data/adb/smsf/headers.txt` | 额外请求头，每行 `Name: value`，`#` 开头为注释 |
| `secret` | `/data/adb/smsf/secret` | 设置后启用 HMAC-SHA256 签名（见下文） |
| `device` | 空 | 设备名，空则取 `ro.product.brand + ro.product.model` |
| `poll` | `5` | 轮询短信数据库指纹的间隔（秒） |
| `db_check` | `60` | 兜底：即使数据库文件没变化也至少多久查询一次 provider（秒，0=每次都查） |
| `timeout` | `15` | 单次 HTTP 超时（秒） |
| `retries` | `2` | 单次发送内的即时重试次数 |
| `retry_delay` | `5` | 即时重试间隔（秒），队列退避基数 |
| `max_attempts` | `100` | 单条短信最多尝试次数，超过后移入 `failed/` |
| `queue_limit` | `200` | 队列上限，超出丢弃最旧记录 |
| `forward_existing` | `0` | 是否转发安装前已存在的短信（初始化时） |
| `tls_insecure` | `0` | `1` = 不校验 HTTPS 证书（自签名时使用） |
| `response_match` | 空 | 非空时要求响应体包含该字符串才算成功（同 SMSForwarder 的「响应校验」） |
| 代理 | — | 模块**不带**代理设置：用系统级 TUN（如 Magisk 版 mihomo）即可覆盖本模块的请求，`HttpURLConnection` 会自动走系统 `ProxySelector` |
| `sender_allow` / `sender_block` | 空 | 号码白/黑名单，POSIX ERE 正则，未锚定时为「包含匹配」 |
| `body_allow` / `body_block` | 空 | 内容白/黑名单，同上 |
| `rule_title` | `sms` | 模板标签 `{{RULE_TITLE}}` 的值 |
| `log_level` | `info` | `debug` 会打印每次跳过 provider 查询等细节 |

示例：

```bash
smsfw set sender_block '^10086$|^95533$'   # 忽略运营商短信
smsfw set body_block '验证码|校验码'         # 忽略验证码
smsfw set timeout 20
smsfw set tls_insecure 1
```

## KernelSU / APatch Web UI

模块内置 `webroot/`，在 KernelSU（或 APatch）管理器里进入本模块点击 **WebUI** 即可打开：

* **Material You 风格**：M3 色调令牌、圆角卡片、filled/tonal/outlined 按钮、涟漪、明暗主题跟随系统；
* **状态显示**：运行状态、配置是否已测试、队列（待发/失败）、累计发送、最后短信 ID、模板/密钥状态、设备名；
* **配置管理**：地址、请求方式、模板（标签提示）、请求头（Key/Value 行，可增删；文件里的 `#` 注释原样保留）、HMAC 密钥、过滤规则、轮询/超时/重试/设备名；保存即写入 `config.conf`；
* **操作**：发送测试推送、预览请求体、立即轮询、重试队列、重启守护进程、启停开关、查看日志。

页面不直接改文件，而是通过 `kernelsu.exec` 调用 `smsfw`，所以 WebUI 与命令行行为完全一致（状态来自
`smsfw status --json`，多行模板/请求头经 `smsfw template|headers|secret put` 落盘）。

界面由官方 Material Web 组件（`md-filled-button`、`md-outlined-text-field`、`md-switch`、`md-outlined-select` …）
加一套 Material 3 色板构成，**全部离线自带**：`webroot/vendor/material-web.min.js` 是打包好的组件
（勿手改），`webroot/tokens.css` 由种子色生成的 light/dark 双色板。二者都由 `tools/webui/build.sh`
重新生成（需要本机 bun 与网络，产物提交进仓库，因此构建模块本身不需要网络）。

浏览器直接打开 `webroot/index.html` 只能看到界面，会提示桥接不可用——它必须由管理器注入的 WebView 打开。Magisk 没有等价机制，请使用 `smsfw wizard` / CLI。

## 输出风格与语言

所有输出遵循 GitHub CLI 风格：`✓` 成功、`✗` 失败、`!` 警告、`•` 提示；颜色仅在输出到终端时启用，
因此日志、管道和脚本里都是纯文本（`SMSF_ASCII=1` 可把符号切换为 `[ok]`/`[x]`/`[!]`）。

语言按 `SMSF_LANG`（`zh`/`en`）→ `LANG`/`LC_ALL` → `persist.sys.locale` 的顺序判定，默认中文：

```bash
SMSF_LANG=en smsfw status    # 强制英文
smsfw help                   # 跟随系统语言
```

新增输出只要往 `payload/bin/i18n.sh` 的 `MSG_zh_*` / `MSG_en_*` 加一对键值即可；
`./build.sh test` 里的 `tests/check_i18n.py` 会校验「代码引用的键一定两种语言都有」。

## 交互式向导

```bash
su -c '/data/adb/smsf/bin/smsfw wizard'
```

GitHub CLI 风格 TUI：`? 问题` + `❯` 光标（↑/↓、`j`/`k`、空格切换，回车确认，Esc/Ctrl-C 取消），文本项把当前值作为占位符显示（回车即接受），密钥输入以 `*` 掩码；非 TTY（`adb shell` 管道、脚本）自动降级为编号/行输入，同一套流程仍可脚本化。`SMSF_ASCII=1` 可强制 ASCII 符号。

提问顺序与上游 SMSForwarder 的发送通道表单一致：

```
规则名称 → 启用 → 请求方式 → 推送地址 → 密钥(HMAC) → 响应校验
→ 请求参数(请求体模板) → 请求头 → 转发规则(过滤) → 高级设置
→ 汇总确认 → 测试推送 → 写入并启动
```

配置仅在最后确认时才写盘，中途取消不会改动任何文件（密钥单独写入 `0600` 的 `/data/adb/smsf/secret`）。

## 模板与标签

模板就是请求体本身。默认的 `template.json`：

```json
{
  "device": "{{DEVICE_NAME}}",
  "from": "{{FROM}}",
  "content": "{{SMS}}",
  "card_slot": "{{CARD_SLOT}}",
  "card_subid": "{{CARD_SUBID}}",
  "receive_time": "{{RECEIVE_TIME}}",
  "timestamp": {{TIMESTAMP}}
}
```

### 转义方式（自动判断，可强制）

| 模式 | 触发条件 | 值处理 |
| --- | --- | --- |
| `json` | `headers` 含 `Content-Type: application/json`，或模板去空格后以 `{` / `[` 开头 | JSON 字符串转义（`"` `\` 换行 控制字符） |
| `url` | `GET` 请求、表单（`x-www-form-urlencoded`）或默认参数 | `URLEncoder`（空格 → `+`，换行 → `%0A`） |
| `raw` | `headers` 中 `Content-Type: text/*` | 原样写入 |

也可以用 `--escape` 强制（由 `smsfw` 内部调用，不常用）。`Content-Type` 未显式配置时按上表自动补全。

### 标签（大小写不敏感，`{{TAG}}` 与 `[tag]` 两种写法等价）

| 标签 | 含义 |
| --- | --- |
| `{{FROM}}` / `[from]` | 发送方号码 |
| `{{SMS}}` / `{{MSG}}` / `[content]` / `[msg]` | 短信正文（多行原样保留） |
| `{{ORG_CONTENT}}` / `[org_content]` | 原始正文。原版里 `[content]` 是「经消息模板加工后」的内容、`[org_content]` 才是原文；本模块的模板就是请求体，没有第二层模板，因此两者相同 |
| `{{CARD_SLOT}}` / `[card_slot]` / `{{TITLE}}` / `[title]` | 卡槽备注（运营商名，取不到则为 `SIM <sub_id>`）；原版 `[title]` 与 `[card_slot]` 同源，这里保持一致 |
| `{{CARD_SUBID}}` / `{{SUBSCRIPTION_ID}}` | 订阅 ID（`sub_id`） |
| `{{SIM_SLOT_INDEX}}` | 卡槽序号（0 起，取不到为空） |
| `{{RECEIVE_TIME}}` | 接收时间，默认 `yyyy-MM-dd HH:mm:ss` |
| `{{CURRENT_TIME}}` | 推送时间 |
| `{{TIMESTAMP}}` / `[timestamp]` | 推送时刻的毫秒时间戳 |
| `{{DEVICE_NAME}}` / `[device_mark]` | 设备名 |
| `{{APP_VERSION}}` / `[app_version]` | 模块版本 |
| `{{RULE_TITLE}}` | 规则别名（默认 `sms`） |
| `{{SIGN}}` / `[sign]` | HMAC 签名（配置了 secret 才有效） |
| `{{MESSAGE_ID}}` / `{{SERVICE_CENTER}}` | 短信库 ID / 短信中心号码 |
| `{{BATTERY_PCT}}` / `{{BATTERY_STATUS}}` / `{{BATTERY_INFO_SIMPLE}}` | 电量（仅模板引用时才采集，较慢） |
| `{{IPV4}}` | 当前 IPv4（仅模板引用时才采集） |

时间格式可自定义（Go/Java 风格，兼容 SMSForwarder 写法）：

```
{{RECEIVE_TIME:yyyy-MM-dd HH:mm}}      [receive_time:HH:mm:ss]
{{CURRENT_TIME:yyyy/MM/dd HH:mm:ss}}
```

模板里未识别的标签会**原样保留**（与原版 SMSForwarder 一致）。
来电/应用通知相关标签（`{{PACKAGE_NAME}}`、`{{UID}}`、`{{CALL_TYPE}}`、`{{CONTACT_NAME}}`、`{{PHONE_AREA}}`、`{{NET_TYPE}}`、位置类标签）本模块不需要，`{{PACKAGE_NAME}}` 按原版语义回退为发送方号码，其余渲染为空串。

### md5(...) 表达式

与 SMSForwarder 一致，模板里可以写 `md5(...)`，它先展开内部标签、再取 MD5（小写十六进制），
常用于给接收端一个幂等/去重键：

```
{"digest": "md5([from]+[content]+'salt')"}
```

拼接符 `+` 会被去掉、单引号内的内容原样保留、引号本身也去掉，因此上面的结果就是
`md5(FROM 值 + 正文 + salt)`。`[sign]` 与它无关，签名仍由 `secret` 决定。

### HMAC 签名

配置 `secret` 后，`{{SIGN}}` / `[sign]` 会被替换为：

```
URLEncoder( Base64( HMAC_SHA256(key = secret, data = "{timestamp}\n{secret}") ) )
```

其中 `{timestamp}` 与 `{{TIMESTAMP}}` 完全一致（同一时刻），可直接在服务端复算校验。这与 SMSForwarder 的签名实现一致：签名值本身是 URL 编码后的 Base64，表单/GET 模板里只写入一次（不要重复编码），JSON 模板里同样按原样写入。

## 模板示例（自定义 Webhook）

模块只做一件事：按你配置的模板，把短信 `POST/PUT/PATCH/GET` 到你的 Webhook 地址。请求体完全由模板决定，**不内置任何第三方服务的专用接口**。

自建服务常用 JSON：

```json
{
  "device": "{{DEVICE_NAME}}",
  "from": "{{FROM}}",
  "content": "{{SMS}}",
  "card_slot": "{{CARD_SLOT}}",
  "receive_time": "{{RECEIVE_TIME}}",
  "timestamp": {{TIMESTAMP}},
  "sign": "{{SIGN}}"
}
```

表单风格（`GET` 时作为查询参数拼接）：

```
from=[from]&content=[content]&timestamp=[timestamp]
```

写入与验证：

```bash
smsfw wizard                                  # 向导里直接粘贴或导入
smsfw template set /sdcard/my-template.json   # 或指定文件（会复制到 /data/adb/smsf/）
smsfw preview 10086 '测试内容'                # 只渲染不发送，便于对照目标服务的字段要求
```

若接收端要求特殊字段名或嵌套结构，按它的 JSON 结构改写模板即可，标签语法见上一节。

## 工作原理

1. `service.sh` 在 `late_start` 阶段启动 `smsfwd supervise`（守护进程 + 崩溃自动重启）。
2. `run` 等待 `sys.boot_completed=1`（BFU 下同样会置位）与 `content://sms/inbox` 可查询。
3. 每 `poll` 秒对比 `/data/user_de/0/com.android.providers.telephony/databases/mmssms.db*` 的大小/mtime 指纹；无变化则不启动 ART，仅每 `db_check` 秒做一次兜底查询。
4. 发现新 `_id` 后，用 `/system/bin/content query`（root 身份，权限检查对 uid 0 放行）逐字段读取号码、正文、时间、`sub_id`，并查 `telephony/siminfo` 解析卡槽。
5. 过滤、落盘为一条「记录」（含当时的 URL/模板/请求头/密钥快照，保证配置变更不影响已入队短信）。
6. 记录进入队列并立即发送：`app_process` 加载模块自带的 DEX 载荷（`lib/smsfw.jar`，与 `/system/bin/am` 完全相同的运行方式）完成模板渲染、JSON/URL 转义、HMAC 签名、TLS 请求与响应校验。
7. 失败按指数退避重试；请求由 Java `HttpURLConnection` 实现，DNS/TLS 用系统实现。模块**不做**代理设置：系统级代理（TUN 或全局 HTTP 代理）由 `ProxySelector` 自动生效，因此 root 设备上用 Magisk 版 mihomo 之类方案即可，无需在这里重复配置。

### 目录布局

```
/data/adb/smsf/
├── bin/            smsfw、smsfwd、common.sh（每次安装覆盖）
├── lib/smsfw.jar   载荷（classes.dex）
├── config.conf     配置（安装时不存在才写入）
├── template.json   模板
├── headers.txt     额外请求头
├── secret          HMAC 密钥（可选）
├── state/          last_sms_id、pid、计数器、runner 缓存
├── queue/          待发送记录
├── failed/         超过最大尝试次数的记录
└── log/smsfwd.log  运行日志（超过 1MB 自动轮转）
```

## BFU（首次解锁前）与无人值守

* 配置、状态、队列都在 `/data/adb`（设备加密，开机即可用），短信库位于 `user_de`，因此**锁屏未解锁时也能转发**；Magisk 的 `late_start` 服务在 BFU 同样会执行。
* 换卡/重启后守护进程由 `supervise` 自动拉起；worker 崩溃会在 10 秒后重启。
* 深度睡眠时定时器不会主动唤醒 CPU（省电），但**收到短信会唤醒基带/AP**，此时到期的定时器立即触发；守护进程还会在检测到「睡眠间隔」后进入 60 秒的 1 秒快速轮询，避免与短信写库竞态。
* 若设备重启后运营商网络尚未就绪，发送失败的记录会留在队列里，联网后自动补发。

## 故障排查

先跑：

```bash
su -c '/data/adb/smsf/bin/smsfw doctor'
tail -n 50 /data/adb/smsf/log/smsfwd.log
```

| 现象 | 排查 |
| --- | --- |
| `doctor` 报 provider 不可达 | 设备是否有短信能力；是否运行在 root；`ls -l /data/user_de/0/com.android.providers.telephony/databases/` |
| 推送返回 4xx | `smsfw preview` 对照接收端文档检查请求体字段；JSON 模板需以 `{` 开头（或显式配置 `Content-Type: application/json`） |
| 推送超时/失败 | `smsfw log -n 100`；`smsfw queue list` 查看重试；必要时 `smsfw flush` |
| 自签名 HTTPS | `smsfw set tls_insecure 1`（会跳过证书与主机名校验） |
| 收不到旧短信 | 默认只转发安装后的新短信；`smsfw set forward_existing 1` 后再 `smsfw reset-state` 可转发存量（量大慎用） |
| 模板标签没被替换 | 检查标签拼写；未知标签会原样保留；`smsfw preview` 可确认 |
| 换机/恢复短信库后漏发 | `smsfw reset-state` 重新基线化 |
| 提示数据目录不可用 | CLI 需要可写的数据目录；非 root 或未安装模块时（例如在电脑上直接跑）会明确报错而不会写到别处，桌面调试可设 `SMSF_DATA=/tmp/smsf` |
| 想暂时停用 | `smsfw off`（保留守护进程与队列），彻底停止用 `smsfw stop` |

## 开发与构建

```
src/com/smsfw/            载荷源码（纯 java.*，可在桌面 JVM 直接运行）
payload/                  模块打包根目录（module.prop、脚本、config、lib/*.jar）
tests/                    桌面端测试：模板/HMAC/HTTP 端到端 + 模拟 Android 的守护进程集成测试
build.sh                  编译 → d8 打包 classes.dex → 生成 dist/*.zip
shell.nix                 Nix 开发环境（JDK + 固定版本 R8/d8 + shellcheck + mksh）
```

```bash
nix-shell shell.nix                  # 可选：提供固定工具链
./build.sh                           # 构建载荷 + 模块 zip
./build.sh test                      # 运行全部桌面测试
./build.sh bump patch                # bump patch 版本并同步 update.json
```

GitHub Actions 的 `Bump version and build nightly` workflow 可手动 bump `patch`/`minor`/`major`，提交版本变更、创建版本 tag 并构建 ZIP。Magisk 更新源使用 GitHub Releases 的稳定 `module.zip` 资产；Actions artifact 仍提供 nightly 构建，需通过 nightly.link 使用时可作为人工下载源。

测试通过伪造的 `content`/`getprop`/`app_process` 在 Linux 上驱动**与设备完全相同的脚本和 jar**（共 219 项：55 载荷 + 92 守护进程 + 27 安装器 + 45 向导）。另有 WebUI 请求头模型测试 8 项（bun，纯函数、无需浏览器），以及三项静态检查：i18n 键覆盖与字面量泄漏、各 harness 端口带互不重叠、WebUI 资源一致性（id 与 `app.js` 对应、组件都在 vendor 包里、色 token 都有定义、页面上没有任何网络引用）。代理用例覆盖 HTTP / 带认证 HTTP / SOCKS5 / 代理不可达；WebUI 通过 `status --json` 契约与静态校验（含 JS 语法检查）保障。伪造的 `app_process` 严格复刻 `app_main.cpp` 的参数顺序（VM 选项 → parent-dir → `--nice-name` → 类名），参数位置错误会直接失败，而不是被静默跳过；向导的 TUI 用例在真实 pty 中运行（util-linux `script`），并用 ANSI 回放校验菜单就地重绘与单行提示，覆盖基线不重发、多行/引号正文、正文含 `usage:`/`[ERROR]` 等伪命令行文本、stderr 噪声不影响投递、过滤、断网入队、恢复补发、模板渲染、默认时间格式、签名单次编码、电量/IP 标签、CLI、DB 指纹节能门控、`content` 恒返回 0 时的错误识别、短信被删除的哨兵值、模板落盘、向导全流程（含无效地址回退、取消不改配置、粘贴模板、方向键与 Esc）、安装/升级/卸载流程等。

载荷 dex 用 d8（R8 9.4.24，SHA-256 固定校验）编译，`min-api 21`。

## 卸载

在管理器中卸载模块即会停止守护进程；配置与队列保留在 `/data/adb/smsf`，彻底清理：

```bash
rm -rf /data/adb/smsf
```

## 许可

GPL-3.0-or-later（见 `LICENSE`）。Webhook 模板语义、签名算法与标签命名参考
[pppscn/SMSForwarder](https://github.com/pppscn/SMSForwarder)（Apache-2.0），以实现配置层面的兼容。

WebUI 里 vendor 了第三方前端产物，它们保留自己的许可（详见 `payload/webroot/vendor/NOTICE`）：
`@material/web` 2.5.0 为 Apache-2.0，Lit 3.3.3 / lit-html / @lit/reactive-element 为 BSD-3-Clause；
两者都与 GPLv3 兼容。许可文本随模块一起分发在 `payload/webroot/vendor/`。
