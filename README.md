# nvim-kanji-to-hiragana

A Neovim plugin that inserts the hiragana reading of a Japanese word
(kanji/compound) right after it. Lookups are performed **offline** against the
[JmdictFurigana](https://github.com/Doublevil/JmdictFurigana) dataset.

## Requirements

- Neovim 0.9+
- A copy of `JmdictFurigana.json` downloaded locally.

### Download the dictionary

Grab the latest `JmdictFurigana.json` from the
[JmdictFurigana releases](https://github.com/Doublevil/JmdictFurigana/releases)
and place it where Neovim's data dir lives. The default expected path is:

- Linux / macOS: `~/.local/share/nvim/JmdictFurigana.json`
- Windows: `~/AppData/Local/nvim-data/JmdictFurigana.json`

Example:

```sh
mkdir -p "$(nvim --headless +'echo stdpath("data")' +q 2>&1)"
curl -L -o "$HOME/.local/share/nvim/JmdictFurigana.json" \
  https://github.com/Doublevil/JmdictFurigana/releases/latest/download/JmdictFurigana.json
```

You can override the path via the `dictionary_path` option.

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

  -- Path to JmdictFurigana.json
  dictionary_path = vim.fn.stdpath("data") .. "/JmdictFurigana.json",

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

On the first lookup of a session, the plugin parses `JmdictFurigana.json`
(~30 MB) once and writes a precompiled Lua table to `cache_path`. Subsequent
sessions load the cached index in ~150 ms via `loadfile`. The cache is
invalidated automatically when the JSON file's mtime is newer.

## Commands

- `:KanjiToHiraganaRebuildIndex` — delete the cache and rebuild the index from
  the JSON. Run this if you replace `JmdictFurigana.json` with a newer release
  and the mtime check doesn't pick it up.

## Limitations

- JmdictFurigana is keyed by dictionary forms; conjugated forms (e.g. 食べた)
  won't match. Selecting the dictionary form (食べる) works.
- For words missing from the dataset, enable `fallback_to_web = true` to
  continue using the legacy jisho.org scraper.
