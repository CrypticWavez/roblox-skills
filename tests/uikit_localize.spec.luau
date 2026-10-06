--!strict
-- G4 specs: UIKit/Localize. Lookup chain (locale, language, fallback, kit defaults), parameters,
-- CLDR-style plurals, pseudo-localisation, the text-fit estimate (a convention; AuditRoblox
-- uses TextFits in Studio), providers over a Translator, LocalizationTable entries and the
-- string-table validator lifted from Creator/UI. Also: every key the gallery stories and the
-- default input map use has a kit default, so a game that ships no tables still shows text.
local roblox = require("@lune/roblox")

local Build = require("../packages/UIKit/Build")
local InputMap = require("../packages/GameKit/InputMap")
local Localize = require("../packages/UIKit/Localize")
local Stories = require("../packages/UIKit/Gallery/Stories")
local FakeEnv = require("./fakes/FakeEnv")
local FakeUIEvents = require("./fakes/FakeUIEvents")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

test("lookup goes locale, language, fallback, kit default, then [key] recorded as missing", function(t)
	local loc = Localize.new({
		locale = "pt-br",
		tables = {
			["pt-br"] = { greeting = "Oi" },
			pt = { farewell = "Adeus" },
			["en-us"] = { greeting = "Hi", farewell = "Bye", only_english = "English" },
		},
	})
	t.eq({ loc:get("greeting") }, { "Oi", true })
	t.eq({ loc:get("farewell") }, { "Adeus", true }, "language table before the fallback")
	t.eq({ loc:get("only_english") }, { "English", true })
	t.eq({ loc:get("uikit.confirm") }, { "Confirm", true }, "kit default last")
	t.eq({ loc:get("nowhere.key") }, { "[nowhere.key]", false })
	t.eq(loc:missing(), { "nowhere.key" })
	t.ok(loc:has("greeting") and not loc:has("nowhere.key"))
	loc:setLocale("en-us")
	t.eq(loc:get("greeting"), "Hi")
	t.throws(function()
		loc:setLocale("EN_US")
	end)
	t.ok(string.find(
		errorText(function()
			loc:get("bad key!")
		end),
		"invalid key",
		1,
		true
	))
end)

