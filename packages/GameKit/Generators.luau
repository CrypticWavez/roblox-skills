--!strict
-- @tier T0
-- Generators: idle production for one player. A generator definition is data the game supplies:
--   { id, currency, rate (units per second per copy; finite > 0), storage? (max uncollected,
--     integer), maxCount? }
-- tick(now) is the step function (never yields; the adapter drives it from BindToSimulation or
-- a server loop with env.clock time): production = rate * count * multiplier * dt, whole units
-- go to storage and the fraction carries over, so nothing is lost to rounding. collect() empties
-- storage and returns { [currency] = amount } for the caller to credit through Wallet.
-- Offline earnings use server UTC only: markSeen(utc) at save time, offline(utc) on join gives
-- min(delta, offlineCap) * offlineRate worth of production, once (it moves lastSeen), and a
-- negative delta (clock skew) gives nothing. No rates or caps ship here.
local Check = require("./Check")

local Generators = {}
Generators.__index = Generators
Generators.SCHEMA = "generators/1"

export type Def = { id: string, currency: string, rate: number, storage: number?, maxCount: number? }
export type Options = {
	offlineCap: number?, -- seconds of offline production credited at most (default 0: none)
	offlineRate: number?, -- 0..1 share of the online rate offline (default 1)
	maxStep: number?, -- longest dt one tick credits (seconds; default unlimited)
	data: any?,
}
type GenFields = {
	notes: { string },
	_defs: { [string]: Def },
	_order: { string },
	_count: { [string]: number },
	_stored: { [string]: number },
	_carry: { [string]: number },
	_multiplier: number,
	_multipliers: { [string]: number },
	_lastTick: number?,
	_lastSeen: number?,
	_options: Options,
}
export type Generators = typeof(setmetatable({} :: GenFields, Generators))

-- Problems with definitions and options (empty when valid).
function Generators.validate(defs: any, options: any?): { string }
	local problems = {}
	if type(defs) ~= "table" or #defs == 0 then
		table.insert(problems, "defs must be a non-empty list")
		return problems
	end
	local seen = {}
	for index, def in defs do
		local where = "generator "
			.. (if type(def) == "table" and type(def.id) == "string" then def.id else "#" .. tostring(index))
		if type(def) ~= "table" then
			table.insert(problems, where .. ": must be a table")
			continue
		end
		if not Check.label(def.id) then
			table.insert(problems, where .. ": id is not a label")
		elseif seen[def.id] then
			table.insert(problems, where .. ": duplicate id")
		end
		seen[def.id] = true
		if not Check.label(def.currency) then
			table.insert(problems, where .. ": currency is not a label")
		end
		if not (Check.finite(def.rate) and def.rate > 0) then
			table.insert(problems, where .. ": rate must be a finite number > 0")
		end
		if def.storage ~= nil and not (Check.integer(def.storage) and def.storage >= 1) then
			table.insert(problems, where .. ": storage must be an integer >= 1")
		end
		if def.maxCount ~= nil and not (Check.integer(def.maxCount) and def.maxCount >= 1) then
			table.insert(problems, where .. ": maxCount must be an integer >= 1")
		end
	end
	if options ~= nil then
		if
			options.offlineCap ~= nil and not (Check.finite(options.offlineCap) and options.offlineCap >= 0)
		then
			table.insert(problems, "offlineCap must be a finite number >= 0 (seconds)")
		end
		if
			options.offlineRate ~= nil
			and not (
				Check.finite(options.offlineRate)
				and options.offlineRate >= 0
				and options.offlineRate <= 1
			)
		then
			table.insert(problems, "offlineRate must be within 0..1")
		end
		if options.maxStep ~= nil and not (Check.finite(options.maxStep) and options.maxStep > 0) then
			table.insert(problems, "maxStep must be a finite number > 0")
		end
	end
	return problems
end

