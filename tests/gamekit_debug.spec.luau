--!strict
-- GameKit/DebugCommands: active only on the unpublished diagnostic place (Env.check), argument
-- parsing and validation, errors contained, bounded history, and the release-check status.
local DebugCommands = require("../packages/GameKit/DebugCommands")
local FakeEnv = require("./fakes/FakeEnv")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local PUBLISHED = { isStudio = true, gameId = 4242, placeId = 0 }

local function registry(place: any?): (any, any)
	local env = FakeEnv.new({ place = place })
	local commands = DebugCommands.new(env)
	commands:register("set_value", {
		description = "Sets a diagnostic value.",
		args = {
			{ name = "amount", kind = "integer", min = 0, max = 100 },
			{ name = "mode", kind = "enum", choices = { "fast", "slow" }, optional = true },
		},
		run = function(_ctx: any, args: any)
			return { amount = args.amount, mode = args.mode or "fast" }
		end,
	})
	return commands, env
end

test("runs on the unpublished Studio place and parses a command line", function(t)
	local commands = registry()
	t.eq({ commands:active() }, { true })
	local ok, result = commands:run("set_value 5 slow")
	t.ok(ok, tostring(result))
	t.eq(result, { amount = 5, mode = "slow" })
	ok, result = commands:run("set_value", { "7" })
	t.ok(ok, tostring(result))
	t.eq(result, { amount = 7, mode = "fast" })
end)

test("is inert on published, live or unknown places", function(t)
	for _, case in
		{
			{ PUBLISHED, "inactive:published_game" },
			{ { isStudio = true, gameId = 0, placeId = 99 }, "inactive:published_place" },
			{ { isStudio = false, gameId = 0, placeId = 0 }, "inactive:not_studio" },
			{ { isStudio = "yes", gameId = 0, placeId = 0 }, "inactive:invalid_place" },
		}
	do
		local commands = registry(case[1])
		local ran = false
		commands:register("probe_side_effect", {
			run = function()
				ran = true
			end,
		})
		t.eq({ commands:run("probe_side_effect") }, { false, case[2] })
		t.ok(not ran, "nothing executes while inactive")
		t.eq(#commands:history(), 0)
	end
	local missing = DebugCommands.new({})
	t.eq({ missing:run("anything") }, { false, "inactive:missing_place" })
end)

test("status reports what the release check asserts", function(t)
	t.eq(DebugCommands.status(FakeEnv.new()), { active = true })
	t.eq(
		DebugCommands.status(FakeEnv.new({ place = PUBLISHED })),
		{ active = false, reason = "published_game" }
	)
	t.eq(DebugCommands.status(nil), { active = false, reason = "missing_place" })
end)

test("rejects bad arguments without running the command", function(t)
	local commands = registry()
	for _, case in
		{
			{ "set_value", "missing_arg: amount" },
			{ "set_value 101", "bad_arg: amount must be at most 100" },
			{ "set_value -1", "bad_arg: amount must be at least 0" },
			{ "set_value 1.5", "bad_arg: amount must be a whole number" },
			{ "set_value nan", "bad_arg: amount must be a number" },
			{ "set_value 1 medium", "bad_arg: mode must be one of fast, slow" },
			{ "set_value 1 fast extra", "too_many_args: set_value takes at most 2" },
			{ "unknown_thing", "unknown_command: unknown_thing" },
			{ "   ", "empty_line" },
			{ 'set_value "5', "bad_line: unclosed quote" },
			{ string.rep("x", 600), "bad_line: line is longer than 512 characters" },
		}
	do
		t.eq({ commands:run(case[1]) }, { false, case[2] }, case[1])
	end
	t.eq(#commands:history(), 0, "rejected lines never reach history")
end)

test("parse groups quoted words and handles escapes", function(t)
	t.eq(DebugCommands.parse('say "two words" plain'), { "say", "two words", "plain" })
	t.eq(DebugCommands.parse('say "a \\"quoted\\" word"'), { "say", 'a "quoted" word' })
	t.eq(DebugCommands.parse("  "), {})
	t.eq(DebugCommands.parse('x""y'), { "x", "", "y" })
	t.eq({ DebugCommands.parse(5 :: any) }, { nil, "line must be a string" })
end)

test("booleans, strings and limits", function(t)
	local commands = DebugCommands.new(FakeEnv.new())
	commands:register("toggle", {
		args = {
			{ name = "on", kind = "boolean" },
			{ name = "label", kind = "string", maxLength = 4, optional = true },
		},
		run = function(_ctx: any, args: any)
			return args
		end,
	})
	t.eq({ commands:run("toggle on") }, { true, { on = true } })
	t.eq({ commands:run("toggle 0 abcd") }, { true, { on = false, label = "abcd" } })
	t.eq({ commands:run("toggle maybe") }, { false, "bad_arg: on must be true or false" })
	t.eq({ commands:run("toggle true abcde") }, { false, "bad_arg: label is longer than 4 characters" })
end)

test("a command that raises is contained and reported", function(t)
	local env = FakeEnv.new()
	local commands = DebugCommands.new(env)
	commands:register("explode", {
		run = function()
			error("boom")
		end,
	})
	local ok, reason = commands:run("explode")
	t.ok(not ok)
	t.ok(string.find(reason, "error: ", 1, true) == 1 and string.find(reason, "boom", 1, true) ~= nil, reason)
	t.eq(#env.reports, 1)
	t.eq(commands:history()[1].ok, false)
end)

test("history keeps the last 32 runs with the env clock", function(t)
	local env = FakeEnv.new({ start = 10 })
	local commands = DebugCommands.new(env)
	commands:register("tick_once", {
		run = function()
			return true
		end,
	})
	for _ = 1, 40 do
		commands:run("tick_once")
		env:advance(1)
	end
	local history = commands:history()
	t.eq(#history, DebugCommands.HISTORY)
	t.eq(history[1].t, 18)
	t.eq(history[#history].t, 49)
end)

test("caller filter and registration rules", function(t)
	local commands = DebugCommands.new(FakeEnv.new(), {
		allow = function(caller: any): boolean
			return caller == "developer"
		end,
	})
	commands:register("noop", {
		run = function()
			return 1
		end,
	})
	t.eq({ commands:run("noop", nil, "guest") }, { false, "caller_not_allowed" })
	t.eq({ commands:run("noop", nil, "developer") }, { true, 1 })
	t.throws(function()
		commands:register("noop", { run = function() end })
	end, "duplicate name")
	t.throws(function()
		commands:register("Bad-Name", { run = function() end })
	end, "label name")
	t.throws(function()
		commands:register("no_run", {} :: any)
	end, "run required")
	t.throws(function()
		commands:register("bad_args", {
			args = { { name = "a", kind = "number", optional = true }, { name = "b", kind = "number" } },
			run = function() end,
		})
	end, "required after optional")
	t.throws(function()
		commands:register("bad_kind", { args = { { name = "a", kind = "vector" } }, run = function() end })
	end, "unknown kind")
	t.throws(function()
		commands:register(
			"bad_range",
			{ args = { { name = "a", kind = "number", min = 2, max = 1 } }, run = function() end }
		)
	end, "min above max")
	t.throws(function()
		commands:register("bad_enum", { args = { { name = "a", kind = "enum" } }, run = function() end })
	end, "enum without choices")
	local listed = commands:list()
	t.eq(#listed, 1)
	t.eq(listed[1].name, "noop")
end)

return cases
