#!/usr/bin/env bash
# build.sh - build the DEX payload and the installable Magisk module zip.
#
#   ./build.sh              payload + module zip into dist/
#   ./build.sh payload      only rebuild payload/lib/smsfw.jar
#   ./build.sh test         build payload, then run the desktop payload tests
#   ./build.sh clean        remove build outputs
#
# Toolchain: a JDK (javac/java) and d8. d8 is looked up in PATH first, then
# R8 is downloaded to .tools/ and verified against the checksum below.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
R8_VERSION=9.4.24
R8_URL="https://dl.google.com/dl/android/maven2/com/android/tools/r8/${R8_VERSION}/r8-${R8_VERSION}.jar"
R8_SHA256=6efd9dacb08001f342d95482ecc15a7b69c634bc261aeb88bbc8e6cd5837f212

BUILD="$ROOT/build"
CLASSES="$BUILD/classes"
DEXDIR="$BUILD/dex"
TOOLS="$ROOT/.tools"
R8_JAR="$TOOLS/r8-${R8_VERSION}.jar"
PAYLOAD_JAR="$ROOT/payload/lib/smsfw.jar"
DIST="$ROOT/dist"
MIN_API=21

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_java() {
    command -v javac >/dev/null || die "javac not found (install a JDK, or run inside: nix-shell shell.nix)"
    command -v java >/dev/null || die "java not found (install a JDK, or run inside: nix-shell shell.nix)"
}

sha256_of() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

ensure_r8() {
    [ -f "$R8_JAR" ] || {
        log "downloading R8 ${R8_VERSION}"
        mkdir -p "$TOOLS"
        if command -v curl >/dev/null; then
            curl -sSL -o "$R8_JAR.part" "$R8_URL"
        elif command -v wget >/dev/null; then
            wget -q -O "$R8_JAR.part" "$R8_URL"
        else
            die "need curl or wget to fetch R8"
        fi
        mv "$R8_JAR.part" "$R8_JAR"
    }
    got=$(sha256_of "$R8_JAR")
    [ "$got" = "$R8_SHA256" ] || die "R8 checksum mismatch: $got"
}

run_d8() {
    if [ -n "${D8_BIN:-}" ]; then
        "$D8_BIN" "$@"
    elif command -v d8 >/dev/null; then
        d8 "$@"
    else
        ensure_r8
        java -cp "$R8_JAR" com.android.tools.r8.D8 "$@"
    fi
}

build_payload() {
    need_java
    log "compiling Java payload"
    rm -rf "$CLASSES" "$DEXDIR"
    mkdir -p "$CLASSES" "$DEXDIR"
    javac --release 8 -Xlint:-options -d "$CLASSES" "$ROOT"/src/com/smsfw/*.java
    log "dexing payload (min-api $MIN_API)"
    # shellcheck disable=SC2046
    run_d8 --min-api "$MIN_API" --output "$DEXDIR" $(find "$CLASSES" -name '*.class' | sort)
    log "packaging $PAYLOAD_JAR"
    mkdir -p "$(dirname "$PAYLOAD_JAR")"
    rm -f "$PAYLOAD_JAR"
    # Reproducible archive: fixed timestamps so re-building the same sources
    # yields the same jar hash.
    find "$CLASSES" "$DEXDIR" -exec touch -t 202001010000 {} + 2>/dev/null
    # classes.dex is what ART/app_process loads on device; the plain .class
    # entries are ignored by ART and let the exact same jar run on a desktop JVM
    # for tests (see tests/test_daemon.sh and the fake app_process).
    (cd "$DEXDIR" && zip -q -X "$PAYLOAD_JAR" classes.dex)
    # shellcheck disable=SC2046
    (cd "$CLASSES" && zip -q -X "$PAYLOAD_JAR" $(find . -name '*.class' | sort))
    log "payload $(du -h "$PAYLOAD_JAR" | cut -f1) sha256=$(sha256_of "$PAYLOAD_JAR")"
}

bump_version() {
    kind=${1:-patch}
    version=$(sed -n 's/^version=//p' "$ROOT/payload/module.prop" | head -n 1)
    version=${version#v}
    IFS=. read -r major minor patch <<EOF
$version
EOF
    case "$kind" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) die "usage: $0 bump [major|minor|patch]" ;;
    esac
    next="v${major}.${minor}.${patch}"
    code=$((major * 10000 + minor * 100 + patch))
    sed -i "s/^version=.*/version=$next/; s/^versionCode=.*/versionCode=$code/" "$ROOT/payload/module.prop"
    sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$next\"/; s/\"versionCode\": [0-9]*/\"versionCode\": $code/" "$ROOT/update.json"
    log "version bumped to $next ($code)"
}

