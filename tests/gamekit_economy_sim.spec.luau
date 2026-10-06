--!strict
-- GameKit/EconomySim: same seed same percentiles, an exact closed-form loop, caps and waste,
-- needs/limit/chance/offline/horizon, conservation, target checks and validation failures.
-- All numbers here are neutral fixture numbers.
local EconomySim = require("../packages/GameKit/EconomySim")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

-- A fixed loop: 0.5 currency_a per second, a 50 currency_a spend every 120 s, 600 s sessions.
local function fixed(extra: { [string]: any }?): any
	local options: any = {
		seed = 1,
		players = 3,
		sessions = { count = 2, seconds = 600 },
		currencies = { currency_a = {} },
		rates = { currency_a = 0.5 },
		actions = { { id = "spend_a", every = 120, spend = { currency_a = 50 } } },
		milestones = {
			{ id = "balance_100", currency = "currency_a", threshold = 100 },
			{ id = "earned_450", currency = "currency_a", threshold = 450, measure = "earned" },
		},
	}
	for key, value in extra or {} do
		options[key] = value
	end
	return options
end

-- A random loop for determinism and conservation checks.
local function random(seed: number | string): any
	return {
		seed = seed,
		players = 200,
		sessions = { count = 5, seconds = { min = 300, max = 1800 }, gap = { min = 600, max = 86400 } },
		currencies = { currency_a = { initial = 10 }, currency_b = { cap = 500 } },
		rates = { currency_a = 0.25 },
		offline = { currency_b = { perSecond = 0.01, capSeconds = 28800 } },
		actions = {
			{
				id = "earn_a",
				every = { min = 20, max = 90 },
				chance = 0.8,
				earn = { currency_a = { min = 1, max = 6 } },
			},
			{
				id = "convert",
				every = { min = 60, max = 240 },
				spend = { currency_a = 25 },
				earn = { currency_b = 3 },
			},
			{
				id = "spend_b",
				every = 300,
				spend = { currency_b = { min = 5, max = 15 } },
				needs = { currency_a = 5 },
			},
		},
		milestones = {
			{ id = "a_200", currency = "currency_a", threshold = 200, measure = "earned" },
			{ id = "b_50", currency = "currency_b", threshold = 50 },
		},
	}
end

test("nearest-rank percentiles", function(t)
	local list = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
	t.eq(EconomySim.percentile(list, 10), 1)
	t.eq(EconomySim.percentile(list, 50), 5)
	t.eq(EconomySim.percentile(list, 90), 9)
	t.eq(EconomySim.percentile(list, 100), 10)
	t.eq(EconomySim.percentile({}, 50), nil)
	t.eq(EconomySim.percentile({ 1, math.huge }, 90), nil, "unreached values are not a time")
end)

