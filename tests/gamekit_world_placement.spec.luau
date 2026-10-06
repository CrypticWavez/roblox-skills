-- GameKit PlacementGrid: footprints and rotation, refusals with reasons (bounds, blocked, zone
-- rules, overlap, duplicates), move and remove, snapping and world poses, free anchors, and
-- placement/1 serialise / restore (including records that no longer fit).
local PlacementGrid = require("../packages/GameKit/PlacementGrid")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local DEFS = {
	block_1x1 = { size = { 1, 1 } },
	wall_3x1 = { size = { 3, 1 } },
	pad_2x2 = { size = { 2, 2 }, tags = { "tower" } },
}

local function grid(extra)
	local options = { width = 8, height = 6, cellSize = 4, origin = { x = -16, z = -12 } }
	for k, value in extra or {} do
		options[k] = value
	end
	return PlacementGrid.new(DEFS, options :: any)
end

test("footprints follow rotation; 90 and 270 swap the sides", function(t)
	local g = grid()
	t.eq(
		g:footprint("wall_3x1", { x = 2, y = 2 }, 0),
		{ { x = 2, y = 2 }, { x = 3, y = 2 }, { x = 4, y = 2 } }
	)
	t.eq(
		g:footprint("wall_3x1", { x = 2, y = 2 }, 90),
		{ { x = 2, y = 2 }, { x = 2, y = 3 }, { x = 2, y = 4 } }
	)
	t.eq({ PlacementGrid.rotatedSize(DEFS.wall_3x1, 270) }, { 1, 3 })
end)

test("refusals carry one reason and the cell that caused it", function(t)
	local g = grid({ blocked = { { x = 5, y = 5 } } })
	t.eq({ g:canPlace("nope", { x = 1, y = 1 }, 0) }, { false, "unknown_item" })
	t.eq({ g:canPlace("block_1x1", { x = 1, y = 1 }, 45) }, { false, "bad_rotation" })
	t.eq({ g:canPlace("wall_3x1", { x = 7, y = 1 }, 0) }, { false, "out_of_bounds", { x = 9, y = 1 } })
	t.eq({ g:canPlace("pad_2x2", { x = 4, y = 4 }, 0) }, { false, "blocked", { x = 5, y = 5 } })
	t.eq({ g:place("a", "pad_2x2", { x = 1, y = 1 }, 0) }, { true })
	t.eq({ g:canPlace("wall_3x1", { x = 2, y = 2 }, 0) }, { false, "occupied", { x = 2, y = 2 } })
	t.eq({ g:place("a", "block_1x1", { x = 6, y = 1 }, 0) }, { false, "duplicate_id" })
	t.eq({ g:place("", "block_1x1", { x = 6, y = 1 }, 0) }, { false, "bad_id" })
	local zoned = grid({
		allowed = function(cell)
			return cell.x <= 4 -- a plot: the left half only
		end,
	})
	t.eq({ zoned:canPlace("wall_3x1", { x = 3, y = 1 }, 0) }, { false, "not_allowed", { x = 5, y = 1 } })
	t.eq({ zoned:canPlace("wall_3x1", { x = 2, y = 1 }, 0) }, { true })
end)

test("move, turn and remove keep the cell map consistent", function(t)
	local g = grid()
	t.eq({ g:place("w", "wall_3x1", { x = 1, y = 1 }, 0) }, { true })
	t.eq({ g:place("b", "block_1x1", { x = 1, y = 3 }, 0) }, { true })
	t.eq({ g:move("w", { x = 1, y = 1 }, 90) }, { false, "occupied" }, "turning onto b")
	t.eq(g:at({ x = 3, y = 1 }), "w", "unchanged after a refused move")
	t.eq({ g:move("w", { x = 2, y = 1 }, 0) }, { true }, "a move may overlap its own cells")
	t.eq(g:at({ x = 1, y = 1 }), nil)
	t.eq(g:at({ x = 4, y = 1 }), "w")
	t.eq({ g:move("missing", { x = 1, y = 1 }, 0) }, { false, "unknown_id" })
	t.eq(g:remove("w"), true)
	t.eq(g:remove("w"), false)
	t.eq(g:at({ x = 3, y = 1 }), nil)
end)

test("snap, world pose and free anchors", function(t)
	local g = grid()
	t.eq(g:snap(-16, -12), { x = 1, y = 1 })
	t.eq(g:snap(-12.1, -8.1), { x = 1, y = 1 })
	t.eq(g:snap(-12, -8), { x = 2, y = 2 })
	t.eq(g:snap(16, 0), nil, "outside")
	g:place("p", "pad_2x2", { x = 3, y = 2 }, 0)
	t.eq(g:worldPose("p"), { x = -16 + 3 * 4, z = -12 + 2 * 4, yaw = 0 })
	g:place("w", "wall_3x1", { x = 6, y = 1 }, 90)
	t.eq(g:worldPose("w"), { x = -16 + 5.5 * 4, z = -12 + 1.5 * 4, yaw = 90 })
	t.eq(g:worldPose("missing"), nil)
	local free = g:freeAnchors("pad_2x2", 0)
	for _, cell in free do
		t.ok((g:canPlace("pad_2x2", cell, 0)))
	end
	t.eq(#free, 7 * 5 - 9 - 6, "35 anchors less those overlapping p (9) or w (6)")
end)

test("serialize and restore round trip; stale records are skipped with a reason", function(t)
	local g = grid()
	g:place("b", "block_1x1", { x = 8, y = 6 }, 0)
	g:place("a", "pad_2x2", { x = 1, y = 1 }, 180)
	local data = g:serialize()
	t.eq(data, {
		format = "placement/1",
		width = 8,
		height = 6,
		items = {
			{ id = "a", key = "pad_2x2", x = 1, y = 1, rotation = 180 },
			{ id = "b", key = "block_1x1", x = 8, y = 6, rotation = 0 },
		},
	})
	local restored, skipped = PlacementGrid.restore(data, DEFS, { width = 8, height = 6 })
	t.eq(skipped, {})
	t.eq((restored :: any):serialize(), data)
	local smaller, dropped = PlacementGrid.restore(data, DEFS, { width = 6, height = 6 })
	t.eq(dropped, { "b: out_of_bounds" })
	t.eq((smaller :: any):at({ x = 2, y = 2 }), "a")
	local _, bad = PlacementGrid.restore({ format = "other" }, DEFS, { width = 1, height = 1 })
	t.eq(bad, { "not placement/1 data" })
end)

test("invalid definitions and options list problems", function(t)
	t.eq(
		PlacementGrid.validate(
			{ ["Bad Key"] = { size = { 0, 1 } } },
			{ width = 0, height = 5, cellSize = -1 }
		),
		{
			"width must be an integer in [1, 4096]",
			"cellSize must be a finite number > 0",
			"definition key Bad Key must be a label",
			"definition Bad Key size must be { w, d } whole cells >= 1",
		}
	)
	t.throws(function()
		PlacementGrid.new(DEFS, { width = 0, height = 1 } :: any)
	end)
end)

return cases
