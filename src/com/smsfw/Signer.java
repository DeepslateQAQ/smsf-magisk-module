package com.smsfw;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * SMSForwarder compatible signature:
 *   sign = URLEncoder(Base64(HMAC_SHA256(key=secret, data="{timestamp}\n{secret}")))
 */
final class Signer {
    static String sign(String secret, long timestampMs) throws Exception {
        String payload = timestampMs + "\n" + secret;
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(secret.getBytes(Util.UTF8), "HmacSHA256"));
        return Util.urlEncode(Util.base64(mac.doFinal(payload.getBytes(Util.UTF8))));
    }

    private Signer() {
    }
}
