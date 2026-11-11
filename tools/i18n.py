#!/usr/bin/env python3
"""
i18n.py — Keep translations/*.json in sync with the strings actually used in QML.

Usage:
  python3 tools/i18n.py extract            # Rebuild translations/<lang>.json from the QML call sites
  python3 tools/i18n.py status             # Show translation coverage per language
  python3 tools/i18n.py check              # Fail when the catalog no longer matches the call sites
  python3 tools/i18n.py add-lang <code>    # Scaffold a translation file for a new locale

Format is the 2-level context bucket JSON required by DMS 1.6+:
{
  "English term": {
    "English term": "Translated term"
  }
}

Only I18n.trFor("depthscape", ...) terms are collected. Plain I18n.tr() calls resolve
from the dux-shell global catalog and must not be duplicated here.
"""

import re
import sys
import json
import argparse
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TRANSLATIONS_DIR = REPO_ROOT / "translations"

PLUGIN_ID = "depthscape"

# Directory names that never hold plugin QML.
EXCLUDE_DIRS = {".git", "engine", "dist", "docs", "node_modules", "assets", "test"}

KNOWN_LANGUAGES = {
    "ar": "Arabic",
    "de": "German",
    "es": "Spanish",
    "fr": "French",
    "it": "Italian",
    "ja": "Japanese",
    "ko": "Korean",
    "pt": "Portuguese",
    "ru": "Russian",
    "tr": "Turkish",
    "uk": "Ukrainian",
    "vi": "Vietnamese",
    "zh_CN": "Chinese (Simplified)",
    "zh_TW": "Chinese (Traditional)",
}

_TR_FOR_RE = re.compile(
    r'I18n\.trFor\(\s*["\']' + re.escape(PLUGIN_ID) + r'["\']\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)'
)
# Bare tr() terms are reported by `status` so stray plugin-private strings stay visible.
_TR_RE = re.compile(r'I18n\.tr\(\s*"((?:[^"\\]|\\.)*)"\s*\)')


def info(msg):    print(f"\033[94m{msg}\033[0m")
def success(msg): print(f"\033[92m{msg}\033[0m")
def warn(msg):    print(f"\033[93mWarning: {msg}\033[0m", file=sys.stderr)
def error(msg):
    print(f"\033[91mError: {msg}\033[0m", file=sys.stderr)
    sys.exit(1)


def _clean(s: str) -> str:
    return s.replace(r'\"', '"').replace(r"\\", "\\").replace(r"\n", "\n")


def _qml_files():
    for path in sorted(REPO_ROOT.rglob("*.qml")) + sorted(REPO_ROOT.rglob("*.js")):
        if any(part in EXCLUDE_DIRS for part in path.parts):
            continue
        if path.is_file():
            yield path


def extract_strings():
    """Every I18n.trFor term used by the plugin, sorted and de-duplicated."""
    strings = set()
    for path in _qml_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in _TR_FOR_RE.finditer(text):
            raw = _clean(m.group(1))
            if raw.strip():
                strings.add(raw)
    return sorted(strings)


def bare_tr_strings():
    """Plain I18n.tr terms; these should all exist in the dux-shell global catalog."""
    strings = set()
    for path in _qml_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in _TR_RE.finditer(text):
            raw = _clean(m.group(1))
            if raw.strip():
                strings.add(raw)
    return sorted(strings)


def locale_files():
    if not TRANSLATIONS_DIR.exists():
        return []
    return sorted(TRANSLATIONS_DIR.glob("*.json"), key=lambda p: p.stem.lower())


def _read_translations(path: Path):
    """Read a locale file into a flat {term: translation} map, tolerant of 1- or 2-level shape."""
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        warn(f"Failed to read {path}: {exc}")
        return {}
    result = {}
    for key, value in data.items():
        if isinstance(value, dict):
            term = value.get(key, "")
            result[key] = term if isinstance(term, str) else ""
        elif isinstance(value, str):
            result[key] = value
    return result


