/* smsfw WebUI front-end.
 *
 * Talks to the module through the KernelSU/APatch WebUI bridge
 * (kernelsu.exec -> { errno, stdout, stderr }) and drives the `smsfw` CLI, so
 * the WebUI and the shell always behave identically. Status comes from
 * `smsfw status --json`.
 */
'use strict';

const BIN = '/data/adb/smsf/bin/smsfw';

/* ------------------------------------------------------------------ bridge */

/* ReSukiSU exposes the native callback API as `ksu.exec(command, options,
 * callbackName)`. Some managers also expose the Promise wrapper as `kernelsu`. */
function findBridge() {
  const promiseApi = globalThis.kernelsu;
  if (promiseApi && typeof promiseApi.exec === 'function') {
    return { name: 'kernelsu', exec: promiseApi.exec.bind(promiseApi) };
  }
  const callbackApi = globalThis.ksu;
  if (callbackApi && typeof callbackApi.exec === 'function') {
    return { name: 'ksu', exec: callbackApi.exec.bind(callbackApi) };
  }
  return null;
}

let bridge = findBridge();

function waitForBridge(timeoutMs = 8000) {
  return new Promise((resolve) => {
    const started = Date.now();
    const poll = () => {
      bridge = findBridge();
      if (bridge) return resolve(bridge);
      if (Date.now() - started > timeoutMs) return resolve(null);
      setTimeout(poll, 200);
    };
    poll();
  });
}

function normalizeResult(raw) {
  if (typeof raw === 'string') {
    try {
      const value = JSON.parse(raw);
      if (!value || typeof value !== 'object'
          || !('errno' in value || 'code' in value || 'stdout' in value || 'stderr' in value || 'out' in value || 'err' in value)) {
        return { code: 0, out: raw, err: '' };
      }
      return {
        code: Number(value.errno ?? value.code ?? 0),
        out: value.stdout ?? value.out ?? '',
        err: value.stderr ?? value.err ?? '',
      };
    } catch (error) {
      return { code: 0, out: raw, err: '' };
    }
  }
  if (raw && typeof raw === 'object') {
    return {
      code: Number(raw.errno ?? raw.code ?? 0),
      out: raw.stdout ?? raw.out ?? '',
      err: raw.stderr ?? raw.err ?? '',
    };
  }
  return { code: 0, out: '', err: '' };
}

