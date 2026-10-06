-- GameKit Leaderboard (ranking modes, tie-breaks, score validation, packing, in-memory board),
-- LeaderboardRoblox on FakeOrderedStore (writes off by default, best-score updates, pages, packed
-- time tie-breaks, Retry on throttles, fatal errors stop), and LiveBoard on FakeLiveSortedMap
-- (best score kept, expiry, descending ranges, the LiveBoardRoblox direction mapping).
local FakeEnv = require("./fakes/FakeEnv")
local FakeLiveSortedMap = require("./fakes/FakeLiveSortedMap")
local FakeOrderedStore = require("./fakes/FakeOrderedStore")
local Leaderboard = require("../packages/GameKit/Leaderboard")
local LeaderboardRoblox = require("../packages/GameKit/LeaderboardRoblox")
local LiveBoard = require("../packages/GameKit/LiveBoard")
local LiveBoardRoblox = require("../packages/GameKit/LiveBoardRoblox")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local ENTRIES = {
	{ key = "a", score = 50, at = 30 },
	{ key = "b", score = 70, at = 10 },
	{ key = "c", score = 50, at = 20 },
	{ key = "d", score = 40 },
	{ key = "e", score = 50, at = 20 },
}

local function ranks(list)
	local out = {}
	for _, e in list do
		table.insert(out, e.key .. "=" .. e.rank)
	end
	return out
end

test("ranking modes and tie-breaks", function(t)
	t.eq(
		ranks(Leaderboard.rank(ENTRIES)),
		{ "b=1", "c=2", "e=2", "a=2", "d=5" },
		"standard; ties by at then key"
	)
	t.eq(ranks(Leaderboard.rank(ENTRIES, { ranks = "dense" })), { "b=1", "c=2", "e=2", "a=2", "d=3" })
	t.eq(ranks(Leaderboard.rank(ENTRIES, { ranks = "ordinal" })), { "b=1", "c=2", "e=3", "a=4", "d=5" })
	t.eq(ranks(Leaderboard.rank(ENTRIES, { order = "asc" })), { "d=1", "c=2", "e=2", "a=2", "b=5" })
end)

test("score validation and packing", function(t)
	t.eq(Leaderboard.scoreProblem(0 / 0), "not_finite")
	t.eq(Leaderboard.scoreProblem(1.5), "not_integer")
	t.eq(Leaderboard.scoreProblem(1.5, { integer = false }), nil)
	t.eq(Leaderboard.scoreProblem(-1), "out_of_range")
	t.eq(Leaderboard.scoreProblem(11, { max = 10 }), "out_of_range")
	local horizon = 86400
	local early, late = Leaderboard.pack(100, 5, horizon), Leaderboard.pack(100, 500, horizon)
	t.ok(early > late, "same score: the earlier time packs higher")
	t.ok(Leaderboard.pack(101, 86399, horizon) > early, "a better score always wins")
	t.eq({ Leaderboard.unpack(late, horizon) }, { 100, 500 })
	t.throws(function()
		Leaderboard.pack(2 ^ 40, 0, 2 ^ 20)
	end, "beyond 2^53")
	t.eq(Leaderboard.validate({ order = "up", ranks = "x", min = 5, max = 1, limit = 0 }), {
		"order must be desc or asc",
		"ranks must be standard, dense or ordinal",
		"min and max must be finite with min <= max",
		"limit must be an integer >= 1",
	})
end)

