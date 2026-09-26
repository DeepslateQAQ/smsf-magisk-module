package com.smsfw;

import java.io.File;
import java.io.FilenameFilter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * On-device HTTP sender for the SMS webhook Magisk module.
 *
 * Runs on Android through app_process (same mechanism as /system/bin/am and /system/bin/content)
 * and on a desktop JVM for tests, because it only uses java.* APIs.
 */
public final class Main {
    static final String VERSION = "1.0.0";

    private static final String DEFAULT_UA = "smsfw/" + VERSION;

    static final class UsageException extends Exception {
        UsageException(String message) {
            super(message);
        }
    }

    public static void main(String[] args) {
        try {
            if (args.length == 0) {
                usage();
                System.exit(2);
            }
            Map<String, String> opt = parseOptions(args, 1);
            Log.verbose = opt.containsKey("verbose");
            String cmd = args[0];
            int rc;
            if ("send".equals(cmd)) {
                rc = cmdSend(opt);
            } else if ("render".equals(cmd)) {
                rc = cmdRender(opt);
            } else if ("sign".equals(cmd)) {
                rc = cmdSign(opt);
            } else if ("version".equals(cmd) || "--version".equals(cmd) || "-v".equals(cmd)) {
                System.out.println(VERSION);
                rc = 0;
            } else {
                usage();
                rc = 2;
            }
            System.exit(rc);
        } catch (UsageException u) {
            System.err.println("usage error: " + u.getMessage());
            System.exit(2);
        } catch (Throwable t) {
            Log.e("fatal: " + t);
            t.printStackTrace(System.err);
            System.exit(3);
        }
    }

    // ---------------------------------------------------------------- commands

    private static int cmdSend(Map<String, String> opt) throws Exception {
        Request req = buildRequest(opt);
        Log.i("sending " + req.method + " " + req.url + " (" + req.body.length + " bytes, mode="
                + req.mode + (req.secret != null ? ", signed" : "") + ")");
        long started = System.currentTimeMillis();
        Http.Result result;
        try {
            result = Http.send(req.url, req.method, req.headers, req.body,
                    req.timeoutSec, req.retries, req.retryDelaySec, req.insecure);
        } catch (Http.Failure f) {
            Log.e("send failed: " + f.getMessage());
            writeResponse(opt, "status=0\nnetwork=" + (f.network ? "1" : "0") + "\nmessage=" + f.getMessage() + "\nurl=" + req.url + "\n");
            return f.network ? 11 : 10;
        }
        long took = System.currentTimeMillis() - started;
        String summary = "HTTP " + result.status + " in " + took + "ms";
        String body = result.body == null ? "" : result.body;
        if (result.isSuccess() && (req.expected == null || req.expected.isEmpty() || body.contains(req.expected))) {
            Log.i(summary + " OK");
            Log.d("response: " + preview(body));
            writeResponse(opt, "status=" + result.status + "\nurl=" + result.finalUrl + "\n" + body);
            return 0;
        }
        Log.w(summary + " FAILED (body: " + preview(body) + ")");
        writeResponse(opt, "status=" + result.status + "\nurl=" + result.finalUrl + "\n" + body);
        return 10;
    }

    private static int cmdRender(Map<String, String> opt) throws Exception {
        Request req = buildRequest(opt);
        String target = firstNonEmpty(opt.get("target"), "body");
        System.out.println("url".equals(target) ? req.url : new String(req.body, Util.UTF8));
        return 0;
    }

    private static int cmdSign(Map<String, String> opt) throws Exception {
        String secret = readSecret(opt);
        if (secret == null) {
            throw new UsageException("--secret-file is required for sign");
        }
        long ts = timestamp(opt);
        System.out.println(Signer.sign(secret, ts));
        return 0;
    }

    // ---------------------------------------------------------------- request

    static final class Request {
        String url;
        String method;
        Map<String, String> headers;
        byte[] body;
        String mode;
        String secret;
        int timeoutSec;
        int retries;
        int retryDelaySec;
        boolean insecure;
        String expected;
    }

