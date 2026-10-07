--!strict
-- @tier T0
-- Localize: text by key for UIKit (docs/uikit.md "Localisation"). Components take keys, never
-- literal production text. Lookup order: the locale (pt-br), its language (pt), the fallback
-- locale (en-us), then the kit's neutral defaults (Localize.KIT); a key found nowhere returns
-- "[key]" and is recorded in missing(). Parameters use the Translator:FormatByKey forms
-- {name} and {1}. Plurals pick key.<category> with CLDR-style categories (zero, one, two, few,
-- many, other) for a built-in set of languages (others use the English rule). Pseudo-locale
-- (pseudo = true or Localize.pseudo) accents and pads text by about 40 percent while keeping
-- {params} and <rich text> tags, so text-fit audits catch overflow before translation.
-- Roblox adapters stay thin: toEntries() gives LocalizationTable:SetEntries data and
-- translatorProvider(translator) wraps Translator:FormatByKey (pcall: it can fail).
-- validateStrings is lifted from the inherited Creator/UI (its callback guard is UIKit/Build.guard).
local Check = require("../GameKit/Check")

local Localize = {}

-- Neutral English defaults for the keys UIKit components use themselves.
Localize.KIT = table.freeze({
	["uikit.confirm"] = "Confirm",
	["uikit.cancel"] = "Cancel",
	["uikit.close"] = "Close",
	["uikit.back"] = "Back",
	["uikit.continue"] = "Continue",
	["uikit.on"] = "On",
	["uikit.off"] = "Off",
	["uikit.loading"] = "Loading",
	["uikit.empty"] = "Nothing here yet",
	["uikit.error"] = "Something went wrong",
	["uikit.retry"] = "Retry",
	["uikit.skip"] = "Skip",
	["uikit.hold_to_skip"] = "Hold to skip",
	["uikit.teleporting"] = "Travelling",
	["uikit.price.pending"] = "Price loading",
	["uikit.price.unavailable"] = "Price unavailable",
	["uikit.shop.unavailable"] = "Not available",
	["uikit.shop.owned"] = "Owned",
	["uikit.shop.setup_watermark"] = "SETUP ONLY - preview",
	["uikit.shop.ribbon.best_value"] = "Best value",
	["uikit.shop.ribbon.most_popular"] = "Most popular",
	["uikit.shop.ribbon.limited"] = "Limited time",
	["uikit.shop.ribbon.new"] = "New",
	["uikit.shop.ribbon.sale"] = "Sale",
	["uikit.shop.ribbon.starter"] = "Starter pack",
	["uikit.offer.get"] = "Get it",
	["uikit.offer.later"] = "Not now",
	["uikit.offer.ends_in"] = "Ends in {time}",
	["uikit.toast.info"] = "Info",
	["uikit.toast.success"] = "Done",
	["uikit.toast.warning"] = "Warning",
	["uikit.toast.error"] = "Error",
	["uikit.leaderboard.empty"] = "No entries",
	["uikit.inventory.empty"] = "Empty slot",
	["uikit.keybind.tap"] = "Tap",
	["uikit.count.one"] = "{count} item",
	["uikit.count.other"] = "{count} items",
	["uikit.go"] = "Go",
	-- settings/1 (GameKit/Settings labelKey = settings.<path>) for SettingsPanel.
	["settings.group.audio"] = "Audio",
	["settings.group.display"] = "Display",
	["settings.group.accessibility"] = "Accessibility",
	["settings.group.controls"] = "Controls",
	["settings.group.language"] = "Language",
	["settings.group.game"] = "Game",
	["settings.volume.master"] = "Master volume",
	["settings.volume.music"] = "Music",
	["settings.volume.sfx"] = "Effects",
	["settings.volume.ui"] = "Interface sounds",
	["settings.volume.ambience"] = "Ambience",
	["settings.volume.dialogue"] = "Dialogue",
	["settings.volume.world"] = "World",
	["settings.reducedMotion"] = "Reduce motion",
	["settings.screenShake"] = "Screen shake",
	["settings.reduceFlashing"] = "Reduce flashing",
	["settings.subtitles"] = "Subtitles",
	["settings.colorblindMode"] = "Colour filter",
	["settings.uiScale"] = "Interface size",
	["settings.haptics"] = "Vibration",
	["settings.cameraSensitivity"] = "Camera sensitivity",
	["settings.invertY"] = "Invert camera Y",
	["settings.language"] = "Language",
	["settings.choice.auto"] = "Automatic",
	["settings.choice.none"] = "Off",
	["settings.choice.protanopia"] = "Protanopia",
	["settings.choice.deuteranopia"] = "Deuteranopia",
	["settings.choice.tritanopia"] = "Tritanopia",
	-- GameKit/InputMap default actions (labelKey = input.<action>) for KeybindPrompt.
	["input.gameplay.move"] = "Move",
	["input.gameplay.jump"] = "Jump",
	["input.gameplay.primary"] = "Primary",
	["input.gameplay.secondary"] = "Secondary",
	["input.gameplay.interact"] = "Interact",
	["input.gameplay.sprint"] = "Sprint",
	["input.gameplay.action_1"] = "Action 1",
	["input.gameplay.action_2"] = "Action 2",
	["input.gameplay.action_3"] = "Action 3",
	["input.ui.confirm"] = "Confirm",
	["input.ui.back"] = "Back",
	["input.ui.navigate"] = "Navigate",
	["input.ui.tab_next"] = "Next tab",
	["input.ui.tab_prev"] = "Previous tab",
	["input.cinematic.skip"] = "Skip",
})

