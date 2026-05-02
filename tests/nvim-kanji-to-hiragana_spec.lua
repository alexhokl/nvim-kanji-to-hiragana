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
