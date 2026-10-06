--!strict
-- @tier T0
-- OddsTable: weighted random outcomes with an exact odds disclosure and a paid-roll policy gate.
-- Roblox's paid random items rules (docs/research/release-monetization-analytics-2026-10.md,
-- section 1e) require odds shown as percentages that "sum to exactly 100%", updated when an
-- outcome can only be obtained once, with probability modifiers numerically explained, and a
-- treatment where ArePaidRandomItemsRestricted is true. So:
--   * weights are integers (exact maths); disclose() splits 1,000,000 units (0.0001 % each) by
--     the largest-remainder method, so the shown percentages always sum to exactly 100.0000 %;
--   * a paid roll (table option paid, or ctx.paid) refuses unless ctx.policyAllows is true or a
--     predicate that returns true for "paidRandomItems" (G1 PolicyGate, fail closed); roll()
--     raises, tryRoll() returns (false, reason) so the game can apply its treatment;
--   * entries with once = true drop out when ctx.owned[id] is set, in rolls and disclosure alike;
--   * ctx.boost = { [id] = integer factor } and the pity rule change odds identically in roll and
--     disclose, and disclose() reports both, so modifiers are numerically explained;
--   * draws are unbiased integers (rejection sampling on ProcGen/Rng's 32-bit output).
-- Pity: { threshold = n, targets = { ids } }: the n-th consecutive roll without a target draws
-- from the targets only. The count is the caller's per-player data (ctx.pity in, result.pity out).
-- No outcomes or weights ship here.
local Check = require("./Check")
local Rng = require("../ProcGen/Rng")

local OddsTable = {}
OddsTable.__index = OddsTable
OddsTable.SCALE = 1000000 -- disclosure units in 100 %: 1 unit = 0.0001 %
-- Largest total weight: keeps weight * SCALE exact below 2^53 and draws unbiased from 32 bits.
OddsTable.MAX_TOTAL = 2 ^ 31
OddsTable.POLICY_FEATURE = "paidRandomItems"

export type Entry = {
	id: string,
	weight: number,
	once: boolean?,
	tags: { string }?,
	data: { [string]: any }?,
}
export type Options = {
	name: string?,
	paid: boolean?,
	pity: { threshold: number, targets: { string } }?,
}
export type Context = {
	paid: boolean?,
	policyAllows: any?, -- true, or (feature) -> boolean
	owned: { [string]: boolean }?,
	exclude: { [string]: boolean }?,
	boost: { [string]: number }?,
	pity: number?,
	rng: Rng.Rng?,
}
export type Line = { id: string, units: number, percent: number, text: string, weight: number }
export type Disclosure = {
	name: string?,
	paid: boolean,
	total: number, -- sum of units: always SCALE
	entries: { Line },
	guaranteed: boolean, -- this roll is a pity roll
	pity: { threshold: number, targets: { string }, rollsLeft: number?, odds: { Line } }?,
	warnings: { string },
}
export type Result = { id: string, entry: Entry, pity: number, pityTriggered: boolean, paid: boolean }

type TableFields = {
	name: string?,
	paid: boolean,
	_entries: { Entry },
	_byId: { [string]: Entry },
	_pity: { threshold: number, targets: { string } }?,
	_rng: Rng.Rng?,
}
export type OddsTable = typeof(setmetatable({} :: TableFields, OddsTable))

-- Text for units (0..SCALE) as a percentage with exactly four decimals: 123456 -> "12.3456%".
function OddsTable.format(units: number): string
	return string.format("%d.%04d%%", units // 10000, units % 10000)
end

-- Splits SCALE units over integer weights by the largest-remainder method. The result sums to
-- exactly SCALE; ties go to the earlier entry. Weights must be integers >= 1 with a total of at
-- most MAX_TOTAL.
function OddsTable.apportion(weights: { number }): { number }
	local total = 0
	for _, weight in weights do
		assert(Check.integer(weight) and weight >= 1, "OddsTable.apportion: weights must be integers >= 1")
		total += weight
	end
	assert(total >= 1 and total <= OddsTable.MAX_TOTAL, "OddsTable.apportion: total weight out of range")
	local units, remainders, used = {}, {}, 0
	for index, weight in weights do
		local scaled = weight * OddsTable.SCALE -- exact: < 2^31 * 10^6 < 2^53
		units[index] = scaled // total
		remainders[index] = scaled % total
		used += units[index]
	end
	local order = {}
	for index in weights do
		table.insert(order, index)
	end
	table.sort(order, function(a: number, b: number): boolean
		if remainders[a] ~= remainders[b] then
			return remainders[a] > remainders[b]
		end
		return a < b
	end)
	for rank = 1, OddsTable.SCALE - used do
		local index = order[rank]
		units[index] += 1
	end
	return units
end

-- Problems with entries and options (empty when valid), including outcomes that would be shown
-- as 0.0000 %.
function OddsTable.validate(entries: any, options: any?): { string }
	if type(entries) ~= "table" or #entries == 0 then
		return { "entries must be a non-empty list" }
	end
	local problems = {}
	local seen: { [string]: boolean } = {}
	local total = 0
	for index, entry in entries do
		local where = "entry "
			.. (
				if type(entry) == "table" and type(entry.id) == "string"
					then entry.id
					else "#" .. tostring(index)
			)
		if type(entry) ~= "table" then
			table.insert(problems, where .. ": must be a table")
			continue
		end
		if not Check.label(entry.id) then
			table.insert(problems, where .. ": id is not a label")
		elseif seen[entry.id] then
			table.insert(problems, where .. ": duplicate id")
		end
		seen[entry.id] = true
		if not (Check.integer(entry.weight) and entry.weight >= 1) then
			table.insert(
				problems,
				where .. ": weight must be an integer >= 1 (scale fractions, e.g. 0.5 % -> 5000 of 1000000)"
			)
		else
			total += entry.weight
		end
		if entry.once ~= nil and type(entry.once) ~= "boolean" then
			table.insert(problems, where .. ": once must be a boolean")
		end
		for key in entry do
			if not table.find({ "id", "weight", "once", "tags", "data" }, key) then
				table.insert(problems, where .. ": unknown key " .. Check.describe(key))
			end
		end
	end
	if total > OddsTable.MAX_TOTAL then
		table.insert(problems, string.format("total weight %d exceeds %d", total, OddsTable.MAX_TOTAL))
	end
	if options ~= nil then
		if type(options) ~= "table" then
			table.insert(problems, "options must be a table")
		else
			if options.name ~= nil and not Check.label(options.name) then
				table.insert(problems, "name must be a label")
			end
			if options.paid ~= nil and type(options.paid) ~= "boolean" then
				table.insert(problems, "paid must be a boolean")
			end
			local pity = options.pity
			if pity ~= nil then
				if type(pity) ~= "table" or not (Check.integer(pity.threshold) and pity.threshold >= 2) then
					table.insert(problems, "pity.threshold must be an integer >= 2")
				end
				if type(pity) ~= "table" or type(pity.targets) ~= "table" or #pity.targets == 0 then
					table.insert(problems, "pity.targets must be a non-empty list of entry ids")
				else
					for _, id in pity.targets do
						if not seen[id] then
							table.insert(problems, "pity target " .. Check.describe(id) .. " is not an entry")
						end
					end
				end
			end
		end
	end
	if #problems == 0 then
		local weights = {}
		for _, entry in entries do
			table.insert(weights, entry.weight)
		end
		for index, units in OddsTable.apportion(weights) do
			if units == 0 then
				table.insert(
					problems,
					string.format(
						"entry %s would be shown as 0.0000%%; raise its weight or drop it",
						entries[index].id
					)
				)
			end
		end
	end
	return problems
end

-- A table over validated entries. rng (ProcGen/Rng, e.g. env.rng(seed)) is the default draw
-- source; ctx.rng overrides it per roll. Raises with every problem listed.
function OddsTable.new(entries: { Entry }, rng: Rng.Rng?, options: Options?): OddsTable
	local problems = OddsTable.validate(entries, options)
	if #problems > 0 then
		error("OddsTable.new: " .. table.concat(problems, "; "), 2)
	end
	local list, byId = {}, {}
	for _, raw in entries do
		local entry = Check.freeze(Check.copy(raw))
		table.insert(list, entry)
		byId[entry.id] = entry
	end
	local pity = options and options.pity
	return setmetatable({
		name = options and options.name,
		paid = options ~= nil and options.paid == true,
		_entries = list,
		_byId = byId,
		_pity = if pity
			then Check.freeze({ threshold = pity.threshold, targets = table.clone(pity.targets) })
			else nil,
		_rng = rng,
	}, OddsTable)
end

local function isPaid(self: OddsTable, ctx: Context?): boolean
	return self.paid or (ctx ~= nil and ctx.paid == true)
end

-- (allowed, reason): fail closed unless the policy says yes.
local function policyAllows(ctx: Context?): (boolean, string?)
	local policy = ctx and ctx.policyAllows
	if policy == nil then
		return false, "policy_missing"
	end
	if policy == true then
		return true, nil
	end
	if type(policy) == "function" then
		local ok, allowed = pcall(policy, OddsTable.POLICY_FEATURE)
		if ok and allowed == true then
			return true, nil
		end
		return false, if ok then "policy_denied" else "policy_error"
	end
	return false, "policy_denied"
end

-- Effective { entry, weight } list for ctx: owned once-only and excluded entries removed,
-- boosts applied, and (when this roll is a pity roll) only pity targets. Returns the list, the
-- pity flag, or nil and a reason.
local function effective(
	self: OddsTable,
	ctx: Context?,
	pityOnly: boolean
): ({ { entry: Entry, weight: number } }?, string?)
	local out = {}
	local total = 0
	local owned = ctx and ctx.owned
	local exclude = ctx and ctx.exclude
	local boost = ctx and ctx.boost
	if boost ~= nil then
		for id, factor in boost do
			if self._byId[id] == nil or not (Check.integer(factor) and factor >= 1) then
				return nil, "invalid_boost"
			end
		end
	end
	for _, entry in self._entries do
		if entry.once and owned and owned[entry.id] then
			continue
		end
		if exclude and exclude[entry.id] then
			continue
		end
		if pityOnly and not table.find((self._pity :: any).targets, entry.id) then
			continue
		end
		local weight = entry.weight * (if boost and boost[entry.id] then boost[entry.id] else 1)
		total += weight
		table.insert(out, { entry = entry, weight = weight })
	end
	if #out == 0 then
		return nil, "no_outcomes"
	end
	if total > OddsTable.MAX_TOTAL then
		return nil, "weight_overflow"
	end
	return out, nil
end

local function pityRoll(self: OddsTable, ctx: Context?): boolean
	local pity = self._pity
	if pity == nil then
		return false
	end
	local count = ctx and ctx.pity or 0
	return count + 1 >= pity.threshold
end

local function lines(list: { { entry: Entry, weight: number } }): { Line }
	local weights = {}
	for _, item in list do
		table.insert(weights, item.weight)
	end
	local out = {}
	for index, units in OddsTable.apportion(weights) do
		table.insert(out, {
			id = list[index].entry.id,
			units = units,
			percent = units / 10000,
			text = OddsTable.format(units),
			weight = weights[index],
		})
	end
	return out
end

-- The odds a roll with this ctx would use, as exact percentages (see the header). Raises when no
-- outcome is left or a boost is invalid.
function OddsTable.disclose(self: OddsTable, ctx: Context?): Disclosure
	local guaranteed = pityRoll(self, ctx)
	local list, err = effective(self, ctx, guaranteed)
	if list == nil and guaranteed then
		-- Every pity target is owned or excluded: the pity rule cannot apply, so plain odds do.
		guaranteed = false
		list, err = effective(self, ctx, false)
	end
	if list == nil then
		error("OddsTable.disclose: " .. tostring(err), 2)
	end
	local entries = lines(list)
	local warnings = {}
	local total = 0
	for _, line in entries do
		total += line.units
		if line.units == 0 then
			table.insert(warnings, line.id .. " shows as 0.0000%")
		end
	end
	local pityInfo = nil
	local pity = self._pity
	if pity then
		local targetsList = effective(self, ctx, true)
		pityInfo = {
			threshold = pity.threshold,
			targets = table.clone(pity.targets),
			rollsLeft = math.max(pity.threshold - ((ctx and ctx.pity or 0) + 1), 0),
			odds = if targetsList then lines(targetsList) else {},
		}
	end
	return {
		name = self.name,
		paid = isPaid(self, ctx),
		total = total,
		entries = entries,
		guaranteed = guaranteed,
		pity = pityInfo,
		warnings = warnings,
	}
end

-- An unbiased integer in [0, n) from 32-bit draws.
local function below(rng: Rng.Rng, n: number): number
	local span = 4294967296
	local limit = span - (span % n)
	while true do
		local value = rng:nextUInt()
		if value < limit then
			return value % n
		end
	end
end

-- Rolls once: (true, result) or (false, reason) with policy_missing, policy_denied,
-- policy_error, no_rng, no_outcomes, invalid_boost, weight_overflow or invalid_pity.
function OddsTable.tryRoll(self: OddsTable, ctx: Context?): (boolean, any)
	local paid = isPaid(self, ctx)
	if paid then
		local allowed, reason = policyAllows(ctx)
		if not allowed then
			return false, reason
		end
	end
	local count = ctx and ctx.pity or 0
	if not (Check.integer(count) and count >= 0) then
		return false, "invalid_pity"
	end
	local rng = (ctx and ctx.rng) or self._rng
	if rng == nil then
		return false, "no_rng"
	end
	local guaranteed = pityRoll(self, ctx)
	local list, err = effective(self, ctx, guaranteed)
	if list == nil and guaranteed then
		guaranteed = false
		list, err = effective(self, ctx, false)
	end
	if list == nil then
		return false, err
	end
	local total = 0
	for _, item in list do
		total += item.weight
	end
	local draw = below(rng :: Rng.Rng, total)
	local chosen = list[#list].entry
	for _, item in list do
		if draw < item.weight then
			chosen = item.entry
			break
		end
		draw -= item.weight
	end
	local hitTarget = self._pity ~= nil and table.find((self._pity :: any).targets, chosen.id) ~= nil
	return true,
		{
			id = chosen.id,
			entry = Check.copy(chosen),
			pity = if self._pity == nil then 0 elseif hitTarget then 0 else count + 1,
			pityTriggered = guaranteed,
			paid = paid,
		}
end

-- Rolls once and returns the result; raises when the roll is refused (a paid roll without the
-- policy's yes raises "OddsTable: paid roll refused (policy_missing)").
function OddsTable.roll(self: OddsTable, ctx: Context?): Result
	local ok, result = self:tryRoll(ctx)
	if not ok then
		local paid = isPaid(self, ctx)
		error(
			string.format(
				"OddsTable: %s refused (%s)",
				if paid then "paid roll" else "roll",
				tostring(result)
			),
			2
		)
	end
	return result
end

function OddsTable.entries(self: OddsTable): { Entry }
	return Check.copy(self._entries)
end

return OddsTable
