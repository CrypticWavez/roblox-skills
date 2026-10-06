--!strict
-- @tier T0
-- Cooldowns: server-time cooldowns with optional charges, keyed by a string (an ability id, a
-- weapon slot, "interact:<target>"). The clock is the server's (env.clock, time() in Roblox);
-- no method takes a time from the caller, so a client can never move a cooldown. A key with
-- n charges recharges one charge per period, in sequence (dash with 2 charges). Keys are capped
-- (maxKeys): when full, expired keys are dropped first and a new key is refused ("full") rather
-- than letting key spam grow memory. Durations must be finite and >= 0; bad arguments raise,
-- because they come from game data, not from clients.
--   local cd = Cooldowns.new(env)                 -- or Cooldowns.new({ maxKeys = 64 }, env)
--   local ok, remaining, reason = cd:use("dash", 1.5, 2)  -- 2 charges, 1.5 s each
local Check = require("./Check")

local Cooldowns = {}
Cooldowns.__index = Cooldowns
Cooldowns.MAX_CHARGES = 99
Cooldowns.KEY_MAX = 128
Cooldowns.DEFAULT_MAX_KEYS = 256
-- Floating slack when comparing times (0.1 + 0.2 style sums must not leave a charge 1e-17 short).
Cooldowns.EPSILON = 1e-9

export type Options = { maxKeys: number? }
type Entry = { fullAt: number, period: number, max: number }
type CooldownsFields = {
	_clock: () -> number,
	_entries: { [string]: Entry },
	_count: number,
	_maxKeys: number,
}
export type Cooldowns = typeof(setmetatable({} :: CooldownsFields, Cooldowns))
export type Snapshot = { [string]: { remaining: number, period: number, max: number } }

local function clockOf(source: any): () -> number
	if type(source) == "function" then
		return source
	elseif type(source) == "table" and type(source.clock) == "function" then
		return source.clock
	end
	error("Cooldowns.new needs an env with clock() or a clock function", 3)
end

local function checkKey(key: any)
	if type(key) ~= "string" or #key == 0 or #key > Cooldowns.KEY_MAX then
		error(
			string.format(
				"Cooldowns: key must be a string of 1-%d characters (got %s)",
				Cooldowns.KEY_MAX,
				Check.describe(key)
			),
			3
		)
	end
end

local function checkSeconds(seconds: any, what: string)
	if not Check.finite(seconds) or seconds < 0 then
		error(
			string.format(
				"Cooldowns: %s must be a finite number >= 0 (got %s)",
				what,
				Check.describe(seconds)
			),
			3
		)
	end
end

local function checkCharges(charges: any)
	if not Check.integer(charges) or charges < 1 or charges > Cooldowns.MAX_CHARGES then
		error(
			string.format(
				"Cooldowns: charges must be an integer 1-%d (got %s)",
				Cooldowns.MAX_CHARGES,
				Check.describe(charges)
			),
			3
		)
	end
end

-- Cooldowns.new(env) or Cooldowns.new(options, env); env is a GameKit Env or a clock function.
function Cooldowns.new(optionsOrEnv: any, maybeEnv: any?): Cooldowns
	local options: Options?, source: any
	if maybeEnv == nil then
		options, source = nil, optionsOrEnv
	else
		options, source = optionsOrEnv, maybeEnv
	end
	local maxKeys = (options and options.maxKeys) or Cooldowns.DEFAULT_MAX_KEYS
	if not Check.integer(maxKeys) or maxKeys < 1 then
		error("Cooldowns: maxKeys must be an integer >= 1", 2)
	end
	return setmetatable({
		_clock = clockOf(source),
		_entries = {},
		_count = 0,
		_maxKeys = maxKeys,
	}, Cooldowns)
end

-- Charges available at now for an entry (max when the entry is full or has no period).
local function available(entry: Entry, now: number): number
	local deficit = entry.fullAt - now
	if deficit <= Cooldowns.EPSILON or entry.period <= 0 then
		return entry.max
	end
	local missing = math.ceil(deficit / entry.period - Cooldowns.EPSILON)
	return math.clamp(entry.max - missing, 0, entry.max)
end

-- Seconds until the next charge for an entry (0 when one is available).
local function untilNext(entry: Entry, now: number): number
	if available(entry, now) >= 1 then
		return 0
	end
	return math.max(0, (entry.fullAt - now) - (entry.max - 1) * entry.period)
end

-- Drops entries that are full again; returns how many were dropped.
local function purge(self: Cooldowns, now: number): number
	local dropped = 0
	for key, entry in self._entries do
		if entry.fullAt <= now + Cooldowns.EPSILON then
			self._entries[key] = nil
			dropped += 1
		end
	end
	self._count -= dropped
	return dropped
end

function Cooldowns.now(self: Cooldowns): number
	return self._clock()
end

-- True when key has at least one charge (unknown keys are ready).
function Cooldowns.ready(self: Cooldowns, key: string): boolean
	checkKey(key)
	local entry = self._entries[key]
	return entry == nil or available(entry, self._clock()) >= 1
end

-- Seconds until key can be used again (0 when ready).
function Cooldowns.remaining(self: Cooldowns, key: string): number
	checkKey(key)
	local entry = self._entries[key]
	if entry == nil then
		return 0
	end
	return untilNext(entry, self._clock())
