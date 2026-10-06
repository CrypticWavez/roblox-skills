-- GameKit TeamBalance: deterministic splits, sizes within one, parties kept together (oversized
-- parties split and reported), swaps that shrink the skill spread, three teams, and invalid input.
local TeamBalance = require("../packages/GameKit/TeamBalance")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local function players(skills, parties)
	local out = {}
	for i, skill in skills do
		table.insert(
			out,
			{ id = "p" .. string.format("%02d", i), skill = skill, party = parties and parties[i] }
		)
	end
	return out
end

local function teamOf(result, id)
	for t, ids in result.teams do
		if table.find(ids, id) then
			return t
		end
	end
	return nil
end

test("solo players: sizes within one, low spread, same input same teams", function(t)
	local list = players({ 1500, 1400, 1300, 1250, 1200, 1100, 1000, 900, 850, 800 })
	local a = TeamBalance.split(list)
	local b = TeamBalance.split(list)
	t.eq(a, b, "deterministic")
	t.eq(a.sizes, { 5, 5 })
	t.ok(a.spread <= 100, "spread " .. a.spread)
	t.eq(a.totals[1] + a.totals[2], 11300)
	local shuffled = {}
	for i = #list, 1, -1 do
		table.insert(shuffled, list[i])
	end
	t.eq(TeamBalance.split(shuffled).teams, a.teams, "input order does not matter")
end)

test("parties stay together; an oversized party is split and reported", function(t)
	local list = players(
		{ 1000, 1000, 1000, 400, 400, 400, 700, 700 },
		{ "red", "red", "red", nil, nil, nil, "blue", "blue" }
	)
	local result = TeamBalance.split(list)
	t.eq(teamOf(result, "p01"), teamOf(result, "p02"))
	t.eq(teamOf(result, "p02"), teamOf(result, "p03"))
	t.eq(teamOf(result, "p07"), teamOf(result, "p08"))
	t.eq(result.sizes[1] + result.sizes[2], 8)
	t.ok(math.abs(result.sizes[1] - result.sizes[2]) <= 1)
	t.eq(result.splitParties, {})
	local big = players({ 5, 5, 5, 5, 5, 1 }, { "huge", "huge", "huge", "huge", "huge", nil })
	local split = TeamBalance.split(big)
	t.eq(split.splitParties, { "huge" }, "five players cannot fit a team of three")
	t.eq(split.sizes, { 3, 3 })
end)

test("three teams and swaps that shrink the spread", function(t)
	local list = players({ 90, 80, 70, 60, 50, 40, 30, 20, 10 })
	local result = TeamBalance.split(list, { teams = 3 })
	t.eq(result.sizes, { 3, 3, 3 })
	t.ok(
		result.spread <= 20,
		"a heuristic: within 20 of the perfect 150 / 150 / 150 (got " .. result.spread .. ")"
	)
	t.eq(result.totals[1] + result.totals[2] + result.totals[3], 450)
	local noSwaps = TeamBalance.split(players({ 10, 9, 8, 1 }), { swapRounds = 0 })
	local withSwaps = TeamBalance.split(players({ 10, 9, 8, 1 }))
	t.ok(withSwaps.spread <= noSwaps.spread)
end)

test("invalid input lists every problem", function(t)
	t.eq(
		TeamBalance.validate({
			{ id = "a", skill = -1 },
			{ id = "a", skill = 1 },
			{ id = 1.5, skill = 0, party = "Bad Party" },
		}, {
			teams = 1,
			maxSizeDiff = -1,
		}),
		{
			"teams must be an integer >= 2",
			"maxSizeDiff must be an integer >= 0",
			"player a skill must be a finite number >= 0",
			"player 2 duplicate id a",
			"player 3 id must be a string or an integer",
			"player 1.5 party must be a label",
		}
	)
	t.throws(function()
		TeamBalance.split({ { id = "a", skill = 0 / 0 } })
	end)
end)

return cases
