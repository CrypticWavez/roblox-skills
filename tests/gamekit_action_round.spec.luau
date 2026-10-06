--!strict
-- G2 RoundLoop: definition checks, exact phase timings whatever the tick rate, minPlayers
-- aborts, the three late-join policies (and the rejoin-to-respawn exploit), last standing,
-- empty rounds, manual finish, optional phases and untrusted ids and clocks.
local FakeEnv = require("./fakes/FakeEnv")
local RoundLoop = require("../packages/GameKit/RoundLoop")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local NAN = 0 / 0
local STANDARD = { durations = { intermission = 10, active = 60, results = 5 }, minPlayers = 2 }

local function timeline(loop: any, until_: number, dt: number): { string }
	local out = {}
	local now = 0
	while now < until_ - 1e-9 do
		now = math.min(until_, now + dt)
		for _, event in loop:tick(now) do
			table.insert(out, string.format("%s@%g:%s", event.phase, event.at, event.reason))
		end
	end
	return out
end

test("validate: every problem is listed; define raises them joined", function(t)
	local problems = RoundLoop.validate({
		phases = { "lobby", "warmup", "results", "intermission" },
		durations = { results = 0 },
		minPlayers = 0,
		maxPlayers = 0.5,
		lateJoin = "maybe",
		joinWindow = 5,
		endOnAlive = -1,
	})
	t.ok(has(problems, 'unknown phase "warmup"'))
	t.ok(has(problems, "must be in the order"))
	t.ok(has(problems, "phases must include lobby and active"))
	t.ok(has(problems, "durations.results must be in"))
	t.ok(has(problems, "minPlayers"))
	t.ok(has(problems, "maxPlayers"))
	t.ok(has(problems, "lateJoin"))
	t.ok(has(problems, "joinWindow only applies"))
	t.ok(has(problems, "endOnAlive must be an integer"))
	t.ok(has(RoundLoop.validate({ durations = {}, minPlayers = 2 }), "durations.intermission is required"))
	t.ok(
		has(
			RoundLoop.validate({ durations = STANDARD.durations, minPlayers = 2, endOnAlive = 2 }),
			"endOnAlive must be below"
		)
	)
	t.ok(
		has(
			RoundLoop.validate({ durations = STANDARD.durations, minPlayers = 4, maxPlayers = 3 }),
			"maxPlayers must be >= minPlayers"
		)
	)
	t.eq(RoundLoop.validate("x")[1], "definition must be a table")
	t.eq(#RoundLoop.validate(STANDARD), 0)
	local ok, err = pcall(RoundLoop.define, { durations = {}, minPlayers = 0 } :: any)
	t.ok(not ok and string.find(tostring(err), "minPlayers", 1, true) ~= nil)
end)

test("timings: phase starts are exact and identical at 60 Hz and at one tick every 7 s", function(t)
	local spec = RoundLoop.define(STANDARD)
	local fine = RoundLoop.new(spec, nil, FakeEnv.new())
	local coarse = RoundLoop.new(spec, nil, FakeEnv.new())
	for _, loop in { fine, coarse } do
		loop:join("a")
		loop:join("b")
	end
	local a = timeline(fine, 100, 1 / 60)
	local b = timeline(coarse, 100, 7)
	t.eq(a, {
		"intermission@0.0166667:enough_players",
		"active@10.0167:countdown",
		"results@70.0167:time",
		"intermission@75.0167:next_round",
		"active@85.0167:countdown",
	})
	-- The coarse loop saw the players at t = 7, so its timeline is the same shape shifted to 7.
	t.eq(b, {
		"intermission@7:enough_players",
		"active@17:countdown",
		"results@77:time",
		"intermission@82:next_round",
		"active@92:countdown",
	})
	-- One late tick can cross several phase ends, each at its exact time.
	local late = RoundLoop.new(spec, nil, FakeEnv.new())
	late:join("a")
	late:join("b")
	late:tick(0)
	local events = late:tick(90)
	t.eq(#events, 4)
	t.eq(events[1].at, 10)
	t.eq(events[2].at, 70)
	t.eq(events[3].at, 75)
	t.eq(events[4].at, 85)
	t.eq(late:round(), 2)
	t.eq(late:timeLeft(90), 55)
	local snap = late:snapshot(90.2)
	t.eq(snap.phase, "active")
	t.eq(snap.timeLeft, 55, "whole seconds, rounded up")
	t.eq(snap.round, 2)
	t.eq(snap.state, "fsm/1:round:active")
end)

test("minPlayers: the lobby waits, intermission aborts and results fall back to the lobby", function(t)
	local env = FakeEnv.new()
	local loop = RoundLoop.new(RoundLoop.define(STANDARD), nil, env)
	local changes = {}
	loop.phaseChanged:Connect(function(phase, from, info)
		table.insert(changes, from .. ">" .. phase .. ":" .. info.reason)
	end)
	loop:join("a")
	t.eq(#loop:tick(5), 0, "one player is not enough")
	t.eq(loop:timeLeft(), nil, "the lobby has no timer")
	loop:join("b")
	loop:tick(6)
	t.eq(loop:phase(), "intermission")
	loop:leave("b")
	loop:tick(7)
	t.eq(loop:phase(), "lobby")
	loop:join("b")
	loop:tick(8)
	loop:tick(18)
	t.eq(loop:phase(), "active")
	loop:tick(78)
	t.eq(loop:phase(), "results")
	loop:leave("a")
	loop:tick(83)
	t.eq(loop:phase(), "lobby")
	t.eq(changes, {
		"lobby>intermission:enough_players",
		"intermission>lobby:not_enough_players",
		"lobby>intermission:enough_players",
		"intermission>active:countdown",
		"active>results:time",
		"results>lobby:not_enough_players",
	})
end)

test("late join: spectate, queue and join (with window); leaving or dying never respawns you", function(t)
	local function started(def: any): any
		local loop = RoundLoop.new(RoundLoop.define(def), nil, FakeEnv.new())
		loop:join("a")
		loop:join("b")
		loop:tick(0)
		loop:tick(10)
		assert(loop:phase() == "active")
		return loop
	end
	local base = { durations = STANDARD.durations, minPlayers = 2 }
	local spectate = started(base)
	t.eq(select(2, spectate:join("c")), "spectator")
	local queue = started({ durations = STANDARD.durations, minPlayers = 2, lateJoin = "queue" })
	t.eq(select(2, queue:join("c")), "queued")
	t.eq(queue:queued(), { "c" })
	local join =
		started({ durations = STANDARD.durations, minPlayers = 2, lateJoin = "join", joinWindow = 15 })
	join:tick(20)
	t.eq(select(2, join:join("c")), "participant", "inside the 15 s window")
	join:tick(30)
	t.eq(select(2, join:join("d")), "spectator", "after the window")
	t.eq(join:alive(), { "a", "b", "c" })
	-- Exploit: leave and rejoin (or die and rejoin) to come back alive.
	t.ok(join:leave("a"))
	t.eq(select(2, join:join("a")), "spectator")
	t.ok(join:eliminate("b"))
	t.ok(join:leave("b"))
	t.eq(select(2, join:join("b")), "spectator")
	-- Next round, everyone present plays again.
	join:tick(70)
	join:tick(75)
	join:tick(85)
	t.eq(join:phase(), "active")
	t.eq(join:alive(), { "c", "d", "a", "b" })
	-- The queue respects maxPlayers in join order.
	local capped = RoundLoop.new(
		RoundLoop.define({ durations = STANDARD.durations, minPlayers = 2, maxPlayers = 2 }),
		nil,
		FakeEnv.new()
	)
	for _, id in { "a", "b", "c" } do
		capped:join(id)
	end
	capped:tick(0)
	capped:tick(10)
	t.eq(capped:alive(), { "a", "b" })
	t.eq(capped:role("c"), "queued")
end)

test("round ends: last standing, empty round, manual finish with a result", function(t)
	local def = { durations = STANDARD.durations, minPlayers = 2, endOnAlive = 1 }
	local loop = RoundLoop.new(RoundLoop.define(def), nil, FakeEnv.new())
	for _, id in { 1, 2, 3 } do
		loop:join(id)
	end
	loop:tick(0)
	loop:tick(10)
	t.ok(loop:eliminate(2))
	t.eq(select(2, loop:eliminate(2)), "not_participant")
	t.eq(#loop:tick(11), 0)
	loop:eliminate(3)
	local events = loop:tick(12)
	t.eq(events[1].phase, "results")
	t.eq(events[1].reason, "last_standing")
	t.eq(events[1].result.survivors, { 1 })
	t.eq(select(2, loop:eliminate(1)), "not_active")

	local empty = RoundLoop.new(RoundLoop.define(STANDARD), nil, FakeEnv.new())
	empty:join("a")
	empty:join("b")
	empty:tick(0)
	empty:tick(10)
	empty:leave("a")
	empty:leave("b")
	local gone = empty:tick(11)
	t.eq(gone[1].phase, "lobby")
	t.eq(gone[1].reason, "empty")

	local manual = RoundLoop.new(RoundLoop.define(STANDARD), nil, FakeEnv.new())
	t.eq(select(2, manual:finish()), "not_active")
	manual:join("a")
	manual:join("b")
	manual:tick(0)
	manual:tick(10)
	manual:tick(20)
	local ok, _, finished = manual:finish({ winners = { "b" } })
	t.ok(ok)
	t.eq((finished :: any)[1].at, 20)
	t.eq(manual:result().winners, { "b" })
	t.eq(manual:phase(), "results")
	manual:tick(25)
	t.eq(manual:phase(), "intermission")
	t.eq(manual:reset()[1].phase, "lobby")
	t.eq(#manual:reset(), 0)
end)

test("optional phases: lobby and active only run rounds back to back", function(t)
	local loop = RoundLoop.new(
		RoundLoop.define({ phases = { "lobby", "active" }, durations = { active = 30 }, minPlayers = 1 }),
		nil,
		FakeEnv.new()
	)
	loop:join("solo")
	local events = loop:tick(0)
	t.eq(events[1].phase, "active")
	local later = loop:tick(65)
	t.eq(#later, 2)
	t.eq(later[1].at, 30)
	t.eq(later[2].at, 60)
	t.eq(loop:round(), 3)
	-- An untimed active phase only ends by finish() or players.
	local untimed = RoundLoop.new(
		RoundLoop.define({ phases = { "lobby", "active" }, durations = {}, minPlayers = 1 }),
		nil,
		FakeEnv.new()
	)
	untimed:join("solo")
	untimed:tick(0)
	t.eq(#untimed:tick(1e6), 0)
	t.eq(untimed:timeLeft(), nil)
	t.eq(untimed:snapshot().timeLeft, -1)
end)

test("untrusted input: bad ids, duplicates, unknown leaves and bad clocks change nothing", function(t)
	local loop = RoundLoop.new(RoundLoop.define(STANDARD), nil, FakeEnv.new({ start = 100 }))
	t.eq(select(2, loop:join(nil)), "bad_id")
	t.eq(select(2, loop:join(NAN)), "bad_id")
	t.eq(select(2, loop:join({} :: any)), "bad_id")
	t.ok(loop:join(7))
	t.eq(select(2, loop:join(7)), "already_joined")
	t.eq(select(2, loop:leave(8)), "unknown")
	t.eq(select(2, loop:leave(nil)), "unknown")
	loop:join(8)
	t.eq(#loop:tick(NAN), 0)
	t.eq(#loop:tick(50), 0, "a clock earlier than construction is ignored")
	t.eq(loop:phase(), "lobby")
	loop:tick(101)
	t.eq(loop:phase(), "intermission")
	t.eq(#loop:tick(100.5), 0, "time never runs backwards")
	t.eq(loop:players(), { 7, 8 })
	t.throws(function()
		RoundLoop.new({} :: any, nil, FakeEnv.new())
	end)
end)

return cases
