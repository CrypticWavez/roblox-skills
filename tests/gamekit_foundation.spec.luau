--!strict
-- Stage 0 foundation specs: GameKit Check, Json, Env (+ EnvRoblox mapping), Signal, Scope, Fsm,
-- Retry, Events (kit-event/1), Settings (settings/1), Catalog (catalog/1), Probe, and the shared
-- helpers tests/fakes/FakeEnv and tests/lib/Golden. Each module gets edge cases and failure paths.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Catalog = require("../packages/GameKit/Catalog")
local Check = require("../packages/GameKit/Check")
local Env = require("../packages/GameKit/Env")
local EnvRoblox = require("../packages/GameKit/EnvRoblox")
local Events = require("../packages/GameKit/Events")
local Fsm = require("../packages/GameKit/Fsm")
local Json = require("../packages/GameKit/Json")
local Probe = require("../packages/GameKit/Probe")
local Retry = require("../packages/GameKit/Retry")
local Rng = require("../packages/ProcGen/Rng")
local Scope = require("../packages/GameKit/Scope")
local Settings = require("../packages/GameKit/Settings")
local Signal = require("../packages/GameKit/Signal")
local FakeEnv = require("./fakes/FakeEnv")
local Golden = require("./lib/Golden")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function kitLoader(path: string): any
	return (require :: any)("../packages/" .. path)
end

-- ---------------------------------------------------------------- Check

test("Check.finite accepts real numbers and rejects NaN, inf and non-numbers", function(t)
	for _, value in { 0, 1, -1.5, 1e300 } do
		t.ok(Check.finite(value), tostring(value))
	end
	for _, value in { 0 / 0, math.huge, -math.huge, "1", nil, true, {} } do
		t.ok(not Check.finite(value), tostring(value))
	end
end)

test("Check.integer needs a finite whole number within 2^53", function(t)
	t.ok(Check.integer(3) and Check.integer(-7) and Check.integer(0) and Check.integer(2 ^ 53))
	t.ok(not Check.integer(3.5), "fraction")
	t.ok(not Check.integer(2 ^ 54), "beyond 2^53")
	t.ok(not Check.integer(0 / 0) and not Check.integer(math.huge) and not Check.integer("3"))
end)

test("Check.label is lower_snake_case with a length cap", function(t)
	t.ok(Check.label("a") and Check.label("currency_a") and Check.label("x9_y"))
	for _, bad in { "", "A", "Ab", "1a", "_a", "a-b", "a b", "a.b" } do
		t.ok(not Check.label(bad), bad)
	end
	t.ok(Check.label(string.rep("a", 64)), "64 chars")
	t.ok(not Check.label(string.rep("a", 65)), "65 chars")
	t.ok(not Check.label("abcd", 3), "custom cap")
	t.ok(not Check.label(5), "number")
end)

test("Check.assertFinite returns the value or names it in the error", function(t)
	t.eq(Check.assertFinite(2.5, "speed"), 2.5)
	local text = errorText(function()
		Check.assertFinite(0 / 0, "speed")
	end)
	t.ok(string.find(text, "speed must be a finite number (got nan)", 1, true) ~= nil, text)
	t.ok(string.find(
		errorText(function()
			Check.assertFinite("1")
		end),
		"value must be a finite number",
		1,
		true
	) ~= nil)
end)

test("Check.copy is deep, keeps shared references and cycles", function(t)
	local shared = { n = 1 }
	local source: any = { a = shared, b = shared, list = { 1, 2, { 3 } } }
	source.self = source
	local copy = Check.copy(source)
	t.ok(copy ~= source and copy.a ~= shared, "new tables")
	t.ok(copy.a == copy.b, "shared reference stays shared")
	t.ok(copy.self == copy, "cycle preserved")
	copy.list[3][1] = 99
	t.eq(source.list[3][1], 3, "source untouched")
	t.eq(Check.copy(5), 5)
	t.eq(Check.copy("x"), "x")
end)

test("Check.freeze freezes every nested table, handles cycles and frozen children", function(t)
	local inner = table.freeze({ 1 })
	local value: any = { a = { b = { c = 1 } }, inner = inner }
	value.loop = value
	local result = Check.freeze(value)
	t.ok(result == value, "returns the same table")
	t.ok(table.isfrozen(value) and table.isfrozen(value.a) and table.isfrozen(value.a.b))
	t.throws(function()
		value.a.b.c = 2
	end, "nested write must fail")
	t.eq(Check.freeze(7), 7)
end)

-- ---------------------------------------------------------------- Json

test("Json.encode is canonical: sorted keys, arrays, scalars", function(t)
	t.eq(Json.encode({ b = 1, a = { 3, 2 }, c = "x" }), '{"a":[3,2],"b":1,"c":"x"}')
	t.eq(Json.encode(true), "true")
	t.eq(Json.encode(nil), "null")
	t.eq(Json.encode({}), "[]")
	t.eq(Json.encode(Json.EMPTY_OBJECT), "{}")
	t.eq(Json.encode({ [1] = "a", [3] = "c" }), '{"1":"a","3":"c"}', "sparse array becomes an object")
	t.eq(Json.encode({ 1, x = 2 }), '{"1":1,"x":2}', "mixed table becomes an object")
end)

test("Json.encode escapes strings and maps non-finite numbers to null", function(t)
	t.eq(Json.encode('a"b\\c\n\t' .. string.char(1)), '"a\\"b\\\\c\\n\\t\\u0001"')
	t.eq(Json.encode({ 0 / 0, math.huge }), "[null,null]")
	t.eq(Json.encode(-3), "-3")
end)

test("Json.encode round-trips floats exactly", function(t)
	for _, value in { 0.1, 1 / 3, 1e-7, 123456.789, 2 ^ 60, -0.5 } do
		local text = Json.encode(value)
		t.eq(tonumber(text), value, text)
		t.eq(serde.decode("json", text), value, "serde reads " .. text)
	end
end)

test("Json.encode refuses cycles, functions and ambiguous keys", function(t)
	local loop: any = {}
	loop.self = loop
	t.ok(string.find(
		errorText(function()
			Json.encode(loop)
		end),
		"cycle at $.self",
		1,
		true
	) ~= nil)
	t.ok(string.find(
		errorText(function()
			Json.encode({ f = print })
		end),
		"cannot encode function at $.f",
		1,
		true
	) ~= nil)
	t.ok(string.find(
		errorText(function()
			Json.encode({ [1] = 1, ["1"] = 2, x = 0 })
		end),
		"duplicate key",
		1,
		true
	) ~= nil)
	t.ok(string.find(
		errorText(function()
			Json.encode({ [true] = 1 })
		end),
		"boolean key",
		1,
		true
	) ~= nil)
end)

test("Json.encode indents when asked and serde reads it back", function(t)
	local value = { b = { 1, 2 }, a = Json.EMPTY_OBJECT }
	local text = Json.encode(value, { indent = "  " })
	t.eq(text, '{\n  "a": {},\n  "b": [\n    1,\n    2\n  ]\n}')
	t.eq(serde.decode("json", text).b[2], 2)
end)

-- ---------------------------------------------------------------- Env

test("Env.new lists every missing required part", function(t)
	local text = errorText(function()
		Env.new({})
	end)
	t.ok(string.find(text, "missing clock, defer, wait", 1, true) ~= nil, text)
	t.throws(function()
		Env.new({ clock = 1, defer = function() end, wait = function() end })
	end, "clock must be a function")
end)

