--!strict
-- G1 telemetry: GameKit/Telemetry (limits at the boundary, funnel and onboarding order, catalog
-- checks, budget, strict mode, sink failures) and GameKit/TelemetryRoblox (AnalyticsService
-- argument mapping against tests/fakes/FakeAnalytics, live/recorder/forPlace sinks). It also
-- regenerates the neutral kit-event/1 fixture fixtures/analytics/kit_events.jsonl (compared byte
-- for byte; rewrite with FACTORY_UPDATE_GOLDEN=gamekit_platform_kit_events) that
-- tests/test_analytics_report.py feeds to tools/analytics_report.py, and a golden of the mapped
-- AnalyticsService calls (gamekit_platform_telemetry_calls).
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Events = require("../packages/GameKit/Events")
local Telemetry = require("../packages/GameKit/Telemetry")
local TelemetryRoblox = require("../packages/GameKit/TelemetryRoblox")
local FakeAnalytics = require("./fakes/FakeAnalytics")
local FakeEnv = require("./fakes/FakeEnv")
local FakePlatformRoblox = require("./fakes/FakePlatformRoblox")
local Golden = require("./lib/Golden")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."
local KIT_EVENTS = ROOT .. "/fixtures/analytics/kit_events.jsonl"

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

local function setup(options: { [string]: any }?): (any, any, any)
	local env = FakeEnv.new({ seed = 3 })
	local recorder = Events.recorder()
	local opts: { [string]: any } = { sink = recorder, budget = false }
	for key, value in options or {} do
		opts[key] = value
	end
	return Telemetry.new(opts :: any, env), recorder, env
end

local function funnelEvent(player: string, funnel: string, step: number, session: string): any
	local event: any = Events.funnel(
		"funnel_step",
		{ funnel = funnel, step = step, step_name = "step_" .. step, funnel_session_id = session }
	)
	event.player = player
	return event
end

local function onboardingEvent(player: string, step: number, name: string?): any
	local event: any =
		Events.onboarding("onboarding_step", { step = step, step_name = name or ("step_" .. step) })
	event.player = player
	return event
end

-- ---------------------------------------------------------------- options

test("validateCatalog and new report every problem", function(t)
	local names = {}
	for index = 1, 101 do
		names["name_" .. index] = {}
	end
	local funnels = {}
	for index = 1, 11 do
		funnels["funnel_" .. index] = { steps = { "a" } }
	end
	local problems = table.concat(
		Telemetry.validateCatalog({
			custom = names,
			onboarding = { "a", "a" },
			funnels = funnels,
			economy = {
				currencies = { "c1", "c2", "c3", "c4", "c5", "c6" },
				transactionTypes = { "Bad Type" },
			},
			progression = { ["Not A Label"] = true },
		}),
		"\n"
	)
	for _, needle in
		{
			"custom declares 101 names",
			"onboarding must list",
			"funnels declares 11 funnels",
			"economy.currencies must list 1 to 5",
			"transaction type",
			"progression path",
		}
	do
		t.ok(has(problems, needle), needle .. "\n" .. problems)
	end
	local reserved = table.concat(
		Telemetry.validateCatalog({ custom = { purchase_x = {}, ok = { fields = { "a", "b", "c", "d" } } } }),
		"\n"
	)
	t.ok(has(reserved, "reserved purchase_ prefix"))
	t.ok(has(reserved, "fields must be at most 3"))
	t.eq(Telemetry.validateCatalog(nil), {})
	local env = FakeEnv.new()
	local ok, err =
		pcall(Telemetry.new, { sink = {}, budget = { capacity = 0, refillPerSec = 1 } } :: any, env)
	t.ok(
		not ok and has(tostring(err), "sink must have emit") and has(tostring(err), "budget:"),
		tostring(err)
	)
	t.throws(function()
		Telemetry.new({ sink = Events.null() }, nil)
	end)
	t.eq(Telemetry.validate({ sink = Events.null() }), {})
end)

