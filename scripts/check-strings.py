#!/usr/bin/env python3
"""App/strings.json vs the code. Usage: scripts/check-strings.py  (exit 1 on any error)

- every key has all 8 languages; a plural group ("key.one/.few/.many/.other") needs .other in
  all 8, and a category only in languages whose CLDR rules have it (missing ones fall back to .other)
- format specifiers (%d %@ %lld %.1f …) and {1} slots match zh-Hans in every language and variant
- every L("…") / Plural.pick("…") literal names a key; every key is used somewhere in Sources/
"""
import json, os, re, sys

LANGS = ["zh-Hans", "zh-Hant", "en", "es", "ru", "fr", "vi", "th"]
CATS = {"one": {"en", "es", "fr", "ru"}, "few": {"ru"}, "many": {"ru"}, "other": set(LANGS)}
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:lld|ld|lu|d|i|u|f|@|s)|\{\d+\}")
LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
table = json.load(open(os.path.join(root, "App/strings.json")))
errors, notes = [], []

def group(k):
    head, _, cat = k.rpartition(".")
    return (head, cat) if cat in CATS and head else (k, None)

groups = {}
for k, row in table.items():
    g, cat = group(k)
    groups.setdefault(g, {})[cat] = row
    unknown = set(row) - set(LANGS)
    if unknown: errors.append(f"{k}: unknown languages {sorted(unknown)}")
    want = CATS[cat] if cat else set(LANGS)
    extra = set(row) - want
    if extra: errors.append(f"{k}: '{cat}' is not a plural category of {sorted(extra)}")
    if not cat and set(LANGS) - set(row): errors.append(f"{k}: missing {sorted(set(LANGS) - set(row))}")
    if cat == "other" and set(LANGS) - set(row): errors.append(f"{k}: missing {sorted(set(LANGS) - set(row))}")
    if cat and cat != "other" and want - set(row): notes.append(f"{k}: {sorted(want - set(row))} use .other")
    for lang, text in row.items():
        if not text.strip(): errors.append(f"{k} [{lang}]: empty")

for g, variants in groups.items():
    ref = sorted(SPEC.findall(variants.get("other", variants.get(None, {})).get("zh-Hans", "")))
    for cat, row in variants.items():
        for lang, text in row.items():
            got = sorted(SPEC.findall(text))
            if got != ref: errors.append(f"{g}{'.' + cat if cat else ''} [{lang}]: specifiers {got} != zh-Hans {ref}")

def first_arg_literals(code, i):
    """String literals in the first argument of the call whose "(" ends at i: L("a"), L(c ? "a" : "b", x)."""
    out, depth, j = [], 0, i
    while j < len(code):
        c = code[j]
        if c == '"':
            m = LIT.match(code, j)
            if not m: break
            out.append(m.group(1)); j = m.end(); continue
        if c in "([": depth += 1
        elif c in ")]":
            if depth == 0: break
            depth -= 1
        elif c == "," and depth == 0: break
        j += 1
    return [k for k in out if "\\(" not in k]

# Code: string literals outside // comments.
literals, called = set(), set()
for d, _, files in os.walk(os.path.join(root, "Sources")):
    for f in files:
        if not f.endswith(".swift"): continue
        for n, line in enumerate(open(os.path.join(d, f)), 1):
            code = re.sub(r'^\s*//.*', "", line)
            code = re.sub(r'\s//\s.*$', "", code)
            for m in LIT.finditer(code): literals.add(m.group(1))
            for m in re.finditer(r'\b(L|Plural\.pick)\(', code):
                for key in first_arg_literals(code, m.end()):
                    called.add((key, f"{f}:{n}", m.group(1) != "L"))
keys = set(table) | set(groups)
for key, where, plural in sorted(called):
    if (key not in groups if plural else key not in table): errors.append(f"{where}: no string for key '{key}'")
used = {g for g in groups if g in literals}
for g in sorted(set(groups) - used): errors.append(f"unused key: {g}")

print(f"strings.json: {len(table)} entries, {len(groups)} keys ({sum(1 for v in groups.values() if None not in v)} plural), "
      f"{len(called)} L()/Plural.pick() call sites")
for n in notes: print("note ", n)
for e in errors: print("ERROR", e)
print("OK" if not errors else f"{len(errors)} errors")
sys.exit(1 if errors else 0)
