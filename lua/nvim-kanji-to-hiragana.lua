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
-- Lookup (async-aware due to vim.ui.select)
-- ---------------------------------------------------------------------------

local function lookup_kanji_async(kanji, callback)
  local idx = load_index()
  local readings = idx and idx[kanji] or nil

  if not readings or #readings == 0 then
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
  -- Capture position of the end byte of the current word, so insertion still
  -- lands correctly even if vim.ui.select runs asynchronously.
  local save_pos = vim.api.nvim_win_get_cursor(0)
  vim.cmd('normal! e')
  local end_row, end_col = unpack(vim.api.nvim_win_get_cursor(0))
  vim.api.nvim_win_set_cursor(0, save_pos)

  lookup_kanji_async(kanji, function(hiragana)
    if not hiragana then return end
    local line = vim.api.nvim_buf_get_lines(bufnr, end_row - 1, end_row, false)[1] or ""
    local b = line:byte(end_col + 1) or 0
    local char_len = 1
    if b >= 0xF0 then char_len = 4
    elseif b >= 0xE0 then char_len = 3
    elseif b >= 0xC0 then char_len = 2
    end
    local insert_col = math.min(end_col + char_len, #line)
    vim.api.nvim_buf_set_text(bufnr, end_row - 1, insert_col, end_row - 1, insert_col,
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
  set_notify = function(fn)
    notify_fn = fn or function() end
  end,
  set_web_lookup = function(fn)
    web_lookup_kanji = fn
  end,
}

return M
