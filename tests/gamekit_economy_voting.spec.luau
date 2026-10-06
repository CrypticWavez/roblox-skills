--!strict
-- GameKit/VotingRound: phases, seeded ballots without self entries, vote refusals, exact mean
-- ranking, seeded and shared tie-breaks, minVotes, spectators and players leaving.
local VotingRound = require("../packages/GameKit/VotingRound")
local FakeEnv = require("./fakes/FakeEnv")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function round(extra: { [string]: any }?): any
	local options: any = { id = "round_a", seed = 7 }
	for key, value in extra or {} do
		options[key] = value
	end
	local r = VotingRound.new(options, FakeEnv.new())
	for _, player in { "p1", "p2", "p3", "p4" } do
		assert(r:submit(player, { look = player }))
	end
	return r
end

local function owners(results: { any }): { string }
	local out = {}
	for _, result in results do
		table.insert(out, result.owner)
	end
	return out
end

test("options are validated", function(t)
	t.throws(function()
		VotingRound.new({ id = "Round A", seed = 1 } :: any)
	end)
	t.throws(function()
		VotingRound.new({ id = "round_a" } :: any)
	end)
	t.throws(function()
		VotingRound.new({ id = "round_a", seed = 1, scale = { min = 5, max = 1 } })
	end)
	t.throws(function()
		VotingRound.new({ id = "round_a", seed = 1, tieBreak = "random" } :: any)
	end)
	t.throws(function()
		VotingRound.new({ id = "round_a", seed = 1, minVotes = -1 })
	end)
end)

test("phases gate submissions and votes", function(t)
	local r = VotingRound.new({ id = "round_a", seed = 1 })
	t.eq({ r:vote("p1", "p2", 3) }, { false, "wrong_phase" })
	t.eq({ r:submit("bad player", {}) }, { false, "invalid_player" })
	t.eq({ r:submit("p1", "text" :: any) }, { false, "invalid_entry" })
	t.ok((r:submit("p1", { v = 1 })))
	t.eq({ r:startVoting() }, { false, "not_enough_entries" })
	r:submit("p2")
	t.ok((r:submit("p1", { v = 2 })), "replacing an entry keeps one slot")
	t.eq(r:entries(), { "p1", "p2" })
	t.eq(r:results(), nil)
	t.ok((r:startVoting()))
	t.eq(r:phase(), "voting")
	t.eq({ r:submit("p3", {}) }, { false, "wrong_phase" })
	t.eq({ r:startVoting() }, { false, "wrong_phase" })
	r:close()
	t.eq(r:phase(), "closed")
	t.eq({ r:vote("p1", "p2", 3) }, { false, "wrong_phase" })
	for _, result in r:close() do
		if result.owner == "p1" then
			t.eq(result.entry, { v = 2 })
		end
	end
end)

