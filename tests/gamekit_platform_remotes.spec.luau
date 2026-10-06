--!strict
-- G1 remotes: GameKit/RateLimit, GameKit/Schema, GameKit/RemoteGuard and the pure parts of
-- GameKit/RemoteGuardRoblox (plan, build, bind against tests/fakes/FakePlatformRoblox). Covers
-- floods, NaN and inf payloads, arity, hostile shapes (sparse, mixed, deep, huge), replayed and
-- reordered requests (Diagnostics/FaultQueue), clock faults and every closed reject reason.
local roblox = require("@lune/roblox")

local Events = require("../packages/GameKit/Events")
local FaultQueue = require("../packages/Diagnostics/FaultQueue")
local RateLimit = require("../packages/GameKit/RateLimit")
local RemoteGuard = require("../packages/GameKit/RemoteGuard")
local RemoteGuardRoblox = require("../packages/GameKit/RemoteGuardRoblox")
local Schema = require("../packages/GameKit/Schema")
local FakeEnv = require("./fakes/FakeEnv")
local FakePlatformRoblox = require("./fakes/FakePlatformRoblox")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

local function player(userId: number): any
	return { UserId = userId }
end

-- ---------------------------------------------------------------- RateLimit

test("RateLimit refuses bad options and a missing clock", function(t)
	t.ok(has(
		errorText(function()
			RateLimit.new({ capacity = 0, refillPerSec = 1 }, FakeEnv.new())
		end),
		"capacity must be"
	))
	t.ok(has(
		errorText(function()
			RateLimit.new({ capacity = 1, refillPerSec = 0 / 0 }, FakeEnv.new())
		end),
		"refillPerSec"
	))
	t.ok(has(
		errorText(function()
			RateLimit.new({ capacity = 1, refillPerSec = 1 })
		end),
		"a clock is required"
	))
	t.eq(#RateLimit.validate({ capacity = 1, refillPerSec = 1, maxKeys = 1.5 }), 1)
end)

test("RateLimit spends a burst, then refills at the stated rate", function(t)
	local env = FakeEnv.new()
	local limit = RateLimit.new({ capacity = 3, refillPerSec = 2 }, env)
	for _ = 1, 3 do
		t.eq({ limit:take("a") }, { true, 0 })
	end
	local ok, wait = limit:take("a")
	t.ok(not ok)
	t.near(wait, 0.5)
	env:advance(0.25)
	ok, wait = limit:take("a")
	t.ok(not ok)
	t.near(wait, 0.25)
	env:advance(0.25)
	t.ok((limit:take("a")))
	t.ok((limit:take("b")), "keys are independent")
	env:advance(100)
	t.near(limit:peek("a"), 3, 1e-9, "refill caps at capacity")
end)

test("RateLimit reports never for a cost above capacity or a zero refill", function(t)
	local env = FakeEnv.new()
	local limit = RateLimit.new({ capacity = 2, refillPerSec = 1 }, env)
	t.eq({ limit:take("a", 3) }, { false, math.huge })
	local fixed = RateLimit.new({ capacity = 1, refillPerSec = 0 }, env)
	t.ok((fixed:take("a")))
	t.eq({ fixed:take("a") }, { false, math.huge })
	env:advance(1000)
	t.ok(not (fixed:take("a")), "nothing refills a fixed budget")
	t.ok(fixed:forget("a"))
	t.ok((fixed:take("a")), "forget restores it")
	for _, bad in { 0, -1, 0 / 0, math.huge } do
		t.throws(function()
			limit:take("a", bad)
		end, "cost " .. tostring(bad))
	end
	t.throws(function()
		limit:take(nil :: any)
	end)
	t.throws(function()
		limit:take(0 / 0)
	end)
end)

test("RateLimit never refills twice when the clock goes backwards", function(t)
	local now = 100
	local limit = RateLimit.new({
		capacity = 2,
		refillPerSec = 1,
		clock = function(): number
			return now
		end,
	})
	t.ok((limit:take("a")) and (limit:take("a")))
	now = 90 -- backwards: no refill, no penalty
	t.ok(not (limit:take("a")))
	now = 100 -- back to where it was: the 10 s were never earned
	t.ok(not (limit:take("a")))
	now = 101
	t.ok((limit:take("a")))
	now = 0 / 0
	t.ok(has(
		errorText(function()
			limit:take("a")
		end),
		"clock returned nan"
	))
end)

test("RateLimit bounds memory: full buckets go first, then the least recently used", function(t)
	local env = FakeEnv.new()
	local limit = RateLimit.new({ capacity = 1, refillPerSec = 1, maxKeys = 3 }, env)
	limit:take("a")
	limit:take("b")
	limit:take("c")
	t.eq(limit:size(), 3)
	limit:take("d") -- nothing has refilled yet: the least recently used (a) goes
	t.eq(limit:size(), 3)
	t.eq(limit:peek("a"), 1, "a was evicted (fresh)")
	t.eq(limit:peek("b"), 0, "b kept its empty bucket")
	env:advance(10) -- everything refilled: all full buckets are dropped at the next eviction
	limit:take("e")
	t.eq(limit:size(), 1)
	t.eq(
		limit:forgetWhere(function(key: any): boolean
			return key == "e"
		end),
		1
	)
	t.eq(RateLimit.key(42, "remote", true), "42|remote|true")
end)

-- ---------------------------------------------------------------- Schema

local function reason(schema: any, value: any, opts: any?): (string?, string?)
	local ok, path, why = Schema.check(schema, value, opts)
	if ok then
		return nil, nil
	end
	return why, path
end

test("Schema.number always rejects NaN and inf, then checks integer and range", function(t)
	local any = Schema.number()
	t.eq(reason(any, 0 / 0), "nan")
	t.eq(reason(any, math.huge), "infinite")
	t.eq(reason(any, -math.huge), "infinite")
	t.eq(reason(any, "1"), "type")
	t.eq(reason(any, 1e308), nil)
	local bounded = Schema.integer({ min = 1, max = 10 })
	t.eq(reason(bounded, 0), "below_min")
	t.eq(reason(bounded, 11), "above_max")
	t.eq(reason(bounded, 2.5), "not_integer")
	t.eq(reason(bounded, 2 ^ 60), "not_integer")
	t.eq(reason(bounded, 10), nil)
	t.eq(reason(bounded, nil), "missing")
	t.throws(function()
		Schema.number({ min = 2, max = 1 })
	end)
	t.throws(function()
		Schema.number({ min = 0 / 0 })
	end)
end)

test("Schema.string checks bytes, UTF-8 and the pattern", function(t)
	local s = Schema.string({ minLen = 2, maxLen = 5, pattern = "^[%a]+$" })
	t.eq(reason(s, "ab"), nil)
	t.eq(reason(s, "a"), "too_short")
	t.eq(reason(s, "abcdef"), "too_long")
	t.eq(reason(s, "ab1"), "pattern")
	t.eq(reason(Schema.string(), "\xff\xfe"), "invalid_utf8")
	t.eq(reason(Schema.string({ utf8 = false }), "\xff"), nil)
	t.eq(reason(Schema.string(), string.rep("x", 257)), "too_long", "default bound is 256 bytes")
	t.eq(reason(Schema.string(), 5), "type")
	t.throws(function()
		Schema.string({ minLen = 3, maxLen = 2 })
	end)
end)

test("Schema.vector3 and cframe reject NaN, inf and far positions", function(t)
	local v = Schema.vector3({ maxMagnitude = 100 })
	t.eq(reason(v, roblox.Vector3.new(1, 2, 3)), nil)
	t.eq(reason(v, roblox.Vector3.new(0 / 0, 0, 0)), "nan")
	t.eq(reason(v, roblox.Vector3.new(0, math.huge, 0)), "infinite")
	t.eq(reason(v, roblox.Vector3.new(100, 1, 0)), "magnitude")
	t.eq(reason(v, { X = 1, Y = 2, Z = 3 }), "type", "a table is not a Vector3")
	t.eq(reason(v, (vector :: any).create(1, 2, 3)), nil, "native vector")
	local c = Schema.cframe({ maxMagnitude = 10 })
	t.eq(reason(c, roblox.CFrame.new(1, 2, 3)), nil)
	t.eq(reason(c, roblox.CFrame.new(0 / 0, 0, 0)), "nan")
	t.eq(reason(c, roblox.CFrame.new(20, 0, 0)), "magnitude")
	t.eq(reason(c, roblox.Vector3.new(0, 0, 0)), "type")
end)

test("Schema.struct is strict and names the failing path", function(t)
	local s = Schema.struct({
		id = Schema.string({ maxLen = 8 }),
		count = Schema.optional(Schema.integer({ min = 0 })),
		inner = Schema.struct({ list = Schema.array(Schema.number(), { maxLen = 4 }) }),
	})
	local good = { id = "a", inner = { list = { 1, 2 } } }
	t.eq(reason(s, good), nil)
	local why, path = reason(s, { id = "a", inner = { list = { 1, 0 / 0 } } })
	t.eq({ why, path }, { "nan", "$.inner.list[2]" })
	why, path = reason(s, { id = "a", inner = { list = {} }, extra = 1 })
	t.eq({ why, path }, { "unexpected_key", "$.extra" })
	why, path = reason(s, { inner = { list = {} } })
	t.eq({ why, path }, { "missing", "$.id" })
	why, path = reason(s, { id = "a", inner = { list = {} }, [1] = true })
	t.eq({ why, path }, { "key", "$[1]" })
	t.eq(reason(Schema.struct({ a = Schema.number() }, { strict = false }), { a = 1, b = 2 }), nil)
	t.throws(function()
		Schema.struct({ a = 5 :: any })
	end)
end)

test("Schema.array refuses sparse, mixed and oversized lists", function(t)
	local list = Schema.array(Schema.optional(Schema.number()), { maxLen = 3 })
	t.eq(reason(list, { 1, 2, 3 }), nil)
	t.eq(reason(list, {}), nil)
	t.eq(reason(list, { [1] = 1, [3] = 3 }), "sparse_array")
	t.eq(reason(list, { [2] = 1, [5] = 2 }), "sparse_array", "holes before every key")
	t.eq(reason(list, { 1, 2, x = 3 }), "not_array")
	t.eq(reason(list, { 1, 2, 3, 4 }), "too_long")
	t.eq(reason(list, { [1.5] = 1 }), "not_array")
	t.eq(reason(Schema.array(Schema.number(), { minLen = 1 }), {}), "too_short")
end)

test("Schema map, enum, literal, union, custom and instanceOf", function(t)
	local map = Schema.map(Schema.string({ maxLen = 4 }), Schema.boolean(), { maxEntries = 2 })
	t.eq(reason(map, { a = true }), nil)
	t.eq(reason(map, { a = true, b = false, c = true }), "too_many")
	t.eq(reason(map, { [1] = true }), "key")
	t.eq(reason(map, { abcde = true }), "too_long")
	t.eq(reason(map, { a = 1 }), "type")
	t.eq(reason(Schema.enum({ "a", "b" }), "c"), "not_in_enum")
	t.eq(reason(Schema.enum({ 1, 2 }), true), "type")
	t.eq(reason(Schema.literal("x"), "y"), "not_in_enum")
	t.eq(reason(Schema.literal("x"), 1), "type")
	local u = Schema.union({ Schema.number(), Schema.string({ maxLen = 2 }) })
	t.eq(reason(u, 1), nil)
	t.eq(reason(u, "ab"), nil)
	t.eq(reason(u, "abc"), "union")
	local even = Schema.custom("even", function(v: any): boolean
		return v % 2 == 0
	end)
	t.eq(reason(even, 2), nil)
	t.eq(reason(even, 3), "custom")
	t.eq(reason(even, "x"), "custom", "an erroring predicate fails closed")
	local folder = FakePlatformRoblox.instance("Folder")
	local remote = FakePlatformRoblox.instance("RemoteEvent")
	remote.Parent = folder
	local outside = FakePlatformRoblox.instance("RemoteEvent")
	local function fakeTypeof(value: any): string
		return if type(value) == "table" and type(value.IsA) == "function" then "Instance" else typeof(value)
	end
	local remoteIn = Schema.instanceOf("BaseRemoteEvent", { ancestor = folder, typeof = fakeTypeof })
	t.eq(reason(remoteIn, remote), nil)
	t.eq(reason(remoteIn, outside), "ancestor")
	t.eq(reason(Schema.instanceOf("Folder", { typeof = fakeTypeof }), remote), "class")
	t.eq(reason(Schema.instanceOf("Folder", { typeof = fakeTypeof }), {}), "type")
	t.eq(reason(Schema.instanceOf("Folder"), remote), "type", "the builtin typeof sees a table")
	t.throws(function()
		Schema.enum({})
	end)
	t.throws(function()
		Schema.union({})
	end)
end)

test("Schema budgets bound hostile payloads", function(t)
	local nested: any = {}
	local node = nested
	for _ = 1, 100 do
		node.next = {}
		node = node.next
	end
	local function chain(depth: number): any
		if depth == 0 then
			return Schema.struct({})
		end
		return Schema.struct({ next = Schema.optional(chain(depth - 1)) })
	end
	t.eq(reason(chain(40), nested), "too_deep", "default depth 32")
	local big = table.create(5000, 1)
	t.eq(reason(Schema.array(Schema.number(), { maxLen = 10000 }), big, { maxNodes = 100 }), "too_many_nodes")
	local ok, _, why = Schema.storable(nested)
	t.eq({ ok, why }, { false, "too_deep" })
end)

test("Schema.storable accepts plain data and names what a DataStore cannot hold", function(t)
	t.ok((Schema.storable({ a = { 1, 2, { b = "x" } }, c = true, d = 1.5, e = {} })))
	local function why(value: any): string?
		local ok, path, r = Schema.storable(value)
		return if ok then nil else (r :: string) .. "@" .. (path :: string)
	end
	t.eq(why({ a = 0 / 0 }), "nan@$.a")
	t.eq(why({ a = function() end }), "type@$.a")
	t.eq(why({ 1, 2, x = 3 }), "mixed_keys@$")
	t.eq(why({ [1] = 1, [3] = 3 }), "sparse_array@$")
	t.eq(why({ [true :: any] = 1 }), "key@$[true]")
	t.eq(why({ v = roblox.Vector3.new(1, 2, 3) }), "type@$.v")
	t.eq(why({ s = "\xff" }), "invalid_utf8@$.s")
	t.eq(why(nil), "type@$")
	local cyclic: any = { a = {} }
	cyclic.a.back = cyclic
	t.eq(why(cyclic), "cycle@$.a.back")
	local shared = { 1 }
	t.ok((Schema.storable({ x = shared, y = shared })), "shared tables are not cycles")
	t.eq(Schema.size({ a = 1 }), #'{"a":1}')
	t.eq(Schema.DATASTORE_VALUE_LIMIT, 4194304)
	t.eq(reason(Schema.any(), { a = { 1 } }), nil)
	t.eq(reason(Schema.any(), { a = 0 / 0 }), "nan")
end)

test("Schema.checkArgs enforces arity and positions", function(t)
	local list = { Schema.number(), Schema.optional(Schema.string()) }
	t.eq(Schema.requiredCount(list), 1)
	t.ok((Schema.checkArgs(list, table.pack(1))))
	t.ok((Schema.checkArgs(list, table.pack(1, "x"))))
	t.eq({ Schema.checkArgs(list, table.pack(1, "x", 3)) }, { false, "args", "arity" })
	t.eq({ Schema.checkArgs(list, table.pack()) }, { false, "args", "arity" })
	t.eq({ Schema.checkArgs(list, table.pack(nil, "x")) }, { false, "args[1]", "missing" })
	t.eq({ Schema.checkArgs(list, table.pack(1, 2)) }, { false, "args[2]", "type" })
end)

-- ---------------------------------------------------------------- RemoteGuard

local function guardFor(env: any, extra: { [string]: any }?): any
	local options: any = {
		schemas = {
			move = {
				kind = "unreliable",
				args = { Schema.vector3({ maxMagnitude = 1000 }) },
				rate = { capacity = 10, refillPerSec = 0 },
			},
			buy = {
				kind = "function",
				args = {
					Schema.string({ maxLen = 32, pattern = "^[%w_]+$" }),
					Schema.integer({ min = 1, max = 99 }),
				},
				dedupe = { arg = 1, window = 2 },
			},
			ping = { kind = "event", args = {} },
		},
	}
	for key, value in extra or {} do
		options[key] = value
	end
	return RemoteGuard.new(options, env)
end

test("RemoteGuard: a 1000-call flood accepts only the bucket capacity", function(t)
	local env = FakeEnv.new()
	local guard = guardFor(env)
	local handled = 0
	local handler = guard:wrap("move", function()
		handled += 1
	end)
	local p = player(1)
	local v = roblox.Vector3.new(1, 0, 0)
	for _ = 1, 1000 do
		handler(p, v)
	end
	t.eq(handled, 10)
	local stats = guard:stats(p)
	t.eq(stats.accepted, 10)
	t.eq(stats.rejected, 990)
	t.eq(stats.reasons.rate, 990)
	t.eq(stats.byRemote.move.accepted, 10)
	-- the same flood with refill: only what the server clock earns gets through
	local env2 = FakeEnv.new()
	local refill = RemoteGuard.new({
		schemas = { move = { args = { Schema.vector3() }, rate = { capacity = 5, refillPerSec = 10 } } },
	}, env2)
	local count = 0
	local h = refill:wrap("move", function()
		count += 1
	end)
	for _ = 1, 1000 do
		h(p, v)
		env2:advance(0.001) -- 1 s of flooding
	end
	t.ok(count >= 14 and count <= 16, "capacity 5 plus ~10 refilled, got " .. count)
end)

test("RemoteGuard rejects NaN vectors, extra and missing args with closed reasons", function(t)
	local env = FakeEnv.new()
	local rejects = {}
	local guard = guardFor(env, {
		onReject = function(_p: any, remote: string, why: string, detail: any)
			table.insert(rejects, { remote, why, detail and detail.path or nil })
		end,
	})
	local p = player(1)
	t.eq({ guard:check("move", p, roblox.Vector3.new(0 / 0, 0, 0)) }, {
		false,
		"schema",
		{ path = "args[1]", reason = "nan" },
	})
	t.eq((select(2, guard:check("move", p, roblox.Vector3.new(1, 1, 1), "extra"))), "arity")
	t.eq((select(2, guard:check("move", p))), "arity")
	t.eq((select(2, guard:check("buy", p, "item_a", 0 / 0))), "schema")
	t.eq((select(2, guard:check("buy", p, "item a", 1))), "schema", "pattern")
	t.eq((select(2, guard:check("teleport_me", p))), "unknown_remote")
	t.eq((select(2, guard:check("ping", nil))), "invalid_player")
	t.eq((select(2, guard:check("ping", { UserId = 0 / 0 }))), "invalid_player")
	t.eq(rejects[1], { "move", "schema", "args[1]" })
	t.eq(#rejects, 8)
	t.ok(guard:check("ping", p))
	for _, why in RemoteGuard.REASONS do
		t.ok(type(why) == "string")
	end
end)

test("RemoteGuard checks rate before schema, so malformed floods spend tokens", function(t)
	local env = FakeEnv.new()
	local guard = guardFor(env)
	local p = player(2)
	local schemaRejects = 0
	for _ = 1, 50 do
		local _, why = guard:check("move", p, "not a vector")
		if why == "schema" then
			schemaRejects += 1
		end
	end
	t.eq(schemaRejects, 10, "only the first 10 were even parsed")
	t.eq(
		(select(2, guard:check("move", p, roblox.Vector3.new(1, 0, 0)))),
		"rate",
		"a valid call is still limited"
	)
end)

test("RemoteGuard ignores client clocks: only the server clock refills", function(t)
	local env = FakeEnv.new()
	local guard = RemoteGuard.new({
		schemas = {
			act = { args = { Schema.number() }, rate = { capacity = 2, refillPerSec = 1 } },
		},
	}, env)
	local p = player(3)
	local accepted = 0
	for i = 1, 20 do
		-- the client claims ever later timestamps; the guard never reads them
		if guard:check("act", p, 1000 + i * 3600) then
			accepted += 1
		end
	end
	t.eq(accepted, 2)
end)

test("RemoteGuard handlers: errors are caught, RemoteFunctions return results or nothing", function(t)
	local env = FakeEnv.new()
	local guard = guardFor(env)
	local p = player(4)
	local invoke = guard:wrap("buy", function(_p: any, item: string, count: number): (string, number)
		if item == "boom" then
			error("server-side detail")
		end
		return item, count * 2
	end)
	t.eq({ invoke(p, "item_a", 2) }, { "item_a", 4 })
	t.eq(select("#", invoke(p, "item_b", 0)), 0, "a rejected invoke returns nothing")
	t.eq(select("#", invoke(p, "boom", 1)), 0, "a handler error returns nothing")
	t.eq(guard:stats(p).handlerErrors, 1)
	t.eq(guard:stats(p).accepted, 2, "the failing call passed the guard")
	t.ok(has(env.reports[1], "server-side detail"), "the error goes to env.report, not the client")
	t.ok(has(
		errorText(function()
			guard:wrap("nope", function() end)
		end),
		"no schema for remote nope"
	))
	t.throws(function()
		guard:wrap("buy", nil :: any)
	end)
	t.eq(guard:kind("buy"), "function")
	t.eq(guard:names(), { "buy", "move", "ping" })
end)

test("RemoteGuard dedupe rejects replayed request ids within the window", function(t)
	local env = FakeEnv.new()
	local guard = guardFor(env)
	local p = player(5)
	t.ok(guard:check("buy", p, "req_1", 1))
	t.eq((select(2, guard:check("buy", p, "req_1", 1))), "duplicate")
	t.ok(guard:check("buy", p, "req_2", 1))
	t.ok(guard:check("buy", p, "req_3", 1)) -- window 2: req_1 falls out
	t.ok(guard:check("buy", p, "req_1", 1), "outside the window it is new again")
	t.ok(guard:check("buy", player(6), "req_3", 1), "ids are per player")
	t.ok(#RemoteGuard.validate({
		schemas = { bad = { args = { Schema.vector3() }, dedupe = { arg = 1 } } },
	}) == 1, "a vector cannot be a request id")
end)

test("RemoteGuard dedupe holds under duplicated and reordered delivery (FaultQueue)", function(t)
	local env = FakeEnv.new()
	local guard = RemoteGuard.new({
		schemas = {
			step = {
				args = { Schema.integer({ min = 1 }) },
				rate = { capacity = 1000, refillPerSec = 0 },
				dedupe = { arg = 1, window = 64 },
			},
		},
	}, env)
	local queue = FaultQueue.new({
		seed = 7,
		capacity = 256,
		minDelay = 0,
		maxDelay = 0.2,
		lossProbability = 0,
		duplicateProbability = 0.5,
	})
	for sequence = 1, 40 do
		queue:enqueue({ sequence = sequence, sentAt = 0, label = "step" })
	end
	local seen: { [number]: number } = {}
	local delivered = 0
	local handler = guard:wrap("step", function(_p: any, sequence: number)
		seen[sequence] = (seen[sequence] or 0) + 1
	end)
	for _ = 1, 10 do
		for _, packet in queue:advance(0.05) do
			delivered += 1
			handler(player(7), packet.sequence)
		end
	end
	t.ok(delivered > 40, "the queue duplicated some packets (" .. delivered .. ")")
	for sequence = 1, 40 do
		t.eq(seen[sequence], 1, "sequence " .. sequence)
	end
	t.eq(guard:stats(player(7)).reasons.duplicate, delivered - 40)
end)

test("RemoteGuard authorize runs after the schema and fails closed", function(t)
	local env = FakeEnv.new()
	local calls = 0
	local guard = RemoteGuard.new({
		schemas = {
			admin = {
				args = { Schema.string() },
				authorize = function(p: any, command: string): boolean
					calls += 1
					if command == "crash" then
						error("authorize bug")
					end
					return p.UserId == 1
				end,
			},
		},
	}, env)
	t.ok(guard:check("admin", player(1), "go"))
	t.eq((select(2, guard:check("admin", player(2), "go"))), "unauthorized")
	t.eq((select(2, guard:check("admin", player(1), "crash"))), "unauthorized")
	t.eq((select(2, guard:check("admin", player(1), 5))), "schema")
	t.eq(calls, 3, "authorize never sees a malformed call")
end)

test("RemoteGuard abuse hook fires once per window and telemetry is rate-limited", function(t)
	local env = FakeEnv.new()
	local abuse = {}
	local sink = Events.recorder({ clock = env.clock })
	local guard = guardFor(env, {
		abuse = {
			rejects = 20,
			window = 10,
			onAbuse = function(p: any, summary: any)
				table.insert(abuse, { p.UserId, summary.rejects })
			end,
		},
		telemetry = sink,
		telemetryRate = { capacity = 3, refillPerSec = 0.1 },
	})
	local p = player(8)
	for _ = 1, 100 do
		guard:check("ping", p, "unexpected")
	end
	t.eq(abuse, { { 8, 20 } })
	t.eq(sink:count(), 3, "three remote_rejected events, not 100")
	local event = sink.events[1]
	t.eq(event.name, "remote_rejected")
	t.eq(event.fields, { remote = "ping", reason = "arity" })
	t.eq(event.player, "8")
	env:advance(10)
	for _ = 1, 20 do
		guard:check("ping", p, "unexpected")
	end
	t.eq(#abuse, 2, "a new window can fire again")
	t.eq(sink:count(), 4, "one token refilled in 10 s")
end)

test("RemoteGuard forget drops buckets, dedupe ids and counts", function(t)
	local env = FakeEnv.new()
	local guard = guardFor(env)
	local p = player(9)
	for _ = 1, 10 do
		guard:check("move", p, roblox.Vector3.new(1, 0, 0))
	end
	t.eq((select(2, guard:check("move", p, roblox.Vector3.new(1, 0, 0)))), "rate")
	guard:check("buy", p, "req", 1)
	guard:forget(p)
	t.eq(guard:stats(p).accepted, 0)
	t.ok(guard:check("move", p, roblox.Vector3.new(1, 0, 0)), "bucket refilled after forget")
	t.ok(guard:check("buy", p, "req", 1), "dedupe ids cleared")
	guard:check("ping", player(10))
	local total = guard:stats()
	t.eq(total.players, 2)
	t.eq(total.accepted, 3)
	guard:forget(nil)
end)

test("RemoteGuard.validate lists every broken spec", function(t)
	local problems = RemoteGuard.validate({
		schemas = {
			["bad name"] = { args = {} },
			k = { kind = "stream", args = { 5 } },
			r = { args = {}, rate = { capacity = -1, refillPerSec = 1 }, cost = 0 },
			d = { args = { Schema.string() }, dedupe = { arg = 3 } },
		},
		abuse = { rejects = 0, window = 1 },
		onReject = 5,
		telemetry = {},
	})
	local text = table.concat(problems, "\n")
	for _, needle in
		{
			"remote bad name",
			"kind must be",
			"args[1] is not a schema",
			"capacity must be",
			"cost must be",
			"dedupe.arg",
			"abuse needs",
			"onReject must be",
			"telemetry must be a sink",
		}
	do
		t.ok(has(text, needle), needle .. " in\n" .. text)
	end
	t.ok(has(
		errorText(function()
			RemoteGuard.new({ schemas = { a = { args = {} } } }, nil)
		end),
		"env with clock"
	))
	t.eq(RemoteGuard.validate({ schemas = {} }), { "schemas must map remote names to specs" })
end)

-- ---------------------------------------------------------------- RemoteGuardRoblox

test("RemoteGuardRoblox.plan fails closed on unguarded, mismatched and missing remotes", function(t)
	local guard = guardFor(FakeEnv.new())
	local plan = RemoteGuardRoblox.plan(guard, {
		{ Name = "move", ClassName = "UnreliableRemoteEvent" },
		{ Name = "buy", ClassName = "RemoteEvent" },
		{ Name = "secret", ClassName = "RemoteFunction" },
		{ Name = "move", ClassName = "UnreliableRemoteEvent" },
		{ Name = "Config", ClassName = "Folder" },
	}, { move = function() end })
	t.eq(#plan.bind, 1)
	t.eq(plan.bind[1].name, "move")
	t.eq(plan.missing, { "ping" })
	local text = table.concat(plan.problems, "\n")
	t.ok(has(text, "remote buy is a RemoteEvent but its schema says function"), text)
	t.ok(has(text, "unguarded remote secret"), text)
	t.ok(has(text, "duplicate remote name move"), text)
	local noHandler = RemoteGuardRoblox.plan(guard, { { Name = "ping", ClassName = "RemoteEvent" } }, {})
	t.ok(has(noHandler.problems[1], "no handler for remote ping"))
end)

test("RemoteGuardRoblox build and bind route real-shaped remotes through the guard", function(t)
	local env = FakeEnv.new()
	local guard = guardFor(env)
	local folder = FakePlatformRoblox.instance("Folder", "Remotes")
	local players = FakePlatformRoblox.players({ 11 })
	local p = players:GetPlayers()[1]
	t.eq(RemoteGuardRoblox.build(folder, guard, FakePlatformRoblox.roblox()), { "buy", "move", "ping" })
	t.eq(RemoteGuardRoblox.build(folder, guard, FakePlatformRoblox.roblox()), {}, "idempotent")
	local moves = 0
	local binding = RemoteGuardRoblox.bind(folder, guard, {
		move = function()
			moves += 1
		end,
		buy = function(_p: any, item: string): string
			return "bought " .. item
		end,
		ping = function() end,
	}, { players = players })
	local move = folder:FindFirstChild("move")
	for _ = 1, 50 do
		move.OnServerEvent:Fire(p, roblox.Vector3.new(1, 2, 3))
	end
	t.eq(moves, 10)
	t.eq(folder:FindFirstChild("buy").OnServerInvoke(p, "item_x", 1), "bought item_x")
	players:leave(p)
	t.eq(guard:stats(p).rejected, 0, "PlayerRemoving cleared the guard state")
	binding.unbind()
	t.eq(move.OnServerEvent:count(), 0)
	t.eq(folder:FindFirstChild("buy").OnServerInvoke, nil)
	local stray = FakePlatformRoblox.instance("RemoteEvent", "backdoor")
	stray.Parent = folder
	t.ok(has(
		errorText(function()
			RemoteGuardRoblox.bind(folder, guard, { move = print, buy = print, ping = print })
		end),
		"unguarded remote backdoor"
	))
	stray:Destroy()
	folder:FindFirstChild("ping"):Destroy()
	t.ok(has(
		errorText(function()
			RemoteGuardRoblox.bind(folder, guard, { move = print, buy = print })
		end),
		"no remote for ping"
	))
	t.ok(RemoteGuardRoblox.bind(folder, guard, { move = print, buy = print }, { allowMissing = true }))
end)

return cases
