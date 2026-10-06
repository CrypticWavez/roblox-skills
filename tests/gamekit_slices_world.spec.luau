-- G7 vertical slices in Lune, pinned by tests/golden/gamekit-world.json:
--   course_checkpoints  a ProcGen linear course -> GameKit Checkpoints: one runner at walk speed,
--                       one who skips, teleports and replays (refused), respawns and splits
--   wave_lane           a ProcGen lanes course -> WaveDirector waves on its lanes, NavAgent units
--                       walking the lane cells, PlacementGrid towers on the build slots that pick
--                       targets with Perception and act through a BehaviorTree, leaks to the base
-- Each slice is deterministic (same seed, same digest); the golden stores the digests and the
-- headline numbers. Rewrite it only on an intended change:
-- python3 tools/check.py --update-golden=gamekit-world.
local BT = require("../packages/GameKit/BehaviorTree")
local Checkpoints = require("../packages/GameKit/Checkpoints")
local Course = require("../packages/ProcGen/Course")
local FakeEnv = require("./fakes/FakeEnv")
local Golden = require("./lib/Golden")
local NavAgent = require("../packages/GameKit/NavAgent")
local Perception = require("../packages/GameKit/Perception")
local PlacementGrid = require("../packages/GameKit/PlacementGrid")
local WaveDirector = require("../packages/GameKit/WaveDirector")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local function r2(value: number): number
	return math.round(value * 100) / 100
end

