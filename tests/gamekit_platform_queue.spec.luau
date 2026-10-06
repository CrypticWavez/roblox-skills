--!strict
-- G1 matchmaking: GameKit/Queue (validation, tickets, party integrity, widening skill bands,
-- partial matches, pools, expiry, team balance, determinism and a seeded golden plan),
-- GameKit/MemoryQueueRoblox against tests/fakes/FakeMemoryStore, GameKit/TeleportRoblox and
-- GameKit/PartyRoblox against the fakes in tests/fakes/FakePlatformRoblox. The Roblox services
-- here are fakes: MemoryStore, teleports and the live Party API stay T4 / T3-pending.
local FakeEnv = require("./fakes/FakeEnv")
local FakeMemoryStore = require("./fakes/FakeMemoryStore")
local FakePlatformRoblox = require("./fakes/FakePlatformRoblox")
local Golden = require("./lib/Golden")
local MemoryQueueRoblox = require("../packages/GameKit/MemoryQueueRoblox")
local PartyRoblox = require("../packages/GameKit/PartyRoblox")
local Queue = require("../packages/GameKit/Queue")
local Rng = require("../packages/ProcGen/Rng")
local TeleportRoblox = require("../packages/GameKit/TeleportRoblox")

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
	for _ = 1, 6000 do
		if out ~= nil then
			break
		end
		env:advance(0.1)
		env:flush()
	end
	assert(out ~= nil, "did not finish: " .. table.concat(env.errors, "\n"))
	return table.unpack(out, 1, out.n)
end

local function solo(id: string, userId: number, skill: number?, at: number?, pool: string?): any
	return { id = id, players = { userId }, skill = skill, at = at or 0, pool = pool }
end

local function teamPlayers(match: any): { { number } }
	local out = {}
	for _, team in match.teams do
		local list = table.clone(team.players)
		table.sort(list)
		table.insert(out, list)
	end
	return out
end

-- ---------------------------------------------------------------- options and tickets

test("validate lists every problem and new raises", function(t)
	local problems = table.concat(
		Queue.validate({
			teams = 0,
			teamSize = 101,
			maxTickets = 0,
			expireAfter = 0,
			skill = { initial = 200, widenPerSecond = -1, max = 100 },
			partial = { after = -1, minPlayers = 0, maxImbalance = 1.5 },
		}),
		"\n"
	)
	for _, needle in
		{
			"teams must be an integer from 1 to 16",
			"teamSize must be an integer from 1 to 100",
			"maxTickets must be",
			"expireAfter must be",
			"skill.widenPerSecond must be",
			"skill.max must be >= skill.initial",
			"partial.after must be",
			"partial.minPlayers must be",
			"partial.maxImbalance must be",
		}
	do
		t.ok(has(problems, needle), needle .. "\n" .. problems)
	end
	t.eq(
		Queue.validate({ teamSize = 2, maxPartySize = 3 }),
		{ "maxPartySize must be an integer from 1 to teamSize" }
	)
	t.eq(Queue.validate("x"), { "options must be a table" })
	t.eq(Queue.validate({ skill = "fast" }), { "skill must be a table or false" })
	t.eq(Queue.validate(nil), {})
	t.ok(not pcall(Queue.new, { teams = 0 }))
	t.ok(not pcall(Queue.planTickets, {}, nil, 0 / 0))
end)