    private static Request buildRequest(Map<String, String> opt) throws Exception {
        Request req = new Request();
        String urlFile = require(opt, "url-file");
        String url = Util.chomp(Util.readFile(new File(urlFile))).trim();
        if (Util.isBlank(url)) {
            throw new UsageException("webhook url is empty: " + urlFile);
        }
        req.method = firstNonEmpty(opt.get("method"), "POST").toUpperCase(Locale.US);
        if (!"GET".equals(req.method) && !"POST".equals(req.method)
                && !"PUT".equals(req.method) && !"PATCH".equals(req.method)) {
            throw new UsageException("unsupported method: " + req.method);
        }
        req.timeoutSec = intOpt(opt, "timeout", 15);
        req.retries = intOpt(opt, "retries", 2);
        req.retryDelaySec = intOpt(opt, "retry-delay", 5);
        req.insecure = opt.containsKey("insecure");
        req.expected = opt.get("response-match");
        req.secret = readSecret(opt);

        String rawTemplate = readOptional(opt.get("template-file"));

        Map<String, String> headers = parseHeaders(readOptional(opt.get("headers-file")));
        String contentType = headerValue(headers, "Content-Type");
        String mode = firstNonEmpty(opt.get("escape"), "auto").toLowerCase(Locale.US);

        if ("auto".equals(mode)) {
            if (contentType != null && contentType.toLowerCase(Locale.US).contains("json")) {
                mode = Template.MODE_JSON;
            } else if (contentType != null && contentType.toLowerCase(Locale.US).startsWith("text/")) {
                mode = Template.MODE_RAW;
            } else {
                String t = rawTemplate == null ? "" : rawTemplate.trim();
                if (t.startsWith("{") || t.startsWith("[")) {
                    mode = Template.MODE_JSON;
                } else {
                    mode = Template.MODE_URL;
                }
            }
        }
        req.mode = mode;

        long now = timestamp(opt);
        Template values = loadValues(opt, now, req.secret);

        String rendered = rawTemplate == null ? "" : values.render(rawTemplate, mode, now);
        if (rawTemplate == null || rawTemplate.trim().isEmpty()) {
            rendered = defaultParams(values, req.secret == null ? null : values.get("SIGN"));
        }

        String userInfo = null;
        int schemeEnd = url.indexOf("://");
        if (schemeEnd > 0) {
            int at = url.indexOf('@', schemeEnd + 3);
            int slash = url.indexOf('/', schemeEnd + 3);
            if (at > 0 && (slash < 0 || at < slash)) {
                userInfo = url.substring(schemeEnd + 3, at);
                url = url.substring(0, schemeEnd + 3) + url.substring(at + 1);
                Log.d("http basic auth detected for user " + userInfo.split(":", 2)[0]);
            }
        }
        if (userInfo != null && headerValue(headers, "Authorization") == null) {
            headers.put("Authorization", "Basic " + Util.base64(userInfo.getBytes(Util.UTF8)));
        }
        if (headerValue(headers, "User-Agent") == null) {
            headers.put("User-Agent", DEFAULT_UA);
        }

        if ("GET".equals(req.method) || "HEAD".equals(req.method)) {
            if (rawTemplate == null || rawTemplate.trim().isEmpty()) {
                req.url = appendQuery(url, rendered);
            } else {
                req.url = appendQuery(url, rendered);
            }
            req.body = new byte[0];
        } else {
            req.body = rendered.getBytes(Util.UTF8);
            if (contentType == null) {
                if (Template.MODE_JSON.equals(mode)) {
                    headers.put("Content-Type", "application/json; charset=utf-8");
                } else if (Template.MODE_RAW.equals(mode)) {
                    headers.put("Content-Type", "text/plain; charset=utf-8");
                } else {
                    headers.put("Content-Type", "application/x-www-form-urlencoded; charset=utf-8");
                }
            }
            req.url = url;
        }
        req.headers = headers;
        return req;
    }

