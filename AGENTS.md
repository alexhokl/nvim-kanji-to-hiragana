# AGENTS.md

Compact context for agents working in this repo. Read before editing.

## Layout

Single-file Neovim plugin. All runtime code lives in
`lua/nvim-kanji-to-hiragana.lua`. There is no `plugin/` autoload directory; the
plugin only activates when the user calls `require("nvim-kanji-to-hiragana").setup{}`.

The Lua module name contains hyphens: `require("nvim-kanji-to-hiragana")`. Do
not rename without updating the loader.

## Dictionary format

The plugin reads **`JmdictFurigana.txt`** (line-delimited
`text|reading|furigana-spec`) from
[Doublevil/JmdictFurigana](https://github.com/Doublevil/JmdictFurigana/releases).
It does **not** read `JmdictFurigana.json`; that path was abandoned because
`vim.json.decode` fails on the 34 MB array. Do not reintroduce JSON parsing as
the primary path.

Default dictionary path: `stdpath('data') .. "/JmdictFurigana.txt"`.
Default cache path: `stdpath('cache') .. "/nvim-kanji-to-hiragana-index.lua"`
(precompiled Lua table, mtime-invalidated against the source file).

## Testing

Tests use `plenary.busted` orchestrated via `Taskfile.yml`.

```sh
task test                                       # full suite
task test:file -- tests/<spec>_spec.lua         # single file
task clean                                      # drop vendored plenary
```

`task deps` clones plenary into `.deps/plenary.nvim` (gitignored). The headless
runner is invoked with `tests/minimal_init.lua`; do not load tests through your
personal Neovim config.

When adding tests, use `plugin._internal` (test-only surface) and
`plugin._defaults_for_test()`. The `set_notify` / `set_web_lookup` injectors
work because the corresponding production locals are forward-declared so that
`set_*` and the consumers share the same upvalue — preserve that pattern if
you add new injectables. Stub `vim.api.nvim_echo` in any test that exercises
`report_error` to keep the busted output clean.

Verb deinflection tests live in `tests/deinflection_spec.lua` and cover
`deinflect()` unit tests (pure, no index) as well as `lookup_kanji_async()`
integration tests using a stub index.

## Architecture quirks

- **Async lookup**: `lookup_kanji_async(kanji, callback)` is callback-based
  because `vim.ui.select` (used for homographs like 今日 → きょう/こんにち) is
  async. Visual/normal-mode handlers capture the target insertion position
  *before* invoking the lookup, then insert via `nvim_buf_set_text` inside the
  callback. Do not assume the cursor is still where it started.
- **Verb deinflection**: when a word is not found in the index, `deinflect(word)`
  generates candidate dictionary forms and the lookup retries each one. Rules
  cover Ichidan (る-verb), Godan (all nine う-verb columns), irregular する/くる,
  and compound する verbs. Candidates are over-generated intentionally; the
  first index hit wins. The web fallback is only reached if all candidates
  miss. `deinflect` is exposed on `M._internal` for testing.
- **Multibyte insertion math**: the `'>` mark and `normal! e` give the byte
  offset of the *first byte* of the last character. Code skips the full UTF-8
  codepoint width before inserting; if you touch this, retest with 1/2/3/4-byte
  characters.
- **Error visibility**: errors go through `report_error()` →
  `nvim_api.nvim_echo(chunks, true, {})`. Do not switch to `vim.notify` at
  ERROR level for multiline messages — the cmdline truncates them and only the
  first line reaches the user.
- **Lua 5.4 const for-vars**: generic-for loop variables are const. Copy to a
  mutable local before reassigning (see `build_index_from_txt`).

## User-facing commands & defaults

- `:KanjiToHiraganaDownloadDictionary` — async (`vim.system`) curl download to
  `dictionary_path`; on success clears `M._index` and `cache_path`. The on-exit
  callback is `vim.schedule_wrap`'d, so tests must `vim.wait()` for completion.
- `:KanjiToHiraganaRebuildIndex` — clears `M._index` and `cache_path`, then
  rebuilds.
- `<leader>hi` is bound in both normal (`expand("<cword>")`) and visual modes.

## Conventions

- 2-space indent, no trailing whitespace, double-quoted strings (matches
  existing file).
- `luac -p lua/nvim-kanji-to-hiragana.lua` for a quick syntax check before
  running the test suite.
- Web fallback (`fallback_to_web = true`, `parse_jisho_html`) is retained but
  off by default; treat it as legacy code, not the primary path.
