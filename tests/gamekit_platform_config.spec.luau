--!strict
-- G1 live config: GameKit/Config (declared keys, schema and type checks, defaults for missing
-- or invalid values, change events) and GameKit/ConfigRoblox against tests/fakes/FakeConfig
-- (load, per-player values, timeout and errors keep defaults, UpdateAvailable refresh, GetValue
-- failures, disconnect).
local Config = require("../packages/GameKit/Config")
local ConfigRoblox = require("../packages/GameKit/ConfigRoblox")
local FakeConfig = require("./fakes/FakeConfig")
local FakeEnv = require("./fakes/FakeEnv")
local Schema = require("../packages/GameKit/Schema")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

local function run(env: any, fn: () -> ...any): ...any
	local out = nil
	env.spawn(function()
		out = table.pack(fn())
	end)
	for _ = 1, 3000 do
		if out ~= nil then
			break
		end
		env:advance(0.1)
		env:flush()
	end
	assert(out ~= nil, "did not finish: " .. table.concat(env.errors, "\n"))
	return table.unpack(out, 1, out.n)
end

local OPTIONS = {
	defaults = {
		feature_enabled = true,
		spawn_rate = 1,
		banner_key = "none",
		weights = { a = 1, b = 2 },
	},
	schema = {
		spawn_rate = Schema.number({ min = 0, max = 10 }),
		banner_key = Schema.enum({ "none", "event_a", "event_b" }),
	},
}

test("validate refuses bad keys, defaults and schemas", function(t)
	local problems = table.concat(
		Config.validate({
			defaults = { ["Bad Key"] = 1, fn = function() end, nan = { x = 0 / 0 }, ok = 5 },
			schema = { ok = Schema.number({ max = 1 }), ghost = Schema.number(), fn = 5 :: any },
		}),
		"\n"
	)
	for _, needle in
		{
			"not a lower_snake label",
			"fn: defaults must be numbers",
			"nan: a table default must be plain",
			"ok: the default fails its own schema",
			"schema names ghost",
		}
	do
		t.ok(has(problems, needle), needle .. "\n" .. problems)
	end
	t.eq(Config.validate(nil), { "defaults must be a table of key -> value" })
	t.ok(not pcall(Config.new, { defaults = { ["Bad Key"] = 1 } }))
	t.eq(Config.validate(OPTIONS), {})
end)

test("get returns defaults, copies tables and raises on undeclared keys", function(t)
	local config = Config.new(OPTIONS)
	t.eq(config:get("spawn_rate"), 1)
	local weights = config:get("weights")
	weights.a = 99
	t.eq(config:get("weights").a, 1)
	t.eq(config:default("banner_key"), "none")
	t.throws(function()
		config:get("typo_key")
	end)
	t.throws(function()
		config:default("typo_key")
	end)
	t.eq(config:keys(), { "banner_key", "feature_enabled", "spawn_rate", "weights" })
	t.eq(config:snapshot().source, "defaults")
end)

