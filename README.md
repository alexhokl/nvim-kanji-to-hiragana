# nvim-kanji-to-hiragana

A Neovim plugin for bidirectional Japanese reading conversion:

- **Kanji → Hiragana**: inserts the hiragana reading of a Japanese word
  (kanji/compound) right after it, in parentheses.
- **Hiragana → Kanji**: prepends the chosen kanji form directly before a
  hiragana word, leaving the source hiragana in place.

Both directions look up offline against the
[JmdictFurigana](https://github.com/Doublevil/JmdictFurigana) dataset.

## Requirements

- Neovim 0.9+
- A copy of `JmdictFurigana.txt` downloaded locally.

### Download the dictionary

Grab the latest `JmdictFurigana.txt` from the
[JmdictFurigana releases](https://github.com/Doublevil/JmdictFurigana/releases)
and place it where Neovim's data dir lives. The default expected path is:

- Linux / macOS: `~/.local/share/nvim/JmdictFurigana.txt`
- Windows: `~/AppData/Local/nvim-data/JmdictFurigana.txt`

Example:

```sh
curl -L -o "$HOME/.local/share/nvim/JmdictFurigana.txt" \
  https://github.com/Doublevil/JmdictFurigana/releases/latest/download/JmdictFurigana.txt
```

You can override the path via the `dictionary_path` option.

> **Note**: prior versions used `JmdictFurigana.json`; the plugin now uses the
> line-delimited `.txt` release because it is faster to parse and uses
> significantly less memory.

## Installation

Using `lazy.nvim`:

```lua
{
  "anomalyco/nvim-kanji-to-hiragana",
  config = function()
    require("nvim-kanji-to-hiragana").setup({})
  end,
}
```

## Usage

### Kanji → Hiragana (`<leader>hi`)

- **Normal mode**: place the cursor on a Japanese word and press `<leader>hi`.
  The plugin inserts ` (よみ)` after the word.
- **Visual mode**: select a Japanese phrase and press `<leader>hi`.

If the word has multiple readings (e.g. 今日 → きょう / こんにち), a picker
appears via `vim.ui.select` — choose the desired reading.

### Hiragana → Kanji (`<leader>hk`)

- **Normal mode**: place the cursor on a hiragana word and press `<leader>hk`.
  The plugin prepends the chosen kanji directly in front of the word
  (e.g. `たべる` → `食べるたべる`).
- **Visual mode**: select a hiragana span and press `<leader>hk`.

Most readings have many homophone kanji, so a `vim.ui.select` picker is shown
by default; configure via `on_multiple_kanji`.

## Configuration

```lua
require("nvim-kanji-to-hiragana").setup({
  visual_mode_keymap = "<leader>hi",
  normal_mode_keymap = "<leader>hi",
  visual_mode_keymap_reverse = "<leader>hk",
  normal_mode_keymap_reverse = "<leader>hk",
  keymap_options = { noremap = true, silent = true },

  -- Path to JmdictFurigana.txt
  dictionary_path = vim.fn.stdpath("data") .. "/JmdictFurigana.txt",

  -- URL used by :KanjiToHiraganaDownloadDictionary
  dictionary_url = "https://github.com/Doublevil/JmdictFurigana/releases/latest/download/JmdictFurigana.txt",

  -- Precompiled lookup-index caches (auto-managed, mtime-invalidated)
  cache_path = vim.fn.stdpath("cache") .. "/nvim-kanji-to-hiragana-index.lua",
  reverse_cache_path = vim.fn.stdpath("cache") .. "/nvim-kanji-to-hiragana-reverse-index.lua",

  -- "select" | "first" | "all"
  on_multiple_readings = "select",
  on_multiple_kanji = "select",

  -- If true, fall back to https://jisho.org HTML scraping when a word is
  -- absent from the local dictionary. Forward (kanji -> hiragana) only;
  -- reverse lookups never consult the web.
  fallback_to_web = false,
  url_template = "https://jisho.org/word/{}",
})
```

## How it works

On first lookup of a session, the plugin streams `JmdictFurigana.txt`
line-by-line and writes a precompiled Lua table to `cache_path`. Subsequent
sessions load the cached index in ~150 ms via `loadfile`. The cache is
invalidated automatically when the source file's mtime is newer.

## Commands

- `:KanjiToHiraganaDownloadDictionary` — fetch the latest `JmdictFurigana.txt`
  from `dictionary_url` (default: GitHub releases) into `dictionary_path` and
  invalidate both caches. Requires `curl` in `$PATH`.
- `:KanjiToHiraganaRebuildIndex` — delete the forward and reverse caches and
  rebuild the forward index from the source file. The reverse index is then
  rebuilt lazily on first hiragana → kanji lookup.

## Limitations

- JmdictFurigana is keyed by dictionary forms; conjugated forms (e.g. 食べた)
  won't match. Selecting the dictionary form (食べる) works.
- For words missing from the dataset, enable `fallback_to_web = true` to
  continue using the legacy jisho.org scraper.

## Development

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted
runner and are orchestrated via [Task](https://taskfile.dev):

```sh
task test               # run the full suite
task test:file -- tests/nvim-kanji-to-hiragana_spec.lua
task clean              # remove vendored test deps
```

The first run vendors plenary into `.deps/plenary.nvim` (gitignored).

