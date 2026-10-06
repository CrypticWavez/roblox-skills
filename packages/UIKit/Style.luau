--!strict
-- @tier T1
-- Style: resolves UIKit tokens to Instance property values, and emits the same tokens as a
-- StyleSheet plan. Decision (docs/uikit.md "Styling decision"): components get their
-- properties from this pure resolver at build time, so Lune specs see exact values and
-- transitions can tween them; UIKit/StyleRoblox turns Style.sheet(tokens) into a native
-- StyleSheet (token attributes, StyleRule per tag and GuiState, StyleQuery breakpoints) for
-- live theming, hover/press states and device queries, which Lune cannot evaluate. Text always
-- uses FontFace (Font.new on a built-in family), never the legacy Font enum. Datatypes come from
-- env.roblox (the globals in Roblox, @lune/roblox in Lune); env is the last parameter.
local Breakpoints = require("./Breakpoints")
local Check = require("../GameKit/Check")
local Tokens = require("./Tokens")

local Style = {}
Style.PLAN_SCHEMA = "uikit-stylesheet/1"
Style.FONT_ROOT = "rbxasset://fonts/families/"

local function roblox(env: any): any
	local r = env and env.roblox
	if r == nil then
		error("Style: env.roblox (Roblox datatypes) is required", 3)
	end
	return r
end

-- Color3 for an { r, g, b } triple.
function Style.rgb(rgb: { number }, env: any): any
	return roblox(env).Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

-- Color3 for a semantic slot ("surface", "text", ...).
function Style.color(tokens: Tokens.Tokens, slot: string, env: any): any
	local rgb = tokens.color[slot]
	if rgb == nil then
		error("Style.color: unknown colour slot " .. tostring(slot), 2)
	end
	return Style.rgb(rgb, env)
end

-- The asset path of a built-in font family.
function Style.familyPath(family: string): string
	return Style.FONT_ROOT .. family .. ".json"
end

-- FontFace for a text role ("body", "title", ...) or a font role with an explicit weight.
function Style.font(tokens: Tokens.Tokens, role: string, env: any, weight: string?): any
	local r = roblox(env)
	local style = tokens.text[role]
	local family, w
	if style then
		family, w = tokens.font[style.font], weight or style.weight
	else
		family, w = tokens.font[role], weight or "Regular"
	end
	if family == nil then
		error("Style.font: unknown text or font role " .. tostring(role), 2)
	end
	return r.Font.new(Style.familyPath(family), r.Enum.FontWeight[w], r.Enum.FontStyle.Normal)
end

-- Properties for a text object in a role: FontFace, TextSize, LineHeight and colour.
function Style.text(tokens: Tokens.Tokens, role: string, env: any, slot: string?): { [string]: any }
	local style = tokens.text[role]
	if style == nil then
		error("Style.text: unknown text role " .. tostring(role), 2)
	end
	return {
		FontFace = Style.font(tokens, role, env),
		TextSize = style.size,
		LineHeight = style.lineHeight,
		TextColor3 = Style.color(tokens, slot or "text", env),
	}
end

-- Background properties for a colour slot (BorderSizePixel 0: borders come from UIStroke).
function Style.surface(
	tokens: Tokens.Tokens,
	slot: string,
	env: any,
	transparency: number?
): { [string]: any }
	return {
		BackgroundColor3 = Style.color(tokens, slot, env),
		BackgroundTransparency = transparency or 0,
		BorderSizePixel = 0,
	}
end

function Style.radius(tokens: Tokens.Tokens, name: string | number, env: any): any
	local px = if type(name) == "number" then name else tokens.radius[name]
	if px == nil then
		error("Style.radius: unknown radius " .. tostring(name), 2)
	end
	return roblox(env).UDim.new(0, px)
end

