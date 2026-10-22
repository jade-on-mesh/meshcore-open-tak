# l10n tools

Every feature adds strings to the same 19 files: `lib/l10n/app_en.arb` and the
generated `app_localizations*.dart` that are checked in. When two feature
branches both appended at the end, merging the second always conflicted.

## Adding strings: `add_strings.py`

```bash
python3 scripts/l10n/add_strings.py keys.json
```

`keys.json` maps each key to its English text, or to `[text, {placeholder: type}]`:

```json
{"mosaic_show": "Photos on the map",
 "mosaic_timelineTitle": ["{count} photos", {"count": "int"}]}
```

It writes the arb entry and what `flutter gen-l10n` would write (the abstract
getter, and the English text in every locale, which lists it as untranslated).
The keys go in as one block, at the place where they would sort among the
existing keys, not at the end. Features with different prefixes land in
different places and merge cleanly. Nothing that's already there moves, so
syncs from upstream stay clean too.

Give a feature's keys a common prefix (`quickReply_`, `reach_`, `ar_`).

## Resolving: `resolve_conflicts.py`

```bash
git merge main
python3 scripts/l10n/resolve_conflicts.py
git add -A && git commit
```

For conflicted l10n files it keeps both sides: theirs, then ours. It repairs
the comma between arb entries and the `@override` that git leaves above only
one side, and keeps a key only once if both sides added it. Markdown conflicts
where both sides only added list lines (the numbered feature list in
`documentation/README.md`, and "... is in [X.md]" lines) get theirs, then ours,
renumbered. Any other conflict is reported and left alone, and the script
exits non-zero.

## Automatic: `.github/workflows/resolve-conflicts.yml`

On every push to main, each open PR from this repo that no longer merges is
handled in turn:

- main is merged into it, and this resolver runs;
- if that leaves no conflicts, the merge is pushed to the PR's branch and its
  checks (`check.yml`, `format.yml`) are started again;
- if a conflict is somewhere else, the run's log names the PR and the files,
  and the branch is left for a person.