local function courseCheckpoints()
	local course = Course.linear({ seed = 701, length = 24 })
	local spec = Checkpoints.fromCourse(course)
	local env = FakeEnv.new()
	local run = Checkpoints.new(spec, nil, env)
	local log = {}
	run.reached:Connect(function(player, index, lap, split)
		table.insert(log, string.format("reached %s %d lap %d at %.2f", player, index, lap, split))
	end)
	run.rejected:Connect(function(player, index, reason)
		table.insert(log, string.format("rejected %s %d %s", player, index, reason))
	end)
	run.finishedRun:Connect(function(player, time)
		table.insert(log, string.format("finished %s %.2f", player, time))
	end)
	-- Runner 1 walks the pads (plan distance pad to pad at walk speed); runner 2 cheats first.
	local function legTime(fromPad: number, toPad: number): number
		local d = 0
		for i = fromPad + 1, toPad do
			local a, b = course.pads[i - 1].pos, course.pads[i].pos
			d += math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
		end
		return d / course.profile.walkSpeed
	end
	local stops = {}
	for _, cp in course.checkpoints do
		table.insert(stops, cp.pad)
	end
	table.insert(stops, #course.pads)
	run:start("1")
	run:start("2")
	local now = 0
	run:touch("2", 2, spec.checkpoints[2].pos, now)
	run:touch("2", 1, spec.checkpoints[1].pos, now + 0.5)
	local previous = 1
	local respawns = {}
	for index, pad in stops do
		now += legTime(previous, pad)
		previous = pad
		run:touch("1", index, spec.checkpoints[index].pos, now)
		run:touch("1", index, spec.checkpoints[index].pos, now)
		local spot = run:respawn("1")
		table.insert(respawns, { r2(spot.pos.x), r2(spot.pos.y), r2(spot.pos.z) })
	end
	local progress = run:progress("1") :: any
	return {
		course = course.hash,
		checkpoints = #spec.checkpoints,
		finished = progress.finished,
		time = r2(progress.time),
		splits = (function()
			local out = {}
			for _, s in progress.splits do
				table.insert(out, r2(s))
			end
			return out
		end)(),
		rejected = (function()
			local out = {}
			for _, line in log do
				if string.sub(line, 1, 8) == "rejected" then
					table.insert(out, line)
				end
			end
			return out
		end)(),
		respawns = respawns,
		digest = Golden.digest(log),
	}
end

local function waveLane()
	local course = Course.lanes({ seed = 704, lanes = 3, length = 24 })
	local cell = course.grid.cellSize
	local function world(c: { number }): { x: number, y: number, z: number }
		return { x = (c[1] - 0.5) * cell, y = 0, z = (c[2] - 0.5) * cell }
	end
	local laneNames, paths = {}, {}
	for lane, cells in course.paths do
		laneNames[lane] = "lane_" .. lane
		local points = {}
		for _, c in cells do
			table.insert(points, { pos = world(c), action = "walk" })
		end
		paths["lane_" .. lane] = points
	end
	-- The grid blocks the path cells.
	local blocked = {}
	for _, cells in course.paths do
		for _, c in cells do
			table.insert(blocked, { x = c[1], y = c[2] })
		end
	end
	local grid = PlacementGrid.new({ tower_basic = { size = { 1, 1 } } }, {
		width = course.grid.width,
		height = course.grid.height,
		cellSize = cell,
		blocked = blocked,
	})
	-- One tower per lane (its best build slot), so some units get through.
	local towers = {}
	for i, slot in course.slots do
		if slot.index > 1 then
			continue
		end
		local id = "tower_" .. i
		assert(grid:place(id, "tower_basic", { x = slot.cell[1], y = slot.cell[2] }, 0))
		local pose = grid:worldPose(id) :: any
		table.insert(towers, { id = id, pos = { x = pose.x, y = 0, z = pose.z }, cooldown = 0 })
	end

	local env = FakeEnv.new()
	local director = WaveDirector.new({
		groups = {
			{ key = "enemy_basic", cost = 1, weight = 3 },
			{ key = "enemy_heavy", cost = 3, weight = 1, minWave = 2 },
		},
		waves = 3,
		budget = { base = 6, perWave = 3 },
		rest = { base = 4 },
		spawnInterval = 1,
		lanes = laneNames,
	}, { seed = 704 }, env)
	local units = {}
	local log = {}
	local kills, leaks, nextId = 0, 0, 0
	local SPEED, DT, RANGE = 12, 0.25, cell * 2.5

	-- Each tower: a perceiver (360 degree sight, its range) and a tree that fires on the most
	-- recently seen unit when its cooldown allows.
	for _, tower in towers do
		tower.eyes = Perception.new({ fov = 360, sightRange = RANGE, memory = 0.5 }, env)
		tower.tree = BT.new(
			BT.selector({
				BT.sequence({
					BT.condition("has_target", function(bb)
						return bb:get("target") ~= nil
					end),
					BT.cooldown(
						BT.action("fire", function(bb)
							local unit = units[bb:get("target")]
							if unit then
								unit.hp -= 1
							end
							return "success"
						end),
						1
					),
				}, "attack"),
				BT.action("idle", function()
					return "success"
				end),
			}),
			nil,
			env
		)
	end

	director:start()
	for _ = 1, 4000 do
		for _, request in director:tick() do
			nextId += 1
			local id = string.format("u%03d", nextId)
			local agent = NavAgent.new({ arriveRadius = 1 })
			agent:moveTo(paths[request.lane][#paths[request.lane]].pos)
			agent:setPath(paths[request.lane], "Success")
			local start = paths[request.lane][1].pos
			units[id] = {
				id = id,
				agent = agent,
				pos = table.clone(start),
				hp = if request.group == "enemy_heavy" then 8 else 3,
				wave = request.wave,
			}
			table.insert(
				log,
				string.format("%.2f spawn %s %s %s", env.clock(), id, request.group, request.lane)
			)
		end
		-- Units walk (sorted ids keep the order deterministic).
		local ids = {}
		for id in units do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local unit = units[id]
			local command = unit.agent:step(DT, unit.pos)
			if command.kind == "move" then
				local to = command.to :: any
				local dx, dz = to.x - unit.pos.x, to.z - unit.pos.z
				local d = math.sqrt(dx * dx + dz * dz)
				local stepLength = math.min(d, SPEED * DT)
				if d > 0 then
					unit.pos =
						{ x = unit.pos.x + dx / d * stepLength, y = 0, z = unit.pos.z + dz / d * stepLength }
				end
			elseif command.kind == "arrived" then
				leaks += 1
				units[id] = nil
				director:defeated(1)
				table.insert(log, string.format("%.2f leak %s", env.clock(), id))
			end
		end
		-- Towers look and act.
		local targets = {}
		for _, id in ids do
			if units[id] then
				table.insert(targets, { id = id, pos = units[id].pos })
			end
		end
		for _, tower in towers do
			local seen = tower.eyes:sense({ pos = tower.pos, look = { x = 0, y = 0, z = 1 } }, targets)
			local target = nil
			for _, memory in seen do
				if memory.seen and units[memory.id] then
					target = memory.id
					break
				end
			end
			tower.tree.blackboard:set("target", target)
			tower.tree:tick()
		end
		for _, id in ids do
			local unit = units[id]
			if unit and unit.hp <= 0 then
				kills += 1
				units[id] = nil
				director:defeated(1)
				table.insert(log, string.format("%.2f kill %s", env.clock(), id))
			end
		end
		env:advance(DT)
		if director:state() == "done" then
			break
		end
	end
	return {
		course = course.hash,
		towers = #towers,
		spawned = nextId,
		kills = kills,
		leaks = leaks,
		state = director:state(),
		seconds = r2(env.clock()),
		digest = Golden.digest(log),
	}
end

test("the slices are deterministic", function(t)
	t.eq(courseCheckpoints(), courseCheckpoints())
	t.eq(waveLane(), waveLane())
end)

test("course_checkpoints: the walker finishes, the cheater is refused", function(t)
	local slice = courseCheckpoints()
	t.eq(slice.finished, true)
	t.eq(#slice.splits, slice.checkpoints)
	t.eq(slice.rejected[1], "rejected 2 2 skipped")
	t.eq(slice.rejected[2], "rejected 2 1 too_fast")
	t.ok(table.find(slice.rejected, "rejected 1 1 already_reached") ~= nil)
end)

test("wave_lane: every spawned unit is killed or leaks and the director finishes", function(t)
	local slice = waveLane()
	t.eq(slice.state, "done")
	t.eq(slice.kills + slice.leaks, slice.spawned)
	t.ok(slice.kills > 0, "towers fire")
	t.ok(slice.leaks > 0, "some units reach the base")
	t.ok(slice.towers > 0)
end)

test("the slices match tests/golden/gamekit-world.json", function()
	Golden.assert("gamekit-world", { course_checkpoints = courseCheckpoints(), wave_lane = waveLane() })
end)

return cases