test("a fixed loop gives exact sources, sinks, inflation and milestones", function(t)
	local report = EconomySim.run(fixed())
	t.eq(report.schema, "economy-sim/1")
	local a = report.currencies.currency_a
	-- Per player per session: 300 passive, 5 spends of 50; balance 50 then 100.
	t.eq(a.sourced, 3 * 600)
	t.eq(a.sunk, 3 * 500)
	t.eq(a.sources, { passive = 1800 })
	t.eq(a.sinks, { spend_a = 1500 })
	t.eq(a.sinkRatio, 0.8333)
	t.eq(a.endBalance, { p10 = 100, p50 = 100, p90 = 100 })
	t.eq(a.netPerHour.p50, 300, "100 units over 1200 play seconds")
	t.eq(a.bySession, {
		{ session = 1, players = 3, balance = 50, sourced = 300, sunk = 250 },
		{ session = 2, players = 3, balance = 100, sourced = 600, sunk = 500 },
	})
	t.eq(report.actions.spend_a, { fired = 30, blocked = 0, skipped = 0, limited = 0, blockedBy = {} })
	t.eq(report.playSeconds, { p10 = 1200, p50 = 1200, p90 = 1200 })
	-- Balance reaches 100 at the end of session 1 just before the last spend.
	local balance = report.milestones.balance_100
	t.eq(balance.reached, 1)
	t.eq(balance.playSeconds, { p10 = 600, p50 = 600, p90 = 600 })
	t.eq(balance.sessions, { p10 = 1, p50 = 1, p90 = 1 })
	t.eq(report.milestones.earned_450.playSeconds.p50, 900)
	t.eq(report.milestones.earned_450.sessions.p50, 2)
	t.eq(report.warnings, {})
	t.ok(#EconomySim.summary(report) >= 3)
end)

test("the same seed gives the same report; another seed differs", function(t)
	local first = EconomySim.run(random(42))
	t.eq(EconomySim.run(random(42)), first)
	local other = EconomySim.run(random(43))
	t.ok(
		other.currencies.currency_a.sourced ~= first.currencies.currency_a.sourced
			or other.milestones.a_200.playSeconds.p50 ~= first.milestones.a_200.playSeconds.p50,
		"a new seed changes the curves"
	)
	t.ok(first.milestones.a_200.reached > 0 and first.milestones.a_200.reached <= 1)
	local p = first.currencies.currency_a.netPerHour
	t.ok(p.p10 <= p.p50 and p.p50 <= p.p90, "percentiles are ordered")
end)

test("currency is conserved: initial + sourced - sunk = end balances", function(t)
	local report = EconomySim.run(random("conservation"))
	for id, initial in { currency_a = 10, currency_b = 0 } do
		local c = report.currencies[id]
		local last = c.bySession[#c.bySession]
		t.eq(last.players, 200)
		local expected = (initial * 200 + c.sourced - c.sunk) / 200
		t.near(last.balance, expected, 1e-4, id)
		local fromSources = 0
		for _, amount in c.sources do
			fromSources += amount
		end
		t.eq(fromSources, c.sourced, id .. " sources add up")
		local fromSinks = 0
		for _, amount in c.sinks do
			fromSinks += amount
		end
		t.eq(fromSinks, c.sunk, id .. " sinks add up")
	end
	t.ok(report.currencies.currency_b.sources.offline > 0, "offline earnings between sessions")
	t.ok(report.actions.earn_a.skipped > 0, "chance skips some firings")
	t.ok(report.actions.spend_b.blocked > 0, "needs and funds block some firings")
end)

test("caps clamp and report waste; reject caps block the action", function(t)
	local clamp = EconomySim.run(fixed({
		currencies = { currency_a = { cap = 100 } },
		actions = {},
		milestones = {},
		players = 1,
	}))
	t.eq(clamp.currencies.currency_a.sourced, 100)
	t.eq(clamp.currencies.currency_a.wasted, 500)
	t.ok(contains(clamp.warnings, "currency_a: 500 units wasted at the cap"))
	t.ok(contains(clamp.warnings, "currency_a: sourced but never sunk"))
	local reject = EconomySim.run({
		seed = 1,
		players = 1,
		sessions = { count = 1, seconds = 100 },
		currencies = { currency_a = { cap = 25, overflow = "reject" } },
		actions = { { id = "earn_a", every = 10, earn = { currency_a = 10 } } },
	})
	t.eq(reject.actions.earn_a.fired, 2)
	t.eq(reject.actions.earn_a.blocked, 8)
	t.eq(reject.actions.earn_a.blockedBy, { at_cap = 8 })
	t.eq(reject.currencies.currency_a.wasted, 0)
end)

test("limits, needs, horizon and targets", function(t)
	local report = EconomySim.run(fixed({
		horizon = 900,
		actions = {
			{ id = "spend_a", every = 120, limit = 2, spend = { currency_a = 50 } },
			{ id = "gated", every = 60, needs = { currency_a = 1000 }, earn = { currency_a = 1 } },
		},
		targets = { currency_a = { sinkRatio = { min = 0.1, max = 0.3 }, netPerHour = { min = 0 } } },
	}))
	t.eq(report.playSeconds.p50, 900, "the horizon cuts session 2 at 300 s")
	t.eq(report.actions.spend_a.fired, 3 * 4, "two per session")
	t.ok(report.actions.spend_a.limited > 0)
	t.eq(report.actions.gated.fired, 0)
	t.eq(report.actions.gated.blockedBy.needs, report.actions.gated.blocked)
	t.ok(contains(report.warnings, "action gated never fired"))
	-- sourced 450, sunk 200 per player: ratio 0.4444 is outside 0.1..0.3.
	t.eq(report.currencies.currency_a.sinkRatio, 0.4444)
	t.eq(report.checks[1], {
		currency = "currency_a",
		metric = "sinkRatio",
		value = 0.4444,
		min = 0.1,
		max = 0.3,
		ok = false,
	})
	t.eq(report.checks[2].metric, "netPerHour.p50")
	t.eq(report.checks[2].ok, true)
	t.eq(report.ok, false)
	t.ok(contains(EconomySim.summary(report), "check currency_a sinkRatio=0.4444 FAIL"))
end)

test("invalid options are refused with every problem listed", function(t)
	t.ok(contains(EconomySim.validate(nil), "options must be a table"))
	local bad = fixed({
		seed = true,
		players = 0,
		sessions = { count = 0, seconds = { min = 10, max = 5 }, gap = -1 },
		horizon = 0,
		currencies = { currency_a = { initial = -1, cap = 0, overflow = "drop" }, ["Bad Id"] = {} },
		rates = { currency_z = 1, currency_a = -1 },
		offline = { currency_a = { perSecond = 1 } },
		actions = {
			{ id = "x", every = 0, chance = 1.5, limit = 0, earn = { currency_q = 1 } },
			{ id = "x", every = 10 },
			{ id = "y", every = 10, spend = { currency_a = -2 }, needs = { currency_a = 0.5 }, price = 1 },
		},
		milestones = { { id = "m", currency = "currency_a", threshold = 0, measure = "peak" } },
		targets = { currency_a = { sinkRatio = { min = 2, max = 1 } } },
		percentiles = { 0 },
		step = 0,
	})
	local problems = EconomySim.validate(bad)
	for _, needle in
		{
			"seed is required",
			"players must be an integer",
			"sessions.count must be an integer >= 1",
			"sessions.seconds must be",
			"sessions.gap must be",
			"horizon must be",
			"initial must be an integer >= 0",
			"cap must be an integer >= 1",
			"overflow must be clamp or reject",
			"id must be a label",
			'rates: unknown currency "currency_z"',
			"rates.currency_a must be a finite number >= 0",
			"offline.currency_a must be",
			"action x: every must be",
			"action x: chance must be in (0, 1]",
			"action x: limit must be",
			'action x earn: unknown currency "currency_q"',
			"action x: duplicate id",
			"action x: needs earn or spend",
			"action y: spend.currency_a must be",
			"action y: needs.currency_a must be",
			'action y: unknown key "price"',
			"milestone m: threshold must be",
			"milestone m: measure must be balance or earned",
			"targets.currency_a.sinkRatio min is above max",
			"percentiles must be",
			"step must be",
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	t.throws(function()
		EconomySim.run(bad)
	end)
	local heavy = random(1)
	heavy.players = 100000
	heavy.sessions.count = 1000
	t.ok(contains(EconomySim.validate(heavy), "passes maxEvents"))
end)

return cases