export type Tables = { [string]: { [string]: string } }
export type Provider = (key: string, args: { [any]: any }?, locale: string) -> string?
export type Options = {
	tables: Tables?,
	locale: string?,
	fallback: string?,
	provider: Provider?,
	pseudo: boolean?,
	maxMissing: number?,
}
export type Localizer = {
	get: (self: Localizer, key: string, args: { [any]: any }?) -> (string, boolean),
	plural: (self: Localizer, key: string, count: number, args: { [any]: any }?) -> (string, boolean),
	has: (self: Localizer, key: string) -> boolean,
	locale: (self: Localizer) -> string,
	setLocale: (self: Localizer, locale: string) -> (),
	missing: (self: Localizer) -> { string },
	fn: (self: Localizer) -> (key: string, args: { [any]: any }?) -> string,
}

local KEY_MAX = 100
local TEXT_MAX = 1024

local function validKey(key: any): boolean
	return type(key) == "string"
		and #key >= 1
		and #key <= KEY_MAX
		and string.match(key, "^[%w_][%w_%.%-]*$") ~= nil
end
Localize.validKey = validKey

-- A lowercase locale id: en, en-us, pt-br, zh-hans.
local function validLocale(locale: any): boolean
	return type(locale) == "string"
		and (
			string.match(locale, "^[a-z][a-z][a-z]?$") ~= nil
			or string.match(locale, "^[a-z][a-z][a-z]?%-[a-z0-9]+$") ~= nil
		)
end
Localize.validLocale = validLocale

-- The lookup chain for a locale: { "pt-br", "pt" }.
function Localize.chain(locale: string): { string }
	local out = { locale }
	local language = string.match(locale, "^([a-z]+)%-")
	if language then
		table.insert(out, language)
	end
	return out
end

-- Fills {name} and {1} parameters; unknown parameters stay as written.
function Localize.format(template: string, args: { [any]: any }?): string
	if args == nil then
		return template
	end
	return (
		string.gsub(template, "{([%w_]+)}", function(name: string): string
			local value = args[name]
			if value == nil then
				local index = tonumber(name)
				if index then
					value = args[index]
				end
			end
			if value == nil then
				return "{" .. name .. "}" -- the whole match, as returning nil would keep it
			end
			return tostring(value)
		end)
	)
end

-- ------------------------------------------------------------------ plurals

local function isInteger(n: number): boolean
	return n % 1 == 0
end