function sh(cmd) {
  if (!bridge) return Promise.reject(new Error('WebUI bridge unavailable'));
  return new Promise((resolve) => {
    let settled = false;
    let timer = 0;
    const callbackName = `__smsfwExec_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const finish = (raw) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      delete globalThis[callbackName];
      resolve(normalizeResult(raw));
    };
    globalThis[callbackName] = (...args) => {
      if (args.length <= 1) finish(args[0]);
      else finish({ errno: args[0], stdout: args[1], stderr: args[2] });
    };
    try {
      const result = bridge.name === 'ksu'
        ? bridge.exec(cmd, '{}', callbackName)
        : bridge.exec(cmd);
      if (result && typeof result.then === 'function') {
        result.then(finish, (error) => finish({ errno: 1, stderr: String(error) }));
      } else if (result && typeof result === 'object') {
        finish(result);
      } else {
        timer = setTimeout(() => finish({ errno: 124, stderr: 'exec timeout' }), 60000);
      }
    } catch (error) {
      finish({ errno: 1, stderr: String(error) });
    }
  });
}

async function smsfw(args) {
  const res = await sh(`${BIN} ${args}`);
  if (res.code !== 0) {
    const detail = [res.err, res.out].filter(Boolean).join('\n').trim();
    throw new Error(detail || `smsfw ${args} failed with code ${res.code}`);
  }
  return res;
}

/* ------------------------------------------------------------- utilities */

const $ = (id) => document.getElementById(id);

/* <md-switch> exposes .selected; a plain checkbox exposes .checked. */
function setToggle(el, on) {
  if ('selected' in el) el.selected = on;
  else el.checked = on;
}

function toggleValue(el) {
  return 'selected' in el ? el.selected : el.checked;
}

/* Status chip: class names are the ones style.css styles (.chip--off/--error). */
function chip(text, kind) {
  const el = $('state-chip');
  el.textContent = text;
  el.className = 'chip' + (kind === 'off' ? ' chip--off' : kind === 'error' ? ' chip--error' : '');
}

/* One label/value cell of the status grid. */
function stat(label, value) {
  const div = document.createElement('div');
  div.className = 'stat';
  const l = document.createElement('div');
  l.className = 'stat__label';
  l.textContent = label;
  const v = document.createElement('div');
  v.className = 'stat__value';
  v.textContent = value === '' || value === undefined ? '—' : String(value);
  div.append(l, v);
  return div;
}

const shellQuote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;
function decodeBase64Utf8(encoded) {
  const binary = atob(encoded.trim());
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  if (typeof globalThis.TextDecoder !== 'undefined') return new globalThis.TextDecoder().decode(bytes);
  let escaped = '';
  for (const byte of bytes) escaped += `%${byte.toString(16).padStart(2, '0')}`;
  return decodeURIComponent(escaped);
}
let secretClearArmedUntil = 0;

function setBusy(button, busy) {
  if (!button) return;
  button.disabled = busy;
  button.setAttribute('aria-busy', busy ? 'true' : 'false');
  if (busy) {
    button.dataset.label = button.textContent;
    button.textContent = '执行中…';
  } else if (button.dataset.label) {
    button.textContent = button.dataset.label;
    delete button.dataset.label;
  }
}

let snackTimer = 0;
let loadedOk = false;
function toast(message, isError = false) {
  const el = $('snackbar');
  el.textContent = message;
  el.style.background = isError
    ? 'var(--md-sys-color-error-container)'
    : 'var(--md-sys-color-inverse-surface)';
  el.style.color = isError
    ? 'var(--md-sys-color-on-error-container)'
    : 'var(--md-sys-color-inverse-on-surface)';
  el.hidden = false;
  clearTimeout(snackTimer);
  snackTimer = setTimeout(() => { el.hidden = true; }, 3200);
}

function showOutput(title, text) {
  $('output-title').textContent = title;
  $('output').textContent = text || '(无输出)';
  $('output-card').hidden = false;
  $('output-card').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function fail(error) {
  const el = $('global-error');
  el.textContent = String(error && error.message ? error.message : error);
  el.hidden = false;
  setTimeout(() => { el.hidden = true; }, 6000);
}

/* ------------------------------------------------------------------ state */

let state = null;
let templateText = '';
let headersText = '';
/* The headers file may open with comments; they are preserved verbatim and only
   the Name: value entries are edited (as rows, so nobody has to remember the
   syntax). */
let headerModel = { items: [], trailingNewline: true };

/* Rows edit the parsed model in place; non-entry lines are re-emitted verbatim,
   so a save never rewrites the file's comments (see headers.js, which is pure
   and covered by tests/test_webui_headers.mjs). */
function headerRow(item) {
  const row = document.createElement('div');
  row.className = 'header-row';
  const key = document.createElement('md-outlined-text-field');
  key.className = 'header-row__key';
  key.label = 'Name';
  key.value = item.name || '';
  key.spellcheck = false;
  key.addEventListener('input', () => { item.name = key.value.trim(); });
  const val = document.createElement('md-outlined-text-field');
  val.className = 'header-row__value';
  val.label = 'Value';
  val.value = item.value || '';
  val.spellcheck = false;
  val.addEventListener('input', () => { item.value = val.value; });
  const remove = document.createElement('md-text-button');
  remove.textContent = '删除';
  remove.addEventListener('click', () => {
    headerModel.items = headerModel.items.filter((entry) => entry !== item);
    row.remove();
  });
  row.append(key, val, remove);
  return row;
}

function rawLine(text) {
  const div = document.createElement('div');
  div.className = 'header-raw';
  div.textContent = text;
  return div;
}

function renderHeaderRows(text) {
  headerModel = SMSFWHeaders.parse(text);
  const container = $('headers-rows');
  container.textContent = '';
  for (const item of headerModel.items) {
    container.append(item.kind === 'entry' ? headerRow(item) : rawLine(item.text));
  }
}

function headersFromRows() {
  return SMSFWHeaders.serialize(headerModel);
}

function render() {
  const s = state;
  $('subtitle').textContent = `模块 ${s.module_version} · 载荷 ${s.payload_version}`;

  $('state-title').textContent = s.enabled
    ? (s.daemon_running ? '转发中' : '已启用（守护进程未运行）')
    : '已停用';
  $('state-detail').textContent = s.webhook
    ? `${s.method} ${s.webhook}`
    : '尚未配置推送地址';
  if (!s.enabled) chip('已停用', 'off');
  else if (!s.daemon_running) chip('守护进程未运行', 'error');
  else if (!s.tested) chip('未测试', 'error');
  else chip('运行中', '');

  setToggle($('enabled-toggle'), !!s.enabled);

  const grid = $('stat-grid');
  grid.textContent = '';
  grid.append(
    stat('配置状态', s.tested ? '已测试通过' : (s.webhook ? '待测试' : '未配置')),
    stat('队列', `${s.queue_pending} 待发 / ${s.queue_failed} 失败`),
    stat('累计发送', s.counter_sent),
    stat('最后短信 ID', s.last_sms_id),
    stat('模板', s.template_exists ? '已配置' : '默认参数'),
    stat('密钥签名', s.secret_set ? '已启用' : '未启用'),
    stat('设备', s.device),
  );

  $('f-url').value = s.webhook || '';
  $('f-method').value = s.method || 'POST';
  $('f-response').value = s.response_match || '';
  $('f-secret').value = '';
  $('secret-hint').textContent = s.secret_set ? '已设置密钥；留空保持不变，点击“清除密钥”可移除' : '留空表示不启用签名';
  $('f-sender-allow').value = s.filter_sender_allow || '';
  $('f-body-allow').value = s.filter_body_allow || '';
  $('f-sender-block').value = s.filter_sender_block || '';
  $('f-body-block').value = s.filter_body_block || '';
  $('f-poll').value = s.poll_interval;
  $('f-timeout').value = s.timeout;
  $('f-retries').value = s.retries;
  $('f-retry-delay').value = s.retry_delay;
  $('f-db-check').value = s.db_check;
  const clearSecret = $('btn-clear-secret');
  clearSecret.hidden = !s.secret_set;
  clearSecret.textContent = '清除密钥';
  secretClearArmedUntil = 0;
  $('f-device').value = s.device || '';
  $('f-template').value = templateText;
  renderHeaderRows(headersText);
}

async function refresh() {
  loadedOk = false;
  try {
    const res = await smsfw('status --json');
    state = JSON.parse(res.out);
    const tmpl = await smsfw('template cat --base64');
    templateText = decodeBase64Utf8(tmpl.out);
    const hdrs = await smsfw('headers cat --base64');
    headersText = decodeBase64Utf8(hdrs.out);
    render();
    loadedOk = true;
  } catch (error) {
    fail(error);
  }
}
async function setKeys(fields) {
  const command = fields
    .map(([key, value]) => `${BIN} set ${key} ${shellQuote(value)}`)
    .join(' && ');
  await smsfw(command.slice(BIN.length + 1));
}

/* ------------------------------------------------------------------- save */

async function putContent(kind, text) {
  await smsfw(`${kind} put ${shellQuote(text)}`);
}

async function save() {
  if (!loadedOk) {
    fail(new Error('配置尚未完整加载，未保存任何更改'));
    return;
  }
  const button = $('btn-save');
  setBusy(button, true);
  try {
    const fields = [
      ['SMSFW_WEBHOOK_URL', $('f-url').value.trim()],
      ['SMSFW_METHOD', $('f-method').value],
      ['SMSFW_RESPONSE_MATCH', $('f-response').value.trim()],
      ['SMSFW_FILTER_SENDER_ALLOW', $('f-sender-allow').value.trim()],
      ['SMSFW_FILTER_SENDER_BLOCK', $('f-sender-block').value.trim()],
      ['SMSFW_FILTER_BODY_ALLOW', $('f-body-allow').value.trim()],
      ['SMSFW_FILTER_BODY_BLOCK', $('f-body-block').value.trim()],
      ['SMSFW_POLL_INTERVAL', $('f-poll').value.trim() || '5'],
      ['SMSFW_TIMEOUT', $('f-timeout').value.trim() || '15'],
      ['SMSFW_RETRIES', $('f-retries').value.trim() || '0'],
      ['SMSFW_RETRY_DELAY', $('f-retry-delay').value.trim() || '5'],
      ['SMSFW_DB_FULL_CHECK_INTERVAL', $('f-db-check').value.trim() || '60'],
      ['SMSFW_DEVICE_NAME', $('f-device').value.trim()],
    ];
    await setKeys(fields);

    if ($('f-template').value !== templateText) {
      await putContent('template', $('f-template').value);
      templateText = $('f-template').value;
    }
    const headersNow = headersFromRows();
    if (headersNow !== headersText) {
      await putContent('headers', headersNow);
      headersText = headersNow;
    }
    if ($('f-secret').value) {
      await putContent('secret', $('f-secret').value);
    }

    toast('配置已保存');
    await refresh();
  } catch (error) {
    fail(error);
    toast('保存失败', true);
  } finally {
    setBusy(button, false);
  }
}

/* ---------------------------------------------------------------- actions */

async function runAction(button, args, title) {
  setBusy(button, true);
  try {
    const res = await smsfw(args);
    showOutput(title, [res.out, res.err].filter(Boolean).join('\n').trim());
    toast(`${title}完成`);
    await refresh();
  } catch (error) {
    fail(error);
    toast(`${title}失败`, true);
  } finally {
    setBusy(button, false);
  }
}

function bind() {
  $('refresh').addEventListener('click', refresh);
  $('btn-add-header').addEventListener('click', () => {
    const item = { kind: 'entry', name: '', value: '', sep: ' ' };
    headerModel.items.push(item);
    $('headers-rows').append(headerRow(item));
  });
  $('btn-clear-secret').addEventListener('click', async () => {
    const button = $('btn-clear-secret');
    const now = Date.now();
    if (now > secretClearArmedUntil) {
      secretClearArmedUntil = now + 5000;
      button.textContent = '再次点击确认';
      setTimeout(() => {
        if (Date.now() >= secretClearArmedUntil && !button.disabled) {
          button.textContent = '清除密钥';
        }
      }, 5100);
      return;
    }
    await runAction(button, 'secret clear', '清除密钥');
  });
  $('btn-save').addEventListener('click', save);
  $('btn-test').addEventListener('click', () => runAction($('btn-test'), 'test', '测试推送'));
  $('btn-preview').addEventListener('click', () => runAction($('btn-preview'), 'preview', '预览请求'));
  $('btn-poll').addEventListener('click', () => runAction($('btn-poll'), 'poll', '立即轮询'));
  $('btn-flush').addEventListener('click', () => runAction($('btn-flush'), 'flush', '重试队列'));
  $('btn-log').addEventListener('click', () => runAction($('btn-log'), 'log -n 200', '日志'));
  $('btn-restart').addEventListener('click', () => runAction($('btn-restart'), 'restart', '重启守护进程'));
  $('btn-clear-output').addEventListener('click', () => { $('output-card').hidden = true; });

  $('enabled-toggle').addEventListener('change', async (event) => {
    const on = toggleValue(event.target);
    try {
      await smsfw(on ? 'on' : 'off');
      toast(on ? '已启用转发' : '已停用转发');
      await refresh();
    } catch (error) {
      setToggle(event.target, !on);
      fail(error);
    }
  });
}

waitForBridge().then((found) => {
  if (!found) {
    $('bridge-warning').hidden = false;
    return;
  }
  bind();
  refresh();
});
