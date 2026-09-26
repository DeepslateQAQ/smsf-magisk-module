#!/usr/bin/env python3
"""Fail if a message key used by the scripts is missing from the catalog.

`msg()` falls back to printing the raw key when a lookup fails, which turns a
typo into user-visible garbage (the "HELP" bug). This check makes that class of
mistake impossible to merge.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "payload/bin/i18n.sh"
SCRIPTS = ["common.sh", "smsfwd", "smsfw", "wizard.sh"]
HELPERS = ("msg", "gh_ok", "gh_err", "gh_warn", "gh_info",
           "log_info", "log_warn", "log_error", "log_debug")

catalog = CATALOG.read_text(encoding="utf-8")
defined = set(re.findall(r"^(MSG_(?:zh|en)_[A-Z0-9_]+)=", catalog, re.M))

source_lines = []
for name in SCRIPTS:
    for line in (ROOT / "payload/bin" / name).read_text(encoding="utf-8").splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        source_lines.append(line)
source = "\n".join(source_lines)
pattern = re.compile(r"\b(?:%s) ([A-Z][A-Z0-9_]*)\b" % "|".join(HELPERS))

missing = set()
for match in pattern.finditer(source):
    key = match.group(1)
    for lang in ("zh", "en"):
        if f"MSG_{lang}_{key}" not in defined:
            missing.add(f"{key} [{lang}]")

if missing:
    print("missing i18n keys (add them to payload/bin/i18n.sh):")
    for item in sorted(missing):
        print("  " + item)
    sys.exit(1)

used = {m.group(1) for m in pattern.finditer(source)}
print(f"i18n ok: {len(used)} keys referenced, all defined in zh+en")

literal = re.compile(r"""\b(?:%s) (['\"])(?![$(])""" % "|".join(HELPERS))
leaks = sorted({m.group(0) for m in literal.finditer(source)})
if leaks:
    print("literal message passed to a localization helper (use a key):")
    for item in leaks:
        print("  " + item)
    sys.exit(1)
print("i18n ok: no literal messages passed to helpers")
