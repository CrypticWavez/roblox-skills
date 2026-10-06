--!strict
-- @tier T0
-- RateLimit: token buckets per key (a player, a player and a remote, a sender). Each key holds
-- `capacity` tokens and regains `refillPerSec` tokens per second; take(key, cost) spends them or
-- says how long to wait. Time is the injected clock (options.clock, else env.clock: time() in
-- Roblox), never a client timestamp. A clock that goes backwards refills nothing and is never
-- held against a key. Memory is bounded: past maxKeys, buckets that have refilled to capacity
-- are dropped first (they behave like new keys), then the least recently used. Pure and
-- non-yielding, so step functions and remote handlers can call it.
local Check = require("./Check")

local RateLimit = {}
RateLimit.__index = RateLimit
RateLimit.DEFAULT_MAX_KEYS = 10000

export type Options = {
	capacity: number, -- burst size in tokens (> 0)
	refillPerSec: number, -- tokens regained per second (>= 0; 0 = a fixed budget until forget)
	maxKeys: number?, -- distinct keys kept (default 10000)
	clock: (() -> number)?, -- seconds; default env.clock
}

type Bucket = { tokens: number, updated: number, touched: number }

type LimiterFields = {
	capacity: number,
	refillPerSec: number,
	maxKeys: number,
	_clock: () -> number,
	_buckets: { [any]: Bucket },
	_count: number,
	_serial: number,
}
export type RateLimit = typeof(setmetatable({} :: LimiterFields, RateLimit))

-- Problems with an options table (empty when usable).
function RateLimit.validate(options: any): { string }
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	local problems = {}
	if not (Check.finite(options.capacity) and options.capacity > 0) then
		table.insert(problems, "capacity must be a finite number > 0")
	end
	if not (Check.finite(options.refillPerSec) and options.refillPerSec >= 0) then
		table.insert(problems, "refillPerSec must be a finite number >= 0")
	end
	if options.maxKeys ~= nil and not (Check.integer(options.maxKeys) and options.maxKeys >= 1) then
		table.insert(problems, "maxKeys must be an integer >= 1")
	end
	if options.clock ~= nil and type(options.clock) ~= "function" then
		table.insert(problems, "clock must be a function")
	end
	return problems
end

-- A limiter. The clock is options.clock, else env.clock; one of them is required.
function RateLimit.new(options: Options, env: any?): RateLimit
	local problems = RateLimit.validate(options)
	local clock = options and options.clock or (env and env.clock)
	if type(clock) ~= "function" then
		table.insert(problems, "a clock is required (options.clock or env.clock)")
	end
	if #problems > 0 then
		error("RateLimit.new: " .. table.concat(problems, "; "), 2)
	end
	return setmetatable({
		capacity = options.capacity,
		refillPerSec = options.refillPerSec,
		maxKeys = options.maxKeys or RateLimit.DEFAULT_MAX_KEYS,
		_clock = clock :: () -> number,
		_buckets = {},
		_count = 0,
		_serial = 0,
	}, RateLimit)
end

-- A composite key from parts, e.g. RateLimit.key(player.UserId, "remote_name").
function RateLimit.key(...: any): string
	local parts = table.pack(...)
	local out = table.create(parts.n)
	for index = 1, parts.n do
		out[index] = tostring(parts[index])
	end
	return table.concat(out, "|")
end

local function validKey(key: any): boolean
	local kind = type(key)
	return (kind == "string" and #key > 0) or Check.finite(key) or kind == "userdata" or kind == "table"
end

local function now(self: RateLimit): number
	local value = self._clock()
	if not Check.finite(value) then
		error("RateLimit: the clock returned " .. Check.describe(value), 3)
	end
	return value
end

-- Brings a bucket up to time t. A clock that went backwards refills nothing and never moves
-- `updated` back, so the lost interval is not refilled twice when the clock recovers.
local function refill(self: RateLimit, bucket: Bucket, t: number)
	if t > bucket.updated then
		bucket.tokens = math.min(self.capacity, bucket.tokens + (t - bucket.updated) * self.refillPerSec)
		bucket.updated = t
	end
end

-- Frees room for one more key: full buckets first (indistinguishable from new keys), then the
-- least recently touched one.
local function evict(self: RateLimit, t: number)
	for key, bucket in self._buckets do
		refill(self, bucket, t)
		if bucket.tokens >= self.capacity then
			self._buckets[key] = nil
			self._count -= 1
		end
	end
	if self._count < self.maxKeys then
		return
	end
	local oldestKey, oldest = nil, math.huge
	for key, bucket in self._buckets do
		if bucket.touched < oldest then
			oldestKey, oldest = key, bucket.touched
		end
	end
	if oldestKey ~= nil then
		self._buckets[oldestKey] = nil
		self._count -= 1
	end
end

local function bucketFor(self: RateLimit, key: any, t: number): Bucket
	local bucket = self._buckets[key]
	if bucket == nil then
		if self._count >= self.maxKeys then
			evict(self, t)
		end
		bucket = { tokens = self.capacity, updated = t, touched = 0 }
		self._buckets[key] = bucket
		self._count += 1
	end
	self._serial += 1
	bucket.touched = self._serial
	return bucket
end

-- Spends cost tokens (default 1) from key's bucket. Returns (true, 0) when allowed, else
-- (false, secondsUntilAllowed); that is math.huge when cost exceeds capacity or nothing refills.
function RateLimit.take(self: RateLimit, key: any, cost: number?): (boolean, number)
	if not validKey(key) then
		error("RateLimit:take needs a key (string, number, Instance or table)", 2)
	end
	local amount = if cost == nil then 1 else cost
	if not (Check.finite(amount) and amount > 0) then
		error("RateLimit:take cost must be a finite number > 0", 2)
	end
	local t = now(self)
	local bucket = bucketFor(self, key, t)
	refill(self, bucket, t)
	if bucket.tokens >= amount then
		bucket.tokens -= amount
		return true, 0
	end
	if amount > self.capacity or self.refillPerSec == 0 then
		return false, math.huge
	end
	return false, (amount - bucket.tokens) / self.refillPerSec
end

-- Tokens key would have now (capacity for an unknown key); spends nothing.
function RateLimit.peek(self: RateLimit, key: any): number
	local bucket = self._buckets[key]
	if bucket == nil then
		return self.capacity
	end
	local t = now(self)
	if t <= bucket.updated then
		return bucket.tokens
	end
	return math.min(self.capacity, bucket.tokens + (t - bucket.updated) * self.refillPerSec)
end

-- Drops key's bucket (call on PlayerRemoving); returns whether it existed.
function RateLimit.forget(self: RateLimit, key: any): boolean
	if self._buckets[key] == nil then
		return false
	end
	self._buckets[key] = nil
	self._count -= 1
	return true
end

-- Drops every bucket whose key satisfies predicate(key); returns how many were dropped.
function RateLimit.forgetWhere(self: RateLimit, predicate: (key: any) -> boolean): number
	local dropped = 0
	for key in self._buckets do
		if predicate(key) then
			self._buckets[key] = nil
			self._count -= 1
			dropped += 1
		end
	end
	return dropped
end

function RateLimit.reset(self: RateLimit)
	self._buckets = {}
	self._count = 0
end

-- Number of keys currently held.
function RateLimit.size(self: RateLimit): number
	return self._count
end

return RateLimit
