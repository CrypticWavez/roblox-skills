--!strict
-- GameKit/Progression (curves, levels, prestige, rewards), GameKit/Objectives (counters,
-- filters, prerequisites, claim once, daily and weekly resets) and GameKit/Streaks (UTC day
-- boundaries, grace days, reset and decay, clock skew).
local Events = require("../packages/GameKit/Events")
local Objectives = require("../packages/GameKit/Objectives")
local Progression = require("../packages/GameKit/Progression")
local Streaks = require("../packages/GameKit/Streaks")

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

local DAY = 86400
-- 2026-10-06T00:00:00Z
local T0 = 1791244800

-- ---------------------------------------------------------------- curves

test("linear, power and table curves give whole requirements and cumulative totals", function(t)
	local linear = Progression.curve({ kind = "linear", base = 10, step = 5, maxLevel = 4 })
	t.eq(
		{ linear:xpToNext(1), linear:xpToNext(2), linear:xpToNext(3), linear:xpToNext(4) },
		{ 10, 15, 20, 0 }
	)
	t.eq(
		{ linear:totalFor(1), linear:totalFor(2), linear:totalFor(4), linear:totalFor(99) },
		{ 0, 10, 45, 45 }
	)
	local power = Progression.curve({ kind = "power", base = 2.5, exponent = 1.5, maxLevel = 5 })
	t.eq(power:xpToNext(1), 2)
	t.eq(power:xpToNext(4), 20, "floor(2.5 * 4^1.5)")
	local tbl = Progression.curve({ kind = "table", requirements = { 3, 4, 5 } })
	t.eq(tbl.maxLevel, 4)
	t.eq({ tbl:levelFor(0) }, { 1, 0, 3 })
	t.eq({ tbl:levelFor(2) }, { 1, 2, 3 })
	t.eq({ tbl:levelFor(3) }, { 2, 0, 4 })
	t.eq({ tbl:levelFor(11) }, { 3, 4, 5 })
	t.eq({ tbl:levelFor(12) }, { 4, 0, 0 })
	t.eq({ tbl:levelFor(1e9) }, { 4, 1e9 - 12, 0 })
end)

test("curve validation refuses bad specs and cumulative overflow", function(t)
	t.ok(contains(Progression.validateCurve({ kind = "cubic" }), "kind must be"))
	t.ok(contains(Progression.validateCurve({ kind = "linear", base = 0, step = 1, maxLevel = 2 }), "base"))
	t.ok(contains(Progression.validateCurve({ kind = "linear", base = 1, step = -1, maxLevel = 2 }), "step"))
	t.ok(
		contains(Progression.validateCurve({ kind = "linear", base = 1, step = 0, maxLevel = 0 }), "maxLevel")
	)
	t.ok(
		contains(
			Progression.validateCurve({ kind = "power", base = 1, exponent = 0 / 0, maxLevel = 3 }),
			"exponent"
		)
	)
	t.ok(contains(Progression.validateCurve({ kind = "table", requirements = { 1, 0 } }), "requirement 2"))
	t.ok(
		contains(
			Progression.validateCurve({ kind = "table", requirements = { 1 }, maxLevel = 5 }),
			"maxLevel must equal"
		)
	)
	t.ok(
		contains(
			Progression.validateCurve({ kind = "power", base = 1e15, exponent = 3, maxLevel = 100 }),
			"is not a whole number"
		)
			or contains(
				Progression.validateCurve({ kind = "power", base = 1e15, exponent = 3, maxLevel = 100 }),
				"passes 2^53"
			)
	)
	t.ok(
		contains(
			Progression.validateCurve({ kind = "linear", base = 2 ^ 52, step = 0, maxLevel = 4 }),
			"passes 2^53"
		)
	)
	t.throws(function()
		Progression.curve({ kind = "linear" })
	end)
end)

-- ---------------------------------------------------------------- tracks