test("Env.new fills spawn, services, rng and report defaults", function(t)
	local env = Env.new({
		clock = function()
			return 0
		end,
		defer = function() end,
		wait = function()
			return 0
		end,
	})
	t.eq(#Env.validate(env), 0)
	t.eq(env.services, {})
	local ran = false
	env.spawn(function()
		ran = true
	end)
	t.ok(ran, "default spawn runs now")
	t.eq(env.rng(5):nextUInt(), Rng.new(5):nextUInt(), "rng is ProcGen/Rng")
	t.throws(function()
		env.rng()
	end, "the default rng needs a seed")
end)

test("Env.validate reports bad shapes", function(t)
	t.eq(Env.validate(5), { "env must be a table" })
	local problems = Env.validate({ services = 1, place = { isStudio = "yes" } })
	t.ok(contains(problems, "env.clock must be a function"))
	t.ok(contains(problems, "env.services must be a table"))
	t.ok(contains(problems, "env.place needs isStudio"))
	t.ok(contains(Env.validate({ place = 3 }), "env.place must be a table"))
end)

test("Env.check refuses everything but an unpublished Studio place", function(t)
	local ok, reason = Env.check({ isStudio = true, gameId = 0, placeId = 0 })
	t.ok(ok and reason == nil)
	local function why(place: any): string?
		return select(2, Env.check(place))
	end
	t.eq(why(nil), "missing_place")
	t.eq(why({ isStudio = true }), "invalid_place")
	t.eq(why({ isStudio = false, gameId = 0, placeId = 0 }), "not_studio")
	t.eq(why({ isStudio = true, gameId = 123, placeId = 0 }), "published_game")
	t.eq(why({ isStudio = true, gameId = 0, placeId = 456 }), "published_place")
end)

test("Env.assertDiagnostic and Env.service raise with the reason", function(t)
	local env = FakeEnv.new({ place = { isStudio = true, gameId = 9, placeId = 9 } })
	local text = errorText(function()
		Env.assertDiagnostic(env, "debug commands")
	end)
	t.ok(string.find(text, "debug commands refused: published_game", 1, true) ~= nil, text)
	Env.assertDiagnostic(FakeEnv.new())
	local fake = { name = "ds" }
	env:register("DataStoreService", fake)
	t.ok(Env.service(env, "DataStoreService") == fake)
	t.ok(string.find(
		errorText(function()
			Env.service(env, "MemoryStoreService")
		end),
		"env.services.MemoryStoreService is missing",
		1,
		true
	) ~= nil)
end)

local function fakeGlobals(log: { string })
	local runService = {
		IsStudio = function()
			return true
		end,
		IsServer = function()
			return true
		end,
		IsClient = function()
			return false
		end,
	}
	local lookups = 0
	local game = {
		GameId = 0,
		PlaceId = 0,
		GetService = function(_self: any, name: string): any
			lookups += 1
			if name == "RunService" then
				return runService
			elseif name == "Players" then
				return { name = "Players" }
			end
			error("not a service: " .. name)
		end,
	}
	local task = {
		defer = function(_fn: any, ...: any)
			table.insert(log, "defer")
		end,
		spawn = function(fn: any, ...: any)
			table.insert(log, "spawn")
			fn(...)
		end,
		wait = function(seconds: number?): number
			table.insert(log, "wait " .. tostring(seconds))
			return seconds or 0
		end,
	}
	local Random = {
		new = function()
			return {
				NextInteger = function(_self: any, low: number, _high: number): number
					table.insert(log, "entropy")
					return low + 41
				end,
			}
		end,
	}
	return {
		game = game,
		task = task,
		time = function()
			return 12.5
		end,
		Random = Random,
		warn = function(message: string)
			table.insert(log, "warn " .. message)
		end,
	}, function()
		return lookups
	end
end

test("EnvRoblox.fromGlobals maps the Roblox globals onto a valid Env", function(t)
	local log = {}
	local globals, lookups = fakeGlobals(log)
	local env = EnvRoblox.fromGlobals(globals :: any)
	t.eq(#Env.validate(env), 0)
	t.eq(env.clock(), 12.5)
	env.defer(function() end)
	env.spawn(function() end)
	t.eq(env.wait(0.25), 0.25)
	t.eq(log, { "defer", "spawn", "wait 0.25" })
	t.eq(env.place, { isStudio = true, gameId = 0, placeId = 0, isServer = true, isClient = false })
	t.ok(Env.check(env.place))
	local before = lookups()
	t.eq(env.services.Players.name, "Players")
	t.eq(env.services.Players.name, "Players")
	t.eq(lookups() - before, 1, "services are cached")
	t.eq(env.services.NotAService, nil)
	t.eq(env.rng(3):nextUInt(), Rng.new(3):nextUInt())
	t.eq(env.rng():nextUInt(), Rng.new(42):nextUInt(), "unseeded rng draws from Random")
	env.report("hello")
	t.eq(log[#log], "warn hello")
	local overridden = EnvRoblox.fromGlobals(globals :: any, {
		clock = function()
			return 1
		end,
	})
	t.eq(overridden.clock(), 1)
end)

test("Env.studio forwards to EnvRoblox, which needs the Roblox globals (not in Lune)", function(t)
	t.throws(function()
		Env.studio()
	end, "no game global in Lune")
end)

-- ---------------------------------------------------------------- Signal

test("Signal fires handlers in connection order with arguments", function(t)
	local signal = Signal.new()
	local seen = {}
	signal:Connect(function(a, b)
		table.insert(seen, "first " .. a .. b)
	end)
	signal:Connect(function(a)
		table.insert(seen, "second " .. a)
	end)
	signal:Fire("x", "y")
	t.eq(seen, { "first xy", "second x" })
end)

test("Signal Once fires once; Disconnect stops a handler", function(t)
	local signal = Signal.new()
	local once, plain = 0, 0
	local connection = signal:Once(function()
		once += 1
	end)
	local other = signal:Connect(function()
		plain += 1
	end)
	signal:Fire()
	signal:Fire()
	t.eq(once, 1)
	t.ok(not connection.Connected)
	other:Disconnect()
	other:Disconnect()
	signal:Fire()
	t.eq(plain, 2)
end)

test("Signal skips handlers disconnected earlier in the same Fire and defers new ones", function(t)
	local signal = Signal.new()
	local seen = {}
	local second
	signal:Connect(function()
		table.insert(seen, "a")
		second:Disconnect()
		signal:Connect(function()
			table.insert(seen, "late")
		end)
	end)
	second = signal:Connect(function()
		table.insert(seen, "b")
	end)
	signal:Fire()
	t.eq(seen, { "a" })
	signal:Fire()
	t.eq(seen, { "a", "a", "late" })
end)

test("Signal isolates handler errors and yields", function(t)
	local reports = {}
	local signal = Signal.new({
		report = function(message: string)
			table.insert(reports, message)
		end,
	})
	local seen = {}
	signal:Connect(function()
		error("boom")
	end)
	signal:Connect(function()
		table.insert(seen, "before yield")
		coroutine.yield()
		table.insert(seen, "never")
	end)
	signal:Connect(function()
		table.insert(seen, "last")
	end)
	signal:Fire()
	t.eq(seen, { "before yield", "last" })
	t.eq(#reports, 1)
	t.ok(string.find(reports[1], "boom", 1, true) ~= nil)
end)

test("Signal with FakeEnv routes handler errors to env.errors", function(t)
	local env = FakeEnv.new()
	local signal = Signal.new(env)
	local ran = false
	signal:Connect(function()
		error("bad handler")
	end)
	signal:Connect(function()
		ran = true
	end)
	signal:Fire()
	t.ok(ran)
	t.eq(#env.errors, 1)
end)

test("Signal Wait resumes with the Fire arguments", function(t)
	local signal = Signal.new()
	local got
	local thread = coroutine.create(function()
		got = { signal:Wait() }
	end)
	coroutine.resume(thread)
	t.eq(coroutine.status(thread), "suspended")
	signal:Fire(1, "two")
	t.eq(got, { 1, "two" })
	t.eq(coroutine.status(thread), "dead")
	t.throws(function()
		signal:Connect(5 :: any)
	end, "Connect needs a function")
end)

test("Signal FireDeferred waits for env.defer and snapshots handlers", function(t)
	t.throws(function()
		Signal.new():FireDeferred()
	end, "FireDeferred without env.defer")
	local env = FakeEnv.new()
	local signal = Signal.new(env)
	local seen = {}
	local dropped = signal:Connect(function(v)
		table.insert(seen, "dropped " .. v)
	end)
	signal:Once(function(v)
		table.insert(seen, "once " .. v)
	end)
	signal:Connect(function(v)
		table.insert(seen, "kept " .. v)
	end)
	signal:FireDeferred(1)
	signal:FireDeferred(2)
	signal:Connect(function(v)
		table.insert(seen, "late " .. v)
	end)
	dropped:Disconnect()
	t.eq(seen, {}, "nothing runs before flush")
	t.eq(env:flush(), 2)
	t.eq(seen, { "once 1", "kept 1", "kept 2" })
end)

test("Signal DisconnectAll and Destroy release every handler", function(t)
	local signal = Signal.new()
	local count = 0
	local a = signal:Connect(function()
		count += 1
	end)
	signal:Connect(function()
		count += 1
	end)
	signal:DisconnectAll()
	t.ok(not a.Connected)
	t.eq(#(signal :: any)._handlers, 0, "no handler kept")
	signal:Fire()
	t.eq(count, 0)
	signal:Connect(function()
		count += 1
	end)
	signal:Destroy()
	signal:Fire()
	t.eq(count, 0)
	t.throws(function()
		signal:Connect(function() end)
	end, "Connect after Destroy")
end)

-- ---------------------------------------------------------------- Scope

test("Scope cleans in LIFO order and stays reusable", function(t)
	local scope = Scope.new()
	local order = {}
	for index = 1, 3 do
		scope:Add(function()
			table.insert(order, index)
		end)
	end
	scope:Clean()
	t.eq(order, { 3, 2, 1 })
	scope:Add(function()
		table.insert(order, 4)
	end)
	scope:Clean()
	t.eq(order, { 3, 2, 1, 4 })
end)

test("Scope finds Destroy/Disconnect, honours a method name and closes threads", function(t)
	local log = {}
	local scope = Scope.new()
	scope:Add({
		Destroy = function()
			table.insert(log, "destroy")
		end,
	})
	scope:Add({
		Disconnect = function()
			table.insert(log, "disconnect")
		end,
	})
	scope:Add({
		Stop = function()
			table.insert(log, "stop")
		end,
	}, "Stop")
	local thread = coroutine.create(function()
		coroutine.yield()
	end)
	coroutine.resume(thread)
	scope:Add(thread)
	local signal = Signal.new()
	local fired = 0
	local connection = scope:Connect(signal, function()
		fired += 1
	end)
	scope:Clean()
	t.eq(log, { "stop", "disconnect", "destroy" })
	t.eq(coroutine.status(thread), "dead")
	t.ok(not connection.Connected)
	signal:Fire()
	t.eq(fired, 0)
end)

test("Scope refuses what it cannot clean", function(t)
	local scope = Scope.new()
	t.throws(function()
		scope:Add({ nothing = true })
	end, "table without a cleanup method")
	t.throws(function()
		scope:Add(nil :: any)
	end, "nil")
	t.throws(function()
		scope:Add(5 :: any)
	end, "number without a method")
end)

test("Scope keeps cleaning after an error and refuses re-entry while cleaning", function(t)
	local env = FakeEnv.new()
	local scope = Scope.new(env)
	local log = {}
	scope:Add(function()
		table.insert(log, "first")
	end)
	scope:Add(function()
		scope:Add(function() end)
	end)
	scope:Add(function()
		scope:Clean()
	end)
	scope:Add(function()
		error("cleanup failed")
	end)
	scope:Clean()
	t.eq(log, { "first" })
	t.eq(#env.reports, 3)
	t.ok(contains(env.reports, "cleanup failed"))
	t.ok(contains(env.reports, "while the scope is cleaning"))
end)

test("Scope Extend children die with the parent; Destroy is final", function(t)
	local parent = Scope.new()
	local child = parent:Extend()
	local log = {}
	child:Add(function()
		table.insert(log, "child")
	end)
	parent:Add(function()
		table.insert(log, "parent")
	end)
	parent:Clean()
	t.eq(log, { "parent", "child" })
	t.throws(function()
		child:Add(function() end)
	end, "child destroyed with the parent clean")
	parent:Destroy()
	parent:Destroy()
	t.throws(function()
		parent:Add(function() end)
	end, "Add after Destroy")
end)

test("Scope Remove cleans one object now", function(t)
	local scope = Scope.new()
	local log = {}
	local a = function()
		table.insert(log, "a")
	end
	scope:Add(a)
	scope:Add(function()
		table.insert(log, "b")
	end)
	t.ok(scope:Remove(a))
	t.ok(not scope:Remove(a), "already removed")
	t.eq(log, { "a" })
	scope:Clean()
	t.eq(log, { "a", "b" })
end)

-- ---------------------------------------------------------------- Fsm

local function roundDef(): any
	return {
		name = "round",
		initial = "lobby",
		states = { lobby = {}, active = {}, results = {}, closed = { terminal = true } },
		transitions = {
			{ from = "lobby", event = "start", to = "active" },
			{ from = "active", event = "finish", to = "results" },
			{ from = "results", event = "reset", to = "lobby" },
			{ from = "*", event = "close", to = "closed" },
		},
	}
end

test("Fsm.validate accepts a sound definition", function(t)
	t.eq(Fsm.validate(roundDef()), {})
end)

test("Fsm.validate names unknown, unreachable, dead-end and shadowed states", function(t)
	local function problems(mutate: (def: any) -> ()): { string }
		local def = roundDef()
		mutate(def)
		return Fsm.validate(def)
	end
	t.ok(contains(
		problems(function(d)
			d.initial = "nope"
		end),
		'initial "nope" is not a state'
	))
	t.ok(contains(
		problems(function(d)
			table.insert(d.transitions, { from = "ghost", event = "go", to = "lobby" })
		end),
		'from "ghost" is not a state'
	))
	t.ok(contains(
		problems(function(d)
			table.insert(d.transitions, { from = "lobby", event = "Bad", to = "lobby" })
		end),
		'event "Bad" is not a label'
	))
	t.ok(contains(
		problems(function(d)
			d.states.orphan = { terminal = true }
		end),
		"state orphan is unreachable"
	))
	t.ok(contains(
		problems(function(d)
			d.transitions[4] = nil
			d.transitions[3] = nil
		end),
		"state results is a dead end"
	))
	t.ok(contains(
		problems(function(d)
			table.insert(d.transitions, { from = "closed", event = "reopen", to = "lobby" })
		end),
		"terminal state closed has a transition"
	))
	t.ok(contains(
		problems(function(d)
			table.insert(d.transitions, { from = "lobby", event = "start", to = "results" })
		end),
		"shadowed by unguarded transition 1"
	))
	t.ok(contains(
		problems(function(d)
			table.insert(d.transitions, { from = "lobby", event = "go", to = "lobby", guard = 3 })
		end),
		"guard must be a function"
	))
	t.eq(Fsm.validate({ initial = "a", states = {}, transitions = {} }), {
		"states must be a non-empty map of name -> { terminal? }",
	})
	t.eq(Fsm.validate(nil), { "definition must be a table" })
end)

test("Fsm.define raises with the problems and freezes the spec", function(t)
	local def = roundDef()
	def.initial = "nope"
	t.ok(string.find(
		errorText(function()
			Fsm.define(def)
		end),
		"Fsm.define: initial",
		1,
		true
	) ~= nil)
	local spec = Fsm.define(roundDef())
	t.ok(table.isfrozen(spec) and table.isfrozen(spec.transitions))
	t.eq(spec.transitions[#spec.transitions].from, "*", "wildcards are tried last")
	t.throws(function()
		Fsm.new(roundDef() :: any)
	end, "Fsm.new needs a defined spec")
end)

test("Fsm send runs hooks in order and fires changed", function(t)
	local log = {}
	local spec = Fsm.define(roundDef())
	local machine = Fsm.new(spec, {
		onEnter = function(state, _ctx, from)
			table.insert(log, "enter " .. state .. " from " .. tostring(from))
		end,
		onExit = function(state, _ctx, to)
			table.insert(log, "exit " .. state .. " to " .. to)
		end,
		onTransition = function(from, to, event)
			table.insert(log, from .. ">" .. to .. " on " .. event)
		end,
	})
	local changes = {}
	machine.changed:Connect(function(from, to, event)
		table.insert(changes, { from, to, event })
	end)
	t.eq({ machine:send("start") }, { true, nil })
	t.eq(machine:state(), "active")
	t.eq(log, {
		"enter lobby from nil",
		"exit lobby to active",
		"lobby>active on start",
		"enter active from lobby",
	})
	t.eq(changes, { { "lobby", "active", "start" } })
end)

test("Fsm send reports unknown events, missing transitions and guard rejections", function(t)
	local def = roundDef()
	local allow = false
	def.transitions[1].guard = function(ctx)
		return allow and ctx.players >= 2
	end
	local machine = Fsm.new(Fsm.define(def))
	t.eq({ machine:send("teleport") }, { false, "unknown_event" })
	t.eq({ machine:send("finish") }, { false, "no_transition" })
	t.eq({ machine:send("start", { players = 5 }) }, { false, "guard_rejected" })
	t.ok(not machine:can("start", { players = 5 }))
	allow = true
	t.ok(machine:can("start", { players = 2 }))
	t.eq(machine:state(), "lobby", "can() does not transition")
	t.ok(machine:send("start", { players = 2 }))
end)

test("Fsm wildcard transitions leave any non-terminal state but not a terminal one", function(t)
	local spec = Fsm.define(roundDef())
	local machine = Fsm.new(spec)
	machine:send("start")
	t.ok(machine:send("close"))
	t.eq(machine:state(), "closed")
	t.eq({ machine:send("close") }, { false, "no_transition" })
end)

test("Fsm specific transitions win over wildcards", function(t)
	local def = roundDef()
	def.states.aborted = { terminal = true }
	table.insert(def.transitions, { from = "*", event = "abort", to = "closed" })
	table.insert(def.transitions, 1, { from = "active", event = "abort", to = "aborted" })
	local machine = Fsm.new(Fsm.define(def))
	machine:send("start")
	machine:send("abort")
	t.eq(machine:state(), "aborted")
end)

test("Fsm queues sends from hooks, bounded at 32", function(t)
	local spec = Fsm.define({
		initial = "a",
		states = { a = {}, b = {} },
		transitions = { { from = "a", event = "flip", to = "b" }, { from = "b", event = "flip", to = "a" } },
	})
	local results = {}
	local machine
	local burst = 0
	machine = Fsm.new(spec, {
		onEnter = function(state, ctx)
			if ctx and ctx.burst and burst == 0 then
				burst = 1
				for _ = 1, Fsm.QUEUE_LIMIT + 1 do
					table.insert(results, select(2, machine:send("flip")))
				end
			end
		end,
	})
	t.ok(machine:send("flip", { burst = true }))
	t.eq(results[1], "queued")
	t.eq(results[Fsm.QUEUE_LIMIT], "queued")
	t.eq(results[Fsm.QUEUE_LIMIT + 1], "queue_full")
	-- 1 direct flip + 32 queued flips = 33 flips from a: ends in b.
	t.eq(machine:state(), "b")
	t.eq(machine:pending(), 0)
end)

test("Fsm hook errors propagate and leave the machine usable", function(t)
	local fail = true
	local machine = Fsm.new(Fsm.define(roundDef()), {
		onEnter = function(state)
			if state == "active" and fail then
				error("hook broke")
			end
		end,
	})
	t.ok(string.find(
		errorText(function()
			machine:send("start")
		end),
		"hook broke",
		1,
		true
	) ~= nil)
	fail = false
	t.eq(machine:state(), "active", "the state changed before the failing hook")
	t.ok(machine:send("finish"), "not stuck busy")
end)

test("Fsm serialize and restore round-trip and refuse foreign text", function(t)
	local spec = Fsm.define(roundDef())
	local machine = Fsm.new(spec)
	machine:send("start")
	local text = machine:serialize()
	t.eq(text, "fsm/1:round:active")
	local entered = false
	local restored = Fsm.restore(spec, text, {
		onEnter = function()
			entered = true
		end,
	})
	t.ok(restored ~= nil and restored:state() == "active")
	t.ok(not entered, "restore does not run onEnter")
	t.eq({ Fsm.restore(spec, "fsm/1:other:active") }, { nil, "wrong_spec" })
	t.eq({ Fsm.restore(spec, "fsm/1:round:ghost") }, { nil, "unknown_state" })
	t.eq({ Fsm.restore(spec, "fsm/2:round:active") }, { nil, "bad_format" })
	t.eq({ Fsm.restore(spec, "round") }, { nil, "bad_format" })
	t.eq({ Fsm.restore(spec, 42) }, { nil, "bad_format" })
	local anon = Fsm.define({ initial = "a", states = { a = { terminal = true } }, transitions = {} })
	t.eq(Fsm.new(anon):serialize(), "fsm/1:fsm:a")
end)

-- ---------------------------------------------------------------- Retry

test("Retry.validate rejects bad options", function(t)
	local problems =
		Retry.validate({ attempts = 0, base = -1, factor = 0.5, maxDelay = 0 / 0, jitter = "some" :: any })
	t.eq(#problems, 5)
	t.eq(Retry.validate(nil), {})
	t.throws(function()
		Retry.delays({ attempts = 1.5 })
	end)
end)

test("Retry delays grow exponentially, cap, and jitter deterministically", function(t)
	t.eq(
		Retry.delays({ attempts = 6, base = 1, factor = 2, maxDelay = 10, jitter = "none" }),
		{ 1, 2, 4, 8, 10 }
	)
	local a = Retry.delays({ attempts = 5, rng = Rng.new(9) })
	local b = Retry.delays({ attempts = 5, rng = Rng.new(9) })
	t.eq(a, b, "same seed, same delays")
	local raw = { 0.5, 1, 2, 4 }
	for index, delay in a do
		t.ok(delay >= 0 and delay <= raw[index], "full jitter in [0, d]")
	end
	for index, delay in Retry.delays({ attempts = 5, jitter = "equal", rng = Rng.new(1) }) do
		t.ok(delay >= raw[index] / 2 and delay <= raw[index], "equal jitter in [d/2, d]")
	end
	t.ok(string.find(
		errorText(function()
			Retry.delay(1, { jitter = "full" })
		end),
		"needs an rng",
		1,
		true
	) ~= nil)
	t.throws(function()
		Retry.delay(0, { jitter = "none" })
	end, "attempt must be >= 1")
end)

test("Retry.classify sorts DataStore-style errors", function(t)
	t.eq(Retry.classify("301: GetAsync request dropped. Request was throttled"), "throttle")
	t.eq(Retry.classify("306: request dropped, queue full"), "throttle")
	t.eq(Retry.classify("502: API Services rejected request"), "transient")
	t.eq(Retry.classify("104: Value too large"), "fatal")
	t.eq(Retry.classify("403"), "fatal")
	t.eq(Retry.classify("HTTP timeout"), "transient")
	t.eq(Retry.classify("ServerScriptService.Data:123: oops"), "transient")
end)

test("Retry.run retries until success and waits the computed delays", function(t)
	local waits = {}
	local calls = 0
	local ok, result, attempts = Retry.run(function(attempt)
		calls += 1
		if attempt < 3 then
			error("502: busy", 0)
		end
		return "saved"
	end, {
		jitter = "none",
		wait = function(seconds)
			table.insert(waits, seconds)
		end,
	})
	t.eq({ ok, result, attempts, calls }, { true, "saved", 3, 3 })
	t.eq(waits, { 0.5, 1 })
end)

test("Retry.run stops on a fatal error and after the last attempt", function(t)
	local calls = 0
	local ok, err, attempts = Retry.run(function()
		calls += 1
		error("101: Key name can't be empty", 0)
	end, { jitter = "none", wait = function() end })
	t.eq({ ok, attempts, calls }, { false, 1, 1 })
	t.ok(string.find(err, "101", 1, true) ~= nil)
	local retries = {}
	ok, err, attempts = Retry.run(function()
		error("throttled", 0)
	end, {
		attempts = 3,
		jitter = "none",
		wait = function() end,
		onRetry = function(_err, attempt, delay)
			table.insert(retries, { attempt, delay })
		end,
	})
	t.eq({ ok, err, attempts }, { false, "throttled", 3 })
	t.eq(retries, { { 1, 0.5 }, { 2, 1 } })
	t.ok(string.find(
		errorText(function()
			Retry.run(function()
				error("transient", 0)
			end, { jitter = "none" })
		end),
		"needs opts.wait or env.wait",
		1,
		true
	) ~= nil)
end)

test("Retry.run backs off on env.wait and draws jitter from env.rng", function(t)
	local env = FakeEnv.new({ seed = "retry" })
	local outcome
	env.spawn(function()
		outcome = {
			Retry.run(function(attempt)
				if attempt < 3 then
					error("busy", 0)
				end
				return env.clock()
			end, nil, env),
		}
	end)
	t.eq(outcome, nil, "parked on env.wait")
	env:advance(60)
	t.ok(outcome ~= nil and outcome[1] == true and outcome[3] == 3, "succeeded on the third try")
	local expected = Retry.delays({ attempts = 3, rng = Rng.new("retry:1") })
	t.near(outcome[2], expected[1] + expected[2], 1e-9, "clock advanced by the two delays")
	t.eq(#env.errors, 0)
end)

test("Retry.dataStore preset is valid", function(t)
	t.eq(Retry.validate(Retry.dataStore(Rng.new(1))), {})
end)

-- ---------------------------------------------------------------- Events (kit-event/1)

local function sampleEvents(): { any }
	return {
		Events.custom("load_finished", 4.5, { build = "b1" }),
		Events.economy("wallet_credit", {
			flow = "source",
			currency = "currency_a",
			amount = 10,
			balance = 25,
			transaction_type = "Gameplay",
			sku = "quest_reward",
		}),
		Events.progression(
			"level_change",
			{ path = "main", status = "complete", level = 3, level_name = "Level 3" }
		),
		Events.funnel(
			"shop_flow",
			{ funnel = "shop", step = 2, step_name = "item_selected", funnel_session_id = "fs-1" }
		),
		Events.onboarding("tutorial", { step = 1, step_name = "moved" }),
		Events.purchaseIntent("offer", { stage = "offer_viewed", product = "pack_a", kind = "devproduct" }),
	}
end

test("Events builders produce valid kit-event/1 records for every category", function(t)
	local seen = {}
	for _, event in sampleEvents() do
		t.eq(Events.validate(event), {}, event.category)
		seen[event.category] = true
	end
	for _, category in Events.CATEGORIES do
		t.ok(seen[category], category)
	end
end)

test("Events.validate rejects bad envelopes", function(t)
	local function problems(mutate: (e: any) -> ()): { string }
		local event: any = Events.custom("ok_name")
		mutate(event)
		return Events.validate(event)
	end
	t.ok(contains(
		problems(function(e)
			e.schema = "kit-event/2"
		end),
		"schema must be kit-event/1"
	))
	t.ok(contains(
		problems(function(e)
			e.category = "journey"
		end),
		'category "journey"'
	))
	t.ok(contains(
		problems(function(e)
			e.name = "BadName"
		end),
		"is not a lower_snake label"
	))
	t.ok(contains(
		problems(function(e)
			e.name = string.rep("a", 65)
		end),
		"is not a lower_snake label"
	))
	t.ok(contains(
		problems(function(e)
			e.t = -1
		end),
		"t must be"
	))
	t.ok(contains(
		problems(function(e)
			e.timestamp = "2026-10-06 12:00"
		end),
		"timestamp must be UTC"
	))
	t.eq(
		problems(function(e)
			e.timestamp = "2026-10-06T12:00:00.250Z"
		end),
		{}
	)
	t.ok(contains(
		problems(function(e)
			e.player = "Some User"
		end),
		"player must be"
	))
	t.ok(contains(
		problems(function(e)
			e.environment = "production"
		end),
		"environment must be"
	))
	t.ok(contains(
		problems(function(e)
			e.synthetic = "yes"
		end),
		"synthetic must be a boolean"
	))
	t.ok(contains(
		problems(function(e)
			e.value = 0 / 0
		end),
		"value must be a finite number"
	))
	t.ok(contains(
		problems(function(e)
			e.extra = 1
		end),
		'unexpected key "extra"'
	))
	t.ok(contains(
		problems(function(e)
			e.economy = {}
		end),
		'unexpected key "economy" for category custom'
	))
	t.eq(Events.validate("x"), { "event must be a table" })
end)

test("Events.validate enforces the custom-field limits", function(t)
	local function fields(map: any): { string }
		return Events.validate(Events.custom("ok_name", nil, map))
	end
	t.eq(fields({ a = "1", b = "2", c = "3" }), {})
	t.ok(contains(fields({ a = "1", b = "2", c = "3", d = "4" }), "fields has 4 entries (at most 3)"))
	t.ok(contains(fields({ a = "x,y" }), "field a must be a string"))
	t.ok(contains(fields({ a = string.rep("x", 65) }), "field a must be a string"))
	t.ok(contains(fields({ a = 5 }), "field a must be a string"))
	t.ok(contains(fields({ Bad = "1" }), 'field name "Bad"'))
end)

test("Events.validate checks every category body", function(t)
	local function economy(mutate: (b: any) -> ()): { string }
		local body: any =
			{ flow = "sink", currency = "currency_a", amount = 5, balance = 0, transaction_type = "Shop" }
		mutate(body)
		return Events.validate(Events.economy("spend", body))
	end
	t.eq(economy(function() end), {})
	t.ok(contains(
		economy(function(b)
			b.flow = "in"
		end),
		"economy.flow"
	))
	t.ok(contains(
		economy(function(b)
			b.amount = 0
		end),
		"economy.amount"
	))
	t.ok(contains(
		economy(function(b)
			b.amount = math.huge
		end),
		"economy.amount"
	))
	t.ok(contains(
		economy(function(b)
			b.balance = -1
		end),
		"economy.balance"
	))
	t.ok(contains(
		economy(function(b)
			b.currency = "Gold Coins"
		end),
		"economy.currency"
	))
	t.eq(
		economy(function(b)
			b.transaction_type = "crafting_fee"
		end),
		{}
	)
	t.ok(contains(
		economy(function(b)
			b.transaction_type = "Bad Type"
		end),
		"economy.transaction_type"
	))
	t.ok(contains(
		economy(function(b)
			b.sku = "has space"
		end),
		"economy.sku"
	))
	t.ok(contains(
		economy(function(b)
			b.price = 5
		end),
		'economy: unexpected key "price"'
	))
	t.ok(
		contains(
			Events.validate({ schema = "kit-event/1", category = "economy", name = "x" }),
			"need a economy table"
		)
	)
	t.ok(
		contains(
			Events.validate(Events.progression("p", { path = "main", status = "done" :: any, level = 1.5 })),
			"progression.status"
		)
	)
	t.ok(
		contains(
			Events.validate(Events.progression("p", { path = "main", status = "start", level = 1.5 })),
			"progression.level"
		)
	)
	t.ok(
		contains(
			Events.validate(
				Events.funnel("f", { funnel = "shop", step = 0, step_name = "a", funnel_session_id = "s" })
			),
			"funnel.step"
		)
	)
	t.ok(
		contains(
			Events.validate(
				Events.funnel("f", { funnel = "shop", step = 101, step_name = "a", funnel_session_id = "s" })
			),
			"funnel.step"
		)
	)
	t.ok(
		contains(
			Events.validate(
				Events.funnel("f", { funnel = "shop", step = 1, step_name = "a", funnel_session_id = "" })
			),
			"funnel_session_id"
		)
	)
	t.ok(contains(Events.validate(Events.onboarding("o", { step = 1 } :: any)), "onboarding.step_name"))
	t.ok(
		contains(
			Events.validate(
				Events.purchaseIntent(
					"p",
					{ stage = "bought" :: any, product = "pack_a", kind = "devproduct" }
				)
			),
			"purchase.stage"
		)
	)
	t.ok(
		contains(
			Events.validate(
				Events.purchaseIntent("p", { stage = "prompted", product = "pack_a", kind = "pass" :: any })
			),
			"purchase.kind"
		)
	)
end)

test("Events.stamp fills only missing envelope fields; encode is canonical", function(t)
	local event: any = Events.custom("ping", 1)
	event.player = "1"
	local stamped =
		Events.stamp(event, { player = "2", session_id = "s1", synthetic = true, environment = "lune" })
	t.eq(stamped.player, "1")
	t.eq(stamped.session_id, "s1")
	t.eq(event.session_id, nil, "the source event is not changed")
	t.eq(
		Events.encode(stamped),
		'{"category":"custom","environment":"lune","name":"ping","player":"1","schema":"kit-event/1","session_id":"s1","synthetic":true,"value":1}'
	)
end)

test("Events.recorder validates, stamps and records", function(t)
	local now = 3
	local recorder = Events.recorder({
		clock = function()
			return now
		end,
		envelope = { synthetic = true, environment = "lune" },
	})
	for _, event in sampleEvents() do
		t.eq({ recorder:emit(event) }, { true, nil })
	end
	t.eq(recorder:count(), 6)
	t.eq(recorder:count("economy"), 1)
	t.eq(#recorder:named("offer"), 1)
	t.eq(recorder.events[1].t, 3)
	t.eq(recorder.events[1].synthetic, true)
	local lines = recorder:lines()
	t.eq(#lines, 6)
	t.eq(serde.decode("json", lines[2]).economy.amount, 10)
	t.ok(string.find(
		errorText(function()
			recorder:emit(Events.custom("Bad"))
		end),
		"kit-event/1:",
		1,
		true
	) ~= nil, "strict raises")
	recorder:clear()
	t.eq(recorder:count(), 0)
	local lenient = Events.recorder({ strict = false })
	local ok, reason = lenient:emit(Events.custom("Bad"))
	t.ok(not ok and reason ~= nil)
	t.eq(#lenient.rejected, 1)
	t.eq({ lenient:emit(5 :: any) }, { false, "event must be a table" })
end)

test("Events.null drops and counts", function(t)
	local sink = Events.null()
	t.eq({ sink:emit(Events.custom("anything")) }, { true, nil })
	t.eq(sink.dropped, 1)
end)

-- ---------------------------------------------------------------- Settings (settings/1)

test("Settings.defaults is a complete, valid settings/1 table", function(t)
	local values = Settings.defaults()
	t.eq(Settings.validate(values), {})
	t.eq(values.schema, "settings/1")
	t.eq(values.version, 1)
	for _, bus in Settings.BUSES do
		t.eq(values.volume[bus], 1, bus)
	end
	for _, name in
		{
			"reducedMotion",
			"screenShake",
			"reduceFlashing",
			"haptics",
			"uiScale",
			"colorblindMode",
			"cameraSensitivity",
			"invertY",
			"subtitles",
			"language",
		}
	do
		t.ok(values[name] ~= nil, name)
	end
	for _, field in Settings.FIELDS do
		t.eq(field.labelKey, "settings." .. field.path)
	end
end)

test("Settings.validate names missing, wrong, out-of-range and unknown values", function(t)
	local values = Settings.defaults()
	values.volume.music = 2
	values.uiScale = 0 / 0
	values.colorblindMode = "sepia"
	values.language = "English"
	values.invertY = "no"
	values.volume.extra = 1
	values.cheat = true
	values.subtitles = nil
	values.version = 0
	local problems = Settings.validate(values)
	for _, needle in
		{
			"volume.music: 2 is not a valid number",
			"uiScale: nan",
			'colorblindMode: "sepia"',
			'language: "English"',
			'invertY: "no"',
			"volume.extra: unknown setting",
			"cheat: unknown setting",
			"subtitles: missing",
			"version must be",
		}
	do
		t.ok(contains(problems, needle), needle)
	end
	t.eq(Settings.validate(nil), { "settings must be a table" })
	values = Settings.defaults()
	values.volume = 1
	t.ok(contains(Settings.validate(values), "volume.master: missing"))
end)

test("Settings.sanitize clamps, defaults and drops with notes", function(t)
	local values, notes = Settings.sanitize({
		volume = { master = 1.5, music = -1, sfx = 0 / 0, ui = 0.25 },
		uiScale = 9,
		language = "pt-br",
		colorblindMode = "sepia",
		mystery = 1,
	})
	t.eq(Settings.validate(values), {})
	t.eq(values.volume.master, 1)
	t.eq(values.volume.music, 0)
	t.eq(values.volume.sfx, 1)
	t.eq(values.volume.ui, 0.25)
	t.eq(values.uiScale, 1.5)
	t.eq(values.language, "pt-br")
	t.eq(values.colorblindMode, "none")
	t.ok(contains(notes, "volume.master: clamped 1.5 to 1"))
	t.ok(contains(notes, "volume.sfx: nan is invalid"))
	t.ok(contains(notes, "mystery: unknown setting dropped"))
	local fallback, why = Settings.sanitize("junk")
	t.eq(fallback, Settings.defaults())
	t.eq(why, { "not a table: defaults used" })
end)

test("Settings.merge applies a partial patch without touching the base", function(t)
	local base = Settings.defaults()
	local merged, notes =
		Settings.merge(base, { volume = { music = 0.4 }, invertY = true, bogus = 1, uiScale = "big" })
	t.eq(merged.volume.music, 0.4)
	t.eq(merged.invertY, true)
	t.eq(merged.uiScale, 1)
	t.eq(base.volume.music, 1, "base unchanged")
	t.ok(contains(notes, "bogus: unknown setting dropped"))
	t.ok(contains(notes, 'uiScale: "big" is invalid'))
	local same, why = Settings.merge(base, 7)
	t.eq(same, base)
	t.eq(why[1], "patch is not a table: ignored")
	local changed = Settings.set(base, "volume.sfx", 0.5)
	t.eq(Settings.get(changed, "volume.sfx"), 0.5)
	t.eq(Settings.get(changed, "volume.nothing"), nil)
end)

test("Settings.migrate runs the hook per version and notes gaps", function(t)
	local values, notes = Settings.migrate(nil)
	t.eq(values, Settings.defaults())
	t.eq(notes, { "no saved settings: defaults used" })
	t.eq(select(2, Settings.migrate(5)), { "saved settings are not a table: defaults used" })
	local saved = { schema = "settings/1", version = 1, musicVolume = 0.3, shake = 0 }
	local migrated, migrateNotes = Settings.migrate(saved, {
		version = 3,
		migrations = {
			[1] = function(data)
				data.volume = { music = data.musicVolume }
				data.musicVolume = nil
				return data
			end,
		},
	})
	t.eq(migrated.version, 3)
	t.eq(migrated.volume.music, 0.3)
	t.ok(contains(migrateNotes, "no migration from version 2"))
	t.ok(contains(migrateNotes, "shake: unknown setting dropped"))
	t.eq(saved.musicVolume, 0.3, "the saved table is not mutated")
	local _, failed = Settings.migrate({ version = 1 }, {
		version = 2,
		migrations = {
			[1] = function()
				error("bad step")
			end,
		},
	})
	t.ok(contains(failed, "migration 1 failed"))
	local newer, newerNotes = Settings.migrate({ version = 9, invertY = true })
	t.eq(newer.version, 1)
	t.eq(newer.invertY, true)
	t.ok(contains(newerNotes, "saved version 9 is newer than 1"))
end)

test("Settings.effective folds the system reduced-motion flag and bus gains", function(t)
	local values = Settings.defaults()
	values.volume.master = 0.5
	values.volume.music = 0.4
	local plain = Settings.effective(values)
	t.eq(plain.reducedMotion, false)
	t.eq(plain.shakeScale, 1)
	t.eq(plain.volume.master, 0.5)
	t.near(plain.volume.music, 0.2)
	t.eq(plain.language, "en-us")
	t.eq(plain.allowFlashes, true)
	local system =
		Settings.effective(values, { reducedMotion = true, hapticsSupported = false, locale = "de-de" })
	t.eq(system.reducedMotion, true)
	t.eq(system.shakeScale, 0)
	t.eq(system.haptics, false)
	t.eq(system.language, "de-de")
	values.reduceFlashing = true
	values.language = "fr-fr"
	t.eq(Settings.effective(values).allowFlashes, false)
	t.eq(Settings.effective(values).language, "fr-fr")
end)

test("Settings.schema adds game.* fields and refuses bad ones", function(t)
	local schema = Settings.schema({
		{ path = "game.showHints", kind = "boolean", default = true },
		{ path = "game.hudDensity", kind = "enum", default = "normal", choices = { "compact", "normal" } },
	})
	local values = Settings.defaults(schema)
	t.eq(values.game.showHints, true)
	t.eq(Settings.validate(values, schema), {})
	t.ok(contains(Settings.validate(values), "game: unknown setting"), "base schema does not know it")
	t.throws(function()
		Settings.schema({ { path = "showHints", kind = "boolean", default = true } })
	end, "extra fields live under game.")
	t.throws(function()
		Settings.schema({ { path = "game.speed", kind = "number", default = 5, min = 0, max = 1 } })
	end, "default out of range")
	t.throws(function()
		Settings.schema({ { path = "game.a", kind = "text", default = "" } })
	end, "unknown kind")
	t.throws(function()
		Settings.schema({
			{ path = "game.a", kind = "boolean", default = true },
			{ path = "game.a.b", kind = "boolean", default = true },
		})
	end, "a value cannot also be a group")
	t.throws(function()
		Settings.schema({
			{ path = "game.a", kind = "boolean", default = true },
			{ path = "game.a", kind = "boolean", default = false },
		})
	end, "duplicate path")
end)

-- ---------------------------------------------------------------- Catalog (catalog/1)

local function sampleCatalog(): any
	return {
		schema = "catalog/1",
		mode = "setup",
		products = {
			{
				key = "currency_pack_a",
				kind = "devproduct",
				id = 0,
				grants = { { type = "currency", currency = "currency_a", amount = 100 } },
				display = { nameKey = "shop.currency_pack_a.name", iconKey = "icon.currency_pack_a" },
				enabled = false,
				ownershipVerified = false,
				tags = { "featured" },
				order = 2,
			},
			{
				key = "pass_a",
				kind = "gamepass",
				id = 0,
				grants = { { type = "entitlement", entitlement = "perk_a" } },
				display = { nameKey = "shop.pass_a.name" },
				enabled = false,
				ownershipVerified = false,
				order = 1,
			},
			{
				key = "sub_a",
				kind = "subscription",
				id = "EXP-0",
				grants = { { type = "custom", handler = "monthly_bonus", data = { tier = "a", amount = 3 } } },
				display = { nameKey = "shop.sub_a.name", descriptionKey = "shop.sub_a.desc" },
				enabled = false,
				ownershipVerified = false,
				tags = { "featured" },
			},
		},
	}
end

test("Catalog accepts a neutral setup catalog and indexes it", function(t)
	local data = sampleCatalog()
	t.eq(Catalog.validate(data), {})
	local catalog = Catalog.define(data)
	t.ok(table.isfrozen(catalog) and table.isfrozen(catalog.products[1].grants[1]))
	t.eq((Catalog.find(catalog, "pass_a") :: any).kind, "gamepass")
	t.eq(Catalog.find(catalog, "nothing"), nil)
	t.eq(Catalog.byId(catalog, 0), nil, "placeholders never match a receipt")
	local keys = {}
	for _, product in Catalog.list(catalog) do
		table.insert(keys, product.key)
	end
	t.eq(keys, { "sub_a", "pass_a", "currency_pack_a" }, "order then key")
	t.eq(#Catalog.list(catalog, "featured"), 2)
	t.eq(Catalog.normalizeKind("pass"), "gamepass")
	t.eq(Catalog.normalizeKind("developer_product"), "devproduct")
	t.eq(Catalog.normalizeKind("devproduct"), "devproduct")
end)

test("Catalog rejects every price-like field", function(t)
	local data = sampleCatalog()
	data.products[1].price = 99
	data.products[2].PriceInRobux = 50
	data.products[3].grants[1].robuxCost = 5
	local problems = Catalog.validate(data)
	t.ok(contains(problems, "currency_pack_a.price: prices are runtime reads"))
	t.ok(contains(problems, "pass_a.PriceInRobux: prices are runtime reads"))
	t.ok(contains(problems, "sub_a.grants[1].robuxCost: prices are runtime reads"))
	t.ok(string.find(
		errorText(function()
			Catalog.define(data)
		end),
		"Catalog.define:",
		1,
		true
	) ~= nil)
end)

test("Catalog enforces setup and game modes", function(t)
	local data = sampleCatalog()
	data.products[1].enabled = true
	t.ok(contains(Catalog.validate(data), "setup mode keeps every product disabled"))
	data = sampleCatalog()
	data.mode = "game"
	data.products[1].id = 1234
	data.products[1].enabled = true
	local problems = Catalog.validate(data)
	t.ok(contains(problems, "pass_a: game mode needs the real id"))
	t.ok(contains(problems, "currency_pack_a: an enabled product needs ownershipVerified"))
	data.products[1].ownershipVerified = true
	data.products[2].id = 99
	data.products[3].id = "EXP-ab12"
	t.eq(Catalog.validate(data), {})
	local catalog = Catalog.define(data)
	t.eq((Catalog.byId(catalog, 1234) :: any).key, "currency_pack_a")
	t.eq((Catalog.byId(catalog, "EXP-ab12") :: any).key, "sub_a")
	data.mode = "live"
	t.ok(contains(Catalog.validate(data), "mode must be setup or game"))
end)

test("Catalog checks keys, kinds, ids, grants and display", function(t)
	local function problems(mutate: (d: any) -> ()): { string }
		local data = sampleCatalog()
		mutate(data)
		return Catalog.validate(data)
	end
	t.ok(contains(
		problems(function(d)
			d.products[2].key = "currency_pack_a"
		end),
		"duplicate key"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].key = "Pack A"
		end),
		"products[1].key must be a label"
	))
	t.ok(contains(
		problems(function(d)
			d.products[2].kind = "pass"
		end),
		"(legacy pass is gamepass)"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].id = 1.5
		end),
		"id must be an integer > 0 (placeholder 0)"
	))
	t.ok(contains(
		problems(function(d)
			d.products[3].id = 77
		end),
		"id must be an EXP- subscription id"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].id = 5
			d.products[2].id = 5
		end),
		"id also used by currency_pack_a"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].grants = {}
		end),
		"grants must be a non-empty list"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].grants[1] = { type = "random_box" }
		end),
		"grants[1].type must be one of"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].grants[1].amount = 2.5
		end),
		"amount must be an integer > 0"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].grants[1] = { type = "item", item = "item_a", count = 0 }
		end),
		"count must be an integer > 0"
	))
	t.ok(contains(
		problems(function(d)
			d.products[3].grants[1].data = { nested = { 1 } }
		end),
		"data.nested must map a label"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].adReward = true
			d.products[1].grants[1] = { type = "custom", handler = "spin" }
		end),
		"ad-reward products grant fixed"
	))
	t.ok(contains(
		problems(function(d)
			d.products[2].adReward = true
		end),
		"only developer products can be ad rewards"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].display = { name = "Gold" }
		end),
		'display: unexpected key "name"'
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].display.nameKey = "has space"
		end),
		"display.nameKey must be a key"
	))
	t.ok(contains(
		problems(function(d)
			d.products[2].display = {}
		end),
		"display.nameKey is required"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].tags = { "Featured" }
		end),
		"is not a label"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].order = 0.5
		end),
		"order must be an integer"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].enabled = nil
		end),
		"enabled must be a boolean"
	))
	t.ok(contains(
		problems(function(d)
			d.products[1].label = "x"
		end),
		'unexpected key "label"'
	))
	t.ok(contains(
		problems(function(d)
			d.extra = true
		end),
		'unexpected key "extra"'
	))
	t.eq(Catalog.validate({ schema = "catalog/1", mode = "setup" }), { "products must be a list" })
	t.eq(Catalog.validate(nil), { "catalog must be a table" })
