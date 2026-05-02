# nvim-kanji-to-hiragana

A Neovim plugin that inserts the hiragana reading of a Japanese word
(kanji/compound) right after it. Lookups are performed **offline** against the
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

- **Normal mode**: place the cursor on a Japanese word and press `<leader>hi`.
  The plugin inserts ` (よみ)` after the word.
- **Visual mode**: select a Japanese phrase and press `<leader>hi`.

If the word has multiple readings (e.g. 今日 → きょう / こんにち), a picker
appears via `vim.ui.select` — choose the desired reading.

## Configuration

```lua
require("nvim-kanji-to-hiragana").setup({
  visual_mode_keymap = "<leader>hi",
  normal_mode_keymap = "<leader>hi",
  keymap_options = { noremap = true, silent = true },

  -- Path to JmdictFurigana.txt
  dictionary_path = vim.fn.stdpath("data") .. "/JmdictFurigana.txt",

  -- Precompiled lookup-index cache (auto-managed, mtime-invalidated)
  cache_path = vim.fn.stdpath("cache") .. "/nvim-kanji-to-hiragana-index.lua",

  -- "select" | "first" | "all"
  on_multiple_readings = "select",

  -- If true, fall back to https://jisho.org HTML scraping when a word is
  -- absent from the local dictionary. Requires curl.
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

- `:KanjiToHiraganaRebuildIndex` — delete the cache and rebuild the index from
  the source file.

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