test("addXp crosses several levels, lists rewards, fires leveled and emits one event", function(t)
	local sink = Events.recorder()
	local curve = Progression.curve({ kind = "linear", base = 10, step = 0, maxLevel = 5 })
	local track = Progression.new({
		curve = curve,
		path = "level_track",
		rewards = { [3] = { grant = "reward_a" }, [5] = { grant = "reward_b" } },
		sink = sink,
		player = "7",
	})
	local leveled = {}
	track.leveled:Connect(function(level, reward)
		table.insert(leveled, { level, reward and reward.grant })
	end)
	local ok, err, result = track:addXp(25)
	t.ok(ok and err == nil)
	t.eq(result.from, 1)
	t.eq(result.to, 3)
	t.eq(result.rewards, { { level = 3, reward = { grant = "reward_a" } } })
	t.eq(leveled, { { 2, nil }, { 3, "reward_a" } })
	t.eq(sink:count("progression"), 1)
	local event = sink.events[1]
	t.eq(event.progression, { path = "level_track", status = "complete", level = 3 })
	t.eq(event.fields, { gained = "2" })
	t.eq(Events.validate(event), {})
	t.eq(track:progress(), { level = 3, into = 5, needed = 10, fraction = 0.5, maxed = false })
	local _, _, capped = track:addXp(100)
	t.eq({ capped.applied, capped.discarded, capped.to }, { 15, 85, 5 })
	t.ok(track:progress().maxed)
	t.eq({ track:addXp(0) }, { false, "invalid_amount", nil })
	t.eq({ track:addXp(1.5) }, { false, "invalid_amount", nil })
	local _, _, none = track:addXp(1)
	t.eq(none.applied, 0)
	t.eq(sink:count(), 2, "no event without a level gained")
end)

test("prestige needs the option and max level, honours the cap and round-trips", function(t)
	local sink = Events.recorder()
	local curve = Progression.curve({ kind = "table", requirements = { 5 } })
	local plain = Progression.new({ curve = curve, path = "track_a" })
	plain:addXp(5)
	t.eq({ plain:prestige() }, { false, "not_enabled" })
	local track = Progression.new({ curve = curve, path = "track_a", prestige = { max = 1 }, sink = sink })
	t.eq({ track:prestige() }, { false, "not_max_level" })
	track:addXp(5)
	t.eq({ track:prestige() }, { true, nil })
	t.eq({ track:level(), track:prestiges(), track:xp() }, { 1, 1, 0 })
	track:addXp(5)
	t.eq({ track:prestige() }, { false, "prestige_cap" })
	t.eq(sink:named("prestige")[1].progression.level, 1)
	local restored = Progression.new({ curve = curve, path = "track_a", data = track:serialize() })
	t.eq({ restored:level(), restored:prestiges() }, { 2, 1 })
	local repaired = Progression.new({
		curve = curve,
		path = "track_a",
		data = { schema = "progression/1", xp = 999, prestige = -1 },
	})
	t.eq(repaired:xp(), 5)
	t.ok(contains(repaired.notes, "clamped") and contains(repaired.notes, "prestige reset"))
	t.throws(function()
		Progression.new({ curve = curve, path = "Bad Path" } :: any)
	end)
	t.throws(function()
		Progression.new({ curve = {}, path = "a" } :: any)
	end)
	t.throws(function()
		Progression.new({ curve = curve, path = "a", rewards = { [1] = {} } } :: any)
	end)
end)

-- ---------------------------------------------------------------- objectives

local function defs()
	return {
		{ id = "collect_a", counter = "collect", target = 5, reward = { grant = "reward_a" } },
		{ id = "defeat_basic", counter = "defeat", target = 2, filter = { kind = "enemy_basic" } },
		{ id = "chain_b", counter = "collect", target = 3, requires = { "collect_a" } },
		{ id = "best_score", counter = "score", target = 100, mode = "max" },
		{ id = "daily_a", counter = "play", target = 1, reset = "daily" },
		{ id = "weekly_a", counter = "play", target = 3, reset = "weekly" },
	}
end