end

-- (available, max) charges for key; an unknown key reports (max, max) for the given max (1).
function Cooldowns.charges(self: Cooldowns, key: string, maxCharges: number?): (number, number)
	checkKey(key)
	local entry = self._entries[key]
	if entry == nil then
		local max = maxCharges or 1
		checkCharges(max)
		return max, max
	end
	return available(entry, self._clock()), entry.max
end

-- Uses one charge of key with a recharge period of seconds and maxCharges (default 1).
-- Returns (true, remaining) on success, where remaining is the wait until the next use, or
-- (false, remaining, reason) with reason "cooldown" or "full" (key cap reached).
-- Changing seconds or maxCharges for an active key rescales its outstanding recharge.
function Cooldowns.use(
	self: Cooldowns,
	key: string,
	seconds: number,
	maxCharges: number?
): (boolean, number, string?)
	checkKey(key)
	checkSeconds(seconds, "seconds")
	local max = maxCharges or 1
	checkCharges(max)
	local now = self._clock()
	local entry = self._entries[key]
	if entry == nil then
		if self._count >= self._maxKeys and purge(self, now) == 0 then
			return false, 0, "full"
		end
		entry = { fullAt = now, period = seconds, max = max }
		self._entries[key] = entry
		self._count += 1
	else
		local current = entry :: Entry
		if current.period ~= seconds or current.max ~= max then
			-- Keep the outstanding recharge in charge units, then clamp to the new charge count.
			local deficit = if current.period > 0
				then math.max(0, current.fullAt - now) / current.period
				else 0
			current.period = seconds
			current.max = max
			current.fullAt = now + math.min(deficit, max) * seconds
		end
	end
	local e = entry :: Entry
	if available(e, now) < 1 then
		return false, untilNext(e, now), "cooldown"
	end
	e.fullAt = math.max(e.fullAt, now) + seconds
	return true, untilNext(e, now), nil
end

-- Adds seconds (may be negative) to key's outstanding recharge; a ready key gains a cooldown
-- of that length. Returns the new remaining time.
function Cooldowns.extend(self: Cooldowns, key: string, seconds: number): number
	checkKey(key)
	if not Check.finite(seconds) then
		error("Cooldowns: extend seconds must be finite (got " .. Check.describe(seconds) .. ")", 2)
	end
	local now = self._clock()
	local entry = self._entries[key]
	if entry == nil then
		if seconds <= 0 then
			return 0
		end
		if self._count >= self._maxKeys and purge(self, now) == 0 then
			return 0
		end
		entry = { fullAt = now + seconds, period = seconds, max = 1 }
		self._entries[key] = entry
		self._count += 1
		return seconds
	end
	local e = entry :: Entry
	e.fullAt = math.max(now, math.max(e.fullAt, now) + seconds)
	return untilNext(e, now)
end

-- Makes key ready again with every charge.
function Cooldowns.reset(self: Cooldowns, key: string)
	checkKey(key)
	if self._entries[key] ~= nil then
		self._entries[key] = nil
		self._count -= 1
	end
end

function Cooldowns.clear(self: Cooldowns)
	self._entries = {}
	self._count = 0
end

-- Tracked keys (expired keys count until the next purge).
function Cooldowns.size(self: Cooldowns): number
	return self._count
end

-- Plain data for replication or a respawn: { [key] = { remaining, period, max } } where
-- remaining is the time until every charge is back (relative, so client clocks do not matter).
function Cooldowns.snapshot(self: Cooldowns): Snapshot
	local now = self._clock()
	local out: Snapshot = {}
	for key, entry in self._entries do
		local remaining = math.max(0, entry.fullAt - now)
		if remaining > Cooldowns.EPSILON then
			out[key] = { remaining = remaining, period = entry.period, max = entry.max }
		end
	end
	return out
end

-- Restores snapshot() output (validated; bad entries are skipped and listed).
function Cooldowns.restore(self: Cooldowns, snapshot: any): { string }
	local problems = {}
	if type(snapshot) ~= "table" then
		return { "snapshot must be a table" }
	end
	local now = self._clock()
	local keys = {}
	for key in snapshot do
		if type(key) == "string" then
			table.insert(keys, key)
		else
			table.insert(problems, "non-string key " .. Check.describe(key))
		end
	end
	table.sort(keys)
	for _, key in keys do
		local item = snapshot[key]
		if #key == 0 or #key > Cooldowns.KEY_MAX then
			table.insert(problems, "bad key " .. Check.describe(key))
		elseif
			type(item) ~= "table"
			or not Check.finite(item.remaining)
			or item.remaining < 0
			or not Check.finite(item.period)
			or item.period < 0
			or not Check.integer(item.max)
			or item.max < 1
			or item.max > Cooldowns.MAX_CHARGES
			or item.remaining > item.period * item.max + Cooldowns.EPSILON
		then
			table.insert(problems, "bad entry for " .. key)
		elseif self._entries[key] == nil and self._count >= self._maxKeys and purge(self, now) == 0 then
			table.insert(problems, "full at " .. key)
		else
			if self._entries[key] == nil then
				self._count += 1
			end
			self._entries[key] = { fullAt = now + item.remaining, period = item.period, max = item.max }
		end
	end
	return problems
end

return Cooldowns
