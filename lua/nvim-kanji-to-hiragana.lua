local M = {}

local default_options = {
  visual_mode_keymap = "<leader>hi",
  normal_mode_keymap = "<leader>hi",
  keymap_options = { noremap = true, silent = true },
  url_template = "https://jisho.org/word/{}",
}

-- URL encode a string (for Japanese characters)
local function url_encode(str)
  -- Use curl's built-in URL encoding via --data-urlencode and extract the result
  -- This avoids dependency on python3
  local encoded = ""
  for i = 1, #str do
    local byte = string.byte(str, i)
    -- Check if it's a safe character (alphanumeric or -_.~)
    if (byte >= 48 and byte <= 57) or                              -- 0-9
        (byte >= 65 and byte <= 90) or                             -- A-Z
        (byte >= 97 and byte <= 122) or                            -- a-z
        byte == 45 or byte == 46 or byte == 95 or byte == 126 then -- -._~
      encoded = encoded .. string.char(byte)
    else
      encoded = encoded .. string.format("%%%02X", byte)
    end
  end
  return encoded
end

-- Extract hiragana reading from Jisho.org HTML response
local function parse_jisho_html(html, word)
  -- The reading is found in the concept_light-representation div
  -- Structure: <span class="furigana">...</span> followed by <span class="text">...</span>
  --
  -- Jisho.org HTML patterns:
  -- 1. For "食べる": furigana has <span>た</span><span></span><span></span>
  --    text has: 食<span>べ</span><span>る</span>
  --    Result: た + べ + る = たべる
  --
  -- 2. For "日本": furigana has <span>にほん</span><span></span>
  --    text has: 日本 (no spans)
  --    Result: にほん (the furigana covers both kanji)
  --
  -- Strategy: Collect all furigana readings (non-empty only) and all text characters,
  -- then build the result by using furigana for kanji and original chars for hiragana

  -- First, try to find the concept_light-representation block
  local representation = html:match('<div class="concept_light%-representation"[^>]*>(.-)</div>')
  if not representation then
    return nil
  end

  -- Normalize whitespace for easier parsing
  representation = representation:gsub("%s+", " ")

  -- Extract furigana block - content between furigana span and text span
  local furigana_block = representation:match('<span class="furigana">(.-)</span> <span class="text">')
  if not furigana_block then
    furigana_block = representation:match('<span class="furigana">(.-)</span>')
  end

  if not furigana_block then
    return nil
  end

  -- Extract text block - need to handle nested spans properly
  -- Find where <span class="text"> starts and extract content until its matching </span>
  local text_tag = '<span class="text">'
  local text_start = representation:find(text_tag, 1, true)
  if not text_start then
    return nil
  end

  local after_text_tag = representation:sub(text_start + #text_tag)
  local text_block = nil

  -- Find the closing </span> for the text span by counting depth
  local depth = 0
  local pos = 1
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

  if not text_block then
    return nil
  end

  -- Trim whitespace from text_block
  text_block = text_block:gsub("^%s+", ""):gsub("%s+$", "")

  -- Collect all non-empty furigana readings in order
  local furigana_readings = {}
  for span_content in furigana_block:gmatch('<span[^>]*>(.-)</span>') do
    if span_content ~= "" then
      table.insert(furigana_readings, span_content)
    end
  end

  -- Collect text parts: hiragana/katakana are in <span>X</span>, kanji are raw text
  -- We need to know which parts are hiragana (in spans) vs kanji (raw)
  local text_parts = {}
  pos = 1
  while pos <= #text_block do
    local span_start, span_end, span_content = text_block:find('<span>(.-)</span>', pos)
    if span_start == pos then
      -- This is hiragana/katakana in a span - use as-is
      table.insert(text_parts, { content = span_content, is_kana = true })
      pos = span_end + 1
    else
      -- Raw text before the next span (or end of string) - these are kanji
      local next_span = text_block:find('<span>', pos)
      local chunk
      if next_span then
        chunk = text_block:sub(pos, next_span - 1)
      else
        chunk = text_block:sub(pos)
      end
      -- The entire chunk of kanji has a single furigana reading
      chunk = chunk:gsub("^%s+", ""):gsub("%s+$", "")
      if chunk ~= "" then
        table.insert(text_parts, { content = chunk, is_kana = false })
      end
      if next_span then
        pos = next_span
      else
        break
      end
    end
  end

  -- Build the result: for kanji parts use furigana readings, for kana use as-is
  -- When multiple consecutive kanji share furigana readings, concatenate all remaining readings
  local result = {}
  local furigana_idx = 1
  for i, part in ipairs(text_parts) do
    if part.is_kana then
      -- Hiragana/katakana - use as-is
      table.insert(result, part.content)
    else
      -- Kanji chunk - use all remaining furigana readings up to the next kana part
      -- Count how many furigana readings belong to this kanji chunk
      -- by looking ahead to see if there's another kanji chunk after the next kana parts
      local readings_for_chunk = {}

      -- Find the next kanji chunk index (if any)
      local next_kanji_idx = nil
      for j = i + 1, #text_parts do
        if not text_parts[j].is_kana then
          next_kanji_idx = j
          break
        end
      end

      -- Calculate how many furigana readings are left for remaining kanji chunks
      local remaining_kanji_chunks = 0
      for j = i + 1, #text_parts do
        if not text_parts[j].is_kana then
          remaining_kanji_chunks = remaining_kanji_chunks + 1
        end
      end

      -- This chunk gets: (remaining furigana) - (furigana needed for remaining kanji chunks)
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
        -- Fallback: no furigana available, use original
        table.insert(result, part.content)
      end
    end
  end

  local hiragana = table.concat(result, "")
  if hiragana == "" then
    return nil
  end
  return hiragana
end

local function lookup_kanji(kanji)
  local encoded_kanji = url_encode(kanji)
  -- Use plain string replacement to avoid % being interpreted as capture reference
  local url = M.options.url_template:gsub("{}", encoded_kanji:gsub("%%", "%%%%"))
  local result = vim.fn.system({ "curl", "-s", "-L", url })
  if vim.v.shell_error ~= 0 then
    print("Error fetching data: " .. result)
    return nil
  end

  local hiragana = parse_jisho_html(result, kanji)
  if not hiragana then
    print("No reading found for: " .. kanji)
    return nil
  end
  return hiragana
end

local function enclose_in_parentheses(text)
  return "(" .. text .. ")"
end

local function get_visual_selection()
  -- Save the current register 'a' content
  local a_save = vim.fn.getreg('a')
  local a_save_type = vim.fn.getregtype('a')

  -- Yank the visual selection to register 'a'
  vim.cmd('normal! "ay')

  -- Move cursor to end of the visual selection (using `> mark)
  vim.cmd('normal! `>')

  -- Get the yanked text
  local selection = vim.fn.getreg('a')

  -- Restore the original register 'a' content
  vim.fn.setreg('a', a_save, a_save_type)

  return selection
end

local function lookup_and_write_after_visual_selection()
  local selected_text = get_visual_selection()
  local hiragana = lookup_kanji(selected_text)
  if hiragana then
    -- enclosde hiragana in parentheses to visually separate it from the kanji
    local enclosed_hiragana = enclose_in_parentheses(hiragana)
    vim.api.nvim_put({ enclosed_hiragana }, "c", true, true)
  end
end

local function lookup_and_write_after_current_word()
  local kanji = vim.fn.expand("<cword>")
  local hiragana = lookup_kanji(kanji)
  if hiragana then
    local enclosed_hiragana = enclose_in_parentheses(hiragana)
    vim.api.nvim_put({ enclosed_hiragana }, "c", true, true)
  end
end

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
end

return M