-- CLDR-style plural category for a count in a locale's language (integers; fractions are
-- "other" except where noted). Languages not listed use the English rule.
function Localize.pluralCategory(locale: string, count: number): string
	local language = string.match(locale, "^([a-z]+)") or "en"
	local n = math.abs(count)
	local integer = isInteger(n)
	local mod10, mod100 = n % 10, n % 100
	if
		language == "ja"
		or language == "zh"
		or language == "ko"
		or language == "th"
		or language == "vi"
		or language == "id"
		or language == "ms"
	then
		return "other"
	elseif language == "fr" or language == "pt" then
		-- French and Portuguese (Brazil): 0 and 1 are "one".
		if n < 2 then
			return "one"
		end
		return "other"
	elseif language == "ru" or language == "uk" then
		if not integer then
			return "other"
		end
		if mod10 == 1 and mod100 ~= 11 then
			return "one"
		elseif mod10 >= 2 and mod10 <= 4 and (mod100 < 12 or mod100 > 14) then
			return "few"
		end
		return "many"
	elseif language == "pl" then
		if not integer then
			return "other"
		end
		if n == 1 then
			return "one"
		elseif mod10 >= 2 and mod10 <= 4 and (mod100 < 12 or mod100 > 14) then
			return "few"
		end
		return "many"
	elseif language == "ar" then
		if not integer then
			return "other"
		end
		if n == 0 then
			return "zero"
		elseif n == 1 then
			return "one"
		elseif n == 2 then
			return "two"
		elseif mod100 >= 3 and mod100 <= 10 then
			return "few"
		elseif mod100 >= 11 then
			return "many"
		end
		return "other"
	end
	if n == 1 and integer then
		return "one"
	end
	return "other"
end

-- ------------------------------------------------------------------ pseudo-locale

local ACCENTS: { [string]: string } = {
	a = "á",
	b = "ƀ",
	c = "ç",
	d = "đ",
	e = "é",
	f = "ƒ",
	g = "ĝ",
	h = "ĥ",
	i = "í",
	j = "ĵ",
	k = "ķ",
	l = "ļ",
	m = "ɱ",
	n = "ñ",
	o = "ö",
	p = "þ",
	q = "ǫ",
	r = "ŕ",
	s = "š",
	t = "ţ",
	u = "ü",
	v = "ṽ",
	w = "ŵ",
	x = "ẋ",
	y = "ý",
	z = "ž",
	A = "Á",
	B = "Ɓ",
	C = "Ç",
	D = "Đ",
	E = "É",
	F = "Ƒ",
	G = "Ĝ",
	H = "Ĥ",
	I = "Í",
	J = "Ĵ",
	K = "Ķ",
	L = "Ļ",
	M = "Ṁ",
	N = "Ñ",
	O = "Ö",
	P = "Þ",
	Q = "Ǫ",
	R = "Ŕ",
	S = "Š",
	T = "Ţ",
	U = "Ü",
	V = "Ṽ",
	W = "Ŵ",
	X = "Ẋ",
	Y = "Ý",
	Z = "Ž",
}

-- Pseudo-localised text: letters accented, padded with "~" to about (1 + expansion) times the
-- length (default 0.4, a common allowance for translations longer than English) and wrapped
-- in [! !]. {params} and <tags> are kept as they are. Deterministic.
function Localize.pseudo(text: string, expansion: number?): string
	local grow = expansion or 0.4
	local out = {}
	local letters = 0
	local index = 1
	local length = #text
	while index <= length do
		local char = string.sub(text, index, index)
		if char == "{" or char == "<" then
			local close = string.find(text, if char == "{" then "}" else ">", index + 1, true)
			if close then
				table.insert(out, string.sub(text, index, close))
				index = close + 1
				continue
			end
		end
		local accented = ACCENTS[char]
		if accented then
			letters += 1
			table.insert(out, accented)
		else
			table.insert(out, char)
		end
		index += 1
	end
	local pad = math.max(math.ceil(letters * grow), if letters > 0 then 1 else 0)
	return "[!" .. table.concat(out) .. string.rep("~", pad) .. "!]"
end

