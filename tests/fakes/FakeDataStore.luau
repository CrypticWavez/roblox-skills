--!strict
-- FakeDataStore (G1): a GlobalDataStore stand-in for Lune specs. GetAsync, SetAsync,
-- UpdateAsync and RemoveAsync with DataStoreKeyInfo-like info (Version, UpdatedTime,
-- GetMetadata, GetUserIds), deep-copied values (callers never share tables with the store),
-- key and value checks close to Roblox's (keys 1-50 characters, values JSON-storable and at
-- most 4,194,304 characters once encoded), and fault injection: fail(n, message) makes the next
-- n calls raise message (a "301: ..." throttle or a "502: ..." server error, which
-- GameKit/Retry classifies as the engine's would). Several handles over one `world` act as
-- servers sharing a store. With env and latency set, each call waits latency seconds before it
-- touches the data, so specs can interleave servers. The UpdateAsync transform gets the value
-- current at write time, as in Roblox; returning nil cancels the write.
-- Error codes are illustrative of Roblox's numbering, not an exhaustive copy of it.
local Json = require("../../packages/GameKit/Json")

local FakeDataStore = {}

export type Entry = {
	value: any,
	version: number,
	updatedAt: number,
	metadata: { [string]: any },
	userIds: { number },
}
export type World = { entries: { [string]: Entry }, clock: number, log: { string } }

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in value do
		out[copy(key)] = copy(item)
	end
	return out
end

local function keyInfo(entry: Entry): any
	local info = { Version = tostring(entry.version), UpdatedTime = entry.updatedAt * 1000 }
	function info.GetMetadata(_self: any): { [string]: any }
		return copy(entry.metadata)
	end
	function info.GetUserIds(_self: any): { number }
		return copy(entry.userIds)
	end
	return info
end

local function checkKey(key: any)
	if type(key) ~= "string" or key == "" then
		error("101: Key name can't be empty.", 3)
	end
	if #key > 50 then
		error("102: Key name exceeds the 50 character limit.", 3)
	end
end

-- Raises like a DataStore given a value it cannot store: functions, threads, userdata and
-- Roblox types are rejected (104); the encoded value must fit 4,194,304 characters (105).
local function checkValue(value: any)
	local function walk(node: any)
		local kind = type(node)
		if kind == "table" then
			for key, item in node do
				walk(key)
				walk(item)
			end
		elseif kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
			error("104: Cannot store " .. typeof(node) .. " in data store.", 0)
		end
	end
	walk(value)
	if #Json.encode(value) > 4194304 then
		error("105: Serialized value exceeds 4MB limit.", 0)
	end
end

-- A shared backing store (one per simulated game).
function FakeDataStore.world(): World
	return { entries = {}, clock = 0, log = {} }
end

-- A DataStore handle over world (a new world when omitted). options.env and options.latency
-- make each call wait; options.now supplies UpdatedTime seconds.
function FakeDataStore.new(options: { world: World?, env: any?, latency: number?, name: string? }?): any
	local world: World = options and options.world or FakeDataStore.world()
	local env = options and options.env
	local latency = options and options.latency or 0
	local store =
		{ world = world, name = options and options.name or "fake", calls = 0, failures = {} } :: any

	local function enter(method: string, key: string)
		store.calls += 1
		table.insert(world.log, method .. " " .. key)
		if latency > 0 and env then
			env.wait(latency)
		end
		local failure = store.failures[1]
		if failure then
			failure.remaining -= 1
			if failure.remaining <= 0 then
				table.remove(store.failures, 1)
			end
			error(failure.message, 0)
		end
	end

	local function write(key: string, value: any, userIds: any, metadata: any)
		checkValue(value)
		local entry = world.entries[key]
		world.clock += 1
		world.entries[key] = {
			value = copy(value),
			version = (if entry then entry.version else 0) + 1,
			updatedAt = world.clock,
			metadata = if metadata ~= nil then copy(metadata) else (if entry then entry.metadata else {}),
			userIds = if userIds ~= nil then copy(userIds) else (if entry then entry.userIds else {}),
		}
	end

	-- Queues a failure: the next `count` calls (default 1) raise `message`.
	function store.fail(self: any, count: number?, message: string?)
		table.insert(
			self.failures,
			{ remaining = count or 1, message = message or "502: API Services rejected request" }
		)
	end

	function store.GetAsync(_self: any, key: string): (any, any)
		checkKey(key)
		enter("GetAsync", key)
		local entry = world.entries[key]
		if entry == nil then
			return nil, nil
		end
		return copy(entry.value), keyInfo(entry)
	end

	function store.SetAsync(
		_self: any,
		key: string,
		value: any,
		userIds: { number }?,
		setOptions: any?
	): string
		checkKey(key)
		enter("SetAsync", key)
		local metadata = setOptions and setOptions.metadata
		write(key, value, userIds or {}, metadata or {})
		return tostring(world.entries[key].version)
	end

	function store.UpdateAsync(_self: any, key: string, transform: (any, any) -> ...any): (any, any)
		checkKey(key)
		enter("UpdateAsync", key)
		local entry = world.entries[key]
		local current = if entry then copy(entry.value) else nil
		local info = if entry then keyInfo(entry) else nil
		local thread = coroutine.running()
		local results = table.pack(transform(current, info))
		assert(coroutine.running() == thread, "UpdateAsync transform must not yield")
		local value = results[1]
		if value == nil then
			return nil, nil
		end
		write(key, value, results[2], results[3])
		local written = world.entries[key]
		return copy(written.value), keyInfo(written)
	end

	function store.RemoveAsync(_self: any, key: string): (any, any)
		checkKey(key)
		enter("RemoveAsync", key)
		local entry = world.entries[key]
		world.entries[key] = nil
		if entry == nil then
			return nil, nil
		end
		return copy(entry.value), keyInfo(entry)
	end

	-- Test helpers (not Roblox API): raw reads and writes that bypass faults and latency.
	function store.peek(_self: any, key: string): (any, { [string]: any }?)
		local entry = world.entries[key]
		if entry == nil then
			return nil, nil
		end
		return copy(entry.value), copy(entry.metadata)
	end
	function store.poke(_self: any, key: string, value: any, metadata: { [string]: any }?)
		write(key, value, nil, metadata)
	end

	return store
end

return FakeDataStore