test("ballots are seeded, complete and never include the voter's own entry", function(t)
	local a, b = round(), round()
	a:startVoting()
	b:startVoting()
	for _, voter in { "p1", "p2", "p3", "p4" } do
		local ballot = a:ballot(voter)
		t.eq(#ballot, 3)
		t.ok(table.find(ballot, voter) == nil)
		t.eq(ballot, b:ballot(voter), "same seed, same ballot")
	end
	local other = round({ seed = 8 })
	other:startVoting()
	local differs = false
	for _, voter in { "p1", "p2", "p3", "p4" } do
		local x, y = a:ballot(voter), other:ballot(voter)
		for i = 1, 3 do
			differs = differs or x[i] ~= y[i]
		end
	end
	t.ok(differs, "another seed deals other orders")
	t.eq(a:ballot("spectator"), {})
end)

test("vote refusals cover self votes, unknown entries, outsiders and the scale", function(t)
	local r = round({ allowRevote = false })
	r:startVoting()
	t.eq({ r:vote("p1", "p1", 3) }, { false, "self_vote" })
	t.eq({ r:vote("p1", "p9", 3) }, { false, "unknown_entry" })
	t.eq({ r:vote("outsider", "p1", 3) }, { false, "not_a_participant" })
	t.eq({ r:vote("p1", "p2", 6) }, { false, "invalid_score" })
	t.eq({ r:vote("p1", "p2", 0) }, { false, "invalid_score" })
	t.eq({ r:vote("p1", "p2", 2.5) }, { false, "invalid_score" })
	t.eq({ r:vote("", "p2", 3) }, { false, "invalid_player" })
	t.eq({ r:vote("p1", "p2", 4) }, { true, nil })
	t.eq({ r:vote("p1", "p2", 5) }, { false, "already_voted" })
	t.eq(r:votesBy("p1"), { p2 = 4 })
	local revote = round()
	revote:startVoting()
	revote:vote("p1", "p2", 1)
	revote:vote("p1", "p2", 5)
	t.eq(revote:votesBy("p1"), { p2 = 5 }, "a revote replaces the score")
end)

test("ranking compares means exactly, then vote counts", function(t)
	local r = round()
	r:startVoting()
	-- p1: 5, 4 (mean 4.5, 2 votes); p2: 5, 4, 5, ... ; p3: 3 (one vote); p4: no votes.
	r:vote("p2", "p1", 5)
	r:vote("p3", "p1", 4)
	r:vote("p1", "p2", 5)
	r:vote("p3", "p2", 4)
	r:vote("p4", "p2", 5)
	r:vote("p4", "p1", 5)
	r:vote("p1", "p3", 3)
	-- p1: 5 + 4 + 5 = 14 / 3; p2: 5 + 4 + 5 = 14 / 3 -> equal means and counts (tie-break).
	local preview = assert(r:results(true))
	t.eq(r:phase(), "voting", "preview does not close")
	local results = r:close()
	t.eq(owners(results), owners(preview))
	t.eq(results[1].sum, 14)
	t.eq(results[1].count, 3)
	t.near(results[1].mean, 14 / 3, 1e-12)
	t.eq(results[3].owner, "p3")
	t.eq(results[4].owner, "p4")
	t.eq(results[4].qualified, false, "no votes never qualifies")
	t.eq({ results[1].rank, results[2].rank, results[3].rank, results[4].rank }, { 1, 2, 3, 4 })
	-- Equal means with different counts: more votes wins (6 / 2 before 3 / 1).
	local exact = round()
	exact:startVoting()
	exact:vote("p2", "p1", 3) -- p1: 3 / 1
	exact:vote("p1", "p2", 3)
	exact:vote("p3", "p2", 3) -- p2: 6 / 2
	exact:vote("p1", "p3", 1)
	exact:vote("p2", "p3", 2) -- p3: 3 / 2
	exact:vote("p1", "p4", 2) -- p4: 2 / 1
	t.eq(owners(exact:close()), { "p2", "p1", "p4", "p3" })
end)

test("seeded tie-breaks are stable; shared ties share a rank", function(t)
	local function tied(tieBreak: string?, seed: number): any
		local r = round({ tieBreak = tieBreak, seed = seed })
		r:startVoting()
		for _, voter in { "p1", "p2", "p3", "p4" } do
			for _, owner in { "p1", "p2", "p3", "p4" } do
				if voter ~= owner then
					r:vote(voter, owner, 3)
				end
			end
		end
		return r:close()
	end
	local first, again = tied(nil, 11), tied(nil, 11)
	t.eq(owners(first), owners(again), "same seed, same order")
	t.eq({ first[1].rank, first[4].rank }, { 1, 4 })
	local seen = {}
	for seed = 1, 12 do
		seen[tied(nil, seed)[1].owner] = true
	end
	local winners = 0
	for _ in seen do
		winners += 1
	end
	t.ok(winners >= 2, "the seeded tie-break is not submission order")
	local shared = tied("shared", 11)
	for _, result in shared do
		t.eq(result.rank, 1)
	end
end)

test("minVotes ranks thin entries last; spectators and leavers", function(t)
	local r = round({ minVotes = 2, votersMustSubmit = false })
	r:startVoting()
	t.eq(#r:ballot("spectator"), 4, "spectators judge every entry")
	r:vote("spectator", "p1", 5) -- p1: one vote at 5 (not qualified)
	r:vote("p3", "p2", 2)
	r:vote("p4", "p2", 2) -- p2: two votes at 2 (qualified)
	r:vote("p2", "p4", 1)
	r:vote("p1", "p4", 1)
	r:vote("p3", "p4", 1) -- p4: three votes at 1 (qualified)
	t.ok(r:remove("p3"), "p3 leaves: entry, ballot and votes go")
	t.eq(r:entries(), { "p1", "p2", "p4" })
	t.eq(r:votesBy("p3"), {})
	local results = r:close()
	-- p4 (2 votes, qualified) first; then p1 (5 / 1) and p2 (2 / 1 after p3's vote went).
	t.eq(owners(results), { "p4", "p1", "p2" })
	t.eq({ results[1].qualified, results[2].qualified, results[3].qualified }, { true, false, false })
	t.eq(results[3].count, 1, "p3's vote for p2 was removed")
	t.ok(not r:remove("p1"), "nothing changes after close")
end)

return cases