test("an in-memory board keeps the best score per key and trims to its limit", function(t)
	local board = Leaderboard.new({ limit = 3 })
	t.eq({ board:submit("a", 10, 1) }, { true, nil })
	t.eq({ board:submit("a", 5, 2) }, { false, "not_better" })
	t.eq({ board:submit("a", 12, 3) }, { true, nil })
	board:submit("b", 20, 4)
	board:submit("c", 15, 5)
	t.eq({ board:submit("d", 1, 6) }, { false, "below_limit" })
	t.eq({ board:submit("", 1) }, { false, "bad_key" })
	t.eq({ board:submit("e", 2.5) }, { false, "not_integer" })
	t.eq(ranks(board:top(2)), { "b=1", "c=2" })
	t.eq((board:rankOf("a") :: any).rank, 3)
	t.eq(board:rankOf("d"), nil)
	t.eq(board:remove("a"), true)
	t.eq(#board:snapshot(), 2)
end)

local function robloxEnv(service)
	local env = FakeEnv.new({ seed = 3 })
	env:register("DataStoreService", service)
	return env
end

local NO_WAIT = { attempts = 3, base = 0, jitter = "none", wait = function() end }

test("LeaderboardRoblox: writes are off by default; updates keep the best; pages rank", function(t)
	local service = FakeOrderedStore.new()
	local env = robloxEnv(service)
	local readOnly = LeaderboardRoblox.new("board_a", { retry = NO_WAIT }, env)
	t.eq({ readOnly:submit("1", 10) }, { false, "writes_disabled" })
	t.eq(#service.calls, 0, "nothing written")
	local board = LeaderboardRoblox.new("board_a", { writes = true, retry = NO_WAIT }, env)
	t.eq({ board:submit("1", 10) }, { true, 10 })
	t.eq({ board:submit("1", 5) }, { true, 10 }, "a worse score keeps the stored value")
	t.eq({ board:submit("1", 1.5) }, { false, "not_integer" })
	for i = 2, 150 do
		board:submit(tostring(i), i)
	end
	local ok, top = board:top(120)
	t.eq(ok, true)
	t.eq(#top, 120, "two pages")
	t.eq(top[1].key, "150")
	t.eq(top[1].rank, 1)
	t.eq(top[120].score, 31)
	t.eq({ board:get("1") }, { true, { key = "1", score = 10 } })
	t.eq({ board:get("missing") }, { true, nil })
end)

test("LeaderboardRoblox: packed times break ties; throttles retry, fatal errors stop", function(t)
	local service = FakeOrderedStore.new()
	local env = robloxEnv(service)
	local board = LeaderboardRoblox.new("timed", { writes = true, horizon = 86400, retry = NO_WAIT }, env)
	board:submit("late", 100, 900)
	board:submit("early", 100, 30)
	board:submit("best", 101, 80000)
	t.eq({ board:submit("x", 1, 86400) }, { false, "bad_time" })
	local _, top = board:top(3)
	t.eq(ranks(top), { "best=1", "early=2", "late=3" })
	t.eq(top[2].at, 30)
	service:failNext("UpdateAsync", "304: request was throttled", 2)
	t.eq(
		{ board:submit("late", 120, 1000) },
		{ true, Leaderboard.pack(120, 1000, 86400) },
		"retried past two throttles"
	)
	service:failNext("UpdateAsync", "104: value not allowed", 1)
	local ok, err = board:submit("late", 130, 1000)
	t.eq(ok, false)
	t.eq(err, "104: value not allowed")
	t.eq(LeaderboardRoblox.validate("", { horizon = 0 }), {
		"name must be a string of 1-50 characters (DataStore name limit)",
		"horizon must be an integer >= 1",
	})
end)

test("LiveBoard on a sorted map: best score, expiry, descending top", function(t)
	local env = FakeEnv.new()
	local map = FakeLiveSortedMap.new(env.clock)
	local board = LiveBoard.new(map, { ttl = 60 }, env)
	t.eq({ board:submit("1", 12.5) }, { true, nil })
	t.eq({ board:submit("1", 3) }, { false, "not_better" })
	env:advance(5)
	board:submit("2", 40)
	board:submit("3", 12.5)
	t.eq(ranks(board:top(10)), { "2=1", "1=2", "3=2" }, "tie: 1 scored first")
	t.eq(board:get("2"), { key = "2", score = 40, at = 5 })
	env:advance(56)
	t.eq(ranks(board:top(10)), { "2=1", "3=2" }, "1 expired 60 s after its write")
	board:remove("2")
	t.eq(board:get("2"), nil)
	t.eq({ board:submit(string.rep("k", 129), 1) }, { false, "bad_key" })
	t.eq(
		LiveBoard.validate({ ttl = 4000000 }),
		{ "ttl must be in (0, 3888000] seconds (MemoryStore expiration limit)" }
	)
	t.throws(function()
		LiveBoard.new(nil, nil, env)
	end)
end)

test("ascending LiveBoards and the LiveBoardRoblox direction mapping", function(t)
	local env = FakeEnv.new()
	local board = LiveBoard.new(FakeLiveSortedMap.new(env.clock), { order = "asc" }, env)
	board:submit("slow", 95.2, 1)
	board:submit("fast", 61.7, 2)
	board:submit("fast", 70, 3)
	t.eq(ranks(board:top(5)), { "fast=1", "slow=2" })
	t.eq((board:get("fast") :: any).score, 61.7)
	t.eq(LiveBoardRoblox.direction("Descending"), "Descending")
	t.throws(function()
		LiveBoardRoblox.direction("Sideways")
	end)
end)

return cases
