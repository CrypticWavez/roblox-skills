--!strict
-- FakeEconomyStore: the key-store interface the G3 economy kits take (docs/runtime-kits.md
-- "Interfaces passed in by callers": store:get(key), store:set(key, value) with plain data).
-- Values are deep-copied in and out, so a kit that mutates what it stored (or what it read)
-- is caught. failSet(n) makes the next n set calls raise, failSetWhen(fn) raises when fn(key,
-- value) is true, so specs can prove that a failed durable write leaves state untouched.
-- Owned by G3 (economy kit); other groups use their own fakes.
local FakeEconomyStore = {}

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[copy(key)] = copy(child)
	end
	return out
end

function FakeEconomyStore.new(initial: { [string]: any }?): any
	local store: any = { data = {}, writes = 0, reads = 0, failures = 0 }
	for key, value in initial or {} do
		store.data[key] = copy(value)
	end
	local failNext = 0
	local failWhen: ((key: string, value: any) -> boolean)? = nil

	function store.get(self: any, key: string): any
		self.reads += 1
		return copy(self.data[key])
	end

	function store.set(self: any, key: string, value: any)
		if failNext > 0 or (failWhen and failWhen(key, value)) then
			if failNext > 0 then
				failNext -= 1
			end
			self.failures += 1
			error("FakeEconomyStore: injected set failure for " .. key, 2)
		end
		self.writes += 1
		self.data[key] = copy(value)
	end

	function store.failSet(_self: any, count: number?)
		failNext = count or 1
	end

	function store.failSetWhen(_self: any, predicate: ((key: string, value: any) -> boolean)?)
		failWhen = predicate
	end

	return store
end

-- A policy predicate (docs/runtime-kits.md: policyAllows(feature) -> boolean, fail closed)
-- that allows exactly the named features.
function FakeEconomyStore.policy(allowed: { string }): (feature: string) -> boolean
	return function(feature: string): boolean
		return table.find(allowed, feature) ~= nil
	end
end

return FakeEconomyStore
