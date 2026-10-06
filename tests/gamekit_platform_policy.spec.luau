--!strict
-- G1 policy and safety gates: GameKit/PolicyGate (the fail-closed matrix, cache, retries,
-- negative cache, concurrent loads, forget), PolicyGateRoblox (fetcher, voice, bind) against
-- FakePolicy; GameKit/TextFilter and TextFilterRoblox against FakeTextService (hostile text,
-- invisible characters, rate, offline users, filter failures); GameKit/Moderation and
-- ModerationRoblox (validation, ladder, refusals in Studio and without confirmation).
local FakeEnv = require("./fakes/FakeEnv")
local FakePlatformRoblox = require("./fakes/FakePlatformRoblox")
local FakePolicy = require("./fakes/FakePolicy")
local FakeTextService = require("./fakes/FakeTextService")
local Moderation = require("../packages/GameKit/Moderation")
local ModerationRoblox = require("../packages/GameKit/ModerationRoblox")
local PolicyGate = require("../packages/GameKit/PolicyGate")
local PolicyGateRoblox = require("../packages/GameKit/PolicyGateRoblox")
local TextFilter = require("../packages/GameKit/TextFilter")
local TextFilterRoblox = require("../packages/GameKit/TextFilterRoblox")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

local function go(env: any, fn: () -> ...any): () -> any
	local out = nil
	env.spawn(function()
		out = table.pack(fn())
	end)
	return function(): any
		return out
	end
end

local function run(env: any, fn: () -> ...any): ...any
	local result = go(env, fn)
	for _ = 1, 3000 do
		if result() ~= nil then
			break
		end
		env:advance(0.1)
		env:flush()
	end
	local out = result()
	assert(out ~= nil, "did not finish: " .. table.concat(env.errors, "\n"))
	return table.unpack(out, 1, out.n)
end

local PLAYER = { UserId = 7 }

-- ---------------------------------------------------------------- PolicyGate.evaluate

test("the fail-closed matrix: every feature against every preset and broken input", function(t)
	local expected = {
		permissive = {
			paidRandomItems = true,
			trading = true,
			ads = true,
			subscriptions = true,
			commerceProducts = true,
			contentSharing = true,
		},
		restricted = {},
		mixed = { ads = true, subscriptions = true, commerceProducts = true },
		partial = { ads = true },
		malformed = {},
	}
	for preset, allowed in expected do
		local info = FakePolicy.PRESETS[preset]
		for _, feature in PolicyGate.FEATURES do
			local ok, reason = PolicyGate.evaluate(info, feature)
			t.eq(ok, allowed[feature] == true, preset .. "." .. feature .. " (" .. reason .. ")")
		end
	end
	-- reasons
	t.eq({ PolicyGate.evaluate(FakePolicy.PRESETS.permissive, "ads") }, { true, "allowed" })
	t.eq({ PolicyGate.evaluate(FakePolicy.PRESETS.restricted, "ads") }, { false, "denied" })
	t.eq({ PolicyGate.evaluate(FakePolicy.PRESETS.partial, "trading") }, { false, "missing_field" })
	t.eq({ PolicyGate.evaluate(FakePolicy.PRESETS.malformed, "ads") }, { false, "missing_field" })
	t.eq({ PolicyGate.evaluate(nil, "ads") }, { false, "no_policy" })
	t.eq({ PolicyGate.evaluate("info", "ads") }, { false, "no_policy" })
	t.eq({ PolicyGate.evaluate(FakePolicy.PRESETS.permissive, "teleport") }, { false, "unknown_feature" })
	t.eq({ PolicyGate.evaluate(FakePolicy.PRESETS.permissive, nil) }, { false, "unknown_feature" })
	t.eq({ PolicyGate.evaluate(FakePolicy.PRESETS.permissive, "externalLinks") }, { false, "never_in_game" })
	t.eq({ PolicyGate.evaluate(FakePolicy.PRESETS.permissive, "socialLinks") }, { false, "never_in_game" })
	-- voice needs the adapter's VoiceEnabled field
	t.eq({ PolicyGate.evaluate(FakePolicy.PRESETS.permissive, "voice") }, { false, "missing_field" })
	t.eq({ PolicyGate.evaluate({ VoiceEnabled = true }, "voice") }, { true, "allowed" })
	-- an info table whose index raises
	local hostile = setmetatable({}, {
		__index = function()
			error("boom")
		end,
	})
	t.eq({ PolicyGate.evaluate(hostile, "ads") }, { false, "missing_field" })
	t.eq(PolicyGate.matrix(nil).ads, false)
	t.eq(PolicyGate.matrix(FakePolicy.PRESETS.permissive).trading, true)
end)