test("objective definitions are validated, including requires cycles", function(t)
	t.eq(Objectives.validate(defs()), {})
	local problems = Objectives.validate({
		{ id = "a", counter = "c", target = 0 },
		{ id = "a", counter = "C", target = 1 },
		{ id = "b", counter = "c", target = 1, requires = { "missing" }, mode = "avg", reset = "hourly" },
		{ id = "x", counter = "c", target = 1, requires = { "y" } },
		{ id = "y", counter = "c", target = 1, requires = { "x" } },
		{ id = "z", counter = "c", target = 1, filter = { kind = {} }, price = 1 },
	})
	for _, needle in
		{
			"objective a: target must be an integer >= 1",
			"objective a: duplicate id",
			'counter "C" is not a label',
			'requires unknown objective "missing"',
			"mode must be sum, max or latest",
			"reset must be never, daily or weekly",
			"requires cycle: x -> y -> x",
			'filter "kind" must map',
			'unknown key "price"',
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	t.throws(function()
		Objectives.define({ { id = "a" } })
	end)
end)

test("counters, filters, prerequisites and claim-once", function(t)
	local sink = Events.recorder()
	local tracker = Objectives.new(Objectives.define(defs()), { sink = sink, player = "3" })
	t.eq(tracker:state("chain_b"), "locked")
	t.eq(tracker:record("collect", 4), {})
	t.eq(tracker:record("defeat", 5, { kind = "enemy_other" }), {}, "filter does not match")
	t.eq(tracker:record("defeat", 1), {}, "no context, no match")
	t.eq(tracker:record("collect", 3), { "collect_a" })
	t.eq({ tracker:progress("collect_a") }, { 7, 5 })
	t.eq(tracker:state("chain_b"), "tracked", "prerequisite completed")
	t.eq({ tracker:progress("chain_b") }, { 0, 3 }, "records before unlock do not count")
	t.eq(tracker:record("defeat", 2, { kind = "enemy_basic", zone = "zone_a" }), { "defeat_basic" })
	t.eq(tracker:record("score", 80), {})
	t.eq(tracker:record("score", 40), {}, "max keeps the best")
	t.eq(tracker:record("score", 120), { "best_score" })
	t.eq({ tracker:claim("collect_a") }, { true, nil, { grant = "reward_a" } })
	t.eq({ tracker:claim("collect_a") }, { false, "already_claimed", nil })
	t.eq({ tracker:claim("chain_b") }, { false, "not_completed", nil })
	t.eq({ tracker:claim("nope") }, { false, "unknown", nil })
	t.eq(sink:count("progression"), 3)
	t.eq(sink:named("objective_claimed")[1].fields, { objective = "collect_a" })
	for _, event in sink.events do
		t.eq(Events.validate(event), {})
	end
	t.throws(function()
		tracker:record("collect", -1)
	end)
	local list = tracker:list()
	t.eq(#list, 6)
	t.eq(list[1].state, "claimed")
end)

test("daily and weekly objectives restart on UTC boundaries and round-trip", function(t)
	local tracker = Objectives.new(Objectives.define(defs()))
	t.eq(tracker:refresh(T0 + 10), {})
	tracker:record("play", 1)
	t.eq(tracker:state("daily_a"), "completed")
	t.eq(tracker:refresh(T0 + DAY - 1), {}, "23:59:59 is still the same day")
	t.eq(tracker:refresh(T0 + DAY), { "daily_a" }, "00:00:00 next day restarts the daily")
	t.eq(tracker:state("daily_a"), "tracked")
	t.eq({ tracker:progress("weekly_a") }, { 1, 3 }, "weekly kept within the week")
	-- 2026-10-06 is a Tuesday; the week turns at Monday 2026-10-12 00:00 UTC.
	t.eq(tracker:refresh(T0 + 5 * DAY + 3600), { "daily_a" })
	t.eq(tracker:refresh(T0 + 6 * DAY), { "daily_a", "weekly_a" })
	tracker:record("play", 1)
	local restored = Objectives.new(Objectives.define(defs()), { data = tracker:serialize() })
	t.eq(restored:serialize(), tracker:serialize())
	local dropped = Objectives.new(
		Objectives.define(defs()),
		{ data = { schema = "objectives/1", entries = { retired = { progress = 1 } } } }
	)
	t.ok(contains(dropped.notes, 'dropped unknown objective "retired"'))
end)

-- ---------------------------------------------------------------- streaks

test("dayIndex, weekIndex and nextReset at UTC boundaries and with an offset", function(t)
	t.eq(Streaks.dayIndex(T0), 20732)
	t.eq(Streaks.dayIndex(T0 - 1), 20731)
	t.eq(Streaks.dayIndex(T0 - 1, 1), 20732, "offset moves the reset")
	t.eq(Streaks.dayIndex(T0, -3600), 20731)
	t.eq(Streaks.weekIndex(T0 + 5 * DAY), Streaks.weekIndex(T0), "Sunday is the same week")
	t.eq(Streaks.weekIndex(T0 + 6 * DAY), Streaks.weekIndex(T0) + 1, "Monday starts a new week")
	t.eq(Streaks.nextReset(T0 + 3600), DAY - 3600)
	t.eq(Streaks.nextReset(T0, -3600), 3600, "reset at 01:00 UTC is an hour away")
	t.throws(function()
		Streaks.dayIndex(0 / 0)
	end)
	t.throws(function()
		Streaks.dayIndex(T0, DAY)
	end)
end)

test("check-ins continue across midnight, ignore same-day repeats and reset after a miss", function(t)
	local sink = Events.recorder()
	local streak =
		Streaks.new({ sink = sink, player = "9", rewards = { [1] = "reward_1", [2] = "reward_2" } })
	local first = streak:checkIn(T0 + DAY - 1)
	t.eq({ first.status, first.streak, first.reward }, { "started", 1, "reward_1" })
	local second = streak:checkIn(T0 + DAY)
	t.eq({ second.status, second.streak, second.reward }, { "continued", 2, "reward_2" })
	t.eq(streak:checkIn(T0 + DAY + 50).status, "already")
	local missed = streak:checkIn(T0 + 3 * DAY)
	t.eq({ missed.status, missed.streak, missed.missed, missed.best }, { "reset", 1, 1, 2 })
	t.eq(streak:checkIn(T0).status, "clock_skew")
	t.eq(streak:streak(), 1, "clock skew never punishes")
	t.eq(streak:total(), 3)
	t.eq(sink:count("custom"), 3)
	t.eq(sink.events[2].value, 2)
	t.eq(Events.validate(sink.events[1]), {})
end)

test("grace days, decay, caps, reward cycles and persistence", function(t)
	local grace = Streaks.new({ graceDays = 1 })
	grace:checkIn(T0)
	local kept = grace:checkIn(T0 + 2 * DAY)
	t.eq({ kept.status, kept.streak, kept.grace }, { "continued", 2, true })
	t.eq(grace:checkIn(T0 + 5 * DAY).status, "reset")
	local decay =
		Streaks.new({ onMiss = "decay", decay = 2, max = 4, cycle = 3, rewards = { "r1", "r2", "r3" } })
	for day = 0, 4 do
		decay:checkIn(T0 + day * DAY)
	end
	t.eq(decay:streak(), 4, "capped at max")
	local decayed = decay:checkIn(T0 + 7 * DAY)
	t.eq({ decayed.status, decayed.streak, decayed.reward }, { "decayed", 3, "r3" })
	local next_ = decay:checkIn(T0 + 8 * DAY)
	t.eq(next_.reward, "r1", "rewards cycle every 3 days")
	local restored = Streaks.new({ data = decay:serialize() })
	t.eq(restored:serialize(), decay:serialize())
	t.eq(restored:checkIn(T0 + 9 * DAY).status, "continued")
	local peeked = restored:peek(T0 + 10 * DAY)
	t.eq(restored:lastDay(), Streaks.dayIndex(T0 + 9 * DAY), "peek changes nothing")
	t.eq(peeked.status, "continued")
	t.ok(contains(Streaks.validate({ graceDays = -1, onMiss = "x", offset = 0.5 }), "graceDays"))
	t.ok(contains(Streaks.validate({ onMiss = "x" }), "onMiss"))
	t.throws(function()
		Streaks.new({ max = 0 })
	end)
	local bad = Streaks.new({ data = { schema = "streaks/1", streak = -2 } })
	t.ok(contains(bad.notes, "streak was invalid"))
end)

return cases
