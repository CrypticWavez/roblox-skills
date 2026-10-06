--!strict
-- GameKit/SeasonTrack: season validation (no prices), tiers, the UTC window, free and premium
-- claims (once, premium retroactive), a new season resetting data, and events.
local Events = require("../packages/GameKit/Events")
local SeasonTrack = require("../packages/GameKit/SeasonTrack")

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

local T0 = 1791244800 -- 2026-10-06T00:00:00Z
local DAY = 86400

local function season(): any
	return {
		id = "season_a",
		start = "2026-10-06T00:00:00Z",
		["end"] = "2026-10-20T00:00:00Z",
		tiers = {
			{ xp = 100, free = { reward = "reward_a" } },
			{ xp = 150, premium = { reward = "reward_b" } },
			{ xp = 200, free = { reward = "reward_c" }, premium = { reward = "reward_d" } },
		},
	}
end

test("a season validates and defines cumulative thresholds", function(t)
	t.eq(SeasonTrack.validate(season()), {})
	local spec = SeasonTrack.define(season())
	t.eq(spec.cumulative, { 0, 100, 250, 450 })
	t.eq(spec.start, T0)
	t.eq(spec.finish, T0 + 14 * DAY)
	t.ok(table.isfrozen(spec))
end)

test("bad seasons are rejected, including prices on tiers", function(t)
	local bad = season()
	bad.id = "Season A"
	bad.tiers[2].xp = 0
	bad.tiers[3].price = 5
	bad["end"] = "2026-10-01T00:00:00Z"
	local problems = SeasonTrack.validate(bad)
	for _, needle in
		{
			"id must be a label",
			"tier 2: xp must be an integer >= 1",
			'tier 3: unknown key "price" (no prices here)',
			"end must be after start",
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	t.ok(contains(SeasonTrack.validate({ id = "s", tiers = {} }), "tiers must be a non-empty list"))
	t.ok(contains(SeasonTrack.validate({ id = "s", tiers = { { xp = 1 } }, start = "soon" }), "UTC seconds"))
	t.throws(function()
		SeasonTrack.define(bad)
	end)
	t.throws(function()
		SeasonTrack.new(season())
	end)
end)

test("xp only counts inside the window and tiers cap at the top", function(t)
	local sink = Events.recorder()
	local pass = SeasonTrack.new(SeasonTrack.define(season()), { sink = sink, player = "1" })
	t.eq({ pass:addXp(50, T0 - 1) }, { false, "season_closed", nil })
	t.eq({ pass:addXp(50) }, { false, "season_closed", nil }, "a windowed season needs the time")
	t.eq({ pass:addXp(0, T0) }, { false, "invalid_amount", nil })
	t.eq({ pass:addXp(1.5, T0) }, { false, "invalid_amount", nil })
	local ok, _, info = pass:addXp(260, T0 + DAY)
	t.ok(ok)
	t.eq(info, { from = 0, to = 2, applied = 260 })
	t.eq(pass:progress(), { tier = 2, into = 10, needed = 200, maxed = false })
	local _, _, capped = pass:addXp(1000, T0 + 2 * DAY)
	t.eq(capped, { from = 2, to = 3, applied = 190 })
	t.eq(pass:progress(), { tier = 3, into = 0, needed = 0, maxed = true })
	t.eq({ pass:addXp(10, T0 + 14 * DAY) }, { false, "season_closed", nil }, "end is exclusive")
	local tiers = sink:named("season_tier")
	t.eq(#tiers, 2)
	t.eq(tiers[2].progression, { path = "season_a", status = "complete", level = 3 })
	t.eq(tiers[2].player, "1")
end)

test("claims happen once per tier and track; premium is retroactive", function(t)
	local sink = Events.recorder()
	local pass = SeasonTrack.new(SeasonTrack.define(season()), { sink = sink })
	t.eq({ pass:claim(1, "free") }, { false, "not_reached", nil })
	pass:addXp(450, T0)
	t.eq(pass:claimable(), {
		{ tier = 1, track = "free", reward = { reward = "reward_a" } },
		{ tier = 3, track = "free", reward = { reward = "reward_c" } },
	})
	t.eq({ pass:claim(2, "premium") }, { false, "premium_required", nil })
	t.eq({ pass:claim(2, "free") }, { false, "no_reward", nil })
	t.eq({ pass:claim(4, "free") }, { false, "unknown_tier", nil })
	t.eq({ pass:claim(1, "gold") }, { false, "bad_track", nil })
	t.eq({ pass:claim(1, "free") }, { true, nil, { reward = "reward_a" } })
	t.eq({ pass:claim(1, "free") }, { false, "already_claimed", nil })
	pass:setPremium(true)
	t.ok(pass:isPremium())
	local all = pass:claimAll()
	t.eq(#all, 3)
	t.eq(all[1], { tier = 2, track = "premium", reward = { reward = "reward_b" } })
	t.eq(pass:claimable(), {})
	t.eq(#sink:named("season_claim"), 4)
	t.eq(sink:named("season_claim")[1].fields, { track = "free", season = "season_a" })
end)

test("saved data round trips; premium is not stored; a new season starts fresh", function(t)
	local spec = SeasonTrack.define(season())
	local pass = SeasonTrack.new(spec, { premium = true })
	pass:addXp(300, T0)
	pass:claim(2, "premium")
	local data = pass:serialize()
	t.eq(
		data,
		{ schema = "season/1", season = "season_a", xp = 300, claimed = { free = {}, premium = { 2 } } }
	)
	local loaded = SeasonTrack.new(spec, { data = data })
	t.eq(loaded:xp(), 300)
	t.ok(not loaded:isPremium())
	t.eq({ loaded:claim(2, "premium") }, { false, "premium_required", nil })
	loaded:setPremium(true)
	t.eq({ loaded:claim(2, "premium") }, { false, "already_claimed", nil })
	local nextSeason = season()
	nextSeason.id = "season_b"
	local fresh = SeasonTrack.new(SeasonTrack.define(nextSeason), { data = data })
	t.eq(fresh:xp(), 0)
	t.ok(contains(fresh.notes, "new season starts fresh"))
	local repaired = SeasonTrack.new(spec, {
		data = { schema = "season/1", season = "season_a", xp = 10 ^ 9, claimed = { free = { 1, 99, "x" } } },
	})
	t.eq(repaired:xp(), 450, "xp is clamped to the track")
	t.eq(repaired:serialize().claimed, { free = { 1 }, premium = {} })
	local open = SeasonTrack.new(SeasonTrack.define({ id = "s", tiers = { { xp = 1 } } }))
	t.ok(open:isOpen(), "no window means always open")
end)

return cases