-- Generators for one player. Raises on invalid definitions. Loads generators/1 data when given.
function Generators.new(defs: { Def }, options: Options?, _env: any?): Generators
	local opts: Options = options or {}
	local problems = Generators.validate(defs, opts)
	if #problems > 0 then
		error("Generators.new: " .. table.concat(problems, "; "), 2)
	end
	local byId, order = {}, {}
	for _, def in defs do
		byId[def.id] = Check.freeze(table.clone(def))
		table.insert(order, def.id)
	end
	local self = setmetatable({
		notes = {},
		_defs = byId,
		_order = order,
		_count = {},
		_stored = {},
		_carry = {},
		_multiplier = 1,
		_multipliers = {},
		_lastTick = nil,
		_lastSeen = nil,
		_options = opts,
	}, Generators)
	for _, id in order do
		self._count[id] = 0
		self._stored[id] = 0
		self._carry[id] = 0
	end
	local data = opts.data
	if data ~= nil then
		if type(data) ~= "table" or data.schema ~= Generators.SCHEMA then
			table.insert(self.notes, "stored data is not generators/1; starting fresh")
		else
			for _, field in { "count", "stored" } do
				for id, value in data[field] or {} do
					if byId[id] == nil then
						table.insert(
							self.notes,
							string.format("dropped %s for unknown generator %s", field, Check.describe(id))
						)
					elseif Check.integer(value) and value >= 0 then
						(self :: any)["_" .. field][id] = value
					else
						table.insert(self.notes, string.format("%s.%s invalid; reset to 0", field, id))
					end
				end
			end
			for id, value in data.carry or {} do
				if byId[id] and Check.finite(value) and value >= 0 and value < 1 then
					self._carry[id] = value
				end
			end
			for id, value in data.multipliers or {} do
				if byId[id] and Check.finite(value) and value >= 0 then
					self._multipliers[id] = value
				end
			end
			if Check.finite(data.multiplier) and data.multiplier >= 0 then
				self._multiplier = data.multiplier
			end
			if Check.finite(data.lastSeen) and data.lastSeen >= 0 then
				self._lastSeen = data.lastSeen
			end
		end
	end
	return self
end

-- Adds count copies of a generator (default 1). (ok, err) with unknown, invalid_count, max_count.
function Generators.add(self: Generators, id: string, count: number?): (boolean, string?)
	local def = self._defs[id]
	if def == nil then
		return false, "unknown"
	end
	local n = count or 1
	if not (Check.integer(n) and n >= 1) then
		return false, "invalid_count"
	end
	if def.maxCount and self._count[id] + n > def.maxCount then
		return false, "max_count"
	end
	self._count[id] += n
	return true, nil
end

function Generators.remove(self: Generators, id: string, count: number?): (boolean, string?)
	if self._defs[id] == nil then
		return false, "unknown"
	end
	local n = count or 1
	if not (Check.integer(n) and n >= 1) or self._count[id] < n then
		return false, "invalid_count"
	end
	self._count[id] -= n
	return true, nil
end

function Generators.count(self: Generators, id: string): number
	return self._count[id] or 0
end

-- Sets the global multiplier, or one generator's with id (finite >= 0).
function Generators.setMultiplier(self: Generators, multiplier: number, id: string?)
	assert(
		Check.finite(multiplier) and multiplier >= 0,
		"Generators: multiplier must be a finite number >= 0"
	)
	if id ~= nil then
		assert(self._defs[id] ~= nil, "Generators: unknown generator " .. tostring(id))
		self._multipliers[id] = multiplier
	else
		self._multiplier = multiplier
	end
end

-- Units per second of one generator id (all copies, all multipliers).
function Generators.rate(self: Generators, id: string): number
	local def = self._defs[id]
	if def == nil then
		return 0
	end
	return def.rate * self._count[id] * self._multiplier * (self._multipliers[id] or 1)
end

-- Units per second into each currency.
function Generators.rates(self: Generators): { [string]: number }
	local out = {}
	for _, id in self._order do
		local currency = self._defs[id].currency
		out[currency] = (out[currency] or 0) + self:rate(id)
	end
	return out
end

