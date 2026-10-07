--!strict
-- @tier T0
-- Boosts: timed multipliers and bonuses (boosts/1 data, docs/monetization.md), the "2x luck
-- for 15 minutes" developer products, potions, event boosts and server-wide boosts of top
-- games. A tracker holds one owner's active boosts (a player, or the server for server boosts)
-- and answers value(stat, now) for game code that applies them. Data:
--   { schema = "boosts/1", stats? = { [stat] = { combine = "multiply" | "add" | "max", cap? } },
--     boosts = { { key, stat, multiplier? | add?, duration, stack?, maxDuration?, clock? } } }
-- stack: "extend" (default: buying again adds duration, up to maxDuration), "refresh" (the
-- timer restarts), "stack" (each purchase is its own instance; their effects combine).
-- clock: "realtime" (default: ends at a UTC time, even offline) or "playtime" (counts down only
-- while the owner is online: pause() on leave, resume() on join). combine says how several
-- boosts on one stat mix: multiply (2x and 2x make 4x), add (2x and 2x make 3x: 1 + 1 + 1) or
-- max (the strongest wins); cap limits the result. Times are server UTC seconds. Grants come
-- from the receipt handler (a custom grant handler that calls tracker:add); nothing here buys.
local Check = require("./Check")

local Boosts = {}
Boosts.__index = Boosts
Boosts.SCHEMA = "boosts/1"
Boosts.STATE_SCHEMA = "boost-state/1"
Boosts.STACKS = table.freeze({ "extend", "refresh", "stack" })
Boosts.CLOCKS = table.freeze({ "realtime", "playtime" })
Boosts.COMBINES = table.freeze({ "multiply", "add", "max" })
Boosts.MAX_INSTANCES = 32 -- convention: stacked instances kept per boost

local BOOST_KEYS =
	table.freeze({ "key", "stat", "multiplier", "add", "duration", "stack", "maxDuration", "clock" })

export type BoostDef = {
	key: string,
	stat: string,
	multiplier: number?,
	add: number?,
	duration: number,
	stack: ("extend" | "refresh" | "stack")?,
	maxDuration: number?,
	clock: ("realtime" | "playtime")?,
}
export type StatRule = { combine: "multiply" | "add" | "max", cap: number? }
export type Data = { schema: string, stats: { [string]: StatRule }?, boosts: { BoostDef } }
export type Active = { key: string, stat: string, remaining: number, endsAt: number? }

-- Problems with boosts/1 data (empty when valid).
function Boosts.validate(data: any): { string }
	if type(data) ~= "table" then
		return { "boosts must be a table" }
	end
	local problems = {}
	if data.schema ~= Boosts.SCHEMA then
		table.insert(problems, "schema must be " .. Boosts.SCHEMA)
	end
	for key in data do
		if key ~= "schema" and key ~= "stats" and key ~= "boosts" then
			table.insert(problems, "unexpected key " .. Check.describe(key))
		end
	end
	if data.stats ~= nil then
		if type(data.stats) ~= "table" then
			table.insert(problems, "stats must be a map")
		else
			for stat, rule in data.stats do
				if not Check.label(stat) or type(rule) ~= "table" then
					table.insert(
						problems,
						"stats." .. tostring(stat) .. " must map a label to { combine, cap? }"
					)
				else
					if not table.find(Boosts.COMBINES, rule.combine) then
						table.insert(problems, "stats." .. stat .. ".combine must be multiply, add or max")
					end
					if rule.cap ~= nil and not (Check.finite(rule.cap) and rule.cap > 0) then
						table.insert(problems, "stats." .. stat .. ".cap must be a number > 0")
					end
					for key in rule do
						if key ~= "combine" and key ~= "cap" then
							table.insert(
								problems,
								"stats." .. stat .. ": unexpected key " .. Check.describe(key)
							)
						end
					end
				end
			end
		end
	end
	if type(data.boosts) ~= "table" then
		table.insert(problems, "boosts must be a list")
		return problems
	end
	local seen: { [string]: boolean } = {}
	for index, boost in data.boosts do
		local where = "boosts[" .. index .. "]"
		if type(boost) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		if Check.label(boost.key) then
			where = boost.key
			if seen[boost.key] then
				table.insert(problems, where .. ": duplicate key")
			end
			seen[boost.key] = true
		else
			table.insert(problems, where .. ".key must be a label")
		end
		for key in boost do
			if not table.find(BOOST_KEYS, key) then
				table.insert(problems, where .. ": unexpected key " .. Check.describe(key))
			end
		end
		if not Check.label(boost.stat) then
			table.insert(problems, where .. ".stat must be a label")
		end
		local hasMul, hasAdd = boost.multiplier ~= nil, boost.add ~= nil
		if hasMul == hasAdd then
			table.insert(problems, where .. ": exactly one of multiplier or add")
		elseif hasMul and not (Check.finite(boost.multiplier) and boost.multiplier > 0) then
			table.insert(problems, where .. ".multiplier must be a number > 0")
		elseif hasAdd and not Check.finite(boost.add) then
			table.insert(problems, where .. ".add must be a finite number")
		end
		if not (Check.finite(boost.duration) and boost.duration > 0) then
			table.insert(problems, where .. ".duration must be seconds > 0")
		end
		if boost.stack ~= nil and not table.find(Boosts.STACKS, boost.stack) then
			table.insert(problems, where .. ".stack must be extend, refresh or stack")
		end
		if boost.clock ~= nil and not table.find(Boosts.CLOCKS, boost.clock) then
			table.insert(problems, where .. ".clock must be realtime or playtime")
		end
		if boost.maxDuration ~= nil then
			if not (Check.finite(boost.maxDuration) and boost.maxDuration > 0) then
				table.insert(problems, where .. ".maxDuration must be seconds > 0")
			elseif Check.finite(boost.duration) and boost.maxDuration < boost.duration then
				table.insert(problems, where .. ".maxDuration must be >= duration")
			end
		end
	end
	return problems
