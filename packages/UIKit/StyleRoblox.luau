--!strict
-- @tier T3
-- probe: ui_style_sheet
-- StyleRoblox: turns a UIKit/Style plan (Style.sheet(tokens)) into native UI Styling instances
-- (docs/uikit.md "Styling decision"): a StyleSheet whose attributes are the tokens (ColorText,
-- SpaceMd, FontBody, ...), one StyleRule per plan rule (Selector, Priority and SetProperties
-- with "$Token" references kept as references), query rules with their child rules, and one
-- StyleQuery per Breakpoints query. link(sheet, gui) adds the StyleLink that applies it to a
-- ScreenGui. Swapping theme = applying another plan's tokens with retheme(sheet, plan), so no
-- component repaints. Instructions are computed purely (StyleRoblox.instructions, Lune-tested);
-- only apply/link touch the engine, and whether the engine applies them (selectors, query
-- conditions, precedence over properties components set at build) is proven only by probe
-- ui_style_sheet. setProperties and setConditions are injectable for that reason.
local Style = require("./Style")

local StyleRoblox = {}

export type Instruction = {
	kind: "rule" | "query",
	name: string,
	parent: string?, -- name of the parent rule (query rules hold child rules)
	selector: string?,
	priority: number?,
	properties: { [string]: any }?,
	conditions: { [string]: any }?,
}

local function ruleName(selector: string, index: number): string
	local clean = string.gsub(selector, "[^%w]", "")
	return string.format("%02d_%s", index, clean)
end

-- The instance plan for a Style plan: rules (depth-first, children after their query rule)
-- then queries. Pure: values stay as plan values ("$Token" strings, numbers, booleans).
function StyleRoblox.instructions(plan: Style.Plan): { Instruction }
	local problems = Style.validateSheet(plan)
	if #problems > 0 then
		error("StyleRoblox: " .. table.concat(problems, "; "), 2)
	end
	local out: { Instruction } = {}
	local function walk(rules: { Style.Rule }, parent: string?)
		for index, rule in rules do
			local name = ruleName(rule.selector, index)
			table.insert(out, {
				kind = "rule",
				name = name,
				parent = parent,
				selector = rule.selector,
				priority = rule.priority,
				properties = rule.properties,
			})
			if rule.children then
				walk(rule.children, name)
			end
		end
	end
	walk(plan.rules, nil)
	for _, query in plan.queries do
		table.insert(out, { kind = "query", name = query.name, conditions = query.conditions })
	end
	return out
end

-- A condition value as a Roblox value (Vector2 for { x, y }, NumberRange for AspectRatioRange,
-- Enum items for PreferredInput / PreferredTextSize names).
local function conditionValue(r: any, name: string, value: any): any
	if name == "MinSize" or name == "MaxSize" then
		return r.Vector2.new(value[1], value[2])
	elseif name == "AspectRatioRange" then
		return r.NumberRange.new(value[1], value[2])
	elseif name == "PreferredInput" then
		return r.Enum.PreferredInput[value]
	elseif name == "PreferredTextSize" then
		return r.Enum.PreferredTextSize[value]
	end
	return value
end

export type ApplyOptions = {
	parent: any?,
	name: string?,
	setProperties: ((rule: any, properties: { [string]: any }) -> ())?,
	setConditions: ((query: any, conditions: { [string]: any }) -> ())?,
}

-- Builds the StyleSheet (not parented unless options.parent).
function StyleRoblox.apply(plan: Style.Plan, env: any, options: ApplyOptions?): any
	local r = env and env.roblox
	assert(r, "StyleRoblox.apply: env.roblox is required")
	local o: ApplyOptions = options or {}
	local setProperties = o.setProperties
		or function(rule: any, properties: { [string]: any })
			rule:SetProperties(properties)
		end
	local setConditions = o.setConditions
		or function(query: any, conditions: { [string]: any })
			for key, value in conditions do
				query[key] = value
			end
		end
	local sheet = r.Instance.new("StyleSheet")
	sheet.Name = o.name or ("UIKit_" .. plan.theme)
	StyleRoblox.retheme(sheet, plan, env)
	local byName: { [string]: any } = {}
	for _, item in StyleRoblox.instructions(plan) do
		if item.kind == "rule" then
			local rule = r.Instance.new("StyleRule")
			rule.Name = item.name
			rule.Selector = item.selector
			rule.Priority = item.priority
			setProperties(rule, item.properties :: { [string]: any })
			rule.Parent = if item.parent then byName[item.parent] else sheet
			byName[item.name] = rule
		else
			local query = r.Instance.new("StyleQuery")
			query.Name = item.name
			local conditions = {}
			for key, value in item.conditions :: { [string]: any } do
				conditions[key] = conditionValue(r, key, value)
			end
			setConditions(query, conditions)
			query.Parent = sheet
		end
	end
	sheet.Parent = o.parent
	return sheet
end

-- Writes a plan's tokens as the sheet's attributes (a theme swap is just this call).
function StyleRoblox.retheme(sheet: any, plan: Style.Plan, env: any)
	local names = {}
	for name in plan.tokens do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		sheet:SetAttribute(name, Style.tokenValue(plan.tokens[name], env))
	end
end

-- A StyleLink under gui pointing at sheet.
function StyleRoblox.link(sheet: any, gui: any, env: any): any
	local link = env.roblox.Instance.new("StyleLink")
	link.Name = "UIKitStyle"
	link.StyleSheet = sheet
	link.Parent = gui
	return link
end

return StyleRoblox