test("missing keys are bounded by maxMissing", function(t)
	local loc = Localize.new({ maxMissing = 2 })
	for index = 1, 5 do
		loc:get("gone_" .. index)
	end
	t.eq(#loc:missing(), 2)
end)

test("format fills named and positional parameters and leaves unknown ones", function(t)
	t.eq(Localize.format("{name} has {1} of {2}", { name = "Player 1", 3, 5 }), "Player 1 has 3 of 5")
	t.eq(Localize.format("{who} {left}", { who = "A" }), "A {left}")
	t.eq(Localize.format("no args {x}"), "no args {x}")
	t.eq(Localize.chain("pt-br"), { "pt-br", "pt" })
	t.eq(Localize.chain("en"), { "en" })
end)

test("plural categories follow the language rules", function(t)
	local function cats(locale: string, counts: { number }): { string }
		local out = {}
		for _, n in counts do
			table.insert(out, Localize.pluralCategory(locale, n))
		end
		return out
	end
	t.eq(cats("en-us", { 0, 1, 2, 1.5 }), { "other", "one", "other", "other" })
	t.eq(cats("fr", { 0, 1, 2 }), { "one", "one", "other" })
	t.eq(cats("ru", { 1, 2, 5, 11, 21, 22, 112 }), { "one", "few", "many", "many", "one", "few", "many" })
	t.eq(cats("pl", { 1, 3, 5, 22, 12 }), { "one", "few", "many", "few", "many" })
	t.eq(cats("ar", { 0, 1, 2, 5, 11, 100 }), { "zero", "one", "two", "few", "many", "other" })
	t.eq(cats("ja", { 1, 2 }), { "other", "other" })
	t.eq(cats("xx", { 1, 2 }), { "one", "other" }, "unknown languages use the English rule")
end)

test("plural picks key.<category>, falls back to key.other and records misses", function(t)
	local loc = Localize.new({
		locale = "ru",
		tables = {
			ru = { ["items.one"] = "{count} предмет", ["items.other"] = "{count} предметов" },
		},
	})
	t.eq(loc:plural("items", 1), "1 предмет")
	t.eq(loc:plural("items", 5), "5 предметов", "many falls back to other")
	t.eq({ loc:plural("coins", 2) }, { "[coins.few]", false })
	t.eq(loc:missing(), { "coins.few" })
	t.throws(function()
		loc:plural("items", 0 / 0)
	end)
end)

test("pseudo-localisation accents, pads about 40 percent and keeps params and tags", function(t)
	local out = Localize.pseudo("Hello {name}, <b>go</b>")
	t.ok(string.find(out, "{name}", 1, true) ~= nil, "params kept")
	t.ok(string.find(out, "<b>", 1, true) ~= nil and string.find(out, "</b>", 1, true) ~= nil, "tags kept")
	t.ok(string.sub(out, 1, 2) == "[!" and string.sub(out, -2) == "!]")
	t.ok(string.find(out, "Ĥéļļö", 1, true) ~= nil)
	local _, tildes = string.gsub(out, "~", "")
	t.eq(tildes, 3, "7 letters x 0.4 rounds up to 3")
	t.eq(Localize.pseudo("Hello {name}, <b>go</b>"), out, "deterministic")
	t.eq(Localize.pseudo("123"), "[!123!]", "no letters, no padding")
	local loc = Localize.new({ pseudo = true })
	t.eq(loc:get("uikit.confirm"), Localize.pseudo("Confirm"))
end)

test("text-fit estimate: wide glyphs count double and an unbreakable word never fits", function(t)
	t.near(Localize.estimateWidth("ab", 10), 11, 1e-9)
	t.near(Localize.estimateWidth("日本", 10), 20, 1e-9)
	t.ok(Localize.estimateFits("Confirm", 18, 120, 24))
	t.ok(not Localize.estimateFits("Supercalifragilistic", 18, 60, 200), "one long word")
	t.ok(not Localize.estimateFits("one two three four five six", 18, 80, 24), "wraps past one line")
	t.ok(Localize.estimateFits("one two three four five six", 18, 80, 200))
end)

test("a provider wins when it answers and failures fall back to the tables", function(t)
	local loc = Localize.new({
		tables = { ["en-us"] = { title = "Table title" } },
		provider = function(key: string): string?
			if key == "title" then
				return "Provided"
			end
			if key == "explode" then
				error("translator down")
			end
			return nil
		end,
	})
	t.eq(loc:get("title"), "Provided")
	t.eq({ loc:get("explode") }, { "[explode]", false }, "a raising provider is contained")
	local translator = {}
	function translator.FormatByKey(_self: any, key: string, args: any): string
		if key == "known" then
			return "T:" .. tostring(args.n)
		end
		error("Key not found")
	end
	local provider = Localize.translatorProvider(translator)
	t.eq(provider("known", { n = 2 }, "en-us"), "T:2")
	t.eq(provider("unknown", nil, "en-us"), nil)
	t.throws(function()
		Localize.new({ provider = "nope" :: any })
	end)
end)

test("toEntries gives sorted LocalizationTable entries and needs the source table", function(t)
	local entries = Localize.toEntries({
		["en-us"] = { b = "Bee", a = "Ay" },
		["pt-br"] = { a = "A" },
		es = { a = "A-es", b = "B-es" },
	})
	t.eq(#entries, 2)
	t.eq(entries[1].Key, "a")
	t.eq(entries[1].Values, { ["pt-br"] = "A", es = "A-es" })
	t.eq(entries[2].Values, { es = "B-es" })
	t.throws(function()
		Localize.toEntries({ fr = { a = "a" } })
	end)
end)

test("validateStrings rejects bad keys, control characters, blank text and missing required keys", function(t)
	local ok, problems = Localize.validateStrings({
		["good.key"] = "Fine",
		["bad key"] = "x",
		blank = "   ",
		bell = "ring\7",
	}, { "good.key", "required.key" })
	t.eq(ok, false)
	t.ok(contains(problems, 'invalid key "bad key"') or contains(problems, "invalid key"), "bad key")
	t.ok(contains(problems, "invalid text for blank"))
	t.ok(contains(problems, "invalid text for bell"))
	t.ok(contains(problems, "missing or invalid key: required.key"))
	t.eq({ Localize.validateStrings({ ["a.b"] = "ok" }) }, { true, {} })
	t.eq({ Localize.validateStrings(5) }, { false, { "strings must be a table" } })
	t.ok(string.find(
		errorText(function()
			Localize.new({ tables = { ["EN"] = {} } })
		end),
		"not a lowercase locale id",
		1,
		true
	))
	t.ok(string.find(
		errorText(function()
			Localize.new({ tables = { ["en-us"] = { ["x y"] = "z" } } })
		end),
		"en-us: invalid key",
		1,
		true
	))
end)

test("every gallery story's text resolves from kit defaults (no missing keys)", function(t)
	local loc = Localize.new()
	local hub = FakeUIEvents.new()
	local ctx = Build.context({
		env = FakeEnv.new({ roblox = roblox }),
		on = hub.on,
		onChanged = hub.onChanged,
		text = loc:fn(),
		measure = function()
			return { x = 0, y = 0, w = 400, h = 300 }
		end,
	})
	local target = roblox.Instance.new("Frame")
	for _, story in Stories.list(ctx) do
		local cleanup = story.build(target)
		for _ = 1, 10 do
			ctx.runner:step(0.1)
		end
		cleanup()
	end
	t.eq(loc:missing(), {})
end)

test("pseudo-locale reaches every text a story shows", function(t)
	local loc = Localize.new({ pseudo = true })
	local hub = FakeUIEvents.new()
	local ctx = Build.context({
		env = FakeEnv.new({ roblox = roblox }),
		on = hub.on,
		onChanged = hub.onChanged,
		text = loc:fn(),
		measure = function()
			return { x = 0, y = 0, w = 400, h = 300 }
		end,
	})
	local target = roblox.Instance.new("Frame")
	local story
	for _, item in Stories.list(ctx) do
		if item.name == "Button" then
			story = item
		end
	end
	local cleanup = story.build(target)
	local texts = 0
	for _, item in target:GetDescendants() do
		if item:IsA("TextLabel") and item.Name == "Label" and item.Text ~= "" then
			texts += 1
			t.ok(string.sub(item.Text, 1, 2) == "[!", item:GetFullName() .. " is not pseudo-localised")
		end
	end
	t.ok(texts > 0)
	cleanup()
end)

test("every default input action has an input.<action> label", function(t)
	local map = InputMap.defaults()
	local missing = {}
	for name in map.actions do
		if Localize.KIT["input." .. name] == nil then
			table.insert(missing, name)
		end
	end
	table.sort(missing)
	t.eq(missing, {})
end)

return cases