-- ------------------------------------------------------------------ text fit (convention)

-- Estimated rendered width of text in px: about 0.55 em per Latin glyph and 1 em per wide
-- (CJK, fullwidth) glyph. A convention for Lune pre-checks only; Studio's TextFits and
-- TextService:GetTextBoundsAsync are the truth (AuditRoblox).
function Localize.estimateWidth(text: string, textSize: number): number
	local width = 0
	for _, code in utf8.codes(text) do
		if code >= 0x2E80 then
			width += 1
		elseif code == 32 then
			width += 0.3
		else
			width += 0.55
		end
	end
	return width * textSize
end

-- Whether text likely fits a box of width x height px at textSize (wrapping by words).
function Localize.estimateFits(
	text: string,
	textSize: number,
	width: number,
	height: number,
	lineHeight: number?
): boolean
	local lines = 1
	local line = 0
	for word in string.gmatch(text, "%S+") do
		local w = Localize.estimateWidth(word, textSize)
		local space = if line > 0 then 0.3 * textSize else 0
		if line > 0 and line + space + w > width then
			lines += 1
			line = w
		else
			line += space + w
		end
		if w > width then
			return false
		end
	end
	return lines * textSize * (lineHeight or 1.2) <= height + 0.5
end

-- ------------------------------------------------------------------ localizer