-- UIPadding properties from a space token (all sides) or { top, right, bottom, left } tokens.
function Style.padding(tokens: Tokens.Tokens, spec: any, env: any): { [string]: any }
	local UDim = roblox(env).UDim
	local top, right, bottom, left
	if type(spec) == "table" then
		top, right, bottom, left =
			spec[1], spec[2] or spec[1], spec[3] or spec[1], spec[4] or spec[2] or spec[1]
	else
		top, right, bottom, left = spec, spec, spec, spec
	end
	return {
		PaddingTop = UDim.new(0, Tokens.space(tokens, top)),
		PaddingRight = UDim.new(0, Tokens.space(tokens, right)),
		PaddingBottom = UDim.new(0, Tokens.space(tokens, bottom)),
		PaddingLeft = UDim.new(0, Tokens.space(tokens, left)),
	}
end

-- UIStroke properties for a border in a colour slot.
function Style.stroke(
	tokens: Tokens.Tokens,
	slot: string,
	width: string | number,
	env: any
): { [string]: any }
	local r = roblox(env)
	local px = if type(width) == "number" then width else tokens.stroke[width]
	if px == nil then
		error("Style.stroke: unknown stroke width " .. tostring(width), 2)
	end
	return {
		Color = Style.color(tokens, slot, env),
		Thickness = px,
		ApplyStrokeMode = r.Enum.ApplyStrokeMode.Border,
	}
end

-- ------------------------------------------------------------------ StyleSheet plan

export type Token = { kind: "Color3" | "number" | "UDim" | "Font", value: any }
export type Rule = { selector: string, priority: number, properties: { [string]: any }, children: { Rule }? }
export type Plan = {
	schema: string,
	theme: string,
	tokens: { [string]: Token },
	rules: { Rule },
	queries: { Breakpoints.Query },
}

local function tokenName(group: string, key: string): string
	local head = string.upper(string.sub(group, 1, 1)) .. string.sub(group, 2)
	local tail = string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)
	return head .. tail
end

-- Variant and part tags components add (CollectionService tags, matched as .Tag selectors).
Style.VARIANTS = table.freeze({
	Button = { "Primary", "Secondary", "Ghost", "Danger" },
})

-- The StyleSheet plan for a token table: token attributes (ColorText, SpaceMd, RadiusMd, ...)
-- and rules that reference them as "$Token". Selectors use only tags (.Button), modifiers
-- (::UICorner), states (:Hover, :Press, :NonInteractable) and queries (@Compact); composed
-- selector syntax beyond these is UNVERIFIED, so each rule uses one tag plus at most one
-- state or modifier.
function Style.sheet(tokens: Tokens.Tokens): Plan
	local planTokens: { [string]: Token } = {}
	for slot, rgb in tokens.color do
		planTokens[tokenName("color", slot)] = { kind = "Color3", value = Check.copy(rgb) }
	end
	for key, px in tokens.space do
		planTokens[tokenName("space", key)] = { kind = "UDim", value = { 0, px } }
	end
	for key, px in tokens.radius do
		planTokens[tokenName("radius", key)] = { kind = "UDim", value = { 0, px } }
	end
	for key, px in tokens.stroke do
		planTokens[tokenName("stroke", key)] = { kind = "number", value = px }
	end
	for role, style in tokens.text do
		planTokens[tokenName("text", role)] = { kind = "number", value = style.size }
		planTokens[tokenName("font", role)] = {
			kind = "Font",
			value = { family = Style.familyPath(tokens.font[style.font]), weight = style.weight },
		}
	end
	local rules: { Rule } = {
		{
			selector = ".UIKitSurface",
			priority = 0,
			properties = { BackgroundColor3 = "$ColorSurface", BorderSizePixel = 0 },
		},
		{ selector = ".UIKitText", priority = 0, properties = { TextColor3 = "$ColorText" } },
		{ selector = ".UIKitMuted", priority = 1, properties = { TextColor3 = "$ColorTextMuted" } },
		{ selector = ".Button::UICorner", priority = 0, properties = { CornerRadius = "$RadiusMd" } },
		{ selector = ".Primary", priority = 1, properties = { BackgroundColor3 = "$ColorAccent" } },
		{ selector = ".Secondary", priority = 1, properties = { BackgroundColor3 = "$ColorSurfaceRaised" } },
		{ selector = ".Ghost", priority = 1, properties = { BackgroundTransparency = 1 } },
		{ selector = ".Danger", priority = 1, properties = { BackgroundColor3 = "$ColorDanger" } },
		{ selector = ".Button:Hover", priority = 2, properties = { BackgroundTransparency = 0.08 } },
		{ selector = ".Button:Press", priority = 3, properties = { BackgroundTransparency = 0.18 } },
		{
			selector = ".Button:NonInteractable",
			priority = 4,
			properties = { BackgroundTransparency = tokens.alpha.disabled },
		},
		-- A query rule holds the rules that apply while its StyleQuery is active.
		{
			selector = "@Compact",
			priority = 5,
			properties = {},
			children = {
				{ selector = ".UIKitTitle", priority = 0, properties = { TextSize = "$TextLabel" } },
			},
		},
	}
	return {
		schema = Style.PLAN_SCHEMA,
		theme = tokens.theme,
		tokens = planTokens,
		rules = rules,
		queries = Breakpoints.queries(),
	}
