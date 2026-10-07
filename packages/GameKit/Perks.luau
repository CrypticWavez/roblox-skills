--!strict
-- @tier T0
-- Perks: what owning a pass, a subscription or an entitlement does (perks/1 data,
-- docs/monetization.md). Top games sell the same few pass shapes: a currency or XP multiplier
-- (2x cash), more slots or storage, faster movement or production, an auto-collect or
-- auto-sell switch, a VIP tag and area. Perks keep those effects as data so game code asks one
-- question (value(stat, base) or has(flag)) instead of checking passes everywhere. Data:
--   { schema = "perks/1", stats? = { [stat] = { combine = "multiply" | "add" | "max", cap? } },
--     perks = { { key, source = { productKey? | entitlement? }, effects = { Effect } } } }
--   Effect = { stat, multiplier? | add? } or { flag }
-- source.productKey names a catalog/1 gamepass or subscription (ownership from
-- GameKit/Commerce.ownership); source.entitlement names an entitlement grant (a developer
-- product that unlocks something for good, or a gift). resolve(perks, owns) takes a predicate
-- over those sources and returns the player's resolved effects; ownership that is unknown is
-- not owned (Commerce's rule), so a perk stays off until a check succeeds.
local Check = require("./Check")

local Perks = {}
Perks.SCHEMA = "perks/1"
Perks.COMBINES = table.freeze({ "multiply", "add", "max" })

export type Effect = { stat: string?, multiplier: number?, add: number?, flag: string? }
export type Source = { productKey: string?, entitlement: string? }
export type Perk = { key: string, source: Source, effects: { Effect } }
export type StatRule = { combine: "multiply" | "add" | "max", cap: number? }
export type Data = { schema: string, stats: { [string]: StatRule }?, perks: { Perk } }
export type Resolved = {
	perks: { string },
	flags: { [string]: boolean },
	stats: { [string]: { factor: number, extra: number, best: number, bonus: number } },
	rules: { [string]: StatRule },
}

local function effectProblems(effect: any, where: string, problems: { string })
	if type(effect) ~= "table" then
		table.insert(problems, where .. " must be a table")
		return
	end
	for key in effect do
		if key ~= "stat" and key ~= "multiplier" and key ~= "add" and key ~= "flag" then
			table.insert(problems, where .. ": unexpected key " .. Check.describe(key))
		end
	end
	if effect.flag ~= nil then
		if not Check.label(effect.flag) then
			table.insert(problems, where .. ".flag must be a label")
		end
		if effect.stat ~= nil or effect.multiplier ~= nil or effect.add ~= nil then
			table.insert(problems, where .. ": a flag effect has no stat, multiplier or add")
		end
		return
	end
	if not Check.label(effect.stat) then
		table.insert(problems, where .. ".stat must be a label (or give a flag)")
	end
	local hasMul, hasAdd = effect.multiplier ~= nil, effect.add ~= nil
	if hasMul == hasAdd then
		table.insert(problems, where .. ": exactly one of multiplier or add")
	elseif hasMul and not (Check.finite(effect.multiplier) and effect.multiplier > 0) then
		table.insert(problems, where .. ".multiplier must be a number > 0")
	elseif hasAdd and not Check.finite(effect.add) then
		table.insert(problems, where .. ".add must be a finite number")
	end
end

-- Problems with perks/1 data (empty when valid). With a catalog/1 table, a productKey source
-- must name a gamepass or subscription in it (developer products are consumed, not owned).
function Perks.validate(data: any, catalog: any?): { string }
	if type(data) ~= "table" then
		return { "perks must be a table" }
	end
	local problems = {}
	if data.schema ~= Perks.SCHEMA then
		table.insert(problems, "schema must be " .. Perks.SCHEMA)
	end
	for key in data do
		if key ~= "schema" and key ~= "stats" and key ~= "perks" then
			table.insert(problems, "unexpected key " .. Check.describe(key))
		end
	end
	if data.stats ~= nil then
		if type(data.stats) ~= "table" then
			table.insert(problems, "stats must be a map")
		else
			for stat, rule in data.stats do
				if
					not Check.label(stat)
					or type(rule) ~= "table"
					or not table.find(Perks.COMBINES, rule.combine)
				then
					table.insert(
						problems,
						"stats." .. tostring(stat) .. " must be { combine = multiply | add | max, cap? }"
					)
				elseif rule.cap ~= nil and not (Check.finite(rule.cap) and rule.cap > 0) then
					table.insert(problems, "stats." .. stat .. ".cap must be a number > 0")
				end
			end
		end
	end
	if type(data.perks) ~= "table" then
		table.insert(problems, "perks must be a list")
		return problems
	end
	local seen: { [string]: boolean } = {}
	for index, perk in data.perks do
		local where = "perks[" .. index .. "]"
		if type(perk) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		if Check.label(perk.key) then
			where = perk.key
			if seen[perk.key] then
				table.insert(problems, where .. ": duplicate key")
			end
			seen[perk.key] = true
		else
			table.insert(problems, where .. ".key must be a label")
		end
		for key in perk do
			if key ~= "key" and key ~= "source" and key ~= "effects" then
				table.insert(problems, where .. ": unexpected key " .. Check.describe(key))
			end
		end
		local source = perk.source
		if type(source) ~= "table" or (source.productKey == nil) == (source.entitlement == nil) then
			table.insert(problems, where .. ".source must give exactly one of productKey or entitlement")
		elseif source.productKey ~= nil then
			if not Check.label(source.productKey) then
				table.insert(problems, where .. ".source.productKey must be a label")
			elseif catalog ~= nil and type(catalog) == "table" and type(catalog.products) == "table" then
				local kind = nil
				for _, product in catalog.products do
					if product.key == source.productKey then
						kind = product.kind
						break
					end
				end
				if kind == nil then
					table.insert(
						problems,
						where .. ".source.productKey " .. source.productKey .. " is not in the catalog"
					)
				elseif kind == "devproduct" then
					table.insert(
						problems,
						where
							.. ".source: a developer product is not owned; grant an entitlement and use source.entitlement"
					)
				end
			end
		elseif not Check.label(source.entitlement) then
			table.insert(problems, where .. ".source.entitlement must be a label")
		end
		if type(perk.effects) ~= "table" or #perk.effects == 0 then
			table.insert(problems, where .. ".effects must be a non-empty list")
		else
			for eindex, effect in perk.effects do
				effectProblems(effect, string.format("%s.effects[%d]", where, eindex), problems)
			end
		end
	end
	return problems
end

function Perks.define(data: any, catalog: any?): Data
	local problems = Perks.validate(data, catalog)
	if #problems > 0 then
		error("Perks.define: " .. table.concat(problems, "; "), 2)
	end
	return Check.freeze(Check.copy(data))
end

-- The effects of every perk whose source owns(source) answers true for. owns errors count as not
-- owned. The result is plain data: cache it per player and resolve again when ownership changes
-- (Commerce ownership changed signal, a new entitlement).
function Perks.resolve(data: Data, owns: (source: Source) -> boolean): Resolved
	local resolved: Resolved = { perks = {}, flags = {}, stats = {}, rules = (data.stats or {}) :: any }
	for _, perk in data.perks do
		local ok, owned = pcall(owns, perk.source)
		if not ok or owned ~= true then
			continue
		end
		table.insert(resolved.perks, perk.key)
		for _, effect in perk.effects do
			if effect.flag ~= nil then
				resolved.flags[effect.flag] = true
				continue
			end
			local stat = effect.stat :: string
			local entry = resolved.stats[stat]
			if entry == nil then
				entry = { factor = 1, extra = 0, best = 1, bonus = 0 }
				resolved.stats[stat] = entry
			end
			if effect.multiplier ~= nil then
				entry.factor *= effect.multiplier
				entry.extra += effect.multiplier - 1
				entry.best = math.max(entry.best, effect.multiplier)
			else
				entry.bonus += effect.add :: number
			end
		end
	end
	table.sort(resolved.perks)
	return resolved
end

-- stat applied to base (default 1) under the stat's combine rule (default multiply), with flat
-- adds after the multipliers and the cap (a multiple of base) last.
function Perks.value(resolved: Resolved, stat: string, base: number?): number
	local start = base or 1
	local entry = resolved.stats[stat]
	if entry == nil then
		return start
	end
	local rule: StatRule = resolved.rules[stat] or { combine = "multiply" }
	local result
	if rule.combine == "add" then
		result = start * (1 + entry.extra) + entry.bonus
	elseif rule.combine == "max" then
		result = start * entry.best + entry.bonus
	else
		result = start * entry.factor + entry.bonus
	end
	if rule.cap ~= nil then
		result = math.min(result, start * rule.cap)
	end
	return result
end

function Perks.has(resolved: Resolved, flag: string): boolean
	return resolved.flags[flag] == true
end

return Perks
