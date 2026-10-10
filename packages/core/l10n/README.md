<!-- packages/core/l10n/README.md -->
# LocalRoll language files

Everything users read is data, one JSON file per language. Code never contains UI text.

| What | Where | Used by |
|---|---|---|
| Languages, picker order, native names | `packages/core/l10n/languages.json` | phone + PC |
| Random device-name words | `packages/core/l10n/names/<lang>.json` | phone + PC |
| PC app text | `apps/desktop/l10n/<lang>.json` | PC |
| Phone app text, including iOS permission prompts (`ios.*` keys) | `apps/mobile/l10n/<lang>.json` | phone |

After editing any of these files, run this from the repo root:

    python scripts/gen_l10n.py

It regenerates the Dart tables and the iOS `InfoPlist.strings` files. CI runs it with `--check`, which reports:

- missing files or keys
- broken `{placeholders}`
- out-of-date outputs

## Adding a language

1. Add an entry to `languages.json`. `ios` is Apple's `.lproj` code.
2. Copy `en.json` to `apps/desktop/l10n/<code>.json` and `apps/mobile/l10n/<code>.json`, then translate.
3. Add `names/<code>.json`: 24 + 24 words and a `pattern` such as `{a} {b}`.
4. Run `python scripts/gen_l10n.py` and `python scripts/patch_platforms.py`.
