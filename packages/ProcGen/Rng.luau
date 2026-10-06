--!strict
-- Deterministic seeded RNG (xorshift32 + string-hash forking).
-- Identical sequences under Lune and Roblox; never uses math.random or Random.
local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable({} :: { state: number, seed: number }, Rng))

local function fnv1a(text: string): number
	local hash = 2166136261
	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		-- 32-bit multiply by the FNV prime 16777619 (2^24 + 403) without precision loss.
		hash = (hash * 403 + bit32.lshift(hash, 24)) % 4294967296
	end
	return hash
end
Rng.hash = fnv1a

function Rng.new(seed: number | string): Rng
	local numeric = if type(seed) == "string" then fnv1a(seed) else math.floor(seed :: number) % 4294967296
	local state = bit32.bxor(numeric, 0x9E3779B9)
	if state == 0 then
		state = 0x6D2B79F5
	end
	return setmetatable({ state = state, seed = numeric }, Rng)
end

function Rng.nextUInt(self: Rng): number
	local x = self.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	self.state = x
	return x
end

-- Float in [0, 1).
function Rng.next(self: Rng): number
	return self:nextUInt() / 4294967296
end

-- Integer in [min, max] inclusive.
function Rng.int(self: Rng, min: number, max: number): number
	assert(max >= min, "Rng.int: max < min")
	return min + math.floor(self:next() * (max - min + 1))
end

function Rng.range(self: Rng, min: number, max: number): number
	return min + self:next() * (max - min)
end

function Rng.chance(self: Rng, probability: number): boolean
	return self:next() < probability
end

function Rng.pick<T>(self: Rng, list: { T }): T
	assert(#list > 0, "Rng.pick: empty list")
	return list[self:int(1, #list)]
end

function Rng.weighted<T>(self: Rng, entries: { { value: T, weight: number } }): T
	local total = 0
	for _, entry in entries do
		total += entry.weight
	end
	assert(total > 0, "Rng.weighted: no positive weight")
	local roll = self:next() * total
	for _, entry in entries do
		roll -= entry.weight
		if roll < 0 then
			return entry.value
		end
	end
	return entries[#entries].value
end

function Rng.shuffle<T>(self: Rng, list: { T }): { T }
	for index = #list, 2, -1 do
		local swap = self:int(1, index)
		list[index], list[swap] = list[swap], list[index]
	end
	return list
end

-- Independent child stream: same parent seed + label always yields the same child.
function Rng.fork(self: Rng, label: string): Rng
	return Rng.new(bit32.bxor(self.seed, fnv1a(label)))
end

return Rng