-- Produces seconds of output into storage at scale (1 online, offlineRate offline). Returns the
-- whole units produced per currency.
local function produce(self: Generators, seconds: number, scale: number): { [string]: number }
	local produced: { [string]: number } = {}
	for _, id in self._order do
		local def = self._defs[id]
		local amount = self:rate(id) * seconds * scale + self._carry[id]
		if amount <= 0 then
			continue
		end
		local whole = math.floor(amount)
		self._carry[id] = amount - whole
		local cap = def.storage or Check.MAX_SAFE_INTEGER
		local room = math.max(cap - self._stored[id], 0)
		if whole > room then
			whole = room
			self._carry[id] = 0 -- full storage wastes the rest, including the fraction
		end
		if whole > 0 then
			self._stored[id] += whole
			produced[def.currency] = (produced[def.currency] or 0) + whole
		end
	end
	return produced
end

-- Step function: credits production since the last tick (env.clock seconds). The first tick only
-- starts the clock; a clock that went backwards restarts it without producing.
function Generators.tick(self: Generators, now: number): { [string]: number }
	assert(Check.finite(now), "Generators.tick needs a finite time")
	local last = self._lastTick
	self._lastTick = now
	if last == nil or now <= last then
		return {}
	end
	local dt = now - last
	if self._options.maxStep then
		dt = math.min(dt, self._options.maxStep)
	end
	return produce(self, dt, 1)
end

-- Records the server UTC time of a save (call before persisting).
function Generators.markSeen(self: Generators, utc: number)
	assert(Check.finite(utc) and utc >= 0, "Generators.markSeen needs server UTC seconds")
	self._lastSeen = utc
end

-- Offline production since the last markSeen, from server UTC seconds. Moves lastSeen to utc, so
-- calling it twice credits once. Returns { seconds, elapsed, capped, skew, produced }.
function Generators.offline(self: Generators, utc: number): any
	assert(Check.finite(utc) and utc >= 0, "Generators.offline needs server UTC seconds")
	local last = self._lastSeen
	self._lastSeen = utc
	if last == nil then
		return { seconds = 0, elapsed = 0, capped = false, skew = false, produced = {} }
	end
	local elapsed = utc - last
	if elapsed <= 0 then
		return { seconds = 0, elapsed = elapsed, capped = false, skew = elapsed < 0, produced = {} }
	end
	local cap = self._options.offlineCap or 0
	local seconds = math.min(elapsed, cap)
	local produced = if seconds > 0 then produce(self, seconds, self._options.offlineRate or 1) else {}
	return { seconds = seconds, elapsed = elapsed, capped = elapsed > cap, skew = false, produced = produced }
end

-- Uncollected units of one generator, or every generator's with no id.
function Generators.stored(self: Generators, id: string?): any
	if id ~= nil then
		return self._stored[id] or 0
	end
	return table.clone(self._stored)
end

-- Empties storage (one generator or all) and returns { [currency] = amount } to credit.
function Generators.collect(self: Generators, id: string?): { [string]: number }
	local out = {}
	for _, gid in self._order do
		if id == nil or gid == id then
			local amount = self._stored[gid]
			if amount > 0 then
				local currency = self._defs[gid].currency
				out[currency] = (out[currency] or 0) + amount
				self._stored[gid] = 0
			end
		end
	end
	return out
end

-- Puts collected amounts back (when the wallet credit failed, e.g. at cap), up to storage.
function Generators.putBack(self: Generators, id: string, amount: number)
	assert(
		self._defs[id] ~= nil and Check.integer(amount) and amount >= 0,
		"Generators.putBack: bad id or amount"
	)
	local cap = self._defs[id].storage or Check.MAX_SAFE_INTEGER
	self._stored[id] = math.min(self._stored[id] + amount, cap)
end

function Generators.serialize(self: Generators): any
	return {
		schema = Generators.SCHEMA,
		count = table.clone(self._count),
		stored = table.clone(self._stored),
		carry = table.clone(self._carry),
		multiplier = self._multiplier,
		multipliers = table.clone(self._multipliers),
		lastSeen = self._lastSeen,
	}
end

return Generators