end

function Boosts.define(data: any): Data
	local problems = Boosts.validate(data)
	if #problems > 0 then
		error("Boosts.define: " .. table.concat(problems, "; "), 2)
	end
	return Check.freeze(Check.copy(data))
end

-- A tracker over defined data. saved is an earlier save() result (or nil); now the UTC time.
-- A tracker starts paused for playtime boosts until resume(now) (call it on join).
function Boosts.new(data: Data, saved: any?, now: number): any
	assert(type(data) == "table" and data.schema == Boosts.SCHEMA, "Boosts.new: data from Boosts.define")
	assert(Check.finite(now), "Boosts.new: now must be UTC seconds")
	local defs: { [string]: BoostDef } = {}
	for _, def in data.boosts do
		defs[def.key] = def
	end
	local self = setmetatable({
		data = data,
		defs = defs,
		-- key -> list of instances { endsAt? (realtime), remaining? (playtime) }
		instances = {} :: { [string]: { any } },
		runningSince = nil :: number?, -- UTC time playtime clocks resumed, nil while paused
	}, Boosts)
	if
		type(saved) == "table"
		and saved.schema == Boosts.STATE_SCHEMA
		and type(saved.instances) == "table"
	then
		for key, list in saved.instances do
			local def = defs[key]
			if def == nil or type(list) ~= "table" then
				continue -- a boost the game removed: forget it
			end
			local kept = {}
			for _, item in list do
				if type(item) ~= "table" then
					continue
				end
				if
					(def.clock or "realtime") == "realtime"
					and Check.finite(item.endsAt)
					and item.endsAt > now
				then
					table.insert(kept, { endsAt = item.endsAt })
				elseif def.clock == "playtime" and Check.finite(item.remaining) and item.remaining > 0 then
					table.insert(kept, { remaining = item.remaining })
				end
			end
			if #kept > 0 then
				self.instances[key] = kept
			end
		end
	end
	return self
end

-- Playtime seconds elapsed since resume, folded into each playtime instance.
local function settle(self: any, now: number)
	local since = self.runningSince
	if since == nil then
		return
	end
	local elapsed = math.max(0, now - since)
	self.runningSince = now
	if elapsed == 0 then
		return
	end
	for key, list in self.instances do
		local def = self.defs[key]
		if def.clock == "playtime" then
			for _, item in list do
				item.remaining = math.max(0, item.remaining - elapsed)
			end
		end
	end
end

local function remainingOf(def: BoostDef, item: any, now: number): number
	if def.clock == "playtime" then
		return item.remaining
	end
	return math.max(0, item.endsAt - now)
end