-- ---------------------------------------------------------------- PolicyGate cache

test("a gate says no until loaded, then answers from the cache without yielding", function(t)
	local env = FakeEnv.new()
	local policy = FakePolicy.new({ preset = "mixed" })
	local gate = PolicyGate.new({ fetch = PolicyGateRoblox.fetcher(policy) }, env)
	t.eq({ gate:allows(PLAYER, "ads") }, { false, "no_policy" })
	t.eq({ gate:allows(PLAYER, "externalLinks") }, { false, "never_in_game" })
	t.eq({ gate:allows(PLAYER, "nope") }, { false, "unknown_feature" })
	t.ok(run(env, function()
		return gate:load(PLAYER)
	end))
	t.eq({ gate:allows(PLAYER, "ads") }, { true, "allowed" })
	t.eq({ gate:allows(PLAYER, "trading") }, { false, "denied" })
	local policyAllows = gate:predicate(PLAYER)
	t.eq(policyAllows("ads"), true)
	t.eq(policyAllows("paidRandomItems"), false)
	t.ok(run(env, function()
		return gate:load(PLAYER)
	end))
	t.eq(policy.calls, 1, "cached for the session")
	local info = gate:info(PLAYER)
	info.AreAdsAllowed = false
	t.eq(gate:allows(PLAYER, "ads"), true, "info() returns a copy")
	gate:forget(PLAYER)
	t.eq(gate:allows(PLAYER, "ads"), false)
	t.eq(gate:info(PLAYER), nil)
end)

test("loads retry, then fail closed with a negative cache", function(t)
	local env = FakeEnv.new()
	local policy = FakePolicy.new({ preset = "permissive" })
	local gate = PolicyGate.new({
		fetch = PolicyGateRoblox.fetcher(policy),
		retry = { attempts = 3, base = 0.5, jitter = "none" },
		negativeTtl = 30,
	}, env)
	policy:fail(2)
	t.ok(
		run(env, function()
			return gate:load(PLAYER)
		end),
		"two failures then success"
	)
	t.eq(policy.calls, 3)
	local other = { UserId = 8 }
	policy:fail(3)
	t.eq({
		run(env, function()
			return gate:load(other)
		end),
	}, { false, "failed" })
	t.eq(gate:allows(other, "ads"), false)
	t.ok(has(env.reports[1], "not loaded"))
	local calls = policy.calls
	t.eq({
		run(env, function()
			return gate:load(other)
		end),
	}, { false, "recent_failure" })
	t.eq(policy.calls, calls, "no fetch inside the negative ttl")
	env:advance(31)
	t.ok(
		run(env, function()
			return gate:load(other)
		end),
		"retried after the ttl"
	)
	-- a fetch that returns a non-table is a failure too
	local weird = PolicyGate.new({
		fetch = function(): any
			return "yes"
		end,
		retry = { attempts = 1 },
	}, env)
	t.eq(
		select(
			2,
			run(env, function()
				return weird:load(PLAYER)
			end)
		),
		"failed"
	)
end)