    /** SMSForwarder default when no template is configured: from=..&content=..&timestamp=.. */
    private static String defaultParams(Template values, String sign) {
        StringBuilder sb = new StringBuilder();
        sb.append("from=").append(Template.escape(values.value("FROM"), Template.MODE_URL));
        sb.append("&content=").append(Template.escape(values.value("SMS"), Template.MODE_URL));
        sb.append("&timestamp=").append(Template.escape(values.value("TIMESTAMP"), Template.MODE_URL));
        if (sign != null && !sign.isEmpty()) {
            sb.append("&sign=").append(sign);
        }
        return sb.toString();
    }

    private static String appendQuery(String url, String query) {
        if (query == null || query.isEmpty()) {
            return url;
        }
        if (query.startsWith("/") || query.startsWith("?")) {
            return url + query;
        }
        return url + (url.contains("?") ? "&" : "?") + query;
    }

    // ---------------------------------------------------------------- values

    private static Template loadValues(Map<String, String> opt, long now, String secret) throws Exception {
        Template t = new Template();
        String dir = opt.get("values-dir");
        if (dir != null) {
            File d = new File(dir);
            if (!d.isDirectory()) {
                throw new UsageException("values dir not found: " + dir);
            }
            File[] files = d.listFiles(new FilenameFilter() {
                public boolean accept(File f, String name) {
                    return !name.startsWith(".");
                }
            });
            if (files != null) {
                Arrays.sort(files);
                for (File f : files) {
                    if (f.isFile()) {
                        t.put(f.getName(), Util.chomp(Util.readFile(f)));
                    }
                }
            }
        }
        // SMSForwarder aliases
        alias(t, "MSG", "SMS");
        alias(t, "CONTENT", "SMS");
        alias(t, "ORG_CONTENT", "SMS");
        alias(t, "TITLE", "CARD_SLOT");
        alias(t, "DEVICE_MARK", "DEVICE_NAME");
        alias(t, "SUBSCRIPTION_ID", "CARD_SUBID");
        alias(t, "PACKAGE_NAME", "FROM");
        // The shell supplies RECEIVE_TIME_MS; the template layer formats RECEIVE_TIME.
        if (t.get("RECEIVE_TIME") == null && !Util.isBlank(t.get("RECEIVE_TIME_MS"))) {
            t.put("RECEIVE_TIME", t.get("RECEIVE_TIME_MS"));
        }
        t.put("TIMESTAMP", Long.toString(now));
        t.put("CURRENT_TIME", Long.toString(now));
        if (secret != null) {
            t.put("SIGN", Signer.sign(secret, now));
        }
        return t;
    }

    private static void alias(Template t, String from, String to) {
        String v = t.get(to);
        if (v != null && t.get(from) == null) {
            t.put(from, v);
        }
    }

    private static long timestamp(Map<String, String> opt) throws UsageException {
        String s = opt.get("timestamp-ms");
        if (s == null) {
            return System.currentTimeMillis();
        }
        try {
            return Long.parseLong(s.trim());
        } catch (NumberFormatException e) {
            throw new UsageException("invalid --timestamp-ms: " + s);
        }
    }

    private static String readSecret(Map<String, String> opt) throws Exception {
        String f = opt.get("secret-file");
        if (f == null) {
            return null;
        }
        File file = new File(f);
        if (!file.isFile()) {
            return null;
        }
        String secret = Util.chomp(Util.readFile(file));
        return secret.isEmpty() ? null : secret;
    }

    private static String readOptional(String path) throws Exception {
        if (path == null) {
            return null;
        }
        File f = new File(path);
        if (!f.isFile()) {
            return null;
        }
        return Util.readFile(f);
    }