local function prune(self: any, now: number)
	settle(self, now)
	for key, list in self.instances do
		local def = self.defs[key]
		local kept = {}
		for _, item in list do
			if remainingOf(def, item, now) > 0 then
				table.insert(kept, item)
			end
		end
		self.instances[key] = if #kept > 0 then kept else nil
	end
end

function Boosts.pause(self: any, now: number)
	settle(self, now)
	self.runningSince = nil
end

function Boosts.resume(self: any, now: number)
	settle(self, now)
	self.runningSince = now
end

-- Adds count activations of boost key at now (a granted developer product). Returns the
-- remaining seconds of that boost afterwards (the longest instance for stack).
function Boosts.add(self: any, key: string, now: number, count: number?): number
	local def: BoostDef? = self.defs[key]
	assert(def ~= nil, "Boosts.add: unknown boost " .. tostring(key))
	local times = count or 1
	assert(Check.integer(times) and times >= 1, "Boosts.add: count must be an integer >= 1")
	prune(self, now)
	local playtime = def.clock == "playtime"
	local list = self.instances[key] or {}
	local stack = def.stack or "extend"
	local cap = def.maxDuration or math.huge
	local function make(seconds: number): any
		return if playtime then { remaining = seconds } else { endsAt = now + seconds }
	end
	if stack == "stack" then
		for _ = 1, times do
			if #list >= Boosts.MAX_INSTANCES then
				break
			end
			table.insert(list, make(math.min(def.duration, cap)))
		end
	elseif stack == "refresh" or #list == 0 then
		local seconds = if stack == "refresh" then def.duration else def.duration * times
		list = { make(math.min(seconds, cap)) }
	else
		local current = remainingOf(def, list[1], now)
		list = { make(math.min(current + def.duration * times, cap)) }
	end
	self.instances[key] = list
	local longest = 0
	for _, item in list do
		longest = math.max(longest, remainingOf(def, item, now))
	end
	return longest
end

-- Active boosts at now, sorted by key: { key, stat, remaining, endsAt? (realtime only) }, one
-- entry per stacked instance.
function Boosts.active(self: any, now: number): { Active }
	prune(self, now)
	local out = {}
	for key, list in self.instances do
		local def = self.defs[key]
		for _, item in list do
			table.insert(out, {
				key = key,
				stat = def.stat,
				remaining = remainingOf(def, item, now),
				endsAt = if def.clock == "playtime" then nil else item.endsAt,
			})
		end
	end
	table.sort(out, function(a: Active, b: Active): boolean
		if a.key ~= b.key then
			return a.key < b.key
		end
		return a.remaining > b.remaining
	end)
	return out
end

-- The combined value of stat at now applied to base (default 1). The multipliers of every
-- active instance mix by the stat's combine rule (default multiply); flat adds go on after
-- them; the cap (a multiple of base) applies last.
function Boosts.value(self: any, stat: string, now: number, base: number?): number
	local start = base or 1
	local rule: StatRule = (self.data.stats and self.data.stats[stat]) or { combine = "multiply" }
	local factor = 1
	local extra = 0 -- add combine: the sum of (multiplier - 1)
	local bonus = 0 -- flat adds, applied after the multipliers
	local best = 1
	for _, entry in self:active(now) do
		if entry.stat ~= stat then
			continue
		end
		local def: BoostDef = self.defs[entry.key]
		if def.multiplier ~= nil then
			if rule.combine == "multiply" then
				factor *= def.multiplier
			elseif rule.combine == "add" then
				extra += def.multiplier - 1
			else
				best = math.max(best, def.multiplier)
			end
		else
			bonus += def.add :: number
		end
	end
	local result
	if rule.combine == "multiply" then
		result = start * factor + bonus
	elseif rule.combine == "add" then
		result = start * (1 + extra) + bonus
	else
		result = start * best + bonus
	end
	if rule.cap ~= nil then
		result = math.min(result, start * rule.cap)
	end
	return result
end

-- A boost-state/1 table to save with player data (realtime instances keep their UTC end,
-- playtime ones their remaining seconds).
function Boosts.save(self: any, now: number): { [string]: any }
	prune(self, now)
	local instances = {}
	for key, list in self.instances do
		local copy = {}
		for _, item in list do
			table.insert(copy, table.clone(item))
		end
		instances[key] = copy
	end
	return { schema = Boosts.STATE_SCHEMA, instances = instances }
end

return Boosts