test("keyOf turns players into opaque keys", function(t)
	t.eq(Telemetry.keyOf({ UserId = 42 }), "42")
	t.eq(Telemetry.keyOf(7), "7")
	t.eq(Telemetry.keyOf("p_1"), "p_1")
	t.eq(Telemetry.keyOf({}), nil)
	t.eq(Telemetry.keyOf(nil), nil)
end)

-- ---------------------------------------------------------------- limits at the boundary

test("the 100th custom name passes and the 101st fails; purchase stages count", function(t)
	local telemetry, recorder = setup()
	for index = 1, 100 do
		t.ok(telemetry:custom("1", "name_" .. index))
	end
	t.eq({ telemetry:custom("1", "name_101") }, { false, "too_many_custom_names" })
	t.ok(telemetry:custom("1", "name_50"), "a known name still passes")
	t.eq(recorder:count(), 101)
	local fresh = setup()
	for index = 1, 98 do
		fresh:custom("1", "name_" .. index)
	end
	t.ok(fresh:purchase("1", "offer_viewed", "product_a", "devproduct"))
	t.ok(fresh:purchase("1", "prompted", "product_a", "devproduct"))
	t.eq({ fresh:purchase("1", "granted", "product_a", "devproduct") }, { false, "too_many_custom_names" })
	t.eq(fresh:report().cardinality.customNames, 100)
end)

test("10 funnels pass and the 11th fails; steps stop at 100", function(t)
	local telemetry = setup()
	for index = 1, 10 do
		t.ok(telemetry:track(funnelEvent("1", "funnel_" .. index, 1, "s")))
	end
	t.eq({ telemetry:track(funnelEvent("1", "funnel_11", 1, "s")) }, { false, "too_many_funnels" })
	local steps = setup()
	t.ok(steps:track(funnelEvent("1", "long", 1, "s")))
	t.ok(steps:track(funnelEvent("1", "long", 100, "s")))
	t.eq({ steps:track(funnelEvent("1", "long", 101, "s")) }, { false, "invalid" })
end)

test("three custom fields pass and a fourth is refused", function(t)
	local telemetry, recorder = setup()
	t.ok(telemetry:custom("1", "probe", nil, { a = "1", b = "2", c = "3" }))
	t.eq(
		{ telemetry:custom("1", "probe", nil, { a = "1", b = "2", c = "3", d = "4" }) },
		{ false, "invalid" }
	)
	t.eq({ telemetry:custom("1", "probe", nil, { a = "has,comma" }) }, { false, "invalid" })
	t.eq({ telemetry:custom("1", "probe", nil, { a = 5 :: any }) }, { false, "invalid" })
	t.eq(recorder:count(), 1)
	t.eq(telemetry:report().rejected.invalid, 3)
end)

test("five currencies and twenty transaction types pass; the next ones fail", function(t)
	local telemetry = setup()
	for index = 1, 5 do
		t.ok(telemetry:economy("1", "source", "currency_" .. index, 1, 1, "Gameplay"))
	end
	t.eq(
		{ telemetry:economy("1", "source", "currency_6", 1, 1, "Gameplay") },
		{ false, "too_many_currencies" }
	)
	for index = 1, 19 do
		t.ok(telemetry:economy("1", "sink", "currency_1", 1, 0, "type_" .. index))
	end
	t.eq(telemetry:report().cardinality.transactionTypes, 20)
	t.eq(
		{ telemetry:economy("1", "sink", "currency_1", 1, 0, "type_20") },
		{ false, "too_many_transaction_types" }
	)
	t.eq({ telemetry:economy("1", "sink", "currency_1", 0, 0, "Gameplay") }, { false, "invalid" }, "amount 0")
	t.eq(
		{ telemetry:economy("1", "sink", "currency_1", 1, -1, "Gameplay") },
		{ false, "invalid" },
		"negative balance"
	)
	t.eq({ telemetry:economy("1", "sink", "currency_1", 0 / 0, 1, "Gameplay") }, { false, "invalid" }, "NaN")
end)

-- ---------------------------------------------------------------- order

