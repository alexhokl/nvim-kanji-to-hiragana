local h = require("tests.helpers")
local plugin = require("nvim-kanji-to-hiragana")
local internal = plugin._internal

local FIXTURE = vim.fn.getcwd() .. "/tests/fixtures/sample.txt"
local FIXTURE_CRLF = vim.fn.getcwd() .. "/tests/fixtures/sample_crlf.txt"

local function reset_options()
  plugin.options = plugin._defaults_for_test()
  plugin._index = nil
end

local function silence_notify()
  internal.set_notify(function() end)
end

describe("build_index_from_txt", function()
  before_each(function()
    reset_options()
    silence_notify()
  end)

  it("parses single readings", function()
    local idx = internal.build_index_from_txt(FIXTURE)
    assert.are.same({ "たべる" }, idx["食べる"])
    assert.are.same({ "にほん" }, idx["日本"])
    assert.are.same({ "ひとびと" }, idx["人々"])
  end)

  it("aggregates multi-reading homographs in file order", function()
    local idx = internal.build_index_from_txt(FIXTURE)
    assert.are.same({ "きょう", "こんにち" }, idx["今日"])
  end)

  it("dedupes identical (text,reading) pairs", function()
    -- 食べる|たべる appears twice in the fixture
    local idx = internal.build_index_from_txt(FIXTURE)
    assert.are.equal(1, #idx["食べる"])
  end)

  it("skips lines without a pipe", function()
    local idx = internal.build_index_from_txt(FIXTURE)
    assert.is_nil(idx["malformed-line-no-pipe"])
  end)

  it("skips lines with empty text or empty reading", function()
    local idx = internal.build_index_from_txt(FIXTURE)
    assert.is_nil(idx[""])
    assert.is_nil(idx["text-only-no-reading"])
  end)

  it("returns nil when file is missing", function()
    local restore = h.stub(vim.api, "nvim_echo", function() end)
    local idx = internal.build_index_from_txt("/nonexistent/path/JmdictFurigana.txt")
    restore()
    assert.is_nil(idx)
  end)

  it("handles CRLF line endings", function()
    local idx = internal.build_index_from_txt(FIXTURE_CRLF)
    assert.are.same({ "たべる" }, idx["食べる"])
    assert.are.same({ "にほん" }, idx["日本"])
  end)
end)

describe("serialize_index", function()
  before_each(function()
    reset_options()
    silence_notify()
  end)

  it("round-trips via loadfile", function()
    local idx = {
      ["食べる"] = { "たべる" },
      ["今日"]   = { "きょう", "こんにち" },
    }
    local path = vim.fn.tempname()
    assert.is_true(internal.serialize_index(idx, path))
    local chunk = assert(loadfile(path))
    local loaded = chunk()
    assert.are.same(idx["食べる"], loaded["食べる"])
    assert.are.same(idx["今日"], loaded["今日"])
    os.remove(path)
  end)

  it("escapes special characters in keys and values", function()
    local idx = {
      ['quote"key']  = { 'with "quote' },
      ['back\\key']  = { 'back\\slash' },
      ['newline\nk'] = { 'tab\treading' },
    }
    local path = vim.fn.tempname()
    assert.is_true(internal.serialize_index(idx, path))
    local loaded = assert(loadfile(path))()
    assert.are.same(idx['quote"key'], loaded['quote"key'])
    assert.are.same(idx['back\\key'], loaded['back\\key'])
    assert.are.same(idx['newline\nk'], loaded['newline\nk'])
    os.remove(path)
  end)

  it("returns false when the cache path is unwritable", function()
    local ok = internal.serialize_index({}, "/nonexistent/dir/cache.lua")
    assert.is_false(ok)
  end)
end)

describe("cache invalidation", function()
  before_each(function()
    reset_options()
    silence_notify()
  end)

  it("returns nil when source is newer than cache", function()
    local source = vim.fn.tempname()
    local cache = vim.fn.tempname()
    h.write_file(source, "食べる|たべる|0:た\n")
    h.write_file(cache, "return { foo = 1 }\n")
    -- Make cache older than source
    h.set_mtime(cache, 1000)
    h.set_mtime(source, 2000)
    local idx = internal.load_cached_index(cache, source)
    assert.is_nil(idx)
    os.remove(source); os.remove(cache)
  end)

  it("loads cache when cache is at-or-newer than source", function()
    local source = vim.fn.tempname()
    local cache = vim.fn.tempname()
    h.write_file(source, "食べる|たべる|0:た\n")
    h.write_file(cache, [[return { ["食べる"] = { "たべる" } }]])
    h.set_mtime(source, 1000)
    h.set_mtime(cache, 2000)
    local idx = internal.load_cached_index(cache, source)
    assert.are.same({ "たべる" }, idx["食べる"])
    os.remove(source); os.remove(cache)
  end)

  it("returns nil when either file is missing", function()
    assert.is_nil(internal.load_cached_index("/no/cache", "/no/source"))
  end)

  it("returns nil and notifies on corrupt cache", function()
    local source = vim.fn.tempname()
    local cache = vim.fn.tempname()
    h.write_file(source, "x|y|0:x\n")
    h.write_file(cache, "this is not lua {{{")
    h.set_mtime(source, 1000)
    h.set_mtime(cache, 2000)
    local idx = internal.load_cached_index(cache, source)
    assert.is_nil(idx)
    os.remove(source); os.remove(cache)
  end)
end)

describe("load_index", function()
  before_each(function()
    reset_options()
    silence_notify()
  end)

  it("builds and caches on first call, then loads from cache", function()
    local source = vim.fn.tempname()
    local cache = vim.fn.tempname()
    os.remove(cache) -- ensure fresh
    h.write_file(source, "食べる|たべる|0:た\n今日|きょう|0:きょう\n今日|こんにち|0:こん;1:にち\n")
    plugin.options.dictionary_path = source
    plugin.options.cache_path = cache

    local idx1 = internal.load_index()
    assert.are.same({ "たべる" }, idx1["食べる"])
    assert.are.same({ "きょう", "こんにち" }, idx1["今日"])

    -- Cache file should now exist
    assert.is_truthy(vim.loop.fs_stat(cache))

    -- Reset memoized index; reload should come from cache
    plugin._index = nil
    local idx2 = internal.load_index()
    assert.are.same(idx1, idx2)

    os.remove(source); os.remove(cache)
  end)

  it("returns nil when the source is missing", function()
    plugin.options.dictionary_path = "/no/such/file.txt"
    plugin.options.cache_path = vim.fn.tempname()
    -- Suppress nvim_echo error output during test
    local restore = h.stub(vim.api, "nvim_echo", function() end)
    local idx = internal.load_index(true)
    restore()
    assert.is_nil(idx)
  end)
end)

describe("lookup_kanji_async", function()
  before_each(function()
    reset_options()
    silence_notify()
    plugin._index = {
      ["食べる"] = { "たべる" },
      ["今日"]   = { "きょう", "こんにち" },
    }
  end)

  it("invokes callback with the only reading", function()
    local got
    internal.lookup_kanji_async("食べる", function(r) got = r end)
    assert.are.equal("たべる", got)
  end)

  it("picks first when on_multiple_readings='first'", function()
    plugin.options.on_multiple_readings = "first"
    local got
    internal.lookup_kanji_async("今日", function(r) got = r end)
    assert.are.equal("きょう", got)
  end)

  it("joins with / when on_multiple_readings='all'", function()
    plugin.options.on_multiple_readings = "all"
    local got
    internal.lookup_kanji_async("今日", function(r) got = r end)
    assert.are.equal("きょう/こんにち", got)
  end)

  it("invokes vim.ui.select for 'select' and forwards choice", function()
    plugin.options.on_multiple_readings = "select"
    local restore = h.stub(vim.ui, "select", function(items, _opts, on_choice)
      on_choice(items[2])
    end)
    local got
    internal.lookup_kanji_async("今日", function(r) got = r end)
    restore()
    assert.are.equal("こんにち", got)
  end)

  it("does not call back when select is cancelled", function()
    plugin.options.on_multiple_readings = "select"
    local restore = h.stub(vim.ui, "select", function(_items, _opts, on_choice)
      on_choice(nil)
    end)
    local called = false
    internal.lookup_kanji_async("今日", function(_) called = true end)
    restore()
    assert.is_false(called)
  end)

  it("notifies and skips callback on miss without web fallback", function()
    plugin.options.fallback_to_web = false
    local called = false
    local notified
    internal.set_notify(function(msg) notified = msg end)
    internal.lookup_kanji_async("missing", function(_) called = true end)
    silence_notify()
    assert.is_false(called)
    assert.is_truthy(notified and notified:find("No reading found", 1, true))
  end)

  it("calls web fallback on miss when enabled", function()
    plugin.options.fallback_to_web = true
    internal.set_web_lookup(function(_) return "てすと" end)
    local got
    internal.lookup_kanji_async("missing", function(r) got = r end)
    assert.are.equal("てすと", got)
  end)

  it("does not invoke callback if web fallback returns nil", function()
    plugin.options.fallback_to_web = true
    internal.set_web_lookup(function(_) return nil end)
    local called = false
    internal.lookup_kanji_async("missing", function(_) called = true end)
    assert.is_false(called)
  end)
end)

describe("download_dictionary", function()
  before_each(function()
    reset_options()
    silence_notify()
  end)

  it("writes file to dictionary_path and clears the cache on success", function()
    local dest = vim.fn.tempname()
    local cache = vim.fn.tempname()
    h.write_file(cache, "return {}")
    plugin.options.dictionary_path = dest
    plugin.options.cache_path = cache
    plugin._index = { foo = { "bar" } }

    -- Stub vim.system to simulate a successful curl by writing the expected
    -- temp file ourselves and reporting exit code 0.
    local restore = h.stub(vim, "system", function(cmd, _opts, on_exit)
      -- Locate "--output <path>" argument and write a payload there.
      for i, arg in ipairs(cmd) do
        if arg == "--output" then
          local out = cmd[i + 1]
          local f = assert(io.open(out, "wb"))
          f:write("食べる|たべる|0:た\n")
          f:close()
        end
      end
      on_exit({ code = 0, stderr = "" })
    end)

    local done
    internal.download_dictionary(function(ok) done = ok end)
    vim.wait(200, function() return done ~= nil end)
    restore()

    assert.is_true(done)
    assert.are.equal("食べる|たべる|0:た\n", h.read_file(dest))
    assert.is_nil(vim.loop.fs_stat(cache)) -- cache removed
    assert.is_nil(plugin._index)           -- in-memory index cleared
    os.remove(dest)
  end)

  it("reports failure and does not move file when curl exits non-zero", function()
    local dest = vim.fn.tempname() .. "-missing"
    plugin.options.dictionary_path = dest

    local restore = h.stub(vim, "system", function(_cmd, _opts, on_exit)
      on_exit({ code = 22, stderr = "HTTP 404" })
    end)
    local echo_restore = h.stub(vim.api, "nvim_echo", function() end)

    local done
    internal.download_dictionary(function(ok) done = ok end)
    vim.wait(200, function() return done ~= nil end)
    restore(); echo_restore()

    assert.is_false(done)
    assert.is_nil(vim.loop.fs_stat(dest))
  end)
end)

-- Helpers that replicate the fixed insertion logic from
-- lookup_and_write_after_current_word. Extracted here so each test case can
-- call them without duplicating the searchpos math.
local function insert_hiragana_after_cword(bufnr, kanji, hiragana)
  -- Mirror the production code: searchpos with 'bcn' finds the byte start of
  -- <cword> without moving the cursor, then we advance by #kanji bytes.
  local insert_row = vim.api.nvim_win_get_cursor(0)[1]
  local found = vim.fn.searchpos("\\V\\<" .. vim.fn.escape(kanji, "\\"), "bcn")
  local word_start_col
  if found[1] > 0 then
    word_start_col = found[2] - 1
  else
    word_start_col = vim.api.nvim_win_get_cursor(0)[2]
  end
  local insert_col_pre = word_start_col + #kanji
  local line = vim.api.nvim_buf_get_lines(bufnr, insert_row - 1, insert_row, false)[1] or ""
  local insert_col = math.min(insert_col_pre, #line)
  vim.api.nvim_buf_set_text(bufnr, insert_row - 1, insert_col, insert_row - 1, insert_col,
    { "(" .. hiragana .. ")" })
end

describe("normal-mode insertion", function()
  before_each(function()
    reset_options()
    silence_notify()
    plugin.options.on_multiple_readings = "first"
  end)

  it("inserts (てん) immediately after 点 in mid-sentence context", function()
    -- Regression test: previously `normal! e` overshot the single-char kanji
    -- and placed the hiragana at the end of the line.
    -- Expected: 点(てん)がもらえません。
    plugin._index = { ["点"] = { "てん" } }
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "点がもらえません。" })
    -- Place cursor on 点 (row 1, byte col 0)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local kanji = vim.fn.expand("<cword>")
    assert.are.equal("点", kanji)
    internal.lookup_kanji_async(kanji, function(hiragana)
      insert_hiragana_after_cword(bufnr, kanji, hiragana)
    end)

    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    assert.are.equal("点(てん)がもらえません。", line)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("inserts (とうきょう) immediately after 東京 in mid-sentence context", function()
    -- Multi-character all-kanji word mid-sentence. In Neovim's default iskeyword
    -- setting consecutive kanji characters form a single <cword>, so cursor on
    -- 東 (col 0) of "東京に行く。" yields <cword> = "東京".
    -- Expected: 東京(とうきょう)に行く。
    plugin._index = { ["東京"] = { "とうきょう" } }
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "東京に行く。" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local kanji = vim.fn.expand("<cword>")
    assert.are.equal("東京", kanji)
    internal.lookup_kanji_async(kanji, function(hiragana)
      insert_hiragana_after_cword(bufnr, kanji, hiragana)
    end)

    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    assert.are.equal("東京(とうきょう)に行く。", line)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("inserts (にほん) immediately after 日本 when cursor is on second character", function()
    -- Cursor placed on the second character 本 (byte col 3) rather than 日.
    -- searchpos 'bcn' should still find the word start at byte col 0.
    -- "日本は好きです。": 日本 is followed by kana so <cword> = "日本" from either byte.
    -- Expected: 日本(にほん)は好きです。
    plugin._index = { ["日本"] = { "にほん" } }
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "日本は好きです。" })
    -- 本 is the second UTF-8 character; each kanji is 3 bytes, so byte col 3.
    vim.api.nvim_win_set_cursor(0, { 1, 3 })

    local kanji = vim.fn.expand("<cword>")
    assert.are.equal("日本", kanji)
    internal.lookup_kanji_async(kanji, function(hiragana)
      insert_hiragana_after_cword(bufnr, kanji, hiragana)
    end)

    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    assert.are.equal("日本(にほん)は好きです。", line)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("inserts (とうきょう) after 東京 at the end of a line", function()
    -- Edge case: kanji is the last word on the line; insert_col must not
    -- exceed the line length.
    -- Expected: 東京(とうきょう)
    plugin._index = { ["東京"] = { "とうきょう" } }
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "東京" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local kanji = vim.fn.expand("<cword>")
    assert.are.equal("東京", kanji)
    internal.lookup_kanji_async(kanji, function(hiragana)
      insert_hiragana_after_cword(bufnr, kanji, hiragana)
    end)

    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    assert.are.equal("東京(とうきょう)", line)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