    static Map<String, String> parseHeaders(String text) throws UsageException {
        Map<String, String> headers = new LinkedHashMap<String, String>();
        if (text == null) {
            return headers;
        }
        for (String line : text.split("\\r?\\n")) {
            String s = line.trim();
            if (s.isEmpty() || s.startsWith("#")) {
                continue;
            }
            int colon = s.indexOf(':');
            if (colon <= 0 || s.substring(0, colon).trim().isEmpty()) {
                throw new UsageException("invalid header line: " + line);
            }
            String name = s.substring(0, colon).trim();
            String value = s.substring(colon + 1).trim();
            if (value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0) {
                throw new UsageException("invalid header value: " + name);
            }
            headers.put(name, value);
        }
        return headers;
    }

    static String headerValue(Map<String, String> headers, String name) {
        for (Map.Entry<String, String> e : headers.entrySet()) {
            if (e.getKey().equalsIgnoreCase(name)) {
                return e.getValue();
            }
        }
        return null;
    }

    private static void writeResponse(Map<String, String> opt, String text) {
        String path = opt.get("response-file");
        if (path == null) {
            return;
        }
        try {
            Util.writeFile(new File(path), text.getBytes(Util.UTF8));
        } catch (Exception e) {
            Log.w("cannot write response file " + path + ": " + e.getMessage());
        }
    }

    private static String preview(String s) {
        if (s == null) {
            return "";
        }
        String one = s.replace("\n", "\\n").replace("\r", "");
        return one.length() > 200 ? one.substring(0, 200) + "..." : one;
    }

    // ---------------------------------------------------------------- options

    static Map<String, String> parseOptions(String[] args, int from) throws UsageException {
        Map<String, String> map = new HashMap<String, String>();
        for (int i = from; i < args.length; i++) {
            String a = args[i];
            if (!a.startsWith("--")) {
                throw new UsageException("unexpected argument: " + a);
            }
            String key = a.substring(2);
            String value = null;
            int eq = key.indexOf('=');
            if (eq >= 0) {
                value = key.substring(eq + 1);
                key = key.substring(0, eq);
            }
            if (value == null) {
                if (i + 1 < args.length && !args[i + 1].startsWith("--")) {
                    value = args[++i];
                } else {
                    value = "1";
                }
            }
            map.put(key, value);
        }
        return map;
    }


    private static String require(Map<String, String> opt, String key) throws UsageException {
        String v = opt.get(key);
        if (v == null || v.isEmpty()) {
            throw new UsageException("--" + key + " is required");
        }
        return v;
    }

    private static int intOpt(Map<String, String> opt, String key, int def) throws UsageException {
        String v = opt.get(key);
        if (v == null) {
            return def;
        }
        try {
            int value = Integer.parseInt(v.trim());
            if ("timeout".equals(key) && value < 1) {
                throw new UsageException("--timeout must be at least 1");
            }
            if (("retries".equals(key) || "retry-delay".equals(key)) && value < 0) {
                throw new UsageException("--" + key + " must not be negative");
            }
            return value;
        } catch (NumberFormatException e) {
            throw new UsageException("invalid --" + key + ": " + v);
        }
    }

    private static String firstNonEmpty(String a, String b) {
        return Util.isBlank(a) ? b : a;
    }

    private static void usage() {
        List<String> lines = new ArrayList<String>();
        lines.add("smsfw-http " + VERSION);
        lines.add("usage:");
        lines.add("  send   --url-file F --method GET|POST|PUT|PATCH --values-dir D");
        lines.add("         [--template-file F] [--headers-file F] [--escape json|url|raw|auto]");
        lines.add("         [--secret-file F] [--timestamp-ms N] [--timeout S] [--retries N]");
        lines.add("         [--retry-delay S] [--insecure] [--response-file F]");
        lines.add("         [--response-match STR] [--verbose]");
        lines.add("  render --url-file F --values-dir D [--template-file F] [--target body|url]");
        lines.add("  sign   --secret-file F [--timestamp-ms N]");
        lines.add("  version");
        for (String l : lines) {
            System.err.println(l);
        }
    }

    private Main() {
    }
}
