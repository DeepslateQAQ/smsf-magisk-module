#!/usr/bin/env python3
"""Consistency checks for the WebUI assets.

These are the failure modes that produce a silently dead page rather than an
error: an id renamed in the markup but still queried by app.js, a component used
without being in the vendored bundle, a stylesheet referencing a colour token
that tokens.css does not define, or a referenced file that is not there.
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEBROOT = os.environ.get("SMSF_WEBROOT", str(ROOT / "payload" / "webroot"))
problems = []


def read(path):
    with open(os.path.join(WEBROOT, path), encoding="utf-8") as fh:
        return fh.read()


html = read("index.html")
app = read("app.js")
css = read("style.css")
tokens = read("tokens.css")

# 1. every id app.js queries must exist in the markup
ids_in_html = set(re.findall(r'id="([^"]+)"', html))
ids_queried = set(re.findall(r"""\$\(['"]([^'"]+)['"]\)""", app))
ids_queried |= set(re.findall(r"""getElementById\(['"]([^'"]+)['"]\)""", app))
for missing in sorted(ids_queried - ids_in_html):
    problems.append("app.js queries #%s but index.html has no such id" % missing)

# 2. every md-* element used must be defined by the vendored bundle
bundle_path = os.path.join(WEBROOT, "vendor", "material-web.min.js")
if not os.path.exists(bundle_path):
    problems.append("vendor/material-web.min.js is missing (run tools/webui/build.sh)")
else:
    bundle = open(bundle_path, encoding="utf-8", errors="replace").read()
    used = set(re.findall(r'<(md-[a-z0-9-]+)', html))
    for tag in sorted(used):
        if tag not in bundle:
            problems.append("index.html uses <%s> but the vendored bundle does not define it" % tag)
    if len(bundle) < 50_000:
        problems.append("vendor bundle looks truncated (%d bytes)" % len(bundle))

# 3. referenced local assets must exist
for ref in re.findall(r'(?:src|href)="([^"]+)"', html):
    if "://" in ref:
        problems.append("index.html loads %s over the network; the WebUI must be offline" % ref)
    elif not os.path.exists(os.path.join(WEBROOT, ref)):
        problems.append("index.html references %s which does not exist" % ref)

# 4. colour tokens used by style.css must be defined by tokens.css
defined = set(re.findall(r'(--md-sys-color-[a-z0-9-]+)\s*:', tokens))
used = set(re.findall(r'var\((--md-sys-color-[a-z0-9-]+)', css))
for token in sorted(used - defined):
    problems.append("style.css uses var(%s) which tokens.css does not define" % token)
if "prefers-color-scheme: dark" not in tokens:
    problems.append("tokens.css has no dark scheme")

# 4b. every bare function call in app.js must be defined there: a swallowed helper
#     (e.g. a block edit that takes chip()/stat() with it) is a runtime error in a
#     WebView nobody can see, and neither a syntax check nor the id check notices.
js = re.sub(r"/\*.*?\*/", "", app, flags=re.S)
js = re.sub(r"(?m)//.*$", "", js)
js_defined = set(re.findall(r"function\s+([A-Za-z_$][\w$]*)\s*\(", js))
js_defined |= set(re.findall(r"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function|\()", js))
js_called = set(re.findall(r"(?<![.\w$])([A-Za-z_$][\w$]*)\s*\(", js))
KEYWORDS = {"if", "for", "while", "switch", "catch", "return", "typeof", "function", "new", "else",
            "do", "async", "await", "yield", "delete", "void", "in", "of", "instanceof", "var"}
GLOBALS = {"Math", "JSON", "Object", "Array", "String", "Number", "Boolean", "Promise", "Date", "Error",
           "RegExp", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "fetch", "parseInt",
           "parseFloat", "isNaN", "encodeURIComponent", "decodeURIComponent", "console", "btoa", "atob",
           "requestAnimationFrame", "Set", "Map", "resolve", "reject"}
for name in sorted(js_called - js_defined - KEYWORDS - GLOBALS):
    problems.append("app.js calls %s() but never defines it" % name)

# 5. the components resolve colours as var(--md-sys-color-x, #6750a4): a role we
#    never define falls back to the Material baseline purple with no error.
if os.path.exists(bundle_path):
    needed = {"--md-sys-color-" + role
              for role in re.findall(r"var\(--md-sys-color-([a-z0-9-]+)", bundle)}
    for role in sorted(needed - defined):
        problems.append("components need %s but tokens.css does not define it" % role)

# 6. the components must not be styled with literal colours in app.js
for literal in re.findall(r'#[0-9a-fA-F]{3,8}\b', app):
    problems.append("app.js hardcodes the colour %s; use a token instead" % literal)

if problems:
    for problem in problems:
        print("webui: " + problem)
    sys.exit(1)
print("webui ok: %d ids, %d components, %d colour tokens"
      % (len(ids_queried), len(set(re.findall(r'<(md-[a-z0-9-]+)', html))), len(used)))
