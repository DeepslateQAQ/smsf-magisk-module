package com.smsfw;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/** Minimal stderr logger. The shell daemon redirects stderr into the module log. */
final class Log {
    static boolean verbose = false;

    static void d(String msg) {
        if (verbose) {
            print("D", msg);
        }
    }

    static void i(String msg) {
        print("I", msg);
    }

    static void w(String msg) {
        print("W", msg);
    }

    static void e(String msg) {
        print("E", msg);
    }

    private static void print(String level, String msg) {
        String ts = new SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(new Date());
        System.err.println(ts + " " + level + " smsfw-http: " + msg);
    }

    private Log() {
    }
}