end)

-- ---------------------------------------------------------------- Probe

test("Probe.runAll prints one check line per check and exactly one done line", function(t)
	local lines = {}
	local summary = Probe.runAll({
		b_probe = function(ctx)
			ctx.check("two", false, { why = "x" })
		end,
		a_probe = function(ctx)
			ctx.check("one", true)
		end,
	}, {
		emit = function(line)
			table.insert(lines, line)
		end,
	})
	t.eq(#lines, 3)
	t.eq(lines[1], 'ENGINE_CHECK {"check":"one","ok":true,"probe":"a_probe"}')
	t.eq(lines[2], 'ENGINE_CHECK {"check":"two","detail":{"why":"x"},"ok":false,"probe":"b_probe"}')
	local done = serde.decode("json", string.sub(lines[3], #Probe.DONE_PREFIX + 1))
	t.eq(
		done,
		{ probes = { "a_probe", "b_probe" }, checks = 2, passed = 1, failed = 1, errors = 0, ok = false }
	)
	t.eq(summary.failed, 1)
end)

test("Probe records a raising probe, an empty run and odd details", function(t)
	local lines = {}
	local function emit(line)
		table.insert(lines, line)
	end
	local summary = Probe.run("bad_probe", function(ctx)
		ctx.check("before", true, print)
		ctx.kit("GameKit/Check")
	end, { emit = emit })
	t.eq(summary.errors, 1)
	t.eq(summary.ok, false)
	t.ok(string.find(lines[1], '"detail":"function', 1, true) ~= nil, "unencodable detail becomes text")
	t.ok(string.find(lines[2], "no kit loader", 1, true) ~= nil, lines[2])
	t.eq(Probe.runAll({}, { emit = emit }).ok, false, "no checks is not a pass")
	t.throws(function()
		Probe.runAll({ ["Bad-Name"] = function() end }, { emit = emit })
	end)
	local only = Probe.runAll({
		x_one = function(ctx)
			ctx.check("a", true)
		end,
		x_two = function(ctx)
			ctx.check("b", true)
		end,
	}, { emit = emit, only = { "x_two" } })
	t.eq(only.probes, { "x_two" })
	t.ok(Probe.validName("foundation_env_studio") and not Probe.validName("x"))
end)

test("foundation_env_studio probe passes against FakeEnv with a Lune kit loader", function(t)
	local registry = require("../fixtures/kits/shared/foundation_probes")
	local env = FakeEnv.new({ seed = "probe" })
	env:register("RunService", { name = "RunService" })
	local lines = {}
	local summary
	env.spawn(function()
		summary = Probe.runAll(registry, {
			env = env,
			kit = kitLoader,
			emit = function(line)
				table.insert(lines, line)
			end,
		})
	end)
	for _ = 1, 5 do
		env:flush()
		env:advance(0.1)
	end
	t.ok(summary ~= nil, "probe finished")
	t.eq(summary.failed, 0, table.concat(lines, "\n"))
	t.eq(summary.checks, 10)
	t.ok(summary.ok)
	t.ok(string.find(lines[#lines], "ENGINE_DONE ", 1, true) == 1)
end)

-- ---------------------------------------------------------------- FakeEnv and Golden

test("FakeEnv wakes sleepers in time order and refuses foreign threads", function(t)
	local env = FakeEnv.new({ start = 10 })
	local log = {}
	for _, spec in { { "slow", 2 }, { "fast", 1 }, { "tie", 1 } } do
		env.spawn(function()
			local waited = env.wait(spec[2])
			table.insert(log, spec[1] .. " " .. waited .. " at " .. env.clock())
		end)
	end
	t.eq({ env:pending() }, { 0, 3 })
	env:advance(1.5)
	t.eq(log, { "fast 1 at 11", "tie 1 at 11" })
	t.eq(env.clock(), 11.5)
	env:advance(1)
	t.eq(log[3], "slow 2 at 12")
	t.ok(string.find(
		errorText(function()
			env.wait(1)
		end),
		"started with env.spawn",
		1,
		true
	) ~= nil)
	t.throws(function()
		env:advance(-1)
	end)
end)

test("FakeEnv flushes deferred calls FIFO and stops defer loops", function(t)
	local env = FakeEnv.new({ deferLimit = 20 })
	local log = {}
	env.defer(function(x)
		table.insert(log, x)
		env.defer(function()
			table.insert(log, "nested")
		end)
	end, "a")
	env.defer(function()
		table.insert(log, "b")
	end)
	t.eq(env:flush(), 3)
	t.eq(log, { "a", "b", "nested" })
	local function loop()
		env.defer(loop)
	end
	env.defer(loop)
	t.ok(string.find(
		errorText(function()
			env:flush()
		end),
		"more than 20 deferred calls",
		1,
		true
	) ~= nil)
end)

test("FakeEnv collects thread errors and seeds rng from a counter", function(t)
	local env = FakeEnv.new({ seed = 5 })
	env.spawn(function()
		error("thread failed")
	end)
	t.eq(#env.errors, 1)
	t.eq(env.rng():nextUInt(), Rng.new("5:1"):nextUInt())
	t.eq(env.rng():nextUInt(), Rng.new("5:2"):nextUInt())
	t.eq(env.rng(8):nextUInt(), Rng.new(8):nextUInt())
	t.eq(#Env.validate(env), 0, "FakeEnv is a valid Env")
end)

test("Golden.updating reads 1 or a comma list", function(t)
	t.ok(Golden.updating("a", "1"))
	t.ok(Golden.updating("gamekit-action", "fixture-hashes, gamekit-action"))
	t.ok(not Golden.updating("gamekit-action", "gamekit-economy"))
	t.ok(not Golden.updating("a", ""))
	t.ok(not Golden.updating("a", "0"))
end)

test("Golden writes only when updating and names the first difference", function(t)
	local dir = ROOT .. "/build/golden-selftest"
	if fs.isDir(dir) then
		fs.removeDir(dir)
	end
	local value = { b = { 1, 2 }, a = "x" }
	local ok, message = Golden.check("sample", value, { dir = dir, setting = "" })
	t.ok(not ok and string.find(message, "is missing", 1, true) ~= nil, message)
	t.eq({ Golden.check("sample", value, { dir = dir, setting = "other" }) }, { false, message })
	t.eq({ Golden.check("sample", value, { dir = dir, setting = "sample" }) }, { true, "updated" })
	t.eq(fs.readFile(dir .. "/sample.json"), Golden.encode(value))
	t.eq({ Golden.check("sample", value, { dir = dir, setting = "1" }) }, { true, "unchanged" })
	t.eq({ Golden.check("sample", value, { dir = dir, setting = "" }) }, { true, "match" })
	fs.writeFile(dir .. "/sample.json", '{"a":"x","b":[1,2]}')
	t.eq({ Golden.check("sample", value, { dir = dir, setting = "" }) }, { true, "match" }, "formatting only")
	ok, message = Golden.check("sample", { b = { 1, 3 }, a = "x" }, { dir = dir, setting = "" })
	t.ok(not ok and string.find(message, "differs at $.b[2]: expected 2, got 3", 1, true) ~= nil, message)
	t.throws(function()
		Golden.assert("sample", { a = "y" }, { dir = dir, setting = "" })
	end)
	t.throws(function()
		Golden.path("../escape")
	end)
	local reserved = { pcall(Golden.check, "fixture-hashes", value, { dir = dir, setting = "1" }) }
	t.ok(not reserved[1] and string.find(tostring(reserved[2]), "written by tools/check.py", 1, true) ~= nil)
	t.ok(not fs.isFile(dir .. "/fixture-hashes.json"), "a reserved golden is never written")
	t.throws(function()
		Golden.assert("studio-smoke", value, { dir = dir, setting = "" })
	end)
	t.eq(#Golden.digest(value), 8)
	t.eq(Golden.digest(value), Golden.digest({ a = "x", b = { 1, 2 } }))
	fs.removeDir(dir)
end)

return cases