test("concurrent loads share one fetch and forget discards a load in flight", function(t)
	local env = FakeEnv.new()
	local policy = FakePolicy.new({ preset = "permissive", env = env, latency = 1 })
	local gate = PolicyGate.new({ fetch = PolicyGateRoblox.fetcher(policy) }, env)
	local a = go(env, function()
		return gate:load(PLAYER)
	end)
	local b = go(env, function()
		return gate:load(PLAYER)
	end)
	env:advance(1.5)
	t.eq(a()[1], true)
	t.eq(b()[1], true)
	t.eq(policy.calls, 1)
	local leaver = { UserId = 9 }
	local pending = go(env, function()
		return gate:load(leaver)
	end)
	local waiter = go(env, function()
		return gate:load(leaver)
	end)
	env:advance(0.5)
	gate:forget(leaver)
	env:advance(1)
	t.eq(pending()[1], false)
	t.eq(waiter()[1], false)
	t.eq(gate:allows(leaver, "ads"), false, "a forgotten player's late result is dropped")
end)

test("PolicyGate.new validates its options", function(t)
	local env = FakeEnv.new()
	local ok, err = pcall(PolicyGate.new, { negativeTtl = -1, retry = { attempts = 0 } } :: any, env)
	t.ok(not ok)
	t.ok(has(tostring(err), "fetch(player) is required"))
	t.ok(has(tostring(err), "negativeTtl"))
	t.ok(has(tostring(err), "retry: attempts"))
	t.throws(function()
		PolicyGate.new({ fetch = function() end }, nil)
	end)
end)

-- ---------------------------------------------------------------- PolicyGateRoblox

test("fetcher copies the known fields and adds voice when available", function(t)
	local policy = FakePolicy.new({ preset = "permissive" })
	local info = PolicyGateRoblox.fetcher(
		policy,
		{ voiceChatService = FakePolicy.voice({ enabled = { [7] = true } }) }
	)(PLAYER)
	t.eq(info.VoiceEnabled, true)
	t.eq(info.AreAdsAllowed, true)
	t.eq(info.IsSubjectToChinaPolicies, nil, "only the fields PolicyGate reads")
	local noVoice =
		PolicyGateRoblox.fetcher(policy, { voiceChatService = FakePolicy.voice({ fail = true }) })(PLAYER)
	t.eq(noVoice.VoiceEnabled, nil, "a voice error leaves voice off")
	t.eq((PolicyGate.evaluate(noVoice, "voice")), false)
	local broken = {
		GetPolicyInfoForPlayerAsync = function(): any
			return nil
		end,
	}
	t.throws(function()
		PolicyGateRoblox.fetcher(broken)(PLAYER)
	end)
	t.throws(function()
		PolicyGateRoblox.fetcher(nil)
	end)
end)

test("bind loads present and joining players and forgets leavers", function(t)
	local env = FakeEnv.new()
	local players = FakePlatformRoblox.players({ 1 })
	local policy = FakePolicy.new({ preset = "restricted", byUserId = { [2] = "permissive" } })
	env:register("PolicyService", policy)
	local gate = PolicyGateRoblox.gate(env)
	local disconnect = PolicyGateRoblox.bind(gate, players, env)
	local first = players:GetPlayerByUserId(1)
	t.eq(gate:allows(first, "ads"), false)
	t.ok(gate:info(first) ~= nil)
	local second = players:join(2)
	t.eq(gate:allows(second, "ads"), true)
	players:leave(second)
	t.eq(gate:info(second), nil)
	disconnect()
	local third = players:join(3)
	t.eq(gate:info(third), nil, "unbound")
end)

-- ---------------------------------------------------------------- TextFilter

local function pipeline(env: any, textService: any, options: { [string]: any }?): any
	local opts: { [string]: any } = { filter = TextFilterRoblox.backend(textService) }
	for key, value in options or {} do
		opts[key] = value
	end
	return TextFilter.new(opts :: any, env)
end

