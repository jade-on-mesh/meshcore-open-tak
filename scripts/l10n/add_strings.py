#!/usr/bin/env python3
"""Add English strings to app_en.arb and the checked-in generated l10n files.

    python3 scripts/l10n/add_strings.py keys.json

keys.json: {"feature_key": "Text", "feature_count": ["{n} items", {"n": "int"}]}

The generated files are what `flutter gen-l10n` writes (an abstract getter in
app_localizations.dart, the English text in every locale's class); the other
locales then list the keys as untranslated.

Why not just append? Every feature branch appending at the end of the same
19 files is what made each merge conflict. New keys go in as one block,
placed where they'd sort among the existing keys (after the existing key just
below the block's first key), in the arb and at the same spot in every
generated file. Features with different prefixes ("quickReply_", "reach_",
"mosaic_", "ar_") then land in different places and merge cleanly. Nothing
already in the files moves, so syncs from upstream stay clean too.
If two branches still collide, scripts/l10n/resolve_conflicts.py keeps both.
"""
import json
import os
import re
import subprocess
import sys

# The checkout the command runs in (the workflow runs main's copy of this script
# inside a feature branch's checkout).
ROOT = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True,
                      check=True).stdout.strip()
L10N = os.path.join(ROOT, 'lib', 'l10n')


def dart_str(t):
    return "'" + t.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$') + "'"


def interp(t, phs):
    out = dart_str(t)
    for ph in phs:
        out = out.replace('{' + ph + '}', '$' + ph)
    return out


def arb_spans(lines):
    """Top-level entries of an arb as (key, first line, last line), in order."""
    starts = [(i, m.group(1)) for i, l in enumerate(lines) if (m := re.match(r'^  "([^"]+)"\s*:', l))]
    spans = []
    for n, (i, k) in enumerate(starts):
        end = starts[n + 1][0] - 1 if n + 1 < len(starts) else max(j for j, l in enumerate(lines) if l.strip() == '}') - 1
        while end > i and not lines[end].strip():
            end -= 1
        spans.append((k, i, end))
    return spans


def anchor_for(first_new, existing):
    """The existing key the block goes after: the largest one below it."""
    below = [k for k in existing if k < first_new]
    return max(below) if below else None


def add_arb(keys):
    path = os.path.join(L10N, 'app_en.arb')
    text = open(path).read()
    existing = [k for k in json.loads(text) if not k.startswith('@')]
    for k in keys:
        assert k not in existing, f'{k} is already in app_en.arb'
    lines = text.split('\n')
    spans = arb_spans(lines)
    anchor = anchor_for(min(keys), existing)
    block = []
    for k, v in keys.items():
        if isinstance(v, list):
            block.append(f'  {json.dumps(k)}: {json.dumps(v[0], ensure_ascii=False)}')
            ph = ', '.join(f'{json.dumps(p)}: {{"type": {json.dumps(t)}}}' for p, t in v[1].items())
            block.append(f'  {json.dumps("@" + k)}: {{"placeholders": {{{ph}}}}}')
        else:
            block.append(f'  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}')
    if anchor is None:   # before every key: right after "@@locale"
        after = next(e for (k, s, e) in spans if k == '@@locale')
    else:
        after = next(e for (k, s, e) in spans if k == anchor)
        meta = next(((k, s, e) for (k, s, e) in spans if k == '@' + anchor), None)
        if meta and meta[1] == after + 1:
            after = meta[2]
    is_last = after == spans[-1][2]
    if is_last:
        lines[after] = lines[after].rstrip() + ','
        new = [l + ',' for l in block[:-1]] + [block[-1]]
    else:
        new = [l + ',' for l in block]
    lines[after + 1:after + 1] = new
    out = '\n'.join(lines)
    json.loads(out)   # still valid
    open(path, 'w').write(out)
    return anchor


def member_end(lines, start):
    """Last line of the Dart member declared at `start`."""
    if lines[start].rstrip().endswith(';'):
        return start
    if lines[start].rstrip().endswith('{'):
        j = start + 1
        while lines[j] != '  }':
            j += 1
        return j
    j = start
    while not lines[j].rstrip().endswith(';'):
        j += 1
    return j


def insert_dart(path, anchor, chunks, abstract):
    lines = open(path).read().split('\n')
    if anchor is None:
        # Before the first member: after the class's opening line.
        start = next(i for i, l in enumerate(lines) if re.match(r'^(abstract )?class AppLocalizations', l))
        if abstract:
            start = next(i for i in range(start, len(lines)) if lines[i].startswith('  /// No description'))
            at = start
        else:
            at = next(i for i in range(start, len(lines)) if lines[i] == '  @override')
        new = '\n'.join(chunks).rstrip('\n').split('\n') + ['']
        lines[at:at] = new
    else:
        pat = re.compile(r'^  String (?:get )?' + re.escape(anchor) + r'\b')
        start = next(i for i, l in enumerate(lines) if pat.match(l))
        end = member_end(lines, start)
        new = [''] + '\n'.join(chunks).rstrip('\n').split('\n')
        lines[end + 1:end + 1] = new
    open(path, 'w').write('\n'.join(lines))


def main():
    keys = json.load(open(sys.argv[1]))
    anchor = add_arb(keys)
    abstract, impl = [], []
    for k, v in keys.items():
        text, phs = (v[0], v[1]) if isinstance(v, list) else (v, {})
        doc = dart_str(text)
        a = f'  /// No description provided for @{k}.\n  ///\n  /// In en, this message translates to:\n  /// **{doc}**\n'
        if phs:
            params = ', '.join(f'{t} {p}' for p, t in phs.items())
            abstract.append(a + f'  String {k}({params});\n')
            impl.append(f'  @override\n  String {k}({params}) {{\n    return {interp(text, phs)};\n  }}\n')
        else:
            abstract.append(a + f'  String get {k};\n')
            impl.append(f'  @override\n  String get {k} => {dart_str(text)};\n')
    insert_dart(os.path.join(L10N, 'app_localizations.dart'), anchor, abstract, True)
    n = 0
    for f in sorted(os.listdir(L10N)):
        if re.match(r'app_localizations_\w+\.dart$', f):
            insert_dart(os.path.join(L10N, f), anchor, impl, False)
            n += 1
    print(f'added {len(keys)} keys after {anchor or "the start"} in app_en.arb and {n} locales')


if __name__ == '__main__':
    main()
