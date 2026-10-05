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
print("PASS " .. count .. " world budget/grid cases; no engine overlap or ray acceptance")
