package com.smsfw;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Renders SMSForwarder style webhook templates.
 *
 * Supported tag spellings (case insensitive):
 *   {{TAG}}            {{TAG:yyyy-MM-dd HH:mm:ss}}      (original SMSForwarder form)
 *   [tag]              [receive_time:HH:mm]             (lowercase webParams form)
 *
 * Escape modes:
 *   json - JSON string escaping (application/json bodies)
 *   url  - application/x-www-form-urlencoded / query string escaping
 *   raw  - no escaping (text/plain bodies)
 *
 * Unknown tags are left untouched, exactly like the original app.
 */
final class Template {
    static final String MODE_JSON = "json";
    static final String MODE_URL = "url";
    static final String MODE_RAW = "raw";

    static final String DEFAULT_TIME_FORMAT = "yyyy-MM-dd HH:mm:ss";
    static final String EPOCH_MS = "EPOCH_MS";

    private static final Pattern BRACE = Pattern.compile("\\{\\{\\s*([A-Za-z0-9_]+)\\s*(?::([^}]*))?\\}\\}");
    private static final Pattern BRACKET = Pattern.compile("\\[\\s*([A-Za-z0-9_]+)\\s*(?::([^\\[\\]]*))?\\s*\\]");

    private final Map<String, String> values = new HashMap<String, String>();

    void put(String tag, String value) {
        if (value != null) {
            values.put(tag.toUpperCase(Locale.US), value);
        }
    }

    String get(String tag) {
        return values.get(tag.toUpperCase(Locale.US));
    }

    /** Raw (unescaped) value of a tag, or "" when unknown. */
    String value(String tag) {
        String v = values.get(tag.toUpperCase(Locale.US));
        return v == null ? "" : v;
    }

    String render(String template, String mode, long nowMs) {
        // SMSForwarder expands md5(...) first, then substitutes the tags inside it
        // and finally embeds the hex into the body.
        String out = replaceMd5(template, nowMs);
        out = replace(BRACE, out, mode, nowMs);
        out = replace(BRACKET, out, mode, nowMs);
        return out;
    }

    private static final Pattern MD5_EXPR = Pattern.compile("md5\\((.*?)\\)");
    private static final Pattern MD5_SEPARATOR = Pattern.compile("'(.*?)'|\\+");

    /**
     * md5([from]+[content]+'salt') -> hex md5 of the concatenated tag values, with the
     * concatenation operators and the quotes around literals removed, exactly like
     * SMSForwarder's replaceMd5Template().
     */
    private String replaceMd5(String input, long nowMs) {
        Matcher m = MD5_EXPR.matcher(input);
        StringBuffer sb = new StringBuffer(input.length() + 32);
        while (m.find()) {
            // Substitute *within* the expression: quoted literals keep their text,
            // the + operators are dropped, everything else stays put (upstream
            // replaces each match instead of reassembling the string, which also
            // keeps the tags in place for the expansion below).
            StringBuffer flat = new StringBuffer();
            Matcher part = MD5_SEPARATOR.matcher(m.group(1));
            while (part.find()) {
                part.appendReplacement(flat, Matcher.quoteReplacement(part.group(1) == null ? "" : part.group(1)));
            }
            part.appendTail(flat);
            String expanded = replace(BRACKET, replace(BRACE, flat.toString(), MODE_RAW, nowMs), MODE_RAW, nowMs);
            m.appendReplacement(sb, Matcher.quoteReplacement(Util.md5Hex(expanded)));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    private String replace(Pattern pattern, String input, String mode, long nowMs) {
        Matcher m = pattern.matcher(input);
        StringBuffer sb = new StringBuffer(input.length() + 64);
        while (m.find()) {
            String tag = m.group(1).toUpperCase(Locale.US);
            String format = m.group(2);
            String raw = values.get(tag);
            String replacement;
            if (raw == null) {
                replacement = m.group(0);
            } else if ("SIGN".equals(tag)) {
                // Signer.sign() already returns the URL-encoded signature
                // (SMSForwarder does the same); only JSON-escape it for bodies.
                replacement = MODE_JSON.equals(mode) ? Json.escape(raw) : raw;
            } else {
                String value = raw;
                if (isTimeTag(tag)) {
                    // Bare {{RECEIVE_TIME}}/[receive_time] must use the default
                    // format, exactly like SMSForwarder's replaceTemplate.
                    String fmt = (format == null || format.isEmpty()) ? DEFAULT_TIME_FORMAT : format;
                    value = formatTime(raw, fmt, nowMs);
                }
                replacement = escape(value, mode);
            }
            m.appendReplacement(sb, Matcher.quoteReplacement(replacement));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    static boolean isTimeTag(String tag) {
        return "RECEIVE_TIME".equals(tag) || "CURRENT_TIME".equals(tag);
    }

    static String formatTime(String epochMs, String format, long fallbackNowMs) {
        long ms;
        try {
            ms = Long.parseLong(epochMs.trim());
        } catch (NumberFormatException e) {
            Log.w("bad epoch value for time tag: " + epochMs);
            ms = fallbackNowMs;
        }
        try {
            return new SimpleDateFormat(format, Locale.US).format(new Date(ms));
        } catch (IllegalArgumentException e) {
            Log.w("bad time format '" + format + "', using default");
            return new SimpleDateFormat(DEFAULT_TIME_FORMAT, Locale.US).format(new Date(ms));
        }
    }

    static String escape(String value, String mode) {
        if (MODE_JSON.equals(mode)) {
            return Json.escape(value);
        }
        if (MODE_URL.equals(mode)) {
            return Util.urlEncode(value);
        }
        return value;
    }
}
