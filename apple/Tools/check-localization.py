#!/usr/bin/env python3
"""Fails when a String Catalog is not fully translated into the ten shipped languages.

    Tools/check-localization.py                  # check every catalog under apple/
    Tools/check-localization.py --stale          # also list entries Xcode marks stale
    Tools/check-localization.py path.xcstrings   # check only the catalogs named

Checks per key: all ten languages present, state "translated", no empty value, and the same
format placeholders as the source text. Also rejects invalid JSON and duplicate keys.
Entries with shouldTranslate=false and the empty key are skipped.
"""
import json
import re
import sys
from pathlib import Path

LANGUAGES = ["de", "es", "fr", "it", "ja", "ko", "pt-BR", "ru", "zh-Hans"]
SOURCE = "en"
APPLE_DIR = Path(__file__).resolve().parent.parent
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+0#]?\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfFeEgGaAcCsSp]")
POSITIONAL = re.compile(r"%(\d+)\$")


def specifiers(text):
    return sorted(re.sub(r"^%\d+\$", "%", m) for m in PLACEHOLDER.findall(text.replace("%%", "")))


def unique_pairs(pairs):
    keys = [k for k, _ in pairs]
    dupes = sorted({k for k in keys if keys.count(k) > 1})
    if dupes:
        raise ValueError("duplicate keys: " + ", ".join(repr(k) for k in dupes[:5]))
    return dict(pairs)


def unit_values(localization):
    """Every string a localization carries: its stringUnit and each plural or device variation."""
    found = []
    if "stringUnit" in localization:
        found.append(("", localization["stringUnit"]))

    def walk(node, path):
        if not isinstance(node, dict):
            return
        if "stringUnit" in node:
            found.append((path, node["stringUnit"]))
        for name, child in node.items():
            if name != "stringUnit":
                walk(child, path + "/" + name)

    walk(localization.get("variations", {}), "")
    return found


def check_catalog(path):
    problems = []
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_pairs)
    except (ValueError, OSError) as error:
        return [f"{path}: invalid catalog: {error}"], []
    if catalog.get("sourceLanguage") != SOURCE:
        problems.append(f"{path}: source language is not {SOURCE}")
    stale = []
    for key, entry in catalog.get("strings", {}).items():
        if key == "" or entry.get("shouldTranslate") is False:
            continue
        if entry.get("extractionState") == "stale":
            stale.append(key)
        localizations = entry.get("localizations", {})
        source_units = unit_values(localizations.get(SOURCE, {}))
        source_text = source_units[0][1].get("value", key) if source_units else key
        source_specs = specifiers(source_text)
        absent = [language for language in LANGUAGES if language not in localizations]
        if absent:
            problems.append(f"{path.name}: {key!r}: missing {', '.join(absent)}")
        for language in LANGUAGES:
            if language not in localizations:
                continue
            units = unit_values(localizations[language])
            if not units:
                problems.append(f"{path.name}: {key!r}: {language} has no string unit")
            for variant, unit in units:
                value = unit.get("value", "")
                where = f"{language}{variant}"
                if unit.get("state") != "translated":
                    problems.append(f"{path.name}: {key!r}: {where} state is {unit.get('state')!r}")
                if not value.strip():
                    problems.append(f"{path.name}: {key!r}: {where} is empty")
                    continue
                got = specifiers(value)
                # A plural variant may drop the number ("One item"), but may not invent one.
                bad = (any(g not in source_specs for g in got) if variant
                       else got != source_specs)
                if bad:
                    problems.append(
                        f"{path.name}: {key!r}: {where} placeholders {got} != source {source_specs}")
                if POSITIONAL.search(value) and len(set(POSITIONAL.findall(value))) != len(got):
                    problems.append(f"{path.name}: {key!r}: {where} repeats or skips a position")
    return problems, stale


def main():
    arguments = [a for a in sys.argv[1:] if not a.startswith("--")]
    report_stale = "--stale" in sys.argv[1:]
    catalogs = [Path(a) for a in arguments] or sorted(
        p for p in APPLE_DIR.rglob("*.xcstrings")
        if not any(part in {"build", "DerivedData", ".build"} for part in p.parts))
    failures = []
    for path in catalogs:
        problems, stale = check_catalog(path)
        failures += problems
        if report_stale and stale:
            print(f"{path.name}: {len(stale)} stale")
            for key in stale:
                print(f"    {key!r}")
    for line in failures:
        print(f"error: {line}")
    print(f"{len(catalogs)} catalogs, {len(failures)} problems")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