test("add refuses bad, oversized, duplicate and over-capacity tickets", function(t)
	local env = FakeEnv.new()
	local queue = Queue.new({ teams = 2, teamSize = 2, maxTickets = 3 }, env)
	local bad: { any } = {
		"ticket",
		{ id = "", players = { 1 }, skill = 1 },
		{ id = "has space", players = { 1 }, skill = 1 },
		{ id = string.rep("x", 65), players = { 1 }, skill = 1 },
		{ id = "a", players = {}, skill = 1 },
		{ id = "a", players = { 1, 1 }, skill = 1 },
		{ id = "a", players = { 0 }, skill = 1 },
		{ id = "a", players = { 1.5 }, skill = 1 },
		{ id = "a", players = { 1, nil, 3 } :: any, skill = 1 },
		{ id = "a", players = { 1 } }, -- skill required while skill is on
		{ id = "a", players = { 1 }, skill = 0 / 0 },
		{ id = "a", players = { 1 }, skill = 1, pool = "Bad Pool" },
		{ id = "a", players = { 1 }, skill = 1, at = math.huge },
	}
	for index, ticket in bad do
		t.eq({ queue:add(ticket) }, { false, "invalid_ticket" }, "bad ticket " .. index)
	end
	t.eq({ queue:add({ id = "big", players = { 1, 2, 3 }, skill = 1 }) }, { false, "party_too_large" })
	local input = { id = "p1", players = { 1, 2 }, skill = 500 }
	t.eq({ queue:add(input) }, { true })
	input.players[1] = 99 -- the queue holds a copy
	t.eq(queue:ticketOf(1), "p1")
	t.eq(queue:get("p1").at, 0, "at defaults to env.clock()")
	t.eq({ queue:add({ id = "p1", players = { 7 }, skill = 1 }) }, { false, "duplicate_ticket" })
	t.eq({ queue:add({ id = "p2", players = { 2, 3 }, skill = 1 }) }, { false, "player_queued" })
	t.eq({ queue:add(solo("s3", 3, 1)) }, { true })
	t.eq({ queue:add(solo("s4", 4, 1)) }, { true })
	t.eq({ queue:add(solo("s5", 5, 1)) }, { false, "full" })
	t.eq({ queue:size() }, { 3, 4 })
	-- a party leaves together
	t.eq(queue:removePlayer(2), "p1")
	t.eq(queue:ticketOf(1), nil)
	t.eq(queue:removePlayer(2), nil)
	t.eq(queue:remove("p1"), false)
	t.eq({ queue:size() }, { 2, 2 })
	-- without an env, tickets must carry at
	local bare = Queue.new({ skill = false })
	t.eq({ bare:add({ id = "x", players = { 1 } }) }, { false, "invalid_ticket" })
	t.eq({ bare:add({ id = "x", players = { 1 }, at = 5 }) }, { true })
	t.ok(not pcall(bare.plan, bare), "plan without now or env raises")
	t.eq(bare:band("x", 100), math.huge, "skill off: unbounded band")
	t.eq(bare:band("missing", 100), nil)
end)

-- ---------------------------------------------------------------- matching

