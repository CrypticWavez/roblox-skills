--!strict
-- @tier T0
-- Tokens: the neutral design tokens every UIKit component reads (docs/uikit.md "Tokens"):
-- spacing scale, radii, strokes, sizes, a type scale with built-in font families, z-layers,
-- motion durations, eases and springs, transparency steps and a greyscale palette mapped to
-- semantic colour slots. Colours are plain { r, g, b } triples (0-255) so tokens stay pure;
-- UIKit/Style turns them into Color3 and Font values. The palette is greyscale on purpose: the
-- hue slots (accent, danger, success, warning, info) are TBD placeholders a game fills with
-- Tokens.resolve(theme, overrides). Two themes ship: dark (default) and light. Numbers marked
-- "convention" are factory choices, not Roblox limits (44 px touch target, minimum text 12).
local Check = require("../GameKit/Check")
local Json = require("../GameKit/Json")
local Rng = require("../ProcGen/Rng")

local Tokens = {}
Tokens.SCHEMA = "uikit-tokens/1"
Tokens.DEFAULT_THEME = "dark"

export type RGB = { number }
export type TextStyle = { size: number, font: string, weight: string, lineHeight: number }
export type Tokens = { [string]: any }

-- Pure greys (r = g = b); the step number is the lightness band, 0 white to 1000 black.
local function grey(level: number): RGB
	return { level, level, level }
end
Tokens.PALETTE = table.freeze({
	grey_0 = grey(255),
	grey_50 = grey(246),
	grey_100 = grey(236),
	grey_200 = grey(218),
	grey_300 = grey(196),
	grey_400 = grey(160),
	grey_500 = grey(128),
	grey_600 = grey(100),
	grey_700 = grey(74),
	grey_800 = grey(50),
	grey_850 = grey(38),
	grey_900 = grey(28),
	grey_950 = grey(18),
	grey_1000 = grey(0),
})

-- Semantic slots. Every theme defines every slot; components never name palette steps.
Tokens.SLOTS = table.freeze({
	"background",
	"surface",
	"surfaceRaised",
	"surfaceSunken",
	"scrim",
	"border",
	"borderStrong",
	"text",
	"textMuted",
	"textDisabled",
	"textInverse",
	"focus",
	"accent",
	"accentText",
	"danger",
	"dangerText",
	"success",
	"successText",
	"warning",
	"warningText",
	"info",
	"infoText",
	"track",
	"fill",
})
-- Slots a game decides (hue, brand). Their greyscale values are placeholders.
Tokens.TBD = table.freeze({ "accent", "danger", "success", "warning", "info" })

local p = Tokens.PALETTE
Tokens.THEMES = table.freeze({
	dark = table.freeze({
		background = p.grey_950,
		surface = p.grey_900,
		surfaceRaised = p.grey_850,
		surfaceSunken = p.grey_1000,
		scrim = p.grey_1000,
		border = p.grey_700,
		borderStrong = p.grey_500,
		text = p.grey_50,
		textMuted = p.grey_300,
		textDisabled = p.grey_500,
		textInverse = p.grey_950,
		focus = p.grey_0,
		accent = p.grey_200,
		accentText = p.grey_950,
		danger = p.grey_300,
		dangerText = p.grey_950,
		success = p.grey_100,
		successText = p.grey_950,
		warning = p.grey_400,
		warningText = p.grey_1000,
		info = p.grey_700,
		infoText = p.grey_0,
		track = p.grey_800,
		fill = p.grey_100,
	}),
	light = table.freeze({
		background = p.grey_50,
		surface = p.grey_0,
		surfaceRaised = p.grey_0,
		surfaceSunken = p.grey_100,
		scrim = p.grey_1000,
		border = p.grey_300,
		borderStrong = p.grey_500,
		text = p.grey_950,
		textMuted = p.grey_700,
		textDisabled = p.grey_400,
		textInverse = p.grey_0,
		focus = p.grey_1000,
		accent = p.grey_800,
		accentText = p.grey_0,
		danger = p.grey_700,
		dangerText = p.grey_0,
		success = p.grey_900,
		successText = p.grey_0,
		warning = p.grey_600,
		warningText = p.grey_0,
		info = p.grey_200,
		infoText = p.grey_1000,
		track = p.grey_200,
		fill = p.grey_850,
	}),
})