test("funnel steps out of order, repeated or never started are refused", function(t)
	local telemetry, recorder = setup()
	t.eq({ telemetry:track(funnelEvent("1", "f", 2, "s1")) }, { false, "funnel_not_started" })
	t.ok(telemetry:track(funnelEvent("1", "f", 1, "s1")))
	t.eq({ telemetry:track(funnelEvent("1", "f", 1, "s1")) }, { false, "funnel_repeat" })
	t.ok(telemetry:track(funnelEvent("1", "f", 3, "s1")), "a skip is allowed by default")
	t.eq({ telemetry:track(funnelEvent("1", "f", 2, "s1")) }, { false, "funnel_out_of_order" })
	-- sessions and players are independent
	t.ok(telemetry:track(funnelEvent("1", "f", 1, "s2")))
	t.ok(telemetry:track(funnelEvent("2", "f", 1, "s1")))
	t.ok(telemetry:track(funnelEvent("2", "f", 2, "s1")))
	t.eq(recorder:count("funnel"), 5)
	-- no gaps when allowGaps = false
	local strictOrder = setup({ allowGaps = false })
	strictOrder:track(funnelEvent("1", "f", 1, "s"))
	t.eq({ strictOrder:track(funnelEvent("1", "f", 3, "s")) }, { false, "funnel_skipped" })
	t.ok(strictOrder:track(funnelEvent("1", "f", 2, "s")))
end)

test("only the 10 most recent funnel sessions per player are tracked; forget clears", function(t)
	local telemetry = setup()
	for index = 1, 11 do
		t.ok(telemetry:track(funnelEvent("1", "f", 1, "s" .. index)))
	end
	t.eq(
		{ telemetry:track(funnelEvent("1", "f", 2, "s1")) },
		{ false, "funnel_not_started" },
		"s1 was evicted"
	)
	t.ok(telemetry:track(funnelEvent("1", "f", 2, "s2")))
	t.ok(telemetry:track(onboardingEvent("1", 1)))
	telemetry:forget({ UserId = 1 })
	t.eq({ telemetry:track(funnelEvent("1", "f", 3, "s2")) }, { false, "funnel_not_started" })
	t.ok(telemetry:track(onboardingEvent("1", 1)), "onboarding restarts after forget")
end)

test("onboarding steps follow the catalog order", function(t)
	local telemetry, recorder =
		setup({ catalog = { onboarding = { "spawned", "moved", "first_core_action" } } })
	t.eq({ telemetry:onboarding("1", "moved") }, { false, "onboarding_not_started" })
	t.ok(telemetry:onboarding("1", "spawned"))
	t.eq({ telemetry:onboarding("1", "spawned") }, { false, "onboarding_repeat" })
	t.ok(telemetry:onboarding("1", "first_core_action"))
	t.eq({ telemetry:onboarding("1", "moved") }, { false, "onboarding_out_of_order" })
	t.eq({ telemetry:onboarding("1", "unknown_step") }, { false, "step_mismatch" })
	t.eq({ telemetry:track(onboardingEvent("2", 1, "wrong_name")) }, { false, "step_mismatch" })
	local steps = {}
	for _, event in recorder.events do
		table.insert(steps, event.onboarding.step)
	end
	t.eq(steps, { 1, 3 })
	local bare = setup()
	t.eq({ bare:onboarding("1", "spawned") }, { false, "undeclared_name" }, "named steps need a catalog")
end)

-- ---------------------------------------------------------------- catalog