test("prepare strips hostile characters and checks length in codepoints", function(t)
	t.eq({ TextFilter.prepare("  hello  ") }, { "hello", nil })
	t.eq({ TextFilter.prepare("a\0b\1c\127d") }, { "abcd", nil })
	t.eq({ TextFilter.prepare("line\nbreak") }, { "linebreak", nil })
	t.eq({ TextFilter.prepare("line\nbreak", nil, true) }, { "line\nbreak", nil })
	t.eq({ TextFilter.prepare("tab\there") }, { "tab here", nil })
	t.eq({ TextFilter.prepare("rtl\u{202E}override\u{200B}zero\u{FEFF}") }, { "rtloverridezero", nil })
	t.eq({ TextFilter.prepare("c1\u{0085}control") }, { "c1control", nil })
	t.eq({ TextFilter.prepare("\u{200B}\u{200B}") }, { nil, "empty" })
	t.eq({ TextFilter.prepare("   ") }, { nil, "empty" })
	t.eq({ TextFilter.prepare("") }, { nil, "empty" })
	t.eq({ TextFilter.prepare(5) }, { nil, "invalid" })
	t.eq({ TextFilter.prepare(nil) }, { nil, "invalid" })
	t.eq({ TextFilter.prepare("\xff\xfe") }, { nil, "invalid_utf8" })
	t.eq(
		{ TextFilter.prepare(string.rep("é", 10), 10) },
		{ string.rep("é", 10), nil },
		"10 codepoints, 20 bytes"
	)
	t.eq({ TextFilter.prepare(string.rep("é", 11), 10) }, { nil, "too_long" })
	t.eq(select(2, TextFilter.prepare(string.rep("a", 201))), "too_long")
end)