test("apply takes valid values, falls back per key and reports what it ignored", function(t)
	local config = Config.new(OPTIONS)
	local changes = {}
	config.changed:Connect(function(key: string, value: any, previous: any)
		table.insert(changes, { key, value, previous })
	end)
	local notes = config:apply({
		feature_enabled = false,
		spawn_rate = 50, -- above max
		banner_key = "event_a",
		weights = "oops", -- wrong type
		unknown_key = 1,
	}, "service")
	t.eq(config:get("feature_enabled"), false)
	t.eq(config:get("spawn_rate"), 1, "invalid -> default")
	t.eq(config:get("banner_key"), "event_a")
	t.eq(config:get("weights"), { a = 1, b = 2 })
	t.eq(#notes, 3)
	t.ok(has(table.concat(notes, "\n"), "spawn_rate: above_max"))
	t.ok(has(table.concat(notes, "\n"), "unknown_key: not declared"))
	t.eq(changes, { { "banner_key", "event_a", "none" }, { "feature_enabled", false, true } })
	t.eq(config:snapshot().source, "service")
	-- a later snapshot without a key brings the default back
	changes = {}
	config:apply({ spawn_rate = 2 }, "service")
	t.eq(config:get("feature_enabled"), true)
	t.eq(config:get("banner_key"), "none")
	t.eq(#changes, 3)
	-- NaN, inf and wrong types never get in
	config:apply({ spawn_rate = 0 / 0 }, "service")
	t.eq(config:get("spawn_rate"), 1)
	config:apply({ feature_enabled = "yes", weights = { a = math.huge } }, "service")
	t.eq(config:get("feature_enabled"), true)
	t.eq(config:get("weights"), { a = 1, b = 2 })
	t.eq(config:apply("garbage" :: any, "service"), { "values are not a table: defaults used" })
	config:apply({ spawn_rate = 3 }, "service")
	config:reset()
	t.eq(config:get("spawn_rate"), 1)
	t.eq(config:snapshot().source, "defaults")
end)

test("ConfigRoblox loads values, follows updates and stops on disconnect", function(t)
	local env = FakeEnv.new()
	local service = FakeConfig.new({ values = { feature_enabled = false, spawn_rate = 4, stray = 1 } })
	local config = Config.new(OPTIONS)
	local binding = run(env, function()
		return ConfigRoblox.load(config, service, nil, env)
	end)
	t.eq({ binding.ok, binding.reason }, { true, nil })
	t.eq(config:get("spawn_rate"), 4)
	t.eq(config:get("feature_enabled"), false)
	t.eq(config:snapshot().source, "service")
	-- a publish fires UpdateAvailable; the binding refreshes and re-applies
	service:publish({ feature_enabled = true, spawn_rate = 6 })
	t.eq(config:get("spawn_rate"), 6)
	t.eq(config:get("feature_enabled"), true)
	-- a kill switch: the key flips back to its default when removed
	service:publish({})
	t.eq(config:get("spawn_rate"), 1)
	binding.disconnect()
	service:publish({ spawn_rate = 9 })
	t.eq(config:get("spawn_rate"), 1, "no longer following")
	t.ok(binding.refresh(), "manual refresh still works")
	t.eq(config:get("spawn_rate"), 9)
end)

test("ConfigRoblox keeps defaults on errors, timeouts and a missing service", function(t)
	local env = FakeEnv.new()
	local service = FakeConfig.new({ values = { spawn_rate = 4 }, env = env })
	local config = Config.new(OPTIONS)
	service:fail("HTTP 500")
	local failed = run(env, function()
		return ConfigRoblox.load(config, service, nil, env)
	end)
	t.eq({ failed.ok, failed.reason }, { false, "error" })
	t.eq(config:get("spawn_rate"), 1)
	t.eq(failed.refresh(), false)
	service.hang = true
	local started = env.clock()
	local hung = run(env, function()
		return ConfigRoblox.load(config, service, { timeout = 3 }, env)
	end)
	t.eq({ hung.ok, hung.reason }, { false, "timeout" })
	t.ok(env.clock() - started >= 3 and env.clock() - started < 4)
	t.eq(config:get("spawn_rate"), 1)
	t.ok(has(table.concat(env.reports, "\n"), "defaults kept"))
	local none = run(env, function()
		return ConfigRoblox.load(config, nil, nil, env)
	end)
	t.eq(none.reason, "no_service")
	-- one key failing to read: the rest apply, the binding says partial
	local partial = FakeConfig.new({ values = { spawn_rate = 5, banner_key = "event_b" } })
	partial:failKey("banner_key")
	local binding = run(env, function()
		return ConfigRoblox.load(config, partial, nil, env)
	end)
	t.eq({ binding.ok, binding.reason }, { false, "partial" })
	t.eq(config:get("spawn_rate"), 5)
	t.eq(config:get("banner_key"), "none")
	t.ok(has(table.concat(binding.notes, "\n"), "banner_key: GetValue failed"))
end)

test("ConfigRoblox reads per-player experiment values", function(t)
	local env = FakeEnv.new()
	local service =
		FakeConfig.new({ values = { spawn_rate = 2 }, playerValues = { [7] = { spawn_rate = 3 } } })
	local playerConfig = Config.new(OPTIONS)
	local binding = run(env, function()
		return ConfigRoblox.load(playerConfig, service, { player = { UserId = 7 } }, env)
	end)
	t.ok(binding.ok)
	t.eq(playerConfig:get("spawn_rate"), 3)
	t.eq(playerConfig:snapshot().source, "service_player")
	local other = Config.new(OPTIONS)
	run(env, function()
		return ConfigRoblox.load(other, service, { player = { UserId = 8 } }, env)
	end)
	t.eq(other:get("spawn_rate"), 2)
end)

return cases