build_zip() {
    [ -f "$PAYLOAD_JAR" ] || build_payload
    version=$(sed -n 's/^version=//p' "$ROOT/payload/module.prop" | head -n 1)
    out="$DIST/smsf_webhook-${version}.zip"
    log "packaging $out"
    mkdir -p "$DIST"
    rm -f "$out"
    (cd "$ROOT/payload" && zip -q -r -X "$out" . -x '.*' -x '*/.*')
    verify_zip "$out"
    log "module $(du -h "$out" | cut -f1) sha256=$(sha256_of "$out")"
}

# Magisk resolves module.prop at the archive root; a stray top-level directory
# (or ./ prefixes) only shows up at install time on device, so check here.
verify_zip() { # ZIP
    zip=$1
    if ! command -v unzip >/dev/null; then
        log "unzip not found, skipping archive layout check"
        return 0
    fi
    entries=$(unzip -Z1 "$zip")
    for want in module.prop bin/smsfwd bin/smsfw bin/common.sh bin/wizard.sh \
                bin/i18n.sh lib/smsfw.jar system/bin/smsfw \
                webroot/index.html webroot/style.css webroot/tokens.css webroot/app.js \
                   webroot/vendor/material-web.min.js webroot/vendor/NOTICE \
                config/config.conf config/template.json customize.sh service.sh \
                uninstall.sh action.sh; do
        if ! printf '%s\n' "$entries" | grep -qx "$want"; then
            die "module zip is missing '$want' (bad archive layout)"
        fi
    done
    if printf '%s\n' "$entries" | grep -q '^\./'; then
        die "module zip contains './' prefixed entries; Magisk needs module.prop at the root"
    fi
    for f in customize.sh service.sh action.sh uninstall.sh bin/smsfw bin/smsfwd bin/common.sh; do
        if unzip -Z1 "$zip" "$f" >/dev/null 2>&1; then :; else
            die "module zip entry '$f' unreadable"
        fi
    done
}

run_tests() {
    log "running payload tests"
    bash "$ROOT/tests/test_payload.sh"
    if [ -f "$ROOT/tests/test_daemon.sh" ]; then
        log "running daemon integration tests"
        bash "$ROOT/tests/test_daemon.sh"
    fi
    if [ -f "$ROOT/tests/test_install.sh" ]; then
        log "running installer tests"
        bash "$ROOT/tests/test_install.sh"
    fi
    if [ -f "$ROOT/tests/test_wizard.sh" ]; then
        log "running wizard tests"
        bash "$ROOT/tests/test_wizard.sh"
    fi
    if [ -f "$ROOT/tests/test_webui_headers.mjs" ] && command -v bun >/dev/null 2>&1; then
        log "running WebUI headers model tests"
        bun "$ROOT/tests/test_webui_headers.mjs"
    fi
    if [ -f "$ROOT/tests/check_webui.py" ]; then
        log "checking WebUI assets"
        python3 "$ROOT/tests/check_webui.py"
    fi
    if [ -f "$ROOT/tests/check_ports.py" ]; then
        log "checking harness port bands"
        python3 "$ROOT/tests/check_ports.py"
    fi
    if [ -f "$ROOT/tests/check_i18n.py" ]; then
        log "checking i18n keys"
        python3 "$ROOT/tests/check_i18n.py"
    fi
}

case "${1:-all}" in
    all)      build_payload; build_zip ;;
    payload)  build_payload ;;
    zip)      build_zip ;;
    test)     build_payload; run_tests ;;
    bump)     bump_version "${2:-patch}" ;;
    clean)    rm -rf "$BUILD" "$DIST"; log "cleaned build/ and dist/" ;;
    *)        die "usage: $0 [all|payload|zip|test|bump|clean]" ;;
esac
