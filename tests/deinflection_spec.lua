-- Tests for verb deinflection support.
-- Covers:
--   * deinflect() unit tests (pure function, no index needed)
--   * lookup_kanji_async() integration: conjugated form → dictionary reading
--   * Negative case: form with no deinflection hit still notifies, no callback

local h = require("tests.helpers")
local plugin = require("nvim-kanji-to-hiragana")
local internal = plugin._internal

local function reset_options()
  plugin.options = plugin._defaults_for_test()
  plugin._index = nil
end

local function silence_notify()
  internal.set_notify(function() end)
end

-- Helper: check that `word` is contained in the deinflect candidates.
local function has_candidate(word, candidates)
  for _, c in ipairs(candidates) do
    if c == word then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- deinflect() unit tests
-- ---------------------------------------------------------------------------

describe("deinflect", function()
  before_each(function()
    reset_options()
    silence_notify()
  end)

  -- Ichidan (る-verb) forms
  describe("Ichidan (る-verb) forms", function()
    it("食べた → 食べる (past)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べた")))
    end)

    it("食べて → 食べる (te-form)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べて")))
    end)

    it("食べない → 食べる (negative)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べない")))
    end)

    it("食べます → 食べる (polite)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べます")))
    end)

    it("食べました → 食べる (polite past)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べました")))
    end)

    it("食べません → 食べる (polite negative)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べません")))
    end)

    it("食べなかった → 食べる (negative past)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べなかった")))
    end)

    it("食べられる → 食べる (passive/potential)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べられる")))
    end)

    it("食べさせる → 食べる (causative)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べさせる")))
    end)

    it("食べさせられる → 食べる (causative-passive)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べさせられる")))
    end)

    it("食べれば → 食べる (conditional)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べれば")))
    end)

    it("食べよう → 食べる (volitional)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べよう")))
    end)

    it("食べている → 食べる (te-iru progressive)", function()
      assert.is_true(has_candidate("食べる", internal.deinflect("食べている")))
    end)
  end)

  -- Godan (う-verb) forms
  describe("Godan (う-verb) forms", function()
    -- く column
    it("書いた → 書く (く past)", function()
      assert.is_true(has_candidate("書く", internal.deinflect("書いた")))
    end)

    it("書いて → 書く (く te-form)", function()
      assert.is_true(has_candidate("書く", internal.deinflect("書いて")))
    end)

    it("書かない → 書く (く negative)", function()
      assert.is_true(has_candidate("書く", internal.deinflect("書かない")))
    end)

    it("書きます → 書く (く polite)", function()
      assert.is_true(has_candidate("書く", internal.deinflect("書きます")))
    end)

    it("書ける → 書く (く potential)", function()
      assert.is_true(has_candidate("書く", internal.deinflect("書ける")))
    end)

    it("書こう → 書く (く volitional)", function()
      assert.is_true(has_candidate("書く", internal.deinflect("書こう")))
    end)

    -- む column
    it("飲んだ → 飲む (む past)", function()
      assert.is_true(has_candidate("飲む", internal.deinflect("飲んだ")))
    end)

    it("飲んで → 飲む (む te-form)", function()
      assert.is_true(has_candidate("飲む", internal.deinflect("飲んで")))
    end)

    it("飲まない → 飲む (む negative)", function()
      assert.is_true(has_candidate("飲む", internal.deinflect("飲まない")))
    end)

    it("飲みます → 飲む (む polite)", function()
      assert.is_true(has_candidate("飲む", internal.deinflect("飲みます")))
    end)

    -- す column
    it("話した → 話す (す past)", function()
      assert.is_true(has_candidate("話す", internal.deinflect("話した")))
    end)

    it("話して → 話す (す te-form)", function()
      assert.is_true(has_candidate("話す", internal.deinflect("話して")))
    end)

    it("話します → 話す (す polite)", function()
      assert.is_true(has_candidate("話す", internal.deinflect("話します")))
    end)

    it("話せる → 話す (す potential)", function()
      assert.is_true(has_candidate("話す", internal.deinflect("話せる")))
    end)

    -- る column (Godan る)
    it("走った → 走る (る Godan past)", function()
      assert.is_true(has_candidate("走る", internal.deinflect("走った")))
    end)

    it("走って → 走る (る Godan te-form)", function()
      assert.is_true(has_candidate("走る", internal.deinflect("走って")))
    end)

    it("走ります → 走る (る Godan polite)", function()
      assert.is_true(has_candidate("走る", internal.deinflect("走ります")))
    end)

    -- う column
    it("言った → 言う (う past)", function()
      assert.is_true(has_candidate("言う", internal.deinflect("言った")))
    end)

    it("言わない → 言う (う negative)", function()
      assert.is_true(has_candidate("言う", internal.deinflect("言わない")))
    end)

    it("言います → 言う (う polite)", function()
      assert.is_true(has_candidate("言う", internal.deinflect("言います")))
    end)
  end)

  -- Irregular verb forms
  describe("Irregular verb forms (する / くる)", function()
    it("した → する", function()
      assert.is_true(has_candidate("する", internal.deinflect("した")))
    end)

    it("して → する", function()
      assert.is_true(has_candidate("する", internal.deinflect("して")))
    end)

    it("しない → する", function()
      assert.is_true(has_candidate("する", internal.deinflect("しない")))
    end)

    it("します → する", function()
      assert.is_true(has_candidate("する", internal.deinflect("します")))
    end)

    it("しました → する", function()
      assert.is_true(has_candidate("する", internal.deinflect("しました")))
    end)

    it("きた → くる", function()
      assert.is_true(has_candidate("くる", internal.deinflect("きた")))
    end)

    it("きて → くる", function()
      assert.is_true(has_candidate("くる", internal.deinflect("きて")))
    end)

    it("こない → くる", function()
      assert.is_true(has_candidate("くる", internal.deinflect("こない")))
    end)

    it("きます → くる", function()
      assert.is_true(has_candidate("くる", internal.deinflect("きます")))
    end)
  end)

  -- Compound する verbs
  describe("Compound する verbs", function()
    it("勉強した → 勉強する", function()
      assert.is_true(has_candidate("勉強する", internal.deinflect("勉強した")))
    end)

    it("勉強して → 勉強する", function()
      assert.is_true(has_candidate("勉強する", internal.deinflect("勉強して")))
    end)

    it("勉強しない → 勉強する", function()
      assert.is_true(has_candidate("勉強する", internal.deinflect("勉強しない")))
    end)

    it("勉強します → 勉強する", function()
      assert.is_true(has_candidate("勉強する", internal.deinflect("勉強します")))
    end)
  end)

  -- Edge cases
  describe("edge cases", function()
    it("returns empty list for empty string", function()
      local c = internal.deinflect("")
      assert.are.equal(0, #c)
    end)

    it("does not return the original word as a candidate", function()
      -- 食べる is already a dictionary form; deinflect should not echo it.
      local c = internal.deinflect("食べる")
      for _, v in ipairs(c) do
        assert.are_not.equal("食べる", v)
      end
    end)

    it("returns no duplicates", function()
      local c = internal.deinflect("食べた")
      local seen = {}
      for _, v in ipairs(c) do
        assert.is_nil(seen[v], "duplicate candidate: " .. v)
        seen[v] = true
      end
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- lookup_kanji_async integration: conjugated form → dictionary reading
-- ---------------------------------------------------------------------------

describe("lookup_kanji_async with deinflection", function()
  before_each(function()
    reset_options()
    silence_notify()
    plugin.options.on_multiple_readings = "first"
    plugin.options.fallback_to_web = false
    plugin._index = {
      ["食べる"] = { "たべる" },
      ["書く"]   = { "かく" },
      ["飲む"]   = { "のむ" },
      ["話す"]   = { "はなす" },
      ["走る"]   = { "はしる" },
      ["言う"]   = { "いう" },
      ["する"]   = { "する" },
      ["くる"]   = { "くる" },
      ["来る"]   = { "くる" },
      ["勉強する"] = { "べんきょうする" },
    }
  end)

  -- Ichidan
  it("食べた → callback(たべる) [Ichidan past]", function()
    local got
    internal.lookup_kanji_async("食べた", function(r) got = r end)
    assert.are.equal("たべる", got)
  end)

  it("食べて → callback(たべる) [Ichidan te-form]", function()
    local got
    internal.lookup_kanji_async("食べて", function(r) got = r end)
    assert.are.equal("たべる", got)
  end)

  it("食べない → callback(たべる) [Ichidan negative]", function()
    local got
    internal.lookup_kanji_async("食べない", function(r) got = r end)
    assert.are.equal("たべる", got)
  end)

  it("食べます → callback(たべる) [Ichidan polite]", function()
    local got
    internal.lookup_kanji_async("食べます", function(r) got = r end)
    assert.are.equal("たべる", got)
  end)

  it("食べられる → callback(たべる) [Ichidan passive/potential]", function()
    local got
    internal.lookup_kanji_async("食べられる", function(r) got = r end)
    assert.are.equal("たべる", got)
  end)

  -- Godan
  it("書いた → callback(かく) [Godan く past]", function()
    local got
    internal.lookup_kanji_async("書いた", function(r) got = r end)
    assert.are.equal("かく", got)
  end)

  it("書きます → callback(かく) [Godan く polite]", function()
    local got
    internal.lookup_kanji_async("書きます", function(r) got = r end)
    assert.are.equal("かく", got)
  end)

  it("飲んだ → callback(のむ) [Godan む past]", function()
    local got
    internal.lookup_kanji_async("飲んだ", function(r) got = r end)
    assert.are.equal("のむ", got)
  end)

  it("話します → callback(はなす) [Godan す polite]", function()
    local got
    internal.lookup_kanji_async("話します", function(r) got = r end)
    assert.are.equal("はなす", got)
  end)

  it("走った → callback(はしる) [Godan る past]", function()
    local got
    internal.lookup_kanji_async("走った", function(r) got = r end)
    assert.are.equal("はしる", got)
  end)

  it("言った → callback(いう) [Godan う past]", function()
    local got
    internal.lookup_kanji_async("言った", function(r) got = r end)
    assert.are.equal("いう", got)
  end)

  -- Irregular
  it("した → callback(する) [irregular past]", function()
    local got
    internal.lookup_kanji_async("した", function(r) got = r end)
    assert.are.equal("する", got)
  end)

  it("して → callback(する) [irregular te-form]", function()
    local got
    internal.lookup_kanji_async("して", function(r) got = r end)
    assert.are.equal("する", got)
  end)

  it("こない → callback(くる) [irregular negative]", function()
    local got
    internal.lookup_kanji_async("こない", function(r) got = r end)
    assert.are.equal("くる", got)
  end)

  -- Compound する
  it("勉強した → callback(べんきょうする) [compound する past]", function()
    local got
    internal.lookup_kanji_async("勉強した", function(r) got = r end)
    assert.are.equal("べんきょうする", got)
  end)

  it("勉強して → callback(べんきょうする) [compound する te-form]", function()
    local got
    internal.lookup_kanji_async("勉強して", function(r) got = r end)
    assert.are.equal("べんきょうする", got)
  end)

  -- Negative: unknown word with no deinflection match → notify, no callback
  it("notifies and does not call back when no deinflection hit exists", function()
    local called = false
    local notified
    internal.set_notify(function(msg) notified = msg end)
    internal.lookup_kanji_async("zzz全然不明zzz", function(_) called = true end)
    silence_notify()
    assert.is_false(called)
    assert.is_truthy(notified and notified:find("No reading found", 1, true))
  end)
end)
