local WorldInspector = require("../../packages/Creator/WorldInspector")
local count = 0
local function check(condition, message)
	assert(condition, message)
	count += 1
end
local function rejects(callback)
	return not pcall(callback)
end
local original = { max_parts = 8, max_descendants = 16 }
local accepted = WorldInspector.validateLimits(original)
original.max_parts = 99999
check(accepted.max_parts == 8, "validation copies caller budgets")
for _, budget in
	{
		{ max_parts = 0 },
		{ max_parts = 1.5 },
		{ max_parts = math.huge },
		{ max_parts = 0 / 0 },
		{ max_parts = 513 },
		{ max_parts = 8, max_descendants = 4 },
		{ cell_size = -1 },
		{ unknown = 1 },
	}
do
	check(
		rejects(function()
			WorldInspector.validateLimits(budget)
		end),
		"invalid finite/count/unknown budget rejected"
	)
end
local coverage = WorldInspector.gridCoverage({ -2, -2, -2 }, { 2, 2, 2 }, 4, { 0, 0, 0 }, 8)
check(
	coverage.references == 8 and coverage.first[1] == -1 and coverage.last[1] == 0,
	"grid covers both sides of negative origin"
)
local shifted = WorldInspector.gridCoverage({ 0, 0, 0 }, { 4, 4, 4 }, 4, { 4, 4, 4 }, 8)
check(
	shifted.references == 8 and shifted.first[1] == -1 and shifted.last[1] == 0,
	"grid uses supplied origin and inclusive box boundary"
)
check(
	rejects(function()
		WorldInspector.gridCoverage({ -2, -2, -2 }, { 2, 2, 2 }, 4, { 0, 0, 0 }, 7)
	end),
	"reference cap fails before enumerating grid"
)
check(
	rejects(function()
		WorldInspector.gridCoverage({ 1, 0, 0 }, { 0, 0, 0 }, 4, { 0, 0, 0 }, 8)
	end),
	"reversed grid bounds rejected"
)
check(
	rejects(function()
		WorldInspector.gridCoverage({ 0 / 0, 0, 0 }, { 0, 0, 0 }, 4, { 0, 0, 0 }, 8)
	end),
	"nonfinite grid coordinates rejected"
)
check(
	rejects(function()
		WorldInspector.gridCoverage(
			{ -1000000, -1000000, -1000000 },
			{ 1000000, 1000000, 1000000 },
			0.01,
			{ 0, 0, 0 },
			16384
		)
	end),
	"extreme finite expansion remains bounded"
)
-- Shared target check (GameKit/Env.check through Env.studio): a fake DataModel stands in for
-- the Roblox globals. A published game or place and a non-Studio session are refused; an
-- unpublished Studio server is accepted (the client-only restriction is gone), so the call
-- gets past the target check and fails on the missing options instead.
local function withGame(fakeGame, callback)
	local globals = getfenv(0)
	local previous = globals.game
	globals.game = fakeGame
	local ok, err = pcall(callback)
	globals.game = previous
	return ok, tostring(err)
end
local function fakeGame(studio, gameId, placeId, client)
	local runService = {
		IsStudio = function()
			return studio
		end,
		IsServer = function()
			return not client
		end,
		IsClient = function()
			return client
		end,
	}
	return {
		GameId = gameId,
		PlaceId = placeId,
		GetService = function(_, name)
			assert(name == "RunService", "unexpected service " .. tostring(name))
			return runService
		end,
	}
end
local function refusal(fake)
	local ok, err = withGame(fake, function()
		WorldInspector.new(nil)
	end)
	check(not ok, "constructor raised")
	return err
end
check(string.find(refusal(nil), "missing_place", 1, true) ~= nil, "no DataModel (Lune) is refused")
check(
	string.find(refusal(fakeGame(true, 4242, 0, false)), "published_game", 1, true) ~= nil,
	"published GameId refused"
)
check(
	string.find(refusal(fakeGame(true, 0, 4242, true)), "published_place", 1, true) ~= nil,
	"published PlaceId refused"
)
check(string.find(refusal(fakeGame(false, 0, 0, true)), "not_studio", 1, true) ~= nil, "live session refused")
local serverErr = refusal(fakeGame(true, 0, 0, false))
check(
	string.find(serverErr, "refused", 1, true) == nil
		and string.find(serverErr, "world inspection options required", 1, true) ~= nil,
	"unpublished Studio server passes the target check: " .. serverErr
)
print(
	"PASS "
		.. count
		.. " world budget/grid cases (target check included); no engine overlap or ray acceptance"
)
