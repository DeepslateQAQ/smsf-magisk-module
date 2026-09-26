package com.smsfw;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.Map;

import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSession;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/** Blocking HTTP sender with retry and redirect handling. */
final class Http {
    private static final int MAX_REDIRECTS = 5;
    private static final int MAX_BODY = 256 * 1024;
    private static final HostnameVerifier ALLOW_ALL_HOSTNAMES = new HostnameVerifier() {
        public boolean verify(String hostname, SSLSession session) {
            return true;
        }
    };
    private static SSLContext insecureContext;

    static final class Result {
        final int status;
        final String body;
        final String finalUrl;

        Result(int status, String body, String finalUrl) {
            this.status = status;
            this.body = body;
            this.finalUrl = finalUrl;
        }

        boolean isSuccess() {
            return status >= 200 && status < 400;
        }
    }

    static final class Failure extends IOException {
        final boolean network;

        Failure(String message, boolean network) {
            super(message);
            this.network = network;
        }
    }

    static Result send(String url, String method, Map<String, String> headers, byte[] body,
                       int timeoutSec, int retries, int retryDelaySec, boolean insecure) throws IOException {
        int attempts = Math.max(1, retries + 1);
        Failure last = null;
        for (int attempt = 1; attempt <= attempts; attempt++) {
            try {
                Result result = once(url, method, headers, body, timeoutSec, insecure);
                boolean retryable = result.status == 429 || result.status >= 500;
                if (!retryable) {
                    return result;
                }
                last = new Failure("HTTP " + result.status + " (retryable)", false);
                Log.w("attempt " + attempt + "/" + attempts + " -> HTTP " + result.status + ", retrying");
            } catch (Failure f) {
                last = f;
                Log.w("attempt " + attempt + "/" + attempts + " failed: " + f.getMessage());
            }
            if (attempt < attempts) {
                sleep(Math.max(1, retryDelaySec) * attempt * 1000L);
            }
        }
        throw last != null ? last : new Failure("request failed", true);
    }

    private static Result once(String url, String method, Map<String, String> headers, byte[] body,
                               int timeoutSec, boolean insecure) throws Failure {
        int timeoutMs = Math.max(1, timeoutSec) * 1000;
        String currentUrl = url;
        String currentMethod = method;
        byte[] currentBody = body;
        Map<String, String> currentHeaders = headers;
        for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
            HttpURLConnection conn = null;
            try {
                URL target = new URL(currentUrl);
                conn = (HttpURLConnection) target.openConnection();
                if (insecure && conn instanceof HttpsURLConnection) {
                    HttpsURLConnection https = (HttpsURLConnection) conn;
                    SSLContext context = insecureContext();
                    https.setSSLSocketFactory(context.getSocketFactory());
                    https.setHostnameVerifier(ALLOW_ALL_HOSTNAMES);
                }
                conn.setRequestMethod(currentMethod);
                conn.setConnectTimeout(timeoutMs);
                conn.setReadTimeout(timeoutMs);
                conn.setInstanceFollowRedirects(false);
                conn.setUseCaches(false);
                for (Map.Entry<String, String> e : currentHeaders.entrySet()) {
                    try {
                        conn.setRequestProperty(e.getKey(), e.getValue());
                    } catch (RuntimeException rex) {
                        throw new Failure("invalid header " + e.getKey() + ": " + rex.getMessage(), false);
                    }
                }
                if (currentBody != null && currentBody.length > 0 && !"GET".equals(currentMethod)
                        && !"HEAD".equals(currentMethod)) {
                    conn.setDoOutput(true);
                    OutputStream out = conn.getOutputStream();
                    try {
                        out.write(currentBody);
                        out.flush();
                    } finally {
                        Util.close(out);
                    }
                }
                int code = conn.getResponseCode();
                if (code >= 300 && code < 400 && hop < MAX_REDIRECTS) {
                    String location = conn.getHeaderField("Location");
                    if (location != null && !location.isEmpty()) {
                        String nextUrl = new URL(new URL(currentUrl), location).toString();
                        if (!sameOrigin(currentUrl, nextUrl)) {
                            currentHeaders = headersForCrossOriginRedirect(headers);
                        }
                        currentUrl = nextUrl;
                        if (code == 301 || code == 302 || code == 303) {
                            currentMethod = "GET";
                            currentBody = null;
                        }
                        Log.d("redirect " + code + " -> " + currentUrl);
                        continue;
                    }
                }
                String text = readBody(conn, code);
                return new Result(code, text, currentUrl);
            } catch (Failure e) {
                throw e;
            } catch (IOException e) {
                throw new Failure(e.getClass().getSimpleName() + ": " + e.getMessage(), true);
            } finally {
                if (conn != null) {
                    conn.disconnect();
                }
            }
        }
        throw new Failure("too many redirects", false);
    }

    private static String readBody(HttpURLConnection conn, int code) throws Failure {
        InputStream in = null;
        try {
            in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            if (in == null) {
                return "";
            }
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
                if (out.size() > MAX_BODY) {
                    break;
                }
            }
            return new String(out.toByteArray(), Util.UTF8);
        } catch (IOException e) {
            throw new Failure("cannot read response body: " + e.getMessage(), true);
        } finally {
            Util.close(in);
        }
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
    private static boolean sameOrigin(String first, String second) throws IOException {
        URL a = new URL(first);
        URL b = new URL(second);
        int aPort = a.getPort() >= 0 ? a.getPort() : a.getDefaultPort();
        int bPort = b.getPort() >= 0 ? b.getPort() : b.getDefaultPort();
        return a.getProtocol().equalsIgnoreCase(b.getProtocol())
                && a.getHost().equalsIgnoreCase(b.getHost()) && aPort == bPort;
    }
    private static Map<String, String> headersForCrossOriginRedirect(Map<String, String> headers) {
        Map<String, String> copy = new java.util.LinkedHashMap<String, String>();
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            if (isSafeRedirectHeader(entry.getKey())) {
                copy.put(entry.getKey(), entry.getValue());
            }
        }
        return copy;
    }

    private static boolean isSafeRedirectHeader(String name) {
        return name.equalsIgnoreCase("Content-Type")
                || name.equalsIgnoreCase("Accept")
                || name.equalsIgnoreCase("User-Agent");
    }


    private static synchronized SSLContext insecureContext() throws Failure {
        if (insecureContext != null) {
            return insecureContext;
        }
        try {
            final TrustManager[] trust = new TrustManager[]{new X509TrustManager() {
                public void checkClientTrusted(X509Certificate[] chain, String authType) {
                }

                public void checkServerTrusted(X509Certificate[] chain, String authType) {
                }

                public X509Certificate[] getAcceptedIssuers() {
                    return new X509Certificate[0];
                }
            }};
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, trust, new SecureRandom());
            insecureContext = context;
            return context;
        } catch (Exception e) {
            throw new Failure("cannot install insecure TLS context: " + e, false);
        }
    }


    private Http() {
    }

}