def _write_translations(path: Path, flat: dict):
    """Write a locale file in the DMS 2-level context bucket format."""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {term: {term: flat.get(term, "")} for term in sorted(flat)}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def cmd_extract(_args):
    strings = extract_strings()
    if not strings:
        warn("No I18n.trFor strings found.")
        return

    files = locale_files()
    if not files:
        warn("No translations/*.json yet. Run: tools/i18n.py add-lang zh_CN")

    total = len(strings)
    for path in files:
        existing = _read_translations(path)
        merged = {term: existing.get(term, "") for term in strings}
        _write_translations(path, merged)
        done = sum(1 for v in merged.values() if v.strip())
        added = sum(1 for term in strings if term not in existing)
        dropped = sum(1 for term in existing if term not in strings)
        info(f"[{path.stem}] {done}/{total} translated (+{added} new, -{dropped} stale)")

    success(f"Synced {total} source strings against {len(files)} locale file(s).")


def cmd_status(_args):
    strings = extract_strings()
    total = len(strings)
    if total == 0:
        warn("No I18n.trFor strings found in QML files.")
        return

    print(f"\n{'Language':<22} {'Locale':<10} {'File':<16} {'Done':>6} {'Missing':>8} {'Coverage':>10}")
    print("-" * 78)
    for path in locale_files():
        existing = _read_translations(path)
        done = sum(1 for term in strings if existing.get(term, "").strip())
        missing = total - done
        name = KNOWN_LANGUAGES.get(path.stem, path.stem)
        icon = "✓" if missing == 0 else ("~" if done else "✗")
        print(f"{name:<22} {path.stem:<10} {path.name:<16} {done:>6} {missing:>8}   {done / total * 100:>6.1f}%  {icon}")

    stale = []
    for path in locale_files():
        existing = _read_translations(path)
        for term in sorted(set(existing) - set(strings)):
            if existing[term].strip():
                stale.append((path.stem, term))
    if stale:
        print()
        warn(f"{len(stale)} stale entr(y/ies) no longer referenced by any trFor call — run tools/i18n.py extract")
        for locale, term in stale[:10]:
            print(f"    [{locale}] {term!r}")

    # Bare tr() terms are expected to resolve from the dux-shell catalog; list them so a
    # plugin-private sentence never hides behind a bare tr() call again.
    bare = bare_tr_strings()
    if bare:
        print(f"\nPlain I18n.tr() terms (must exist in the dux-shell global catalog): {len(bare)}")
        for term in bare:
            print(f"    {term!r}")
    print()


def cmd_check(_args):
    """Exit non-zero when a locale file no longer matches the QML call sites."""
    strings = extract_strings()
    if not strings:
        error("No I18n.trFor strings found in QML files.")

    failed = False
    files = locale_files()
    if not files:
        error("translations/ has no locale files.")

    for path in files:
        existing = _read_translations(path)
        missing = [term for term in strings if term not in existing]
        stale = [term for term in existing if term not in strings]
        untranslated = [term for term in strings if not existing.get(term, "").strip()]
        gaps = missing + stale + untranslated
        if gaps:
            failed = True
            print(f"\033[91mFAIL\033[0m {path.name}: {len(gaps)} problem(s)")
            for label, items in (("missing", missing), ("stale", stale), ("untranslated", untranslated)):
                for term in items:
                    print(f"    {label:<13} {term!r}")
        else:
            print(f"  OK   {path.name}: {len(strings)} terms, in sync")

    if failed:
        error("translations are out of sync — run: python3 tools/i18n.py extract")
    success("translations are in sync with the QML call sites.")


def cmd_add_lang(args):
    code = args.code.strip().replace("-", "_")
    out_path = TRANSLATIONS_DIR / f"{code}.json"
    if out_path.exists():
        warn(f"{out_path.name} already exists.")
        return
    strings = extract_strings()
    if not strings:
        warn("No source strings found; writing an empty file.")
    _write_translations(out_path, {term: "" for term in strings})
    success(f"Created {out_path.name} for '{KNOWN_LANGUAGES.get(code, code)}' with {len(strings)} terms ready to translate.")


def main():
    parser = argparse.ArgumentParser(
        description=f"i18n tooling for the {PLUGIN_ID} DMS plugin",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("extract", help="Rebuild translations/*.json from QML call sites")
    sub.add_parser("status", help="Show translation coverage per language")
    sub.add_parser("check", help="Fail when translations no longer match the QML call sites")
    p_add = sub.add_parser("add-lang", help="Scaffold a translation file for a new locale")
    p_add.add_argument("code", help="Locale code (e.g. es, pt_BR, zh_TW)")

    args = parser.parse_args()
    {"extract": cmd_extract, "status": cmd_status, "check": cmd_check,
     "add-lang": cmd_add_lang}[args.command](args)


if __name__ == "__main__":
    main()
