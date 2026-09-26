#!/usr/bin/env bash
# Rebuilds the vendored WebUI assets (both are committed; nothing here runs at
# install time or on the device):
#   payload/webroot/vendor/material-web.min.js  Material Web components + Lit
#   payload/webroot/tokens.css                  Material 3 palette from a seed
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

bun install --frozen-lockfile
bun run gen-tokens.mjs
bun build --minify --target=browser entry.js \
    --outfile "$ROOT/payload/webroot/vendor/material-web.min.js"

python3 - "$ROOT" <<'PY'
import gzip, os, sys
root = sys.argv[1]
for rel in ("payload/webroot/vendor/material-web.min.js", "payload/webroot/tokens.css"):
    path = os.path.join(root, rel)
    raw = open(path, "rb").read()
    print("%-52s raw %6.1f KB  gzip %6.1f KB" % (rel, len(raw) / 1024, len(gzip.compress(raw)) / 1024))
PY