test("a catalog pins names, fields, currencies, types, paths and funnel steps", function(t)
	local telemetry, recorder = setup({
		catalog = {
			custom = { session_end = { fields = { "exit_reason" } } },
			funnels = { first_session = { steps = { "joined", "tutorial_done" } } },
			economy = { currencies = { "currency_a" }, transactionTypes = { "quest_reward" } },
			progression = { main_path = true },
		},
	})
	t.ok(telemetry:custom("1", "session_end", 30, { exit_reason = "left" }))
	t.eq({ telemetry:custom("1", "other_event") }, { false, "undeclared_name" })
	t.eq({ telemetry:custom("1", "session_end", nil, { surprise = "x" }) }, { false, "undeclared_field" })
	t.ok(telemetry:economy("1", "source", "currency_a", 5, 5, "quest_reward"))
	t.ok(telemetry:economy("1", "source", "currency_a", 5, 10, "Shop"), "standard types are always allowed")
	t.eq({ telemetry:economy("1", "source", "currency_z", 5, 5, "Shop") }, { false, "unknown_currency" })
	t.eq(
		{ telemetry:economy("1", "source", "currency_a", 5, 5, "other_type") },
		{ false, "unknown_transaction_type" }
	)
	t.ok(telemetry:progression("1", "main_path", "start", 1))
	t.eq({ telemetry:progression("1", "side_path", "start", 1) }, { false, "unknown_path" })
	local session = telemetry:funnelStart("1", "first_session")
	t.ok(session ~= nil and has(session, "fs_"), tostring(session))
	t.ok(telemetry:funnelStep("1", "first_session", session :: string, "tutorial_done"))
	t.eq(
		{ telemetry:funnelStep("1", "first_session", session :: string, "not_a_step") },
		{ false, "step_mismatch" }
	)
	t.eq({ telemetry:funnelStart("1", "unknown_funnel") }, { nil, "undeclared_name" })
	local wrong = funnelEvent("1", "first_session", 1, "s9")
	t.eq({ telemetry:track(wrong) }, { false, "step_mismatch" }, "number and name must agree")
	t.eq(recorder:named("funnel_step")[2].funnel.step, 2)
	-- seeded ids are deterministic
	local again = setup({ catalog = { funnels = { first_session = { steps = { "joined" } } } } })
	t.eq(again:funnelStart("2", "first_session"), session)
end)

-- ---------------------------------------------------------------- budget, strict, sinks

test("the budget drops overflow, refills with time and never raises", function(t)
	local telemetry, recorder, env = setup({ budget = { capacity = 5, refillPerSec = 1 }, strict = true })
	for _ = 1, 5 do
		t.ok(telemetry:custom("1", "tick"))
	end
	t.eq({ telemetry:custom("1", "tick") }, { false, "budget" })
	env:advance(1)
	t.ok(telemetry:custom("1", "tick"))
	t.eq(recorder:count(), 6)
	t.eq(telemetry:report().rejected.budget, 1)
	-- a funnel step dropped by the budget does not advance the funnel
	env:advance(10)
	t.ok(telemetry:track(funnelEvent("1", "f", 1, "s")))
	for _ = 1, 4 do
		telemetry:custom("1", "tick")
	end
	t.eq({ telemetry:track(funnelEvent("1", "f", 2, "s")) }, { false, "budget" })
	env:advance(1)
	t.ok(telemetry:track(funnelEvent("1", "f", 2, "s")), "step 2 is not a repeat")
end)

test("strict mode raises on caller errors with the reason", function(t)
	local telemetry = setup({ strict = true })
	local ok, err = pcall(function()
		telemetry:custom("1", "Bad Name")
	end)
	t.ok(not ok and has(tostring(err), "Telemetry: invalid"), tostring(err))
	telemetry:track(funnelEvent("1", "f", 1, "s"))
	ok, err = pcall(function()
		telemetry:track(funnelEvent("1", "f", 1, "s"))
	end)
	t.ok(not ok and has(tostring(err), "funnel_repeat"), tostring(err))
	t.throws(function()
		telemetry:track("not an event")
	end)
end)