-- A localizer over string tables keyed by locale. Raises on malformed options.
function Localize.new(options: Options?): Localizer
	local o: Options = options or {}
	local tables: Tables = o.tables or {}
	if type(tables) ~= "table" then
		error("Localize.new: tables must map locales to { key = text }", 2)
	end
	for locale, strings in tables do
		if not validLocale(locale) then
			error("Localize.new: " .. tostring(locale) .. " is not a lowercase locale id (en-us)", 2)
		end
		local ok, problems = Localize.validateStrings(strings)
		if not ok then
			error("Localize.new: " .. locale .. ": " .. table.concat(problems, "; "), 2)
		end
	end
	local current = o.locale or "en-us"
	local fallback = o.fallback or "en-us"
	if not validLocale(current) or not validLocale(fallback) then
		error("Localize.new: locale and fallback must be lowercase locale ids", 2)
	end
	local provider = o.provider
	if provider ~= nil and type(provider) ~= "function" then
		error("Localize.new: provider must be a function", 2)
	end
	local maxMissing = o.maxMissing or 256
	local missing: { [string]: boolean } = {}
	local missingCount = 0
	local self: any = {}

	local function lookup(key: string, args: { [any]: any }?): string?
		if provider then
			local ok, value = pcall(provider, key, args, current)
			if ok and type(value) == "string" and value ~= "" then
				return value
			end
		end
		local chain = Localize.chain(current)
		if fallback ~= current then
			table.insert(chain, fallback)
		end
		for _, locale in chain do
			local strings = tables[locale]
			local value = strings and strings[key]
			if value ~= nil then
				return Localize.format(value, args)
			end
		end
		local default = Localize.KIT[key]
		if default then
			return Localize.format(default, args)
		end
		return nil
	end

	local function note(key: string)
		if not missing[key] and missingCount < maxMissing then
			missing[key] = true
			missingCount += 1
		end
	end

	local function finish(value: string): string
		return if o.pseudo then Localize.pseudo(value) else value
	end

	function self.get(_self: any, key: string, args: { [any]: any }?): (string, boolean)
		if not validKey(key) then
			error("Localize: invalid key " .. Check.describe(key), 2)
		end
		local value = lookup(key, args)
		if value == nil then
			note(key)
			return "[" .. key .. "]", false
		end
		return finish(value), true
	end

	-- key.<category> for count (the locale's plural rule), falling back to key.other; args gain
	-- count unless they set it.
	function self.plural(_self: any, key: string, count: number, args: { [any]: any }?): (string, boolean)
		if not validKey(key) then
			error("Localize: invalid key " .. Check.describe(key), 2)
		end
		if not Check.finite(count) then
			error("Localize.plural: count must be a finite number", 2)
		end
		local params: { [any]: any } = if args then table.clone(args) else {}
		if params.count == nil then
			params.count = count
		end
		local exact = key .. "." .. Localize.pluralCategory(current, count)
		local value = lookup(exact, params) or lookup(key .. ".other", params)
		if value == nil then
			note(exact)
			return "[" .. exact .. "]", false
		end
		return finish(value), true
	end

	function self.has(_self: any, key: string): boolean
		return lookup(key, nil) ~= nil
	end

	function self.locale(_self: any): string
		return current
	end

	function self.setLocale(_self: any, locale: string)
		if not validLocale(locale) then
			error("Localize.setLocale: " .. tostring(locale) .. " is not a lowercase locale id", 2)
		end
		current = locale
	end

	function self.missing(_self: any): { string }
		local out = {}
		for key in missing do
			table.insert(out, key)
		end
		table.sort(out)
		return out
	end

	function self.fn(this: any): (string, { [any]: any }?) -> string
		return function(key: string, args: { [any]: any }?): string
			return (this:get(key, args))
		end
	end

	return self
end

-- ------------------------------------------------------------------ Roblox shapes

export type Entry = {
	Key: string,
	Source: string,
	Context: string,
	Example: string,
	Values: { [string]: string },
}

-- LocalizationTable:SetEntries data: one entry per key, Source from sourceLocale (default
-- en-us), Values for every other locale. Keys sorted, so output is deterministic.
function Localize.toEntries(tables: Tables, sourceLocale: string?): { Entry }
	local source = sourceLocale or "en-us"
	local base = tables[source]
	if base == nil then
		error("Localize.toEntries: no table for source locale " .. source, 2)
	end
	local keys = {}
	for key in base do
		table.insert(keys, key)
	end
	table.sort(keys)
	local locales = {}
	for locale in tables do
		if locale ~= source then
			table.insert(locales, locale)
		end
	end
	table.sort(locales)
	local out = {}
	for _, key in keys do
		local values = {}
		for _, locale in locales do
			local value = tables[locale][key]
			if value ~= nil then
				values[locale] = value
			end
		end
		table.insert(out, { Key = key, Source = base[key], Context = "", Example = "", Values = values })
	end
	return out
end

-- A provider over a Roblox Translator (LocalizationService:GetTranslatorForPlayerAsync, which
-- the adapter must pcall): FormatByKey with the args table; failures return nil so the
-- localizer falls back to its tables.
function Localize.translatorProvider(translator: any): Provider
	return function(key: string, args: { [any]: any }?, _locale: string): string?
		local ok, value = pcall(function()
			return translator:FormatByKey(key, args or {})
		end)
		if ok and type(value) == "string" then
			return value
		end
		return nil
	end
end

-- ------------------------------------------------------------------ lifted from Creator/UI

local function textOk(value: any, maximum: number): boolean
	if
		type(value) ~= "string"
		or string.match(value, "^%s*$")
		or string.find(value, "[%z\1-\8\11\12\14-\31]")
	then
		return false
	end
	local length = utf8.len(value)
	return length ~= nil and length <= maximum
end
Localize.textOk = textOk

-- (ok, problems) for a { key = text } table: keys and texts bounded, UTF-8, no control
-- characters, at most 4096 keys, every required key present.
function Localize.validateStrings(strings: any, required: { string }?): (boolean, { string })
	local problems = {}
	if type(strings) ~= "table" then
		return false, { "strings must be a table" }
	end
	local count = 0
	for key, value in strings do
		count += 1
		if not validKey(key) then
			table.insert(problems, "invalid key " .. Check.describe(key))
		elseif not textOk(value, TEXT_MAX) then
			table.insert(problems, "invalid text for " .. tostring(key))
		end
	end
	if count > 4096 then
		table.insert(problems, "more than 4096 keys")
	end
	for _, key in required or {} :: { string } do
		if not textOk(strings[key], TEXT_MAX) then
			table.insert(problems, "missing or invalid key: " .. tostring(key))
		end
	end
	table.sort(problems)
	return #problems == 0, problems
end

return Localize