test("parties are never split and teams fill exactly", function(t)
	local queue = Queue.new({ teams = 2, teamSize = 3, skill = false })
	queue:add({ id = "trio", players = { 1, 2, 3 }, at = 0 })
	queue:add({ id = "duo", players = { 4, 5 }, at = 1 })
	queue:add({ id = "duo2", players = { 6, 7 }, at = 2 })
	queue:add(solo("s8", 8, nil, 3))
	queue:add(solo("s9", 9, nil, 4))
	local plan = queue:take(10)
	t.eq(#plan.matches, 1)
	local match = plan.matches[1]
	t.eq(match.id, "match:trio")
	t.eq(match.players, 6)
	t.eq(match.tickets, { "trio", "duo", "s8" }, "oldest first; duo2 skipped because it cannot be packed")
	t.eq(teamPlayers(match), { { 1, 2, 3 }, { 4, 5, 8 } })
	t.eq(plan.waiting, 2)
	t.eq({ queue:size() }, { 2, 3 })
	-- three duos can never fill two teams of three
	local stuck = Queue.new({ teams = 2, teamSize = 3, skill = false })
	for index = 1, 3 do
		stuck:add({ id = "d" .. index, players = { index * 10, index * 10 + 1 }, at = index })
	end
	t.eq(#stuck:plan(100).matches, 0)
	-- free-for-all: one team
	local ffa = Queue.new({ teams = 1, teamSize = 3, skill = false })
	for userId = 1, 4 do
		ffa:add(solo("f" .. userId, userId, nil, userId))
	end
	local ffaPlan = ffa:take(10)
	t.eq(teamPlayers(ffaPlan.matches[1]), { { 1, 2, 3 } })
	t.eq(ffa:ticketOf(4), "f4")
end)

test("skill bands widen with the anchor's wait and stop at the cap", function(t)
	local options = { teams = 2, teamSize = 1, skill = { initial = 100, widenPerSecond = 10, max = 1000 } }
	local queue = Queue.new(options)
	queue:add(solo("low", 1, 1000, 0))
	queue:add(solo("high", 2, 1400, 5))
	t.eq(queue:band("low", 0), 100)
	t.eq(queue:band("low", 29.9), 399)
	t.eq(#queue:plan(29.9).matches, 0, "400 apart: not yet")
	local plan = queue:plan(30)
	t.eq(#plan.matches, 1, "band 400 at 30 s")
	t.eq(plan.matches[1].spread, 400)
	t.eq(plan.matches[1].waited, 30)
	t.eq(queue:band("low", 10000), 1000, "capped")
	local far = Queue.new(options)
	far:add(solo("a", 1, 0, 0))
	far:add(solo("b", 2, 1001, 0))
	t.eq(#far:plan(1e6).matches, 0, "beyond the cap never matches")
	-- a closer candidate does not jump an older one inside the band
	local fair =
		Queue.new({ teams = 2, teamSize = 1, skill = { initial = 500, widenPerSecond = 0, max = 500 } })
	fair:add(solo("anchor", 1, 1000, 0))
	fair:add(solo("older_far", 2, 1400, 1))
	fair:add(solo("newer_near", 3, 1000, 2))
	t.eq(fair:plan(3).matches[1].tickets, { "anchor", "older_far" })
end)

test("teams are balanced by skill", function(t)
	local queue =
		Queue.new({ teams = 2, teamSize = 2, skill = { initial = 1000, widenPerSecond = 0, max = 1000 } })
	for index, skill in { 100, 200, 300, 400 } do
		queue:add(solo("s" .. index, index, skill, index))
	end
	local match = queue:plan(10).matches[1]
	t.eq(teamPlayers(match), { { 1, 4 }, { 2, 3 } })
	t.eq({ match.teams[1].skill, match.teams[2].skill }, { 500, 500 })
end)

test("partial matches wait, keep teams non-empty and within the imbalance", function(t)
	local options =
		{ teams = 2, teamSize = 4, skill = false, partial = { after = 30, minPlayers = 2, maxImbalance = 1 } }
	local queue = Queue.new(options)
	queue:add(solo("a", 1, nil, 0))
	queue:add(solo("b", 2, nil, 10))
	t.eq(#queue:plan(29).matches, 0)
	local plan = queue:plan(30)
	t.eq(#plan.matches, 1)
	t.eq(plan.matches[1].partial, true)
	t.eq(teamPlayers(plan.matches[1]), { { 1 }, { 2 } })
	-- a lone party cannot fill both teams
	local lone = Queue.new(options)
	lone:add({ id = "duo", players = { 1, 2 }, at = 0 })
	t.eq(#lone:plan(100).matches, 0)
	-- 3 v 1 breaks maxImbalance 1 but passes maxImbalance 2
	local trio = { id = "trio", players = { 1, 2, 3 }, at = 0 }
	local strict = Queue.new(options)
	strict:add(trio)
	strict:add(solo("s", 4, nil, 0))
	t.eq(#strict:plan(100).matches, 0)
	local loose = Queue.new({
		teams = 2,
		teamSize = 4,
		skill = false,
		partial = { after = 30, minPlayers = 2, maxImbalance = 2 },
	})
	loose:add(trio)
	loose:add(solo("s", 4, nil, 0))
	t.eq(teamPlayers(loose:plan(100).matches[1]), { { 1, 2, 3 }, { 4 } })
	-- an empty team is never allowed, even inside the imbalance
	local emptyTeam = Queue.new({
		teams = 2,
		teamSize = 4,
		skill = false,
		partial = { after = 0, minPlayers = 2, maxImbalance = 2 },
	})
	emptyTeam:add({ id = "duo", players = { 1, 2 }, at = 0 })
	t.eq(#emptyTeam:plan(100).matches, 0)
	-- below minPlayers nothing starts
	local few = Queue.new({ teams = 1, teamSize = 4, skill = false, partial = { after = 0, minPlayers = 3 } })
	few:add(solo("a", 1, nil, 0))
	few:add(solo("b", 2, nil, 0))
	t.eq(#few:plan(100).matches, 0)
end)

test("pools never mix, expired tickets drop and plan does not mutate", function(t)
	local queue = Queue.new({ teams = 2, teamSize = 1, skill = false, expireAfter = 60 })
	queue:add(solo("a1", 1, nil, 0, "mode_a"))
	queue:add(solo("b1", 2, nil, 0, "mode_b"))
	queue:add(solo("a2", 3, nil, 50, "mode_a"))
	queue:add(solo("old", 4, nil, -100, "mode_b"))
	queue:add(solo("b2", 5, nil, 55, "mode_b"))
	local before = queue:snapshot()
	local plan = queue:plan(59)
	t.eq(queue:snapshot(), before, "plan leaves the queue alone")
	t.eq(plan.expired, { "old" })
	t.eq(#plan.matches, 2)
	t.eq({ plan.matches[1].pool, plan.matches[1].tickets }, { "mode_a", { "a1", "a2" } })
	t.eq({ plan.matches[2].pool, plan.matches[2].tickets }, { "mode_b", { "b1", "b2" } })
	local taken = queue:take(59)
	t.eq(taken, plan)
	t.eq({ queue:size() }, { 0, 0 })
	-- the default pool is "default"
	local plain = Queue.new({ teams = 1, teamSize = 1, skill = false })
	plain:add(solo("x", 1, nil, 0))
	t.eq(plain:plan(1).matches[1].pool, "default")
end)

test("the same tickets give the same plan in any insertion order", function(t)
	local rng = Rng.new("queue-order")
	local tickets = {}
	for index = 1, 40 do
		table.insert(tickets, {
			id = string.format("t%02d", index),
			players = { index },
			skill = rng:int(800, 1600),
			at = rng:int(0, 30),
		})
	end
	local options = { teams = 2, teamSize = 2, skill = { initial = 100, widenPerSecond = 20, max = 600 } }
	local reference = Queue.planTickets(tickets, options, 40)
	t.ok(#reference.matches > 0)
	for round = 1, 5 do
		local shuffled = Rng.new("shuffle-" .. round):shuffle(table.clone(tickets))
		local queue = Queue.new(options)
		for _, ticket in shuffled do
			queue:add(ticket)
		end
		t.eq(queue:plan(40), reference, "round " .. round)
	end
end)

test("a seeded queue simulation matches its golden plan", function(t)
	local rng = Rng.new("gamekit_platform_queue")
	local queue = Queue.new({
		teams = 2,
		teamSize = 3,
		maxPartySize = 3,
		skill = { initial = 75, widenPerSecond = 15, max = 600 },
		partial = { after = 45, minPlayers = 4, maxImbalance = 1 },
		expireAfter = 120,
	})
	local nextUser = 1
	local timeline = {}
	for step = 0, 36 do
		local now = step * 5
		for _ = 1, rng:int(0, 3) do
			local size = rng:weighted({
				{ value = 1, weight = 6 },
				{ value = 2, weight = 3 },
				{ value = 3, weight = 1 },
			})
			local players = {}
			for _ = 1, size do
				table.insert(players, nextUser)
				nextUser += 1
			end
			queue:add({
				id = string.format("k%03d", nextUser),
				players = players,
				skill = rng:int(600, 1800),
				pool = rng:pick({ "pool_a", "pool_b" }),
				at = now,
			})
		end
		local plan = queue:take(now)
		if #plan.matches > 0 or #plan.expired > 0 then
			table.insert(timeline, { now = now, matches = plan.matches, expired = plan.expired })
		end
	end
	local tickets, players = queue:size()
	local value = { timeline = timeline, left = { tickets = tickets, players = players } }
	Golden.assert("gamekit_platform_queue", value)
	-- every queued player was matched, expired or is still waiting, exactly once
	local seen = {}
	for _, entry in timeline do
		for _, match in entry.matches do
			for _, team in match.teams do
				for _, userId in team.players do
					t.ok(not seen[userId], "player " .. userId .. " matched twice")
					seen[userId] = true
				end
				t.ok(#team.players <= 3)
			end
		end
	end
	t.ok(#timeline > 3, "the simulation forms matches")
end)

-- ---------------------------------------------------------------- MemoryQueueRoblox

local QUEUE_OPTIONS = { teams = 2, teamSize = 1, skill = false }

test("MemoryQueueRoblox moves tickets between servers and requeues the rest", function(t)
	local env = FakeEnv.new()
	local world = FakeMemoryStore.new(env)
	local lobbyA = MemoryQueueRoblox.new(world:service(), { name = "mm_a" }, env)
	local lobbyB = MemoryQueueRoblox.new(world:service(), { name = "mm_a" }, env)
	t.eq({ run(env, function()
		return lobbyA:push(solo("a1", 1, nil, nil))
	end) }, { true })
	run(env, function()
		lobbyB:push(solo("b1", 2, nil, nil))
		lobbyB:push(solo("b2", 3, nil, nil))
		return lobbyB:push({ id = "bad id", players = { 9 }, at = 0 })
	end)
	t.eq(
		run(env, function()
			return lobbyA:size()
		end),
		4
	)
	local launched = {}
	local result = run(env, function()
		return lobbyA:cycle(QUEUE_OPTIONS, function(match: any): boolean
			table.insert(launched, match.tickets)
			return true
		end)
	end)
	t.eq(launched, { { "a1", "b1" } })
	t.eq(result.launched, { "match:a1" })
	t.eq(result.dropped, { "invalid_ticket" })
	t.eq(result.requeued, 1)
	t.eq({ result.ok, result.lost }, { true, 0 })
	local left = world.queues.mm_a:peek()
	t.eq(#left, 1)
	t.eq({ left[1].id, left[1].at }, { "b2", 0 }, "requeued with its original time")
	-- a failing or refusing onMatch puts its tickets back
	run(env, function()
		return lobbyA:push(solo("a2", 4, nil, nil))
	end)
	local refused = run(env, function()
		return lobbyA:cycle(QUEUE_OPTIONS, function(): boolean
			error("reserve failed")
		end)
	end)
	t.eq({ #refused.launched, refused.requeued }, { 0, 2 })
	t.ok(has(table.concat(env.reports, "\n"), "reserve failed"))
	t.eq(#world.queues.mm_a:peek(), 2)
	-- onMatch answering false (not launched) also puts the tickets back
	local declined = run(env, function()
		return lobbyA:cycle(QUEUE_OPTIONS, function(): boolean
			return false
		end)
	end)
	t.eq({ #declined.launched, declined.requeued }, { 0, 2 })
	-- a ticket pushed without a time is stamped with the server clock
	env:advance(7)
	local stampWorld = FakeMemoryStore.new(env)
	local stamper = MemoryQueueRoblox.new(stampWorld:service(), { name = "mm_stamp" }, env)
	local stampedAt = env.clock()
	run(env, function()
		return stamper:push({ id = "late", players = { 77 } })
	end)
	t.eq(stampWorld.queues.mm_stamp:peek()[1].at, stampedAt)
	-- an empty queue is a quiet no-op
	local emptyWorld = FakeMemoryStore.new(env)
	local empty = MemoryQueueRoblox.new(emptyWorld:service(), { name = "mm_empty" }, env)
	local quiet = run(env, function()
		return empty:cycle(QUEUE_OPTIONS, function(): boolean
			return true
		end)
	end)
	t.eq({ quiet.ok, #quiet.launched, quiet.requeued }, { true, 0, 0 })
end)

test("MemoryQueueRoblox fails safe when reads, removes or pushes fail", function(t)
	local env = FakeEnv.new()
	local world = FakeMemoryStore.new(env)
	local mq = MemoryQueueRoblox.new(world:service(), { name = "mm_fail", invisibility = 30 }, env)
	run(env, function()
		mq:push(solo("a", 1, nil, nil))
		return mq:push(solo("b", 2, nil, nil))
	end)
	-- reads retried, then given up
	world:fail("ReadAsync", 5)
	local readFailed = run(env, function()
		return mq:cycle(QUEUE_OPTIONS, function(): boolean
			return true
		end)
	end)
	t.eq({ readFailed.ok, readFailed.reason }, { false, "read_failed" })
	-- a failed remove launches nothing twice: the batch reappears after the invisibility timeout
	world:fail("RemoveAsync", 5)
	local calls = 0
	local ackFailed = run(env, function()
		return mq:cycle({ teams = 2, teamSize = 2, skill = false }, function(): boolean
			calls += 1
			return true
		end)
	end)
	t.eq({ ackFailed.ok, ackFailed.reason, ackFailed.requeued }, { false, "ack_failed", 0 })
	t.eq(
		run(env, function()
			return mq:size()
		end),
		2,
		"nothing pushed back while the batch is still stored"
	)
	t.eq({ run(env, function()
		return mq:pull(10, 0)
	end) }, { {} }, "still invisible")
	env:advance(31)
	local items = run(env, function()
		return mq:pull(10, 0)
	end)
	t.eq(#items, 2, "visible again after the timeout")
	-- pushes that keep failing are counted as lost and reported
	env:advance(31)
	local lostWorld = FakeMemoryStore.new(env)
	local lossy = MemoryQueueRoblox.new(lostWorld:service(), { name = "mm_lost" }, env)
	run(env, function()
		lossy:push(solo("a", 1, nil, nil))
		lossy:push(solo("b", 2, nil, nil))
		return lossy:push(solo("c", 3, nil, nil))
	end)
	lostWorld:fail("AddAsync", 10)
	local lost = run(env, function()
		return lossy:cycle(QUEUE_OPTIONS, function(): boolean
			return true
		end)
	end)
	t.eq({ lost.ok, #lost.launched, lost.lost }, { true, 1, 1 })
	t.ok(has(table.concat(env.reports, "\n"), "1 tickets not pushed back"))
	t.eq({ run(env, function()
		return lossy:push("x" :: any)
	end) }, { false, "invalid_ticket" })
	t.ok(not pcall(MemoryQueueRoblox.new, world:service(), { name = "" }, env))
	t.ok(not pcall(MemoryQueueRoblox.new, world:service(), { name = "q", batch = 101 }, env))
	t.ok(not pcall(MemoryQueueRoblox.new, world:service(), { name = "q", expiration = 0 }, env))
end)

-- ---------------------------------------------------------------- TeleportRoblox

local function liveEnv(): any
	return FakeEnv.new({
		roblox = FakePlatformRoblox.roblox(),
		place = { isStudio = false, gameId = 1, placeId = 1, isServer = true },
	})
end

test("TeleportRoblox builds options, retries TeleportAsync and refuses Studio", function(t)
	local env = liveEnv()
	local service = FakePlatformRoblox.teleportService()
	local players = FakePlatformRoblox.players()
	local one, two = players:join(1), players:join(2)
	local options = TeleportRoblox.options(env.roblox, { reserve = true, data = { matchId = "match:a" } })
	t.eq({ options.ShouldReserveServer, options:GetTeleportData() }, { true, { matchId = "match:a" } })
	t.ok(not pcall(TeleportRoblox.options, env.roblox, { reserve = true, accessCode = "x" }))
	t.ok(not pcall(TeleportRoblox.options, env.roblox, { accessCode = "" }))
	local named = TeleportRoblox.options(env.roblox, { accessCode = "code_1" })
	t.eq(named.ReservedServerAccessCode, "code_1")
	t.eq(TeleportRoblox.options(env.roblox, { serverInstanceId = "job_1" }).ServerInstanceId, "job_1")
	service:fail(2)
	local ok, result = run(env, function()
		return TeleportRoblox.teleport(service, 1234, { one, two }, options, env)
	end)
	t.eq(ok, true)
	t.eq(result.ReservedServerAccessCode, "access_teleport")
	t.eq(#service.teleports, 1)
	t.eq(service.teleports[1].userIds, { 1, 2 })
	service:fail(10, "HTTP 500 teleport")
	local failed, reason, detail = run(env, function()
		return TeleportRoblox.teleport(service, 1234, { one }, nil, env)
	end)
	t.eq({ failed, reason }, { false, "failed" })
	t.ok(has(detail, "HTTP 500 teleport"))
	t.eq({ TeleportRoblox.teleport(service, 0, { one }, nil, env) }, { false, "invalid" })
	t.eq({ TeleportRoblox.teleport(service, 1234, {}, nil, env) }, { false, "invalid" })
	local studio = FakeEnv.new({ roblox = FakePlatformRoblox.roblox() })
	t.eq({ TeleportRoblox.teleport(service, 1234, { one }, nil, studio) }, { false, "studio" })
	t.eq({ TeleportRoblox.reserve(service, 1234, studio) }, { false, "studio" })
	-- An unknown place fails closed: no env, or an env without a place, never teleports.
	local placeless = FakeEnv.new({ roblox = FakePlatformRoblox.roblox() })
	placeless.place = nil
	local before = #service.teleports
	t.eq({ TeleportRoblox.teleport(service, 1234, { one }, nil, nil) }, { false, "studio" })
	t.eq({ TeleportRoblox.teleport(service, 1234, { one }, nil, placeless) }, { false, "studio" })
	t.eq({ TeleportRoblox.reserve(service, 1234, placeless) }, { false, "studio" })
	t.eq(#service.teleports, before)
	service.failures = 0
	t.eq(
		{ run(env, function()
			return TeleportRoblox.reserve(service, 1234, env)
		end) },
		{ true, "access_1", "server_1" }
	)
	t.eq({ TeleportRoblox.reserve(service, -1, env) }, { false, "invalid" })
	service:fail(10)
	t.eq(
		select(
			2,
			run(env, function()
				return TeleportRoblox.reserve(service, 1234, env)
			end)
		),
		"failed"
	)
end)

test("TeleportRoblox.bindRetry retries Flooded and Failure and gives up on the rest", function(t)
	local env = liveEnv()
	local service = FakePlatformRoblox.teleportService()
	local players = FakePlatformRoblox.players()
	local one = players:join(1)
	local gaveUp = {}
	local disconnect = TeleportRoblox.bindRetry(service, env, {
		maxRetries = 2,
		onGiveUp = function(player: any, result: string)
			table.insert(gaveUp, { player.UserId, result })
		end,
	})
	service:initFail(one, "Flooded", "busy", 1234, nil)
	env:advance(14.9)
	env:flush()
	t.eq(#service.teleports, 0, "Flooded waits 15 s")
	env:advance(0.2)
	env:flush()
	t.eq(#service.teleports, 1)
	service:initFail(one, "Failure", "flaky", 1234, nil)
	env:advance(1.1)
	env:flush()
	t.eq(#service.teleports, 2)
	service:initFail(one, "Failure", "flaky", 1234, nil)
	t.eq(gaveUp, { { 1, "Failure" } }, "capped at maxRetries")
	service:initFail(one, "GameFull", "full", 1234, nil)
	t.eq(gaveUp[2], { 1, "GameFull" }, "not retryable")
	t.ok(has(table.concat(env.reports, "\n"), "GameFull"))
	disconnect()
	service:initFail(one, "Flooded", "busy", 1234, nil)
	env:advance(20)
	env:flush()
	t.eq(#service.teleports, 2, "disconnected")
end)

-- ---------------------------------------------------------------- PartyRoblox

test("PartyRoblox builds party tickets and drops them on leave or party change", function(t)
	local env = FakeEnv.new()
	local players = FakePlatformRoblox.players()
	local a = players:join(30, "party-1")
	local c = players:join(20, "party-1")
	local b = players:join(10, "party-1")
	local d = players:join(40, "")
	local social = FakePlatformRoblox.socialService(players, {
		remote = {
			["party-1"] = {
				{ UserId = 99, PlaceId = 5, JobId = "elsewhere" },
				{ PlaceId = 5 }, -- malformed: no UserId, skipped
			},
		},
	})
	t.eq(PartyRoblox.partyId(d), nil)
	t.eq(PartyRoblox.partyId(a), "party-1")
	local ticket = PartyRoblox.ticket(social, a, {
		at = 3,
		pool = "pool_a",
		skillOf = function(list: { any }): number
			return #list * 100
		end,
	})
	t.eq(ticket, { id = "party:party-1", players = { 30, 10, 20 }, skill = 300, pool = "pool_a", at = 3 })
	t.eq(PartyRoblox.ticket(social, d), { id = "solo:40", players = { 40 } })
	t.eq(PartyRoblox.membersHere(social, "party-1")[1], b, "members sorted by UserId")
	local alone = players:join(60, "party-alone")
	t.eq(PartyRoblox.ticket(social, alone).id, "solo:60", "a party with no one else here queues solo")
	players:leave(alone)
	t.eq(PartyRoblox.ticket(social, a, { maxPartySize = 2 }).players, { 30, 10 })
	t.eq(PartyRoblox.membersHere(nil, "party-1"), {})
	t.eq(PartyRoblox.membersHere(social, nil), {})
	local ok, members = run(env, function()
		return PartyRoblox.members(social, "party-1", env)
	end)
	t.eq(ok, true)
	t.eq(members[4], { userId = 99, placeId = 5, jobId = "elsewhere" })
	t.eq(#members, 4)
	social:fail(5)
	local failed, why = run(env, function()
		return PartyRoblox.members(social, "party-1", env)
	end)
	t.eq(failed, false)
	t.ok(has(why, "HTTP 503"))
	t.eq({ PartyRoblox.members(social, "", env) }, { false, "no_party" })
	-- the queue follows party changes and leavers
	local queue = Queue.new({ teams = 2, teamSize = 3, skill = false }, env)
	t.eq({ queue:add(ticket) }, { true })
	t.eq({ queue:add(PartyRoblox.ticket(social, d)) }, { true })
	local removed = {}
	local disconnect = PartyRoblox.bind(queue, players, {
		onRemoved = function(player: any, id: string, reason: string)
			table.insert(removed, { player.UserId, id, reason })
		end,
	})
	b.PartyId = "party-2"
	t.eq(queue:ticketOf(30), nil, "a party edit cancels the whole party's ticket")
	players:leave(d)
	t.eq(removed, { { 10, "party:party-1", "party_changed" }, { 40, "solo:40", "left" } })
	local late = players:join(50, "")
	queue:add(PartyRoblox.ticket(social, late))
	late.PartyId = "party-3"
	t.eq(queue:ticketOf(50), nil, "players who join later are watched too")
	disconnect()
	queue:add(PartyRoblox.ticket(social, c))
	c.PartyId = "party-4"
	t.ok(queue:ticketOf(20) ~= nil, "unbound: no longer watched")
end)

return cases
