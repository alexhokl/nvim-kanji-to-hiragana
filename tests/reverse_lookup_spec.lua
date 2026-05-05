local h = require("tests.helpers")
local plugin = require("nvim-kanji-to-hiragana")
local internal = plugin._internal

local FIXTURE = vim.fn.getcwd() .. "/tests/fixtures/sample.txt"

local function reset_options()
  plugin.options = plugin._defaults_for_test()
  plugin._index = nil
  plugin._reverse_index = nil
end

local function silence_notify()
  internal.set_notify(function() end)
end

describe("build_reverse_index_from_txt", function()
  before_each(function()
    reset_options()
    silence_notify()
  end)

  it("inverts text->reading into reading->{texts}", function()
    local idx = internal.build_reverse_index_from_txt(FIXTURE)
    assert.are.same({ "食べる" }, idx["たべる"])
    assert.are.same({ "日本" }, idx["にほん"])
    assert.are.same({ "人々" }, idx["ひとびと"])
  end)

  it("groups multiple kanji that share a reading", function()
    -- Add a homophone reading by writing a custom fixture.
    local path = vim.fn.tempname()
    h.write_file(path,
      "食べる|たべる|0:た\n" ..
      "下さい|ください|0:くだ\n" ..
      "ください|ください|\n")
    local idx = internal.build_reverse_index_from_txt(path)
    assert.are.same({ "下さい", "ください" }, idx["ください"])
    os.remove(path)
  end)

  it("dedupes identical (reading,text) pairs", function()
    -- 食べる|たべる appears twice in the fixture.
    local idx = internal.build_reverse_index_from_txt(FIXTURE)
    assert.are.equal(1, #idx["たべる"])
  end)

  it("returns nil when file is missing", function()
    local restore = h.stub(vim.api, "nvim_echo", function() end)
    local idx = internal.build_reverse_index_from_txt("/no/such/file.txt")
    restore()
    assert.is_nil(idx)
  end)
end)

describe("load_reverse_index", function()
  before_each(function()
    reset_options()
    silence_notify()
  end)

  it("builds and caches on first call, then loads from cache", function()
    local source = vim.fn.tempname()
    local cache = vim.fn.tempname()
    os.remove(cache)
    h.write_file(source,
      "食べる|たべる|0:た\n" ..
      "今日|きょう|0:きょう\n" ..
      "今日|こんにち|0:こん;1:にち\n")
    plugin.options.dictionary_path = source
    plugin.options.reverse_cache_path = cache

    local idx1 = internal.load_reverse_index()
    assert.are.same({ "食べる" }, idx1["たべる"])
    assert.are.same({ "今日" }, idx1["きょう"])
    assert.are.same({ "今日" }, idx1["こんにち"])

    -- Cache file should now exist.
    assert.is_truthy(vim.loop.fs_stat(cache))

    -- Reset memoized index; reload should come from cache.
    plugin._reverse_index = nil
    local idx2 = internal.load_reverse_index()
    assert.are.same(idx1, idx2)

    os.remove(source); os.remove(cache)
  end)

  it("rebuilds when source is newer than cache", function()
    local source = vim.fn.tempname()
    local cache = vim.fn.tempname()
    h.write_file(source, "食べる|たべる|0:た\n")
    h.write_file(cache, [[return { ["stale"] = { "stale" } }]])
    h.set_mtime(cache, 1000)
    h.set_mtime(source, 2000)
    plugin.options.dictionary_path = source
    plugin.options.reverse_cache_path = cache

    local idx = internal.load_reverse_index()
    assert.are.same({ "食べる" }, idx["たべる"])
    assert.is_nil(idx["stale"])

    os.remove(source); os.remove(cache)
  end)
end)

describe("lookup_hiragana_async", function()
  before_each(function()
    reset_options()
    silence_notify()
    plugin._reverse_index = {
      ["たべる"]   = { "食べる" },
      ["ください"] = { "下さい", "ください" },
    }
  end)

  it("invokes callback with the only kanji match", function()
    local got
    internal.lookup_hiragana_async("たべる", function(k) got = k end)
    assert.are.equal("食べる", got)
  end)

  it("picks first when on_multiple_kanji='first'", function()
    plugin.options.on_multiple_kanji = "first"
    local got
    internal.lookup_hiragana_async("ください", function(k) got = k end)
    assert.are.equal("下さい", got)
  end)

  it("joins with / when on_multiple_kanji='all'", function()
    plugin.options.on_multiple_kanji = "all"
    local got
    internal.lookup_hiragana_async("ください", function(k) got = k end)
    assert.are.equal("下さい/ください", got)
  end)

  it("invokes vim.ui.select for 'select' and forwards choice", function()
    plugin.options.on_multiple_kanji = "select"
    local restore = h.stub(vim.ui, "select", function(items, _opts, on_choice)
      on_choice(items[2])
    end)
    local got
    internal.lookup_hiragana_async("ください", function(k) got = k end)
    restore()
    assert.are.equal("ください", got)
  end)

  it("does not call back when select is cancelled", function()
    plugin.options.on_multiple_kanji = "select"
    local restore = h.stub(vim.ui, "select", function(_items, _opts, on_choice)
      on_choice(nil)
    end)
    local called = false
    internal.lookup_hiragana_async("ください", function(_) called = true end)
    restore()
    assert.is_false(called)
  end)

  it("notifies and skips callback on miss", function()
    local called = false
    local notified
    internal.set_notify(function(msg) notified = msg end)
    internal.lookup_hiragana_async("missing", function(_) called = true end)
    silence_notify()
    assert.is_false(called)
    assert.is_truthy(notified and notified:find("No kanji found", 1, true))
  end)
end)

describe("reverse insertion", function()
  before_each(function()
    reset_options()
    silence_notify()
    plugin._reverse_index = { ["たべる"] = { "食べる" } }
  end)

  it("prepends the chosen kanji directly before a buffer word", function()
    -- Build a scratch buffer containing a single hiragana word and place the
    -- cursor on it, then directly drive the lookup-and-insert path.
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "たべる" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    -- Mirror lookup_and_write_before_current_word_kanji's insertion: prepend
    -- the chosen kanji at the start of <cword>.
    local reading = vim.fn.expand("<cword>")
    assert.are.equal("たべる", reading)
    internal.lookup_hiragana_async(reading, function(kanji)
      local row, col = 1, 0
      vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { kanji })
    end)

    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    assert.are.equal("食べるたべる", line)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