-- Text on fill: pairs checked by validate against the WCAG thresholds below.
Tokens.CONTRAST_PAIRS = table.freeze({
	{ "text", "background", "body" },
	{ "text", "surface", "body" },
	{ "text", "surfaceRaised", "body" },
	{ "textMuted", "surface", "body" },
	{ "textMuted", "background", "body" },
	{ "accentText", "accent", "body" },
	{ "dangerText", "danger", "body" },
	{ "successText", "success", "body" },
	{ "warningText", "warning", "body" },
	{ "infoText", "info", "body" },
	{ "textInverse", "fill", "body" },
	{ "focus", "background", "ui" },
	{ "fill", "track", "ui" },
})

local BASE = {
	-- Spacing scale in pixels (offsets, paddings, gaps).
	space = { none = 0, xxs = 2, xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32, xxxl = 48 },
	-- Corner radii in pixels; pill is clamped by UICorner to half the short side.
	radius = { none = 0, sm = 4, md = 8, lg = 12, xl = 16, pill = 999 },
	stroke = { hairline = 1, thin = 1.5, thick = 2, focus = 3 },
	size = {
		touchMin = 44, -- convention (minimum touch target, px at phone)
		control = 44,
		controlSmall = 36,
		controlLarge = 56,
		icon = 24,
		iconSmall = 16,
		iconLarge = 32,
		actionButton = 72, -- convention (on-screen touch action button)
		actionButtonSmall = 56, -- convention
		panelMax = 560, -- convention (dialog max width)
		contentMax = 1200, -- convention (readable content width)
	},
	-- Built-in families (rbxasset://fonts/families/<Name>.json): no upload needed.
	font = { body = "BuilderSans", heading = "BuilderSans", mono = "RobotoMono" },
	text = {
		caption = { size = 14, font = "body", weight = "Regular", lineHeight = 1.15 },
		label = { size = 16, font = "body", weight = "Medium", lineHeight = 1.1 },
		body = { size = 18, font = "body", weight = "Regular", lineHeight = 1.2 },
		button = { size = 18, font = "body", weight = "SemiBold", lineHeight = 1 },
		title = { size = 22, font = "heading", weight = "Bold", lineHeight = 1.1 },
		heading = { size = 28, font = "heading", weight = "Bold", lineHeight = 1.05 },
		display = { size = 36, font = "heading", weight = "ExtraBold", lineHeight = 1 },
		numeric = { size = 20, font = "mono", weight = "Medium", lineHeight = 1 },
	},
	textMin = 12, -- convention (readable minimum at phone)
	textMinDocs = 9, -- Roblox docs: never set MinTextSize below 9
	-- ScreenGui DisplayOrder per layer (higher draws on top).
	layer = {
		world = 0,
		hud = 10,
		panel = 20,
		overlay = 30,
		modal = 40,
		toast = 50,
		tooltip = 60,
		cinematic = 80,
		transition = 90,
		debug = 100,
	},
	motion = {
		duration = { instant = 0, fast = 0.12, base = 0.2, slow = 0.32, page = 0.45, emphasis = 0.6 },
		ease = {
			enter = "Quint.Out",
			exit = "Quad.In",
			move = "Cubic.InOut",
			emphasis = "Back.Out",
			linear = "Linear.In",
		},
		-- dampingRatio and frequency (Hz) as in Feel/Spring; ratio < 1 overshoots.
		spring = {
			gentle = { dampingRatio = 1, frequency = 3 },
			snappy = { dampingRatio = 0.82, frequency = 5 },
			bouncy = { dampingRatio = 0.55, frequency = 4 },
		},
		reducedFade = 0.15, -- reduced motion: fades only, at most this long
		tooltipDelay = 0.4, -- convention
		toastDuration = 4, -- convention
	},
	alpha = { scrim = 0.4, disabled = 0.5, subtle = 0.85, glass = 0.12, hidden = 1 },
	-- WCAG 2.x contrast thresholds: body text 4.5, large text 3 (24 px, or 18.66 px bold), UI parts 3.
	contrast = { body = 4.5, large = 3, ui = 3, largeSize = 24, largeBoldSize = 19 },
}

local WEIGHTS =
	{ "Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Heavy" }
Tokens.WEIGHTS = table.freeze(WEIGHTS)

-- ------------------------------------------------------------------ colour maths

local function isRgb(value: any): boolean
	if type(value) ~= "table" or #value ~= 3 then
		return false
	end
	for index = 1, 3 do
		local channel = value[index]
		if not (Check.integer(channel) and channel >= 0 and channel <= 255) then
			return false
		end
	end
	return true
end
Tokens.isRgb = isRgb

local function linear(channel: number): number
	local c = channel / 255
	if c <= 0.04045 then
		return c / 12.92
	end
	return ((c + 0.055) / 1.055) ^ 2.4
end

-- WCAG 2.x relative luminance of an sRGB triple (0 black to 1 white).
function Tokens.luminance(rgb: RGB): number
	assert(isRgb(rgb), "Tokens.luminance: needs an { r, g, b } triple of integers 0-255")
	return 0.2126 * linear(rgb[1]) + 0.7152 * linear(rgb[2]) + 0.0722 * linear(rgb[3])
end

-- WCAG contrast ratio between two colours, 1 (same) to 21 (black on white).
function Tokens.contrast(a: RGB, b: RGB): number
	local la, lb = Tokens.luminance(a), Tokens.luminance(b)
	local hi, lo = math.max(la, lb), math.min(la, lb)
	return (hi + 0.05) / (lo + 0.05)
end

-- The contrast threshold for text of this size and weight (large text needs 3, else 4.5).
function Tokens.requiredContrast(tokens: Tokens, size: number, bold: boolean?): number
	local c = tokens.contrast
	if size >= c.largeSize or (bold and size >= c.largeBoldSize) then
		return c.large
	end
	return c.body
end

-- ------------------------------------------------------------------ resolve and validate

local function deepMerge(base: any, patch: any, path: string, problems: { string })
	for key, value in patch do
		local where = if path == "" then tostring(key) else path .. "." .. tostring(key)
		local current = base[key]
		if current == nil then
			table.insert(problems, where .. ": unknown token")
		elseif
			type(current) == "table"
			and not isRgb(current)
			and type(value) == "table"
			and not isRgb(value)
		then
			deepMerge(current, value, where, problems)
		elseif type(current) ~= type(value) then
			table.insert(
				problems,
				string.format("%s: expected %s, got %s", where, type(current), type(value))
			)
		else
			base[key] = Check.copy(value)
		end
	end
end

export type ResolveOptions = { colorblindMode: string?, colorblind: { [string]: { [string]: RGB } }? }

-- A complete, frozen token table for theme (dark or light) with optional overrides: a partial
-- table of the same shape (color = { accent = { r, g, b } }, space = { md = 14 }, ...). Unknown
-- keys and wrong types raise. options.colorblind maps a settings/1 colorblindMode to slot
-- overrides the game supplies (the greyscale defaults need none).
function Tokens.resolve(theme: string?, overrides: { [string]: any }?, options: ResolveOptions?): Tokens
	local name = theme or Tokens.DEFAULT_THEME
	local colors = (Tokens.THEMES :: any)[name]
	if colors == nil then
		error("Tokens.resolve: unknown theme " .. tostring(name), 2)
	end
	local out: any = Check.copy(BASE)
	out.schema = Tokens.SCHEMA
	out.theme = name
	out.color = Check.copy(colors)
	out.tbd = table.clone(Tokens.TBD :: any)
	if overrides then
		if type(overrides) ~= "table" then
			error("Tokens.resolve: overrides must be a table", 2)
		end
		local problems = {}
		deepMerge(out, overrides, "", problems)
		if #problems > 0 then
			error("Tokens.resolve: " .. table.concat(problems, "; "), 2)
		end
		-- Overridden hue slots are no longer placeholders.
		if type(overrides.color) == "table" then
			local remaining = {}
			for _, slot in out.tbd do
				if overrides.color[slot] == nil then
					table.insert(remaining, slot)
				end
			end
			out.tbd = remaining
		end
	end
	local mode = options and options.colorblindMode
	if mode and mode ~= "none" and options and options.colorblind and options.colorblind[mode] then
		local problems = {}
		deepMerge(out.color, options.colorblind[mode], "color", problems)
		if #problems > 0 then
			error("Tokens.resolve: " .. table.concat(problems, "; "), 2)
		end
	end
	local problems = Tokens.validate(out)
	if #problems > 0 then
		error("Tokens.resolve: " .. table.concat(problems, "; "), 2)
	end
	return Check.freeze(out)
end

-- Problems with a resolved token table (empty when valid): every slot is a colour, sizes are
-- sane, fonts and weights are known and every listed text/fill pair meets its WCAG threshold.
function Tokens.validate(tokens: any): { string }
	if type(tokens) ~= "table" then
		return { "tokens must be a table" }
	end
	local problems = {}
	if tokens.schema ~= Tokens.SCHEMA then
		table.insert(problems, "schema must be " .. Tokens.SCHEMA)
	end
	local color = tokens.color
	if type(color) ~= "table" then
		table.insert(problems, "color must be a table of slots")
		return problems
	end
	for _, slot in Tokens.SLOTS do
		if not isRgb(color[slot]) then
			table.insert(problems, "color." .. slot .. ": needs an { r, g, b } triple of integers 0-255")
		end
	end
	for _, group in { "space", "radius", "stroke", "size", "layer" } do
		local values = tokens[group]
		if type(values) ~= "table" then
			table.insert(problems, group .. " must be a table")
			continue
		end
		for key, value in values do
			if not (Check.finite(value) and value >= 0) then
				table.insert(problems, string.format("%s.%s must be a number >= 0", group, tostring(key)))
			end
		end
	end
	if not (Check.finite(tokens.textMin) and tokens.textMin >= tokens.textMinDocs) then
		table.insert(problems, "textMin must be >= textMinDocs (" .. tostring(tokens.textMinDocs) .. ")")
	end
	if type(tokens.font) ~= "table" then
		table.insert(problems, "font must map roles to built-in family names")
	else
		for role, family in tokens.font do
			if type(family) ~= "string" or not string.match(family, "^%u[%w]+$") then
				table.insert(
					problems,
					"font." .. tostring(role) .. " must be a family name such as BuilderSans"
				)
			end
		end
	end
	if type(tokens.text) ~= "table" then
		table.insert(problems, "text must be a table of text styles")
	else
		for role, style in tokens.text do
			local where = "text." .. tostring(role)
			if type(style) ~= "table" then
				table.insert(problems, where .. " must be a table")
				continue
			end
			if not (Check.finite(style.size) and style.size >= tokens.textMin) then
				table.insert(problems, where .. ".size must be >= textMin")
			end
			if type(tokens.font) == "table" and tokens.font[style.font] == nil then
				table.insert(problems, where .. ".font names no font role")
			end
			if not table.find(WEIGHTS, style.weight) then
				table.insert(problems, where .. ".weight must be a FontWeight name")
			end
			if not (Check.finite(style.lineHeight) and style.lineHeight >= 1 and style.lineHeight <= 3) then
				table.insert(problems, where .. ".lineHeight must be within 1-3")
			end
		end
	end
	local motion = tokens.motion
	if type(motion) ~= "table" or type(motion.duration) ~= "table" then
		table.insert(problems, "motion.duration must be a table")
	else
		for key, value in motion.duration do
			if not (Check.finite(value) and value >= 0 and value <= 5) then
				table.insert(problems, "motion.duration." .. tostring(key) .. " must be within 0-5 s")
			end
		end
		for key, spring in motion.spring or {} do
			if
				type(spring) ~= "table"
				or not (Check.finite(spring.dampingRatio) and spring.dampingRatio > 0)
				or not (Check.finite(spring.frequency) and spring.frequency > 0)
			then
				table.insert(
					problems,
					"motion.spring." .. tostring(key) .. " needs dampingRatio > 0 and frequency > 0"
				)
			end
		end
	end
	if #problems == 0 then
		for _, pair in Tokens.CONTRAST_PAIRS do
			local fg, bg, kind = pair[1], pair[2], pair[3]
			local ratio = Tokens.contrast(color[fg], color[bg])
			local need = tokens.contrast[kind]
			if ratio + 1e-9 < need then
				table.insert(
					problems,
					string.format("contrast %s on %s is %.2f, needs %.1f (%s)", fg, bg, ratio, need, kind)
				)
			end
		end
	end
	return problems
end

-- A space token in pixels; numbers pass through (so props may say "md" or 10).
function Tokens.space(tokens: Tokens, value: any): number
	if type(value) == "number" then
		return value
	end
	local px = tokens.space[value]
	if px == nil then
		error("Tokens.space: unknown space token " .. tostring(value), 2)
	end
	return px
end

-- An 8-hex digest of the canonical JSON of a token table (same tokens, same digest everywhere).
function Tokens.digest(tokens: Tokens): string
	return string.format("%08x", Rng.hash(Json.encode(tokens)))
end

return Tokens