test("submit filters for broadcast and for one user, and fails closed", function(t)
	local env = FakeEnv.new()
	local service = FakeTextService.new({ blocked = { "badword" }, online = { 7, 8 } })
	local filter = pipeline(env, service)
	t.eq({
		run(env, function()
			return filter:submit(PLAYER, "a BadWord here")
		end),
	}, { true, "a ####### here", "ok" })
	t.eq({
		run(env, function()
			return filter:submit(PLAYER, "hi badword", 8)
		end),
	}, { true, "hi #######", "ok" })
	t.eq(service.calls[#service.calls].method, "GetNonChatStringForUserAsync")
	-- the recipient left: fail closed with empty text
	t.eq({
		run(env, function()
			return filter:submit(PLAYER, "hello", 99)
		end),
	}, { false, "", "filter_failed" })
	-- the author is not online (FilterStringAsync raises)
	t.eq({
		run(env, function()
			return filter:submit({ UserId = 50 }, "hello")
		end),
	}, { false, "", "filter_failed" })
	-- the service fails
	service:fail(1)
	t.eq({
		run(env, function()
			return filter:submit(PLAYER, "hello")
		end),
	}, { false, "", "filter_failed" })
	t.ok(#env.reports >= 3)
	-- a filter that returns a non-string
	local odd = TextFilter.new({
		filter = function(): any
			return nil
		end,
	}, env)
	t.eq({
		run(env, function()
			return odd:submit(PLAYER, "hello")
		end),
	}, { false, "", "filter_failed" })
	-- bad inputs never reach the service
	local before = #service.calls
	for _, case in
		{
			{ PLAYER, 42, nil, "invalid" },
			{ PLAYER, "\xff", nil, "invalid_utf8" },
			{ PLAYER, "   ", nil, "empty" },
			{ PLAYER, string.rep("x", 201), nil, "too_long" },
			{ PLAYER, "hello", 0, "invalid_audience" },
			{ PLAYER, "hello", "everyone", "invalid_audience" },
			{ {}, "hello", nil, "invalid" },
		}
	do
		local ok, text, reason = filter:submit(case[1], case[2], case[3] :: any)
		t.eq({ ok, text, reason }, { false, "", case[4] })
	end
	t.eq(#service.calls, before)
	t.eq(filter:counts().invalid, 2)
end)

test("submit rate-limits per player and forget resets it", function(t)
	local env = FakeEnv.new()
	local service = FakeTextService.new({ online = { 7, 8 } })
	local filter = pipeline(env, service, { rate = { capacity = 2, refillPerSec = 0.5 } })
	local function send(player: any): string
		return select(
			3,
			run(env, function()
				return filter:submit(player, "hello")
			end)
		)
	end
	t.eq(send(PLAYER), "ok")
	t.eq(send(PLAYER), "ok")
	t.eq(send(PLAYER), "rate")
	t.eq(send({ UserId = 8 }), "ok", "per player")
	filter:forget(PLAYER)
	t.eq(send(PLAYER), "ok")
	-- filter() for stored text has no rate limit
	for _ = 1, 5 do
		t.eq(
			select(
				3,
				run(env, function()
					return filter:filter("stored", 7, "broadcast")
				end)
			),
			"ok"
		)
	end
end)

test("TextFilter.new validates its options", function(t)
	local env = FakeEnv.new()
	local ok, err = pcall(TextFilter.new, { maxLength = 0 } :: any, env)
	t.ok(not ok and has(tostring(err), "filter(text") and has(tostring(err), "maxLength"))
	t.throws(function()
		TextFilter.new({ filter = function() end } :: any, nil)
	end)
end)

test("chat permission helpers fail closed", function(t)
	local chat = FakeTextService.chat({ blockedPairs = { { 1, 2 } } })
	t.eq(TextFilterRoblox.canChat(chat, 1, 3), true)
	t.eq(TextFilterRoblox.canChat(chat, 2, 1), false)
	t.eq(TextFilterRoblox.canDirectChat(chat, 1, { 2, 3, 4 }), { 3, 4 })
	local down = FakeTextService.chat({ fail = true })
	t.eq(TextFilterRoblox.canChat(down, 1, 3), false)
	t.eq(TextFilterRoblox.canDirectChat(down, 1, { 3 }), {})
	-- an answer listing users that were not asked about is filtered out
	local liar = {
		CanUsersDirectChatAsync = function(): any
			return { 3, 99, "x" }
		end,
	}
	t.eq(TextFilterRoblox.canDirectChat(liar, 1, { 3 }), { 3 })
	-- a context is passed through
	local service = FakeTextService.new({ online = { 7 } })
	TextFilterRoblox.backend(service, { context = "PublicChat" })("hi", 7, "broadcast")
	t.eq(service.calls[1].args[3], "PublicChat")
end)

-- ---------------------------------------------------------------- Moderation

local function banRequest(extra: { [string]: any }?): any
	local request: { [string]: any } = {
		userIds = { 11, 12 },
		duration = 3600,
		displayReason = "Broke a rule",
		privateReason = "report 42",
	}
	for key, value in extra or {} do
		request[key] = value
	end
	return request
end

test("banRequest builds the BanAsync config or lists every problem", function(t)
	local config, problems = Moderation.banRequest(banRequest())
	t.eq(problems, {})
	t.eq(config, {
		UserIds = { 11, 12 },
		ApplyToUniverse = true,
		Duration = 3600,
		DisplayReason = "Broke a rule",
		PrivateReason = "report 42",
		ExcludeAltAccounts = false,
	})
	local permanent =
		Moderation.banRequest(banRequest({ duration = Moderation.PERMANENT, applyToUniverse = false }))
	t.eq({ permanent.Duration, permanent.ApplyToUniverse }, { -1, false })
	local _, all = Moderation.banRequest({
		userIds = { 0, 5, 5 },
		duration = 1.5,
		displayReason = string.rep("x", 401),
		privateReason = "",
		excludeAltAccounts = "no",
	})
	local text = table.concat(all, "\n")
	for _, needle in
		{
			"integers > 0",
			"repeats 5",
			"duration",
			"displayReason is 401 characters",
			"privateReason must be",
			"excludeAltAccounts",
		}
	do
		t.ok(has(text, needle), needle .. "\n" .. text)
	end
	local many = {}
	for index = 1, 51 do
		many[index] = index
	end
	t.eq(
		select(2, Moderation.banRequest(banRequest({ userIds = many })))[1],
		"userIds must list 1 to 50 user ids"
	)
	t.eq(select(2, Moderation.banRequest(nil))[1], "request must be a table")
	t.eq(#select(2, Moderation.banRequest(banRequest({ displayReason = "\xff" }))), 1)
end)

test("a ladder from game data decides the next action", function(t)
	local ladder = Moderation.ladder({
		{ after = 1, action = "warn" },
		{ after = 3, action = "kick" },
		{ after = 5, action = "ban", duration = 86400 },
		{ after = 8, action = "ban", duration = Moderation.PERMANENT },
	})
	t.eq(Moderation.decide(ladder, 0), nil)
	t.eq(Moderation.decide(ladder, 1).action, "warn")
	t.eq(Moderation.decide(ladder, 4).action, "kick")
	t.eq(Moderation.decide(ladder, 6).duration, 86400)
	t.eq(Moderation.decide(ladder, 100).duration, -1)
	t.throws(function()
		Moderation.decide(ladder, -1)
	end)
	for _, bad in
		{
			{},
			{ { after = 0, action = "warn" } },
			{ { after = 2, action = "warn" }, { after = 2, action = "kick" } },
			{ { after = 1, action = "mute" } },
			{ { after = 1, action = "ban" } },
			{ { after = 1, action = "kick", duration = 5 } },
		}
	do
		t.throws(function()
			Moderation.ladder(bad :: any)
		end)
	end
end)

test("ModerationRoblox refuses in Studio, without confirmation and with bad requests", function(t)
	local calls = {}
	local players = {
		BanAsync = function(_self: any, config: any)
			table.insert(calls, { "ban", config })
		end,
		UnbanAsync = function(_self: any, config: any)
			table.insert(calls, { "unban", config })
		end,
		GetBanHistoryAsync = function(_self: any, userId: number): any
			if userId == 0 then
				error("bad user")
			end
			return { userId = userId }
		end,
	}
	local studio =
		{ place = { isStudio = true, gameId = 0, placeId = 0 }, confirm = ModerationRoblox.CONFIRM }
	local live = { place = { isStudio = false, gameId = 1, placeId = 2 }, confirm = ModerationRoblox.CONFIRM }
	local unconfirmed = { place = live.place }
	t.eq({ ModerationRoblox.ban(players, banRequest(), studio) }, { false, "studio_refused", nil })
	t.eq({ ModerationRoblox.ban(players, banRequest(), unconfirmed :: any) }, { false, "not_confirmed", nil })
	t.eq({ ModerationRoblox.ban(players, banRequest(), {} :: any) }, { false, "no_place", nil })
	local ok, reason, detail = ModerationRoblox.ban(players, banRequest({ duration = 0 }), live)
	t.eq({ ok, reason }, { false, "invalid_request" })
	t.ok(#detail >= 1)
	t.eq(#calls, 0, "nothing reached BanAsync")
	t.eq({ ModerationRoblox.ban(players, banRequest(), live) }, { true, nil, nil })
	t.eq(calls[1][2].UserIds, { 11, 12 })
	t.eq({ ModerationRoblox.unban(players, { 11 }, nil, studio) }, { false, "studio_refused", nil })
	t.eq(
		{ ModerationRoblox.unban(players, {}, nil, live) },
		{ false, "invalid_request", { "userIds must list 1 to 50 user ids" } }
	)
	t.ok(ModerationRoblox.unban(players, { 11 }, false, live))
	t.eq(calls[2][2], { UserIds = { 11 }, ApplyToUniverse = false })
	local failing = {
		BanAsync = function()
			error("HTTP 403")
		end,
	}
	local failed, why, message = ModerationRoblox.ban(failing, banRequest(), live)
	t.eq({ failed, why }, { false, "ban_failed" })
	t.ok(has(message, "HTTP 403"))
	t.eq(ModerationRoblox.history(players, 5), { userId = 5 })
	t.eq(select(2, ModerationRoblox.history(players, 0)) ~= nil, true)
end)

return cases
