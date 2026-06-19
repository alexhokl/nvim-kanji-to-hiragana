local M = {}

local default_options = {
  visual_mode_keymap = "<leader>hi",
  normal_mode_keymap = "<leader>hi",
  -- Reverse direction (hiragana -> kanji). Inserts the chosen kanji directly
  -- before the source hiragana, leaving the original characters in place.
  visual_mode_keymap_reverse = "<leader>hk",
  normal_mode_keymap_reverse = "<leader>hk",
  keymap_options = { noremap = true, silent = true },
  -- Path to JmdictFurigana.txt (download from
  -- https://github.com/Doublevil/JmdictFurigana/releases).
  -- Format per line: text|reading|furigana-spec
  dictionary_path = vim.fn.stdpath("data") .. "/JmdictFurigana.txt",
  -- URL used by :KanjiToHiraganaDownloadDictionary to fetch the latest
  -- JmdictFurigana.txt release asset.
  dictionary_url =
  "https://github.com/Doublevil/JmdictFurigana/releases/latest/download/JmdictFurigana.txt",
  -- Path to the precompiled Lua index (auto-generated, mtime-invalidated).
  cache_path = vim.fn.stdpath("cache") .. "/nvim-kanji-to-hiragana-index.lua",
  -- Path to the precompiled reverse Lua index (reading -> {texts}).
  reverse_cache_path = vim.fn.stdpath("cache") ..
      "/nvim-kanji-to-hiragana-reverse-index.lua",
  -- "select" prompts via vim.ui.select; "first" picks the first reading; "all"
  -- joins them with "/".
  on_multiple_readings = "select",
  -- Same semantics, applied to reverse lookup (reading -> kanji). Reverse
  -- lookups almost always have many homophones; "select" is the sensible
  -- default.
  on_multiple_kanji = "select",
  -- If true, fall back to the legacy jisho.org HTML scraper when the kanji is
  -- not found in the local dictionary. Requires curl. Reverse lookups never
  -- consult the web fallback.
  fallback_to_web = false,
  url_template = "https://jisho.org/word/{}",
}

-- ---------------------------------------------------------------------------
-- Notification (overridable for tests)
-- ---------------------------------------------------------------------------

local notify_fn = function(msg, level)
  vim.notify("[kanji-to-hiragana] " .. msg, level or vim.log.levels.INFO)
end

local function notify(msg, level)
  notify_fn(msg, level)
end

-- Multi-line error reporter that bypasses the cmdline truncation. The message
-- is appended to :messages history.
local function report_error(lines)
  local chunks = {}
  for i, line in ipairs(lines) do
    if i > 1 then chunks[#chunks + 1] = { "\n" } end
    chunks[#chunks + 1] = { "[kanji-to-hiragana] " .. line, "ErrorMsg" }
  end
  vim.api.nvim_echo(chunks, true, {})
end

-- ---------------------------------------------------------------------------
-- Index loading / building
-- ---------------------------------------------------------------------------

local function file_mtime(path)
  local stat = vim.loop.fs_stat(path)
  if not stat then return nil end
  return stat.mtime.sec
end

local function build_index_from_txt(path)
  if not vim.loop.fs_stat(path) then
    report_error({
      "Dictionary not found at " .. path,
      "Download JmdictFurigana.txt from",
      "https://github.com/Doublevil/JmdictFurigana/releases",
      "and place it at the path above (or set dictionary_path in setup()).",
    })
    return nil
  end

  local idx = {}
  local ok, err = pcall(function()
    for raw_line in io.lines(path) do
      local line = raw_line
      -- Strip trailing CR if present (CRLF files).
      if line:sub(-1) == "\r" then line = line:sub(1, -2) end
      local p1 = line:find("|", 1, true)
      if p1 then
        local p2 = line:find("|", p1 + 1, true)
        local text = line:sub(1, p1 - 1)
        local reading = p2 and line:sub(p1 + 1, p2 - 1) or line:sub(p1 + 1)
        if text ~= "" and reading ~= "" then
          local list = idx[text]
          if not list then
            idx[text] = { reading }
          else
            local seen = false
            for _, r in ipairs(list) do
              if r == reading then seen = true; break end
            end
            if not seen then list[#list + 1] = reading end
          end
        end
      end
    end
  end)
  if not ok then
    report_error({ "Failed to read " .. path, tostring(err) })
    return nil
  end
  return idx
end

local function serialize_index(idx, path)
  local f, err = io.open(path, "wb")
  if not f then
    notify("Could not write cache " .. path .. ": " .. tostring(err),
      vim.log.levels.WARN)
    return false
  end
  local parts = { "return {\n" }
  for text, readings in pairs(idx) do
    parts[#parts + 1] = "[" .. string.format("%q", text) .. "]={"
    for i, r in ipairs(readings) do
      if i > 1 then parts[#parts + 1] = "," end
      parts[#parts + 1] = string.format("%q", r)
    end
    parts[#parts + 1] = "},\n"
  end
  parts[#parts + 1] = "}\n"
  f:write(table.concat(parts))
  f:close()
  return true
end

local function load_cached_index(cache_path, source_path)
  local cache_mtime = file_mtime(cache_path)
  local source_mtime = file_mtime(source_path)
  if not cache_mtime or not source_mtime then return nil end
  if cache_mtime < source_mtime then return nil end
  local chunk, err = loadfile(cache_path)
  if not chunk then
    notify("Cache load failed (" .. tostring(err) .. "); rebuilding.",
      vim.log.levels.WARN)
    return nil
  end
  local ok, idx = pcall(chunk)
  if not ok or type(idx) ~= "table" then
    notify("Cache invalid; rebuilding.", vim.log.levels.WARN)
    return nil
  end
  return idx
end

local function load_index(force_rebuild)
  if not force_rebuild and M._index then return M._index end

  local source_path = M.options.dictionary_path
  local cache_path = M.options.cache_path

  if not force_rebuild then
    local cached = load_cached_index(cache_path, source_path)
    if cached then
      M._index = cached
      return cached
    end
  end

  notify("Building reading index from JmdictFurigana.txt (one-time)...")
  local idx = build_index_from_txt(source_path)
  if not idx then return nil end
  serialize_index(idx, cache_path)
  M._index = idx
  return idx
end

-- ---------------------------------------------------------------------------
-- Reverse index (reading -> {texts})
-- ---------------------------------------------------------------------------

local function build_reverse_index_from_txt(path)
  if not vim.loop.fs_stat(path) then
    report_error({
      "Dictionary not found at " .. path,
      "Download JmdictFurigana.txt from",
      "https://github.com/Doublevil/JmdictFurigana/releases",
      "and place it at the path above (or set dictionary_path in setup()).",
    })
    return nil
  end

  local idx = {}
  local ok, err = pcall(function()
    for raw_line in io.lines(path) do
      local line = raw_line
      if line:sub(-1) == "\r" then line = line:sub(1, -2) end
      local p1 = line:find("|", 1, true)
      if p1 then
        local p2 = line:find("|", p1 + 1, true)
        local text = line:sub(1, p1 - 1)
        local reading = p2 and line:sub(p1 + 1, p2 - 1) or line:sub(p1 + 1)
        if text ~= "" and reading ~= "" then
          local list = idx[reading]
          if not list then
            idx[reading] = { text }
          else
            local seen = false
            for _, t in ipairs(list) do
              if t == text then seen = true; break end
            end
            if not seen then list[#list + 1] = text end
          end
        end
      end
    end
  end)
  if not ok then
    report_error({ "Failed to read " .. path, tostring(err) })
    return nil
  end
  return idx
end

local function load_cached_reverse_index(cache_path, source_path)
  -- Reuse the same staleness rules as the forward cache.
  return load_cached_index(cache_path, source_path)
end

local function load_reverse_index(force_rebuild)
  if not force_rebuild and M._reverse_index then return M._reverse_index end

  local source_path = M.options.dictionary_path
  local cache_path = M.options.reverse_cache_path

  if not force_rebuild then
    local cached = load_cached_reverse_index(cache_path, source_path)
    if cached then
      M._reverse_index = cached
      return cached
    end
  end

  notify("Building reverse reading index from JmdictFurigana.txt (one-time)...")
  local idx = build_reverse_index_from_txt(source_path)
  if not idx then return nil end
  serialize_index(idx, cache_path)
  M._reverse_index = idx
  return idx
end

-- ---------------------------------------------------------------------------
-- Legacy web fallback (only used when fallback_to_web = true)
-- ---------------------------------------------------------------------------

local function url_encode(str)
  local encoded = ""
  for i = 1, #str do
    local byte = string.byte(str, i)
    if (byte >= 48 and byte <= 57) or
        (byte >= 65 and byte <= 90) or
        (byte >= 97 and byte <= 122) or
        byte == 45 or byte == 46 or byte == 95 or byte == 126 then
      encoded = encoded .. string.char(byte)
    else
      encoded = encoded .. string.format("%%%02X", byte)
    end
  end
  return encoded
end

local function parse_jisho_html(html)
  local representation = html:match('<div class="concept_light%-representation"[^>]*>(.-)</div>')
  if not representation then return nil end
  representation = representation:gsub("%s+", " ")

  local furigana_block = representation:match('<span class="furigana">(.-)</span> <span class="text">')
      or representation:match('<span class="furigana">(.-)</span>')
  if not furigana_block then return nil end

  local text_tag = '<span class="text">'
  local text_start = representation:find(text_tag, 1, true)
  if not text_start then return nil end

  local after_text_tag = representation:sub(text_start + #text_tag)
  local text_block, depth, pos = nil, 0, 1
  while pos <= #after_text_tag do
    local open_start = after_text_tag:find("<span", pos)
    local close_start = after_text_tag:find("</span>", pos)
    if not close_start then break end
    if open_start and open_start < close_start then
      depth = depth + 1
      pos = open_start + 5
    else
      if depth == 0 then
        text_block = after_text_tag:sub(1, close_start - 1)
        break
      end
      depth = depth - 1
      pos = close_start + 7
    end
  end
  if not text_block then return nil end
  text_block = text_block:gsub("^%s+", ""):gsub("%s+$", "")

  local furigana_readings = {}
  for span_content in furigana_block:gmatch('<span[^>]*>(.-)</span>') do
    if span_content ~= "" then
      table.insert(furigana_readings, span_content)
    end
  end

  local text_parts = {}
  pos = 1
  while pos <= #text_block do
    local span_start, span_end, span_content = text_block:find('<span>(.-)</span>', pos)
    if span_start == pos then
      table.insert(text_parts, { content = span_content, is_kana = true })
      pos = span_end + 1
    else
      local next_span = text_block:find('<span>', pos)
      local chunk = next_span and text_block:sub(pos, next_span - 1) or text_block:sub(pos)
      chunk = chunk:gsub("^%s+", ""):gsub("%s+$", "")
      if chunk ~= "" then
        table.insert(text_parts, { content = chunk, is_kana = false })
      end
      if next_span then pos = next_span else break end
    end
  end

  local result, furigana_idx = {}, 1
  for i, part in ipairs(text_parts) do
    if part.is_kana then
      table.insert(result, part.content)
    else
      local readings_for_chunk = {}
      local remaining_kanji_chunks = 0
      for j = i + 1, #text_parts do
        if not text_parts[j].is_kana then
          remaining_kanji_chunks = remaining_kanji_chunks + 1
        end
      end
      local remaining_furigana = #furigana_readings - furigana_idx + 1
      local readings_to_take = remaining_furigana - remaining_kanji_chunks
      if readings_to_take < 1 then readings_to_take = 1 end
      for _ = 1, readings_to_take do
        if furigana_idx <= #furigana_readings then
          table.insert(readings_for_chunk, furigana_readings[furigana_idx])
          furigana_idx = furigana_idx + 1
        end
      end
      if #readings_for_chunk > 0 then
        table.insert(result, table.concat(readings_for_chunk, ""))
      else
        table.insert(result, part.content)
      end
    end
  end

  local hiragana = table.concat(result, "")
  if hiragana == "" then return nil end
  return hiragana
end

local web_lookup_kanji
web_lookup_kanji = function(kanji)
  local encoded = url_encode(kanji)
  local url = M.options.url_template:gsub("{}", (encoded:gsub("%%", "%%%%")))
  local result = vim.fn.system({ "curl", "-s", "-L", url })
  if vim.v.shell_error ~= 0 then
    notify("Error fetching data: " .. result, vim.log.levels.ERROR)
    return nil
  end
  return parse_jisho_html(result)
end

-- ---------------------------------------------------------------------------
-- Verb deinflection
-- ---------------------------------------------------------------------------

-- Returns an ordered list of candidate dictionary-form strings for `word`.
-- Candidates are over-generated intentionally; callers filter by index lookup.
-- The list is ordered most-specific first so longer suffix matches win.
--
-- Strategy:
--   1. Hard-coded irregular verb forms (する/くる and their kanji compounds).
--   2. Ichidan (る-verb) endings: strip the ending and append る.
--   3. Godan (う-verb) endings: reverse the standard conjugation vowel shift.
--
-- Only the kana suffix is examined; the kanji stem is kept unchanged.
-- All kana comparisons are in UTF-8 byte strings (Lua 5.4 default).

-- utf8_len: number of UTF-8 codepoints in s (used to guard minimum stem length)
local function utf8_len(s)
  local n = 0
  local i = 1
  while i <= #s do
    local b = s:byte(i)
    if b >= 0xF0 then i = i + 4
    elseif b >= 0xE0 then i = i + 3
    elseif b >= 0xC0 then i = i + 2
    else i = i + 1
    end
    n = n + 1
  end
  return n
end

-- utf8_sub: return the last `n` UTF-8 codepoints of s as a byte string.
-- Also returns the byte index of the split point so the stem can be extracted.
local function utf8_last_bytes(s, n)
  -- Walk from the end: collect codepoint start positions from the back.
  local positions = {}
  local i = #s
  while i >= 1 do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then
      -- This byte is a codepoint start (ASCII or leading byte of multibyte).
      table.insert(positions, 1, i)
      if #positions == n then break end
    end
    i = i - 1
  end
  if #positions == 0 then return "", #s + 1 end
  local split = positions[1]
  return s:sub(split), split
end

-- Deinflection rule table.
-- Each entry: { suffix_bytes, replacement_bytes, min_stem_codepoints }
-- suffix_bytes   : kana suffix to strip (UTF-8 string)
-- replacement    : kana to append after stripping (UTF-8 string, may be "")
-- min_stem_cp    : minimum codepoints required in the remaining stem
--
-- Rules are tried in order; first matching rule whose stripped stem has at
-- least min_stem_cp codepoints produces a candidate.  Multiple rules may
-- fire for the same input — all candidates are returned.
local DEINFLECT_RULES = {
  -- -------------------------------------------------------------------------
  -- Irregular: する and compound verbs ending in する (〜する)
  -- -------------------------------------------------------------------------
  -- These are matched as whole-word replacements handled separately below.

  -- -------------------------------------------------------------------------
  -- Long suffixes first (most specific)
  -- -------------------------------------------------------------------------

  -- Causative-passive: 〜させられ(る) ← す-verb causative passive
  { "させられる", "す", 1 },
  { "させられた", "す", 1 },
  { "させられて", "す", 1 },
  { "させられない", "す", 1 },
  -- Causative: 〜させ(る)
  { "させる", "す", 1 },
  { "させた", "す", 1 },
  { "させて", "す", 1 },
  { "させない", "す", 1 },

  -- Ichidan causative-passive: 〜させられ ← 〜る (stem + させられ)
  { "させられる", "る", 1 },
  { "させられた", "る", 1 },
  { "させられて", "る", 1 },
  { "させられない", "る", 1 },
  -- Ichidan causative: 〜させる
  { "させる", "る", 1 },
  { "させた", "る", 1 },
  { "させて", "る", 1 },

  -- Passive / potential Ichidan: stem + られ
  { "られる", "る", 1 },
  { "られた", "る", 1 },
  { "られて", "る", 1 },
  { "られない", "る", 1 },
  { "られれば", "る", 1 },

  -- Polite negative past: 〜ませんでした
  { "ませんでした", "る", 1 },  -- Ichidan
  -- Polite negative: 〜ません
  { "ません", "る", 1 },        -- Ichidan
  -- Polite past: 〜ました
  { "ました", "る", 1 },        -- Ichidan
  -- Polite: 〜ます (Ichidan: strip nothing from stem, add る)
  -- The masu-stem of Ichidan is the bare stem, so 食べます → 食べ + ます → 食べる
  { "ます", "る", 1 },

  -- te-iru / te-iru contracted forms (progressive)
  { "ている", "る", 1 },
  { "ていた", "る", 1 },
  { "ていて", "る", 1 },
  { "ていない", "る", 1 },
  { "ている", "る", 1 },  -- same as above, shorthand
  -- contracted: 〜てる / 〜てた
  { "てる", "る", 1 },
  { "てた", "る", 1 },

  -- Negative past: 〜なかった (Ichidan)
  { "なかった", "る", 1 },
  -- Negative: 〜ない (Ichidan)
  { "ない", "る", 1 },
  -- Negative adverbial: 〜なく (Ichidan)
  { "なく", "る", 1 },

  -- Conditional: 〜れば (Ichidan)
  { "れば", "る", 1 },
  -- Potential Ichidan: 〜られる (already above)

  -- Past / ta-form Ichidan: 〜た
  { "た", "る", 1 },
  -- Te-form Ichidan: 〜て
  { "て", "る", 1 },
  -- Volitional Ichidan: 〜よう
  { "よう", "る", 1 },
  -- Imperative Ichidan: 〜ろ / 〜よ
  { "ろ", "る", 1 },
  { "よ", "る", 1 },

  -- -------------------------------------------------------------------------
  -- Godan (う-verb) conjugation reversal
  -- Each godan column ends in a different vowel row:
  --   dict  | a-row | i-row | te/ta | e-row
  --   く    | か    | き    | いて  | け
  --   ぐ    | が    | ぎ    | いで  | げ
  --   す    | さ    | し    | して  | せ
  --   つ    | た    | ち    | って  | て
  --   ぬ    | な    | に    | んで  | ね
  --   ぶ    | ば    | び    | んで  | べ
  --   む    | ま    | み    | んで  | め
  --   る    | ら    | り    | って  | れ
  --   う    | わ    | い    | って  | え
  -- -------------------------------------------------------------------------

  -- Godan polite negative past
  { "きませんでした", "く", 1 },
  { "ぎませんでした", "ぐ", 1 },
  { "しませんでした", "す", 1 },
  { "ちませんでした", "つ", 1 },
  { "にませんでした", "ぬ", 1 },
  { "びませんでした", "ぶ", 1 },
  { "みませんでした", "む", 1 },
  { "りませんでした", "る", 1 },
  { "いませんでした", "う", 1 },

  -- Godan polite negative: 〜ません
  { "きません", "く", 1 },
  { "ぎません", "ぐ", 1 },
  { "しません", "す", 1 },
  { "ちません", "つ", 1 },
  { "にません", "ぬ", 1 },
  { "びません", "ぶ", 1 },
  { "みません", "む", 1 },
  { "りません", "る", 1 },
  { "いません", "う", 1 },

  -- Godan polite past: 〜ました
  { "きました", "く", 1 },
  { "ぎました", "ぐ", 1 },
  { "しました", "す", 1 },
  { "ちました", "つ", 1 },
  { "にました", "ぬ", 1 },
  { "びました", "ぶ", 1 },
  { "みました", "む", 1 },
  { "りました", "る", 1 },
  { "いました", "う", 1 },

  -- Godan polite: 〜ます
  { "きます", "く", 1 },
  { "ぎます", "ぐ", 1 },
  { "します", "す", 1 },
  { "ちます", "つ", 1 },
  { "にます", "ぬ", 1 },
  { "びます", "ぶ", 1 },
  { "みます", "む", 1 },
  { "ります", "る", 1 },
  { "います", "う", 1 },

  -- Godan negative past: 〜なかった
  { "かなかった", "く", 1 },
  { "がなかった", "ぐ", 1 },
  { "さなかった", "す", 1 },
  { "たなかった", "つ", 1 },
  { "ななかった", "ぬ", 1 },
  { "ばなかった", "ぶ", 1 },
  { "まなかった", "む", 1 },
  { "らなかった", "る", 1 },
  { "わなかった", "う", 1 },

  -- Godan negative: 〜ない
  { "かない", "く", 1 },
  { "がない", "ぐ", 1 },
  { "さない", "す", 1 },
  { "たない", "つ", 1 },
  { "なない", "ぬ", 1 },
  { "ばない", "ぶ", 1 },
  { "まない", "む", 1 },
  { "らない", "る", 1 },
  { "わない", "う", 1 },

  -- Godan te-iru (progressive): 〜いている
  { "いている", "く", 1 },
  { "いでいる", "ぐ", 1 },
  { "していている", "す", 1 },  -- rare but handled
  { "っている", "つ", 1 },
  { "んでいる", "ぬ", 1 },
  { "んでいる", "ぶ", 1 },
  { "んでいる", "む", 1 },
  { "っている", "る", 1 },
  { "っている", "う", 1 },

  -- Godan te-form + た/て (past/te)
  -- く → いた / いて
  { "いた", "く", 1 },
  { "いて", "く", 1 },
  -- ぐ → いだ / いで
  { "いだ", "ぐ", 1 },
  { "いで", "ぐ", 1 },
  -- す → した / して
  { "した", "す", 1 },
  { "して", "す", 1 },
  -- つ → った / って
  { "った", "つ", 1 },
  { "って", "つ", 1 },
  -- ぬ → んだ / んで
  { "んだ", "ぬ", 1 },
  { "んで", "ぬ", 1 },
  -- ぶ → んだ / んで
  { "んだ", "ぶ", 1 },
  { "んで", "ぶ", 1 },
  -- む → んだ / んで
  { "んだ", "む", 1 },
  { "んで", "む", 1 },
  -- る → った / って  (Godan る)
  { "った", "る", 1 },
  { "って", "る", 1 },
  -- う → った / って
  { "った", "う", 1 },
  { "って", "う", 1 },

  -- Godan conditional: 〜eba row (e-row + ば)
  { "けば", "く", 1 },
  { "げば", "ぐ", 1 },
  { "せば", "す", 1 },
  { "てば", "つ", 1 },
  { "ねば", "ぬ", 1 },
  { "べば", "ぶ", 1 },
  { "めば", "む", 1 },
  { "れば", "る", 1 },
  { "えば", "う", 1 },

  -- Godan potential: e-row + る
  { "ける", "く", 1 },
  { "げる", "ぐ", 1 },
  { "せる", "す", 1 },
  { "てる", "つ", 1 },
  { "ねる", "ぬ", 1 },
  { "べる", "ぶ", 1 },
  { "める", "む", 1 },
  { "れる", "る", 1 },
  { "える", "う", 1 },

  -- Godan passive: a-row + れる
  { "かれる", "く", 1 },
  { "がれる", "ぐ", 1 },
  { "される", "す", 1 },
  { "たれる", "つ", 1 },
  { "なれる", "ぬ", 1 },
  { "ばれる", "ぶ", 1 },
  { "まれる", "む", 1 },
  { "られる", "る", 1 },
  { "われる", "う", 1 },

  -- Godan causative: a-row + せる/させる
  { "かせる", "く", 1 },
  { "がせる", "ぐ", 1 },
  { "させる", "す", 1 },
  { "たせる", "つ", 1 },
  { "なせる", "ぬ", 1 },
  { "ばせる", "ぶ", 1 },
  { "ませる", "む", 1 },
  { "らせる", "る", 1 },
  { "わせる", "う", 1 },

  -- Godan volitional: o-row + う
  { "こう", "く", 1 },
  { "ごう", "ぐ", 1 },
  { "そう", "す", 1 },
  { "とう", "つ", 1 },
  { "のう", "ぬ", 1 },
  { "ぼう", "ぶ", 1 },
  { "もう", "む", 1 },
  { "ろう", "る", 1 },
  { "おう", "う", 1 },

  -- Godan imperative: e-row bare
  { "け", "く", 1 },
  { "げ", "ぐ", 1 },
  { "せ", "す", 1 },
  { "て", "つ", 1 },
  { "ね", "ぬ", 1 },
  { "べ", "ぶ", 1 },
  { "め", "む", 1 },
  { "れ", "る", 1 },
  { "え", "う", 1 },

  -- Godan masu-stem (i-row): used in compounds but also standalone misses
  { "き", "く", 1 },
  { "ぎ", "ぐ", 1 },
  { "し", "す", 1 },
  { "ち", "つ", 1 },
  { "に", "ぬ", 1 },
  { "び", "ぶ", 1 },
  { "み", "む", 1 },
  { "り", "る", 1 },
  { "い", "う", 1 },
}

-- Irregular verb hard-coded mappings.
-- Key: conjugated kana suffix that appears at the END of the full word.
-- Value: { stem_kana_suffix_to_strip, replacement } where the FULL word's
-- kana tail is replaced.  Simpler: we list full kana-tail patterns.
-- For compound する verbs (愛する, 勉強する) we handle the する/する tail specially.
local IRREGULAR_RULES = {
  -- くる (来る) forms
  { "きた",     "くる" },
  { "きて",     "くる" },
  { "きない",   "くる" },
  { "きません", "くる" },
  { "きます",   "くる" },
  { "こない",   "くる" },
  { "こよう",   "くる" },
  { "こられる", "くる" },
  { "こい",     "くる" },
  { "くれば",   "くる" },
  { "きた",     "くる" },
  -- する forms
  { "した",     "する" },
  { "して",     "する" },
  { "しない",   "する" },
  { "しません", "する" },
  { "しました", "する" },
  { "します",   "する" },
  { "しよう",   "する" },
  { "される",   "する" },
  { "させる",   "する" },
  { "すれば",   "する" },
  { "しろ",     "する" },
  { "せよ",     "する" },
  { "できる",   "する" },  -- potential of する (informal)
}

local function deinflect(word)
  if not word or #word == 0 then return {} end

  local seen = {}
  local candidates = {}

  local function add(c)
    if not seen[c] and c ~= word then
      seen[c] = true
      candidates[#candidates + 1] = c
    end
  end

  -- 1. Irregular rules: match kana tail of `word`.
  for _, rule in ipairs(IRREGULAR_RULES) do
    local conj_tail, dict_tail = rule[1], rule[2]
    -- Check if `word` ends with conj_tail (byte suffix match).
    if #word >= #conj_tail and word:sub(- #conj_tail) == conj_tail then
      local stem = word:sub(1, #word - #conj_tail)
      -- For plain する/くる (no kanji stem), the stem is empty and we just
      -- return the dict_tail itself.
      if stem == "" then
        add(dict_tail)
      else
        add(stem .. dict_tail)
      end
    end
  end

  -- 2. Compound する verbs: if word ends in する conjugations, try 〜する.
  -- Already handled above for する itself; here handle 〜する where the word
  -- has a kanji/kana stem before する.
  -- e.g. 勉強した → check 勉強 + する path via "した" → "する" above.
  -- Already covered; no extra work needed.

  -- 3. General rules: strip suffix, append replacement.
  for _, rule in ipairs(DEINFLECT_RULES) do
    local suffix, repl, min_cp = rule[1], rule[2], rule[3]
    local suf_len = #suffix
    if #word > suf_len and word:sub(-suf_len) == suffix then
      local stem = word:sub(1, #word - suf_len)
      -- Ensure the stem has at least min_cp codepoints.
      if utf8_len(stem) >= min_cp then
        add(stem .. repl)
      end
    end
  end

  return candidates
end

-- ---------------------------------------------------------------------------
-- Lookup (async-aware due to vim.ui.select)
-- ---------------------------------------------------------------------------

local function lookup_kanji_async(kanji, callback)
  local idx = load_index()
  local readings = idx and idx[kanji] or nil

  if not readings or #readings == 0 then
    -- Before giving up, attempt verb deinflection: generate candidate
    -- dictionary forms and look each one up in the index.
    local candidates = deinflect(kanji)
    for _, dict_form in ipairs(candidates) do
      local alt = idx and idx[dict_form] or nil
      if alt and #alt > 0 then
        -- Delegate to the same function so on_multiple_readings logic is reused.
        lookup_kanji_async(dict_form, callback)
        return
      end
    end

    if M.options.fallback_to_web then
      local r = web_lookup_kanji(kanji)
      if r then callback(r) else notify("No reading found for: " .. kanji) end
    else
      notify("No reading found for: " .. kanji)
    end
    return
  end

  if #readings == 1 then
    callback(readings[1])
    return
  end

  local mode = M.options.on_multiple_readings
  if mode == "first" then
    callback(readings[1])
  elseif mode == "all" then
    callback(table.concat(readings, "/"))
  else
    vim.ui.select(readings, {
      prompt = "Reading for " .. kanji .. ":",
    }, function(choice)
      if choice then callback(choice) end
    end)
  end
end

local function lookup_hiragana_async(reading, callback)
  local idx = load_reverse_index()
  local matches = idx and idx[reading] or nil

  if not matches or #matches == 0 then
    notify("No kanji found for: " .. reading)
    return
  end

  if #matches == 1 then
    callback(matches[1])
    return
  end

  local mode = M.options.on_multiple_kanji
  if mode == "first" then
    callback(matches[1])
  elseif mode == "all" then
    callback(table.concat(matches, "/"))
  else
    vim.ui.select(matches, {
      prompt = "Kanji for " .. reading .. ":",
    }, function(choice)
      if choice then callback(choice) end
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Insertion helpers
-- ---------------------------------------------------------------------------

local function enclose_in_parentheses(text)
  return "(" .. text .. ")"
end

local function get_visual_selection()
  local a_save = vim.fn.getreg('a')
  local a_save_type = vim.fn.getregtype('a')
  vim.cmd('normal! "ay')
  vim.cmd('normal! `>')
  local selection = vim.fn.getreg('a')
  vim.fn.setreg('a', a_save, a_save_type)
  return selection
end

-- Insert text after the position of the '> mark in the given buffer. Robust
-- against the user moving the cursor while vim.ui.select is open. The '> mark
-- column is the byte offset of the *first* byte of the last selected
-- character, so we must skip the full UTF-8 codepoint width.
local function insert_after_mark(bufnr, mark, text)
  local pos = vim.api.nvim_buf_get_mark(bufnr, mark)
  local row, col = pos[1], pos[2]
  if row == 0 then return end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local b = line:byte(col + 1) or 0
  local char_len = 1
  if b >= 0xF0 then char_len = 4
  elseif b >= 0xE0 then char_len = 3
  elseif b >= 0xC0 then char_len = 2
  end
  local insert_col = math.min(col + char_len, #line)
  vim.api.nvim_buf_set_text(bufnr, row - 1, insert_col, row - 1, insert_col, { text })
end

local function lookup_and_write_after_visual_selection()
  local selected_text = get_visual_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  lookup_kanji_async(selected_text, function(hiragana)
    if hiragana then
      insert_after_mark(bufnr, '>', enclose_in_parentheses(hiragana))
    end
  end)
end

local function lookup_and_write_after_current_word()
  local kanji = vim.fn.expand("<cword>")
  local bufnr = vim.api.nvim_get_current_buf()
  -- Compute the insertion point without cursor motion to avoid the `normal! e`
  -- overshoot: when <cword> is a single character already at a word-end, `e`
  -- jumps forward to the *next* word-end, placing the hiragana at the wrong
  -- position (e.g. end of line instead of right after the kanji).
  --
  -- Strategy: use searchpos with flags 'bcn' (backward from cursor, accept
  -- match at cursor position, don't move cursor) to locate the byte column of
  -- the first byte of <cword>, then advance by #kanji bytes to land immediately
  -- after the last byte of the word. This is stable across an async
  -- vim.ui.select call because the position is captured before the call.
  local insert_row = vim.api.nvim_win_get_cursor(0)[1]
  -- searchpos returns {row, col} 1-indexed; col 0 means not found.
  local found = vim.fn.searchpos("\\V\\<" .. vim.fn.escape(kanji, "\\"), "bcn")
  local word_start_col
  if found[1] > 0 then
    word_start_col = found[2] - 1  -- convert to 0-indexed byte column
  else
    -- Fallback: use current cursor column (handles edge cases where the word
    -- boundary pattern doesn't match, e.g. non-keyword context).
    word_start_col = vim.api.nvim_win_get_cursor(0)[2]
  end
  -- Byte offset immediately after the last byte of <cword>; #kanji counts all
  -- bytes in the word string so no per-character UTF-8 width math is needed.
  local insert_col_pre = word_start_col + #kanji

  lookup_kanji_async(kanji, function(hiragana)
    if not hiragana then return end
    local line = vim.api.nvim_buf_get_lines(bufnr, insert_row - 1, insert_row, false)[1] or ""
    local insert_col = math.min(insert_col_pre, #line)
    vim.api.nvim_buf_set_text(bufnr, insert_row - 1, insert_col, insert_row - 1, insert_col,
      { enclose_in_parentheses(hiragana) })
  end)
end

-- Insert text at the position of the given mark (i.e. immediately *before*
-- the marked byte). Used by the reverse mapping to prepend kanji directly in
-- front of the source hiragana.
local function insert_at_mark(bufnr, mark, text)
  local pos = vim.api.nvim_buf_get_mark(bufnr, mark)
  local row, col = pos[1], pos[2]
  if row == 0 then return end
  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { text })
end

local function lookup_and_write_before_visual_selection_kanji()
  local selected_text = get_visual_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  lookup_hiragana_async(selected_text, function(kanji)
    if kanji then
      insert_at_mark(bufnr, '<', kanji)
    end
  end)
end

local function lookup_and_write_before_current_word_kanji()
  local reading = vim.fn.expand("<cword>")
  local bufnr = vim.api.nvim_get_current_buf()
  -- Capture the position of the *first* byte of the current word so we can
  -- prepend the chosen kanji even after vim.ui.select returns asynchronously.
  local save_pos = vim.api.nvim_win_get_cursor(0)
  vim.cmd('normal! b')
  local start_row, start_col = unpack(vim.api.nvim_win_get_cursor(0))
  -- If the cursor was already mid-word on a non-keyword boundary, `b` may
  -- have moved to the previous word. In practice <cword> + `b` lands at the
  -- first byte of <cword> for typical hiragana sequences, but we restore the
  -- original position regardless.
  vim.api.nvim_win_set_cursor(0, save_pos)

  lookup_hiragana_async(reading, function(kanji)
    if not kanji then return end
    vim.api.nvim_buf_set_text(bufnr, start_row - 1, start_col,
      start_row - 1, start_col, { kanji })
  end)
end

-- ---------------------------------------------------------------------------
-- Dictionary download
-- ---------------------------------------------------------------------------

local function download_dictionary(callback)
  local url = M.options.dictionary_url
  local dest = M.options.dictionary_path

  if vim.fn.executable("curl") ~= 1 then
    report_error({ "curl is required to download the dictionary; not found in $PATH." })
    if callback then callback(false) end
    return
  end

  -- Ensure the destination directory exists.
  local dir = vim.fn.fnamemodify(dest, ":h")
  vim.fn.mkdir(dir, "p")

  local tmp = dest .. ".download"
  notify("Downloading " .. url .. " ...")

  local cmd = { "curl", "--fail", "--location", "--silent", "--show-error",
    "--output", tmp, url }

  local function on_exit(obj)
    local code = obj.code or obj
    if code ~= 0 then
      pcall(os.remove, tmp)
      local stderr = (type(obj) == "table" and obj.stderr) or ""
      report_error({
        "Failed to download dictionary (curl exit " .. tostring(code) .. ").",
        stderr ~= "" and stderr or "URL: " .. url,
      })
      if callback then callback(false) end
      return
    end
    local ok, err = os.rename(tmp, dest)
    if not ok then
      report_error({ "Failed to move downloaded file to " .. dest .. ": " .. tostring(err) })
      pcall(os.remove, tmp)
      if callback then callback(false) end
      return
    end
    -- Invalidate caches so the next lookup rebuilds from the fresh source.
    M._index = nil
    M._reverse_index = nil
    pcall(os.remove, M.options.cache_path)
    pcall(os.remove, M.options.reverse_cache_path)
    notify("Dictionary saved to " .. dest)
    if callback then callback(true) end
  end

  if vim.system then
    -- Neovim 0.10+: async, non-blocking.
    vim.system(cmd, { text = true }, vim.schedule_wrap(on_exit))
  else
    -- Fallback for older Neovim: synchronous.
    local out = vim.fn.system(cmd)
    on_exit({ code = vim.v.shell_error, stderr = out })
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

M.setup = function(options)
  M.options = vim.tbl_deep_extend("force", default_options, options or {})

  vim.keymap.set(
    "x",
    M.options.visual_mode_keymap,
    function() lookup_and_write_after_visual_selection() end,
    vim.tbl_extend("force", M.options.keymap_options, { desc = "Kanji to Hiragana (Visual Mode)" })
  )
  vim.keymap.set(
    "n",
    M.options.normal_mode_keymap,
    function() lookup_and_write_after_current_word() end,
    vim.tbl_extend("force", M.options.keymap_options, { desc = "Kanji to Hiragana (Normal Mode)" })
  )

  vim.keymap.set(
    "x",
    M.options.visual_mode_keymap_reverse,
    function() lookup_and_write_before_visual_selection_kanji() end,
    vim.tbl_extend("force", M.options.keymap_options, { desc = "Hiragana to Kanji (Visual Mode)" })
  )
  vim.keymap.set(
    "n",
    M.options.normal_mode_keymap_reverse,
    function() lookup_and_write_before_current_word_kanji() end,
    vim.tbl_extend("force", M.options.keymap_options, { desc = "Hiragana to Kanji (Normal Mode)" })
  )

  vim.api.nvim_create_user_command("KanjiToHiraganaRebuildIndex", function()
    M._index = nil
    M._reverse_index = nil
    pcall(os.remove, M.options.cache_path)
    pcall(os.remove, M.options.reverse_cache_path)
    if load_index(true) then
      notify("Index rebuilt.")
    end
  end, { desc = "Rebuild the JmdictFurigana lookup index" })

  vim.api.nvim_create_user_command("KanjiToHiraganaDownloadDictionary", function()
    download_dictionary()
  end, { desc = "Download the latest JmdictFurigana.txt to dictionary_path" })
end

-- ---------------------------------------------------------------------------
-- Test-only surface (not stable API)
-- ---------------------------------------------------------------------------

M._defaults_for_test = function()
  return vim.deepcopy(default_options)
end

M._internal = {
  build_index_from_txt = build_index_from_txt,
  serialize_index = serialize_index,
  load_cached_index = load_cached_index,
  load_index = load_index,
  build_reverse_index_from_txt = build_reverse_index_from_txt,
  load_reverse_index = load_reverse_index,
  lookup_kanji_async = lookup_kanji_async,
  lookup_hiragana_async = lookup_hiragana_async,
  download_dictionary = download_dictionary,
  deinflect = deinflect,
  set_notify = function(fn)
    notify_fn = fn or function() end
  end,
  set_web_lookup = function(fn)
    web_lookup_kanji = fn
  end,
}

return M