test("sink errors and refusals are counted, reported and never raise", function(t)
	local env = FakeEnv.new()
	local calls = 0
	local raising = {
		emit = function(): (boolean, string?)
			calls += 1
			error("sink exploded")
		end,
	}
	local telemetry = Telemetry.new({ sink = raising, budget = false, strict = true }, env)
	for _ = 1, 3 do
		t.eq({ telemetry:custom("1", "x") }, { false, "sink_error" })
	end
	t.eq(calls, 3)
	t.eq(#env.reports, 1, "reported once, not per event")
	t.ok(has(env.reports[1], "sink exploded"))
	local refusing = {
		emit = function(): (boolean, string?)
			return false, "nope"
		end,
	}
	local other = Telemetry.new({ sink = refusing, budget = false }, env)
	t.eq({ other:track(funnelEvent("1", "f", 1, "s")) }, { false, "sink_rejected" })
	t.eq(other:report().rejected, { sink_rejected = 1 })
	-- the refused step 1 did not start the funnel session
	t.eq({ other:track(funnelEvent("1", "f", 2, "s")) }, { false, "funnel_not_started" })
end)

test("events are stamped with the envelope and the clock, and Telemetry is a sink", function(t)
	local telemetry, recorder, env =
		setup({ envelope = { synthetic = true, environment = "lune", session_id = "s_1" } })
	env:advance(12.5)
	t.ok(telemetry:emit(Events.economy("wallet_credit", {
		flow = "source",
		currency = "currency_a",
		amount = 10,
		balance = 25,
		transaction_type = "Gameplay",
	})))
	local event = recorder.events[1]
	t.eq(event.t, 12.5)
	t.eq(event.synthetic, true)
	t.eq(event.environment, "lune")
	t.eq(event.session_id, "s_1")
	t.eq(
		Events.encode(Events.stamp(Events.custom("x"), { t = 1 })),
		'{"category":"custom","name":"x","schema":"kit-event/1","t":1}'
	)
end)

test("distinct field values warn once at 80 percent of Roblox's 8000", function(t)
	local telemetry, _, env = setup({ budget = false })
	for index = 1, 6399 do
		telemetry:custom("1", "probe", nil, { slot = "v" .. index })
	end
	t.eq(#env.reports, 0)
	telemetry:custom("1", "probe", nil, { slot = "v6400" })
	t.eq(#env.reports, 1)
	t.ok(has(env.reports[1], "6400 distinct custom field values"))
	telemetry:custom("1", "probe", nil, { slot = "v6401" })
	t.eq(#env.reports, 1)
	t.eq(telemetry:report().cardinality.fieldValues, 6401)
end)

-- ---------------------------------------------------------------- TelemetryRoblox

local function liveEvent(event: any, player: string): any
	event.player = player
	event.synthetic = false
	event.environment = "live"
	return event
end

test("toCall maps every category to AnalyticsService arguments in order", function(t)
	local enums = roblox.Enum
	local method, args = TelemetryRoblox.toCall(
		Events.economy("x", {
			flow = "sink",
			currency = "currency_a",
			amount = 3,
			balance = 7,
			transaction_type = "Shop",
			sku = "item_a",
		}, { slot = "a" }),
		{ enums = enums, player = "P" }
	)
	t.eq(method, "LogEconomyEvent")
	t.eq(args.n, 8)
	t.ok(args[2] == enums.AnalyticsEconomyFlowType.Sink)
	t.eq(
		{ args[1], args[3], args[4], args[5], args[6], args[7] },
		{ "P", "currency_a", 3, 7, "Shop", "item_a" }
	)
	t.eq(args[8], { CustomField01 = "a" })
	method, args = TelemetryRoblox.toCall(
		Events.progression("x", { path = "main_path", status = "fail", level = 2, level_name = "two" }),
		{ enums = enums, player = "P" }
	)
	t.eq(method, "LogProgressionEvent")
	t.ok(args[3] == enums.AnalyticsProgressionType.Fail)
	t.eq({ args[2], args[4], args[5], args[6] }, { "main_path", 2, "two", nil })
	method, args = TelemetryRoblox.toCall(
		Events.funnel("x", { funnel = "f", step = 2, step_name = "b", funnel_session_id = "s" }),
		{ enums = enums, player = "P" }
	)
	t.eq({ method, args[2], args[3], args[4], args[5] }, { "LogFunnelStepEvent", "f", "s", 2, "b" })
	method, args =
		TelemetryRoblox.toCall(Events.onboarding("x", { step = 1, step_name = "a" }), { enums = enums })
	t.eq({ method, args[2], args[3] }, { "LogOnboardingFunnelStepEvent", 1, "a" })
	method, args = TelemetryRoblox.toCall(Events.custom("hit", 5), { enums = enums })
	t.eq({ method, args[2], args[3], args[4], args.n }, { "LogCustomEvent", "hit", 5, nil, 4 })
	method, args = TelemetryRoblox.toCall(
		Events.purchaseIntent("p", { stage = "prompted", product = "product_a", kind = "gamepass" }),
		{ enums = enums }
	)
	t.eq({ method, args[2], args[3] }, { "LogCustomEvent", "purchase_prompted", nil })
	t.eq(args[4], { CustomField01 = "product_a", CustomField02 = "gamepass" })
	-- declared order pins slots even when a field is missing
	t.eq(TelemetryRoblox.customFields({ c = "3" }, { "a", "b", "c" }), { CustomField03 = "3" })
	t.eq(TelemetryRoblox.customFields({ c = "3", a = "1" }), { CustomField01 = "1", CustomField02 = "3" })
	t.eq(TelemetryRoblox.customFields({}), nil)
	t.throws(function()
		TelemetryRoblox.toCall(
			Events.economy("x", {
				flow = "sink",
				currency = "c",
				amount = 1,
				balance = 0,
				transaction_type = "Shop",
			}),
			{} :: any
		)
	end)
end)

test("live sends to AnalyticsService and refuses synthetic, absent players and failures", function(t)
	local env = FakeEnv.new()
	local analytics = FakeAnalytics.new()
	local players = FakePlatformRoblox.players({ 1, 2 })
	local reports = {}
	local sink = TelemetryRoblox.live(analytics, {
		players = players,
		enums = roblox.Enum,
		catalog = { custom = { session_end = { fields = { "exit_reason", "zone" } } } },
		report = function(message: string)
			table.insert(reports, message)
		end,
	})
	local telemetry = Telemetry.new({
		sink = sink,
		budget = false,
		envelope = { synthetic = false, environment = "live" },
		catalog = { custom = { session_end = { fields = { "exit_reason", "zone" } } } },
	}, env)
	t.ok(telemetry:custom({ UserId = 1 }, "session_end", 30, { zone = "z1" }))
	local call = analytics:calls()[1]
	t.eq(call.method, "LogCustomEvent")
	t.ok(call.args[1] == players:GetPlayerByUserId(1), "the Player object, not the key")
	t.eq(call.args[4], { CustomField02 = "z1" }, "declared slot kept")
	t.eq(
		{ sink:emit(Events.stamp(Events.custom("x"), { player = "1", synthetic = true })) },
		{ false, "synthetic" }
	)
	t.eq(
		{ sink:emit(Events.stamp(Events.custom("x"), { player = "1", environment = "studio" })) },
		{ false, "synthetic" }
	)
	t.eq({ sink:emit(liveEvent(Events.custom("x"), "99")) }, { false, "no_player" })
	analytics:fail(1)
	t.eq({ sink:emit(liveEvent(Events.custom("x"), "2")) }, { false, "call_failed" })
	t.ok(has(reports[1], "LogCustomEvent failed"))
	t.ok(sink:emit(liveEvent(Events.custom("x"), "2")))
	t.eq(sink.sent, 2)
	t.eq(sink.failed, 1)
	-- the fake refuses client calls and bad arguments like the engine
	local client = FakeAnalytics.new({ isClient = true })
	local clientSink = TelemetryRoblox.live(client, { players = players, enums = roblox.Enum })
	t.eq({ clientSink:emit(liveEvent(Events.custom("x"), "1")) }, { false, "call_failed" })
	t.throws(function()
		analytics:LogEconomyEvent(players:GetPlayerByUserId(1), "Source", "c", 1, 1, "Shop")
	end)
end)

test("recorder prints TELEMETRY_JSON lines and forPlace picks the sink", function(t)
	local lines = {}
	local recorder = TelemetryRoblox.recorder(function(line: string)
		table.insert(lines, line)
	end)
	t.ok(
		recorder:emit(
			Events.stamp(Events.custom("hit", 2), { player = "1", environment = "live", synthetic = false })
		)
	)
	t.eq(
		lines[1],
		'TELEMETRY_JSON {"category":"custom","environment":"studio","name":"hit","player":"1","schema":"kit-event/1","synthetic":true,"value":2}'
	)
	t.eq(
		{ recorder:emit(Events.custom("Bad Name")) },
		{ false, 'name "Bad Name" is not a lower_snake label of at most 64 characters' }
	)
	local env = FakeEnv.new({ roblox = { Enum = roblox.Enum } })
	env.place = { isStudio = true, gameId = 0, placeId = 0, isServer = true, isClient = false }
	local studioSink, envelope = TelemetryRoblox.forPlace(env, { print = function() end })
	t.eq({ studioSink.kind, envelope.environment, envelope.synthetic }, { "recorder", "studio", true })
	env.place = { isStudio = false, gameId = 5, placeId = 6, isServer = true, isClient = false }
	env:register("AnalyticsService", FakeAnalytics.new())
	env:register("Players", FakePlatformRoblox.players({ 1 }))
	local liveSink, liveEnvelope = TelemetryRoblox.forPlace(env)
	t.eq({ liveSink.kind, liveEnvelope.environment, liveEnvelope.synthetic }, { "live", "live", false })
	env.place = { isStudio = false, gameId = 5, placeId = 6, isServer = false, isClient = true }
	t.throws(function()
		TelemetryRoblox.forPlace(env)
	end)
end)

-- ---------------------------------------------------------------- neutral fixture and golden

local CATALOG = {
	custom = { session_end = { fields = { "exit_reason" } }, load_finished = {} },
	onboarding = { "spawned", "moved", "first_core_action" },
	funnels = {
		first_session = { steps = { "joined", "tutorial_done", "first_core_action", "second_core_action" } },
	},
	economy = { currencies = { "currency_a", "currency_b" }, transactionTypes = { "quest_reward" } },
	progression = { main_path = true },
}

-- Three synthetic players through every category, deterministic (seeded env, fixed steps).
local function scenario(): (any, any)
	local env = FakeEnv.new({ seed = 11 })
	local recorder = Events.recorder()
	local telemetry = Telemetry.new({
		sink = recorder,
		catalog = CATALOG,
		budget = false,
		strict = true,
		envelope = { synthetic = true, environment = "lune" },
	}, env)
	local serial = 0
	local function send(player: number, event: any)
		serial += 1
		event.player = tostring(player)
		event.session_id = "s_" .. player
		event.event_id = string.format("e_%03d", serial)
		assert(telemetry:track(event))
		env:advance(2)
	end
	local function funnel(player: number, session: string, stepName: string)
		local step = table.find(CATALOG.funnels.first_session.steps, stepName) :: number
		send(
			player,
			Events.funnel("funnel_step", {
				funnel = "first_session",
				step = step,
				step_name = stepName,
				funnel_session_id = session,
			})
		)
	end
	local function onboarding(player: number, stepName: string)
		send(
			player,
			Events.onboarding("onboarding_step", {
				step = table.find(CATALOG.onboarding, stepName) :: number,
				step_name = stepName,
			})
		)
	end
	local function economy(
		player: number,
		flow: any,
		currency: string,
		amount: number,
		balance: number,
		kind: string
	)
		send(
			player,
			Events.economy("economy_" .. flow, {
				flow = flow,
				currency = currency,
				amount = amount,
				balance = balance,
				transaction_type = kind,
			})
		)
	end
	local function progression(player: number, status: any, level: number)
		send(
			player,
			Events.progression(
				"progression_" .. status,
				{ path = "main_path", status = status, level = level }
			)
		)
	end
	local function purchase(player: number, stage: any)
		send(
			player,
			Events.purchaseIntent(
				"purchase_" .. stage,
				{ stage = stage, product = "product_a", kind = "devproduct", surface = "shop_panel" }
			)
		)
	end
	-- player 1: the whole path
	send(1, Events.custom("load_finished", 4))
	onboarding(1, "spawned")
	funnel(1, "fs_1_a", "joined")
	onboarding(1, "moved")
	funnel(1, "fs_1_a", "tutorial_done")
	onboarding(1, "first_core_action")
	funnel(1, "fs_1_a", "first_core_action")
	economy(1, "source", "currency_a", 10, 10, "Gameplay")
	progression(1, "start", 1)
	progression(1, "complete", 1)
	progression(1, "start", 2)
	progression(1, "fail", 2)
	purchase(1, "offer_viewed")
	purchase(1, "prompted")
	purchase(1, "granted")
	economy(1, "sink", "currency_a", 4, 6, "Shop")
	funnel(1, "fs_1_a", "second_core_action")
	funnel(1, "fs_1_b", "joined")
	send(1, Events.custom("session_end", 300, { exit_reason = "left" }))
	-- player 2: part of the way
	send(2, Events.custom("load_finished", 6))
	onboarding(2, "spawned")
	funnel(2, "fs_2_a", "joined")
	onboarding(2, "moved")
	funnel(2, "fs_2_a", "tutorial_done")
	economy(2, "source", "currency_b", 5, 5, "quest_reward")
	progression(2, "start", 1)
	progression(2, "complete", 1)
	purchase(2, "offer_viewed")
	purchase(2, "prompted")
	purchase(2, "prompt_closed")
	send(2, Events.custom("session_end", 120, { exit_reason = "left" }))
	-- player 3: leaves early
	onboarding(3, "spawned")
	funnel(3, "fs_3_a", "joined")
	progression(3, "start", 1)
	purchase(3, "offer_viewed")
	send(3, Events.custom("session_end", 20, { exit_reason = "left" }))
	return recorder, telemetry
end

test("the neutral kit-event/1 fixture is reproduced byte for byte", function(t)
	local recorder, telemetry = scenario()
	local text = table.concat(recorder:lines(), "\n") .. "\n"
	t.eq(telemetry:report().accepted, #recorder.events)
	t.eq(#recorder.rejected, 0)
	local again = scenario()
	t.eq(table.concat(again:lines(), "\n") .. "\n", text, "deterministic")
	if Golden.updating("gamekit_platform_kit_events") then
		fs.writeFile(KIT_EVENTS, text)
	end
	t.ok(
		fs.isFile(KIT_EVENTS),
		"missing " .. KIT_EVENTS .. " (FACTORY_UPDATE_GOLDEN=gamekit_platform_kit_events)"
	)
	t.ok(fs.readFile(KIT_EVENTS) == text, "fixtures/analytics/kit_events.jsonl differs from the scenario")
end)

test("the mapped AnalyticsService calls match the golden", function(t)
	local recorder = scenario()
	local analytics = FakeAnalytics.new()
	local players = FakePlatformRoblox.players({ 1, 2, 3 })
	local sink =
		TelemetryRoblox.live(analytics, { players = players, enums = roblox.Enum, catalog = CATALOG })
	for _, event in recorder.events do
		local live = table.clone(event)
		live.synthetic = false
		live.environment = "live"
		t.ok(sink:emit(live))
	end
	local calls = {}
	for _, call in analytics:calls() do
		local args = {}
		for index = 1, call.args.n do
			local value = call.args[index]
			if typeof(value) == "EnumItem" then
				value = tostring(value)
			elseif type(value) == "table" and value.UserId then
				value = "player:" .. value.UserId
			elseif value == nil then
				value = "nil"
			end
			table.insert(args, value)
		end
		table.insert(calls, { method = call.method, args = args })
	end
	t.eq(#calls, #recorder.events)
	Golden.assert("gamekit_platform_telemetry_calls", calls)
end)

return cases