end

local function selectorOk(selector: string, queries: { [string]: boolean }): (boolean, string?)
	local query = string.match(selector, "^@(%a+)$")
	if query then
		return queries[query] == true, "names no StyleQuery"
	end
	local tag, rest = string.match(selector, "^%.(%a+)(.*)$")
	if tag == nil or rest == nil then -- rest is never nil when tag matched; this narrows it
		return false, "must start with .Tag or @Query"
	end
	if rest == "" then
		return true, nil
	end
	if string.match(rest, "^::%a+$") or string.match(rest, "^:%a+$") then
		local state = string.match(rest, "^:(%a+)$")
		if
			state
			and state ~= "Hover"
			and state ~= "Press"
			and state ~= "NonInteractable"
			and state ~= "Idle"
		then
			return false, "state must be a GuiState (Idle, Hover, Press, NonInteractable)"
		end
		return true, nil
	end
	return false, "only one ::Modifier or :State after the tag"
end

-- Problems with a plan: every "$Token" reference resolves, selectors use the allowed forms and
-- every @Query names a query.
function Style.validateSheet(plan: any): { string }
	if type(plan) ~= "table" or plan.schema ~= Style.PLAN_SCHEMA then
		return { "plan must be a " .. Style.PLAN_SCHEMA .. " table" }
	end
	local problems = {}
	local queries: { [string]: boolean } = {}
	for _, query in plan.queries do
		queries[query.name] = true
	end
	local function check(rules: any, prefix: string)
		for index, rule in rules do
			local where = string.format("%s[%d] %s", prefix, index, tostring(rule.selector))
			local ok, why = selectorOk(tostring(rule.selector), queries)
			if not ok then
				table.insert(problems, where .. ": selector " .. tostring(why))
			end
			if not Check.integer(rule.priority) then
				table.insert(problems, where .. ": priority must be an integer")
			end
			for property, value in rule.properties do
				if type(value) == "string" and string.sub(value, 1, 1) == "$" then
					if plan.tokens[string.sub(value, 2)] == nil then
						table.insert(
							problems,
							string.format("%s: %s references unknown token %s", where, property, value)
						)
					end
				end
			end
			if rule.children ~= nil then
				if string.sub(tostring(rule.selector), 1, 1) ~= "@" then
					table.insert(problems, where .. ": only @Query rules hold child rules")
				end
				check(rule.children, where .. ".children")
			end
		end
	end
	check(plan.rules, "rules")
	return problems
end

-- A plan token as a Roblox value (Color3, UDim, number or Font).
function Style.tokenValue(token: Token, env: any): any
	local r = roblox(env)
	if token.kind == "Color3" then
		return r.Color3.fromRGB(token.value[1], token.value[2], token.value[3])
	elseif token.kind == "UDim" then
		return r.UDim.new(token.value[1], token.value[2])
	elseif token.kind == "Font" then
		return r.Font.new(token.value.family, r.Enum.FontWeight[token.value.weight], r.Enum.FontStyle.Normal)
	end
	return token.value
end

return Style
