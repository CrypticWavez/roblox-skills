--!strict
-- Cross-group integration slices (after the merge of every kit group), pinned by
-- tests/golden/slices-integration.json. Each slice composes modules of at least three groups
-- through their public APIs, seeded and deterministic, with fakes injected through env, and
-- asserts its invariants before its digest goes into the golden (each section header names its
-- modules):
--   race_loop_vehicle       Course raceLoop -> Zones gates -> Vehicles bots -> Checkpoints ->
--                           Leaderboard -> Telemetry; a teleporting cheat is refused everywhere
--   stalker_ai              Dungeon -> NavAgentRoblox over FakePathfinding -> Perception ->
--                           BehaviorTree -> Vitals -> RoundLoop -> AudioCues and Shake (Settings)
--   projectile_arena        Course microArena -> TeamBalance -> RoundLoop -> RemoteGuard ->
--                           Projectile and Hitbox rewind -> Vitals -> Wallet and Progression ->
--                           HitStop and Popups; one exploiter is refused on every request
--   session_persistence     PlayerData (two servers) -> Wallet, Inventory, Progression,
--                           SettingsStore, Onboarding -> Commerce receipts -> Telemetry
--   ui_onboarding_flow      Onboarding over PlayerData -> Settings reduced motion -> Cinematics
--                           hold-to-skip -> InputMap contexts -> UIKit Modal and components
--   authority_input_client  the Studio client fixture loaded with @lune/luau: InputMap ->
--                           InputMapRoblox -> AuthorityRoblox payloads into the fixture arena
-- Rewrite the golden only on an intended change:
--   FACTORY_UPDATE_GOLDEN=slices-integration lune run tests/run.luau slices_integration
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local AudioCues = require("../packages/AVKit/AudioCues")
local AuthorityArena = require("../fixtures/kits/shared/authority_Arena")
local AuthorityRoblox = require("../packages/GameKit/AuthorityRoblox")
local BT = require("../packages/GameKit/BehaviorTree")
local Build = require("../packages/UIKit/Build")
local Catalog = require("../packages/GameKit/Catalog")
local Checkpoints = require("../packages/GameKit/Checkpoints")
local Cinematics = require("../packages/Cinematics/Cinematics")
local Commerce = require("../packages/GameKit/Commerce")
local Cooldowns = require("../packages/GameKit/Cooldowns")
local Course = require("../packages/ProcGen/Course")
local Dungeon = require("../packages/ProcGen/Dungeon")
local Events = require("../packages/GameKit/Events")
local FakeEnv = require("./fakes/FakeEnv")
local FakePathfinding = require("./fakes/FakePathfinding")
local FakeUIEvents = require("./fakes/FakeUIEvents")
local Golden = require("./lib/Golden")
local HitStop = require("../packages/Feel/HitStop")
local Hitbox = require("../packages/GameKit/Hitbox")
local InputMap = require("../packages/GameKit/InputMap")
local InputMapRoblox = require("../packages/GameKit/InputMapRoblox")
local Inventory = require("../packages/GameKit/Inventory")
local ItemDefs = require("../packages/GameKit/ItemDefs")
local Json = require("../packages/GameKit/Json")
local Leaderboard = require("../packages/GameKit/Leaderboard")
local Movement = require("../packages/GameKit/Movement")
local MovementRoblox = require("../packages/GameKit/MovementRoblox")
local NavAgentRoblox = require("../packages/GameKit/NavAgentRoblox")
local Onboarding = require("../packages/GameKit/Onboarding")
local Perception = require("../packages/GameKit/Perception")
local PlayerData = require("../packages/GameKit/PlayerData")
local Popups = require("../packages/Feel/Popups")
local Progression = require("../packages/GameKit/Progression")
local Projectile = require("../packages/GameKit/Projectile")
local RemoteGuard = require("../packages/GameKit/RemoteGuard")
local Rng = require("../packages/ProcGen/Rng")
local RoundLoop = require("../packages/GameKit/RoundLoop")
local Schema = require("../packages/GameKit/Schema")
local Settings = require("../packages/GameKit/Settings")
local SettingsStore = require("../packages/GameKit/SettingsStore")
local Shake = require("../packages/Feel/Shake")
local TeamBalance = require("../packages/GameKit/TeamBalance")
local Telemetry = require("../packages/GameKit/Telemetry")
local UIKit = require("../packages/UIKit/UIKit")
local Vec = require("../packages/SceneKit/Vec")
local Vehicles = require("../packages/GameKit/Vehicles")
local Vitals = require("../packages/GameKit/Vitals")
local Wallet = require("../packages/GameKit/Wallet")
local Zones = require("../packages/GameKit/Zones")
local ORBIT = require("../fixtures/kits/shared/cin_setup_only_orbit")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

-- t.eq with both sides in the message as canonical JSON (t.eq prints table addresses).
local function same(t: any, actual: any, expected: any, message: string?)
	if Json.encode(actual) ~= Json.encode(expected) then
		error(
			string.format(
				"%s: expected %s, got %s",
				message or "same",
				Json.encode(expected),
				Json.encode(actual)
			),
			2
		)
	end
	t.eq(actual, expected, message)
end

local function r3(value: number): number
	return math.round(value * 1000) / 1000
end

-- Each slice runs once per spec run; its cases and the golden case share the result.
local memo: { [string]: any } = {}
local function once(name: string, fn: () -> any): any
	if memo[name] == nil then
		memo[name] = fn()
	end
	return memo[name]
end

local ENVELOPE = { environment = "lune", synthetic = true }

-- ---------------------------------------------------------------- race_loop_vehicle

local RACE = { laps = 2, bots = 4, dt = 1 / 60, maxSteps = 6000 }

local function raceLoopVehicle(): { [string]: any }
	local course = Course.raceLoop({
		seed = "slices:race",
		laps = RACE.laps,
		length = 900,
		width = 30,
		gates = 6,
		segmentKinds = { "straight", "sweeper", "corner" },
	})
	local env = FakeEnv.new({ seed = "slices:race" })
	local recorder = Events.recorder({ strict = true })
	local telemetry =
		Telemetry.new({ sink = recorder, envelope = ENVELOPE, strict = true, budget = false }, env)

	-- One car definition (fixture values, not tuning); each bot gets its own throttle from a
	-- string-seeded Rng, so lap times differ.
	local car = Vehicles.define({
		maxSpeed = 60,
		acceleration = 30,
		brake = 60,
		steerRate = 2.5,
		grip = 8,
	})
	local limits = Vehicles.limits(car)

	-- Course gates as a Zones course: a thin box across the track at each gate, facing the
	-- direction of travel. ProcGen yaw looks along (sin yaw, cos yaw); the last gate is the line.
	local samples = course.samples
	local gateCount = #course.checkpoints
	local defs = {}
	for _, cp in course.checkpoints do
		local yaw = math.rad(cp.yaw)
		local f = { x = math.sin(yaw), z = math.cos(yaw) }
		local l = { x = math.cos(yaw), z = -math.sin(yaw) }
		local half = cp.width / 2
		local function corner(a: number, b: number): { x: number, z: number }
			return { x = cp.pos.x + f.x * a + l.x * b, z = cp.pos.z + f.z * a + l.z * b }
		end
		-- The least time from the previous gate at top speed (straight line less both widths):
		-- a teleport or a shortcut arrives sooner.
		local previous = course.checkpoints[(cp.index - 2) % gateCount + 1]
		local gap = math.sqrt((cp.pos.x - previous.pos.x) ^ 2 + (cp.pos.z - previous.pos.z) ^ 2)
		local minTime = math.max(0.5, (gap - cp.width) / (car.maxSpeed * 1.25))
		table.insert(defs, {
			id = "gate_" .. cp.index,
			kind = "gate",
			shape = Zones.prism(
				{ corner(-1, -half), corner(1, -half), corner(1, half), corner(-1, half) },
				-10,
				20
			),
			gate = {
				order = cp.index,
				finish = cp.index == gateCount,
				direction = Vec.new(f.x, 0, f.z),
				minTime = minTime,
			},
		})
	end
	local set = Zones.define(defs)
	assert(#Zones.validateCourse(set, { laps = RACE.laps }) == 0, "the gates form a course")
	local tracker = Zones.tracker(set, nil, env)
	local zoneCourse = Zones.course(set, { laps = RACE.laps }, env)
	local lineId = "gate_" .. gateCount

	-- Checkpoints from the same manifest. fromCourse sizes maxSpeed from the walking profile
	-- (walkSpeed x 1.25); a vehicle course passes its own top speed with the same slack.
	local spec = Checkpoints.fromCourse(course)
	spec.maxSpeed = car.maxSpeed * 1.25
	local checkpoints = Checkpoints.new(spec, { sink = telemetry }, env)

	local board = Leaderboard.new({ order = "asc", ranks = "standard" })
	local log: { string } = {}
	local function note(text: string)
		table.insert(log, string.format("%.3f %s", env.clock(), text))
	end

	local function nearest(position: Vec.V3, from: number): number
		-- Walks forward from the last sample while the next one is closer.
		local n = #samples
		local index = from
		for _ = 1, n do
			local here, ahead = samples[index].pos, samples[index % n + 1].pos
			local dHere = (here.x - position.x) ^ 2 + (here.z - position.z) ^ 2
			local dAhead = (ahead.x - position.x) ^ 2 + (ahead.z - position.z) ^ 2
			if dAhead >= dHere then
				break
			end
			index = index % n + 1
		end
		return index
	end

	local bots = {}
	for i = 1, RACE.bots do
		local slot = course.spawn.slots[i]
		local rng = Rng.new("slices:race:bot:" .. i)
		local key = "bot_" .. i
		bots[i] = {
			key = key,
			vehicle = Vehicles.new(
				car,
				{ position = Vec.new(slot.pos.x, 0, slot.pos.z), heading = math.rad(slot.yaw) + math.pi },
				env
			),
			throttle = 0.85 + 0.15 * rng:next(),
			cruise = 45 + 14 * rng:next(), -- the bot's own top speed (its "skill")
			cornerSpeed = 28 + 14 * rng:next(),
			sample = slot.sample,
			leftGrid = false,
			sectors = {},
			refusals = {},
			maxLateral = 0,
		}
		tracker:update(key, bots[i].vehicle.state.position)
	end

	-- The cheat: a scripted body that drives the line legitimately, then reports two jumps
	-- after gate 1 (onto gate 2 at once, then onto gate 3).
	local cheat = {
		key = "bot_cheat",
		pos = Vec.new(course.spawn.slots[5].pos.x, 0, course.spawn.slots[5].pos.z),
		sample = course.spawn.slots[5].sample,
		leftGrid = false,
		jumps = 0,
		travel = {},
		course = {},
		checkpoints = {},
	}
	tracker:update(cheat.key, cheat.pos)

	-- A standing start: every timer starts at 0 on the grid behind the line, and each body's
	-- first forward crossing of the line is the start, not gate N of the course.
	for _, body in { bots[1], bots[2], bots[3], bots[4], cheat } do
		zoneCourse:start(body.key)
		checkpoints:start(body.key)
	end
	local function feed(body: any, position: Vec.V3, onEvent: (event: any) -> ())
		local events = {}
		for _, event in tracker:update(body.key, position) do
			if not body.leftGrid and event.kind == "enter" and event.zone == lineId and event.forward then
				body.leftGrid = true
				note(body.key .. " over the line")
			else
				table.insert(events, event)
			end
		end
		for _, event in zoneCourse:observe(events) do
			onEvent(event)
		end
	end

	local finished = 0
	local steps = 0
	while finished < RACE.bots and steps < RACE.maxSteps do
		steps += 1
		env:advance(RACE.dt)
		local now = env.clock()
		for _, bot in bots do
			local vehicle = bot.vehicle
			local state = vehicle.state
			bot.sample = nearest(state.position, bot.sample)
			local centre = samples[bot.sample].pos
			bot.maxLateral = math.max(
				bot.maxLateral,
				math.sqrt((centre.x - state.position.x) ^ 2 + (centre.z - state.position.z) ^ 2)
			)
			local look = 4 + math.floor(vehicle:speed() / 8)
			local aimPoint = samples[(bot.sample + look - 1) % #samples + 1].pos
			local aim = Vec.sub(Vec.new(aimPoint.x, 0, aimPoint.z), state.position)
			local forward = Vehicles.forward(state.heading)
			local cross = forward.z * aim.x - forward.x * aim.z
			local angle = math.atan2(cross, Vec.dot(forward, aim))
			local braking = math.abs(angle) > 0.35 and vehicle:speed() > bot.cornerSpeed
			local cruising = vehicle:speed() >= bot.cruise
			vehicle:step(RACE.dt, {
				throttle = if braking then -0.4 elseif cruising then 0 else bot.throttle,
				steer = math.clamp(angle * 2.5, -1, 1),
			})
			local position = vehicle.state.position
			feed(bot, position, function(event)
				if event.kind == "sector" then
					table.insert(bot.sectors, event.order)
					local ok, reason = checkpoints:touch(bot.key, event.order, position)
					if not ok then
						table.insert(bot.refusals, "checkpoints:" .. tostring(reason))
					end
				elseif event.kind == "lap" then
					local ms = math.round(event.lapTime * 1000)
					board:submit(bot.key, ms, steps)
					telemetry:progression(bot.key, "race", "custom", event.lap)
					note(string.format("%s lap %d %.3f", bot.key, event.lap, event.lapTime))
				elseif event.kind == "finish" then
					finished += 1
					telemetry:custom(bot.key, "race_finish", r3(event.total))
					note(string.format("%s finish %.3f", bot.key, event.total))
				else
					table.insert(bot.refusals, "zones:" .. event.kind)
				end
			end)
		end

		-- The cheat moves sample to sample at 30 studs/s until it has passed gate 1.
		local progress = zoneCourse:progress(cheat.key)
		local passedFirst = progress ~= nil and progress.gates >= 1
		local nextPos: Vec.V3
		if not passedFirst or cheat.jumps >= 2 then
			local target = samples[cheat.sample % #samples + 1].pos
			local to = Vec.new(target.x, 0, target.z)
			local delta = Vec.sub(to, cheat.pos)
			local length = Vec.length(delta)
			local stepLength = 30 * RACE.dt
			if length <= stepLength then
				nextPos = to
				cheat.sample = cheat.sample % #samples + 1
			else
				nextPos = Vec.add(cheat.pos, Vec.scale(delta, stepLength / length))
			end
		else
			cheat.jumps += 1
			local gate = course.checkpoints[cheat.jumps + 1]
			nextPos = Vec.new(gate.pos.x, 0, gate.pos.z)
		end
		if cheat.jumps < 3 then
			-- What the server's travel check says about the report ...
			local ok, reason = Movement.checkTravel(limits, cheat.pos, nextPos, RACE.dt)
			if not ok then
				table.insert(cheat.travel, reason)
			end
			-- ... and what the gates say when a game skips that check (defence in depth).
			feed(cheat, nextPos, function(event)
				if event.kind == "sector" then
					local okTouch, why = checkpoints:touch(cheat.key, event.order, nextPos, now)
					if not okTouch then
						table.insert(cheat.checkpoints, why)
					end
				else
					table.insert(cheat.course, event.kind)
				end
				if event.kind == "wrong_gate" or event.kind == "too_fast" then
					-- The gate refused it; the checkpoint layer gets the same claim.
					local _, why = checkpoints:touch(cheat.key, event.order, nextPos, now)
					table.insert(cheat.checkpoints, why)
				end
			end)
			cheat.pos = nextPos
			if cheat.jumps == 2 then
				cheat.jumps = 3 -- both jumps reported; the cheat is out of the race
			end
		end
	end

	local results = {}
	for _, bot in bots do
		local zp = zoneCourse:progress(bot.key) :: any
		local cp = checkpoints:progress(bot.key) :: any
		results[bot.key] = {
			laps = table.clone(zp.laps),
			total = zp.total,
			finished = zp.finished,
			gates = zp.gates,
			checkpointTime = cp and cp.time,
			checkpointFinished = cp and cp.finished,
			checkpointStages = cp and cp.stage,
			sectors = bot.sectors,
			refusals = bot.refusals,
			maxLateral = bot.maxLateral,
		}
	end
	return {
		course = course,
		gateCount = gateCount,
		steps = steps,
		results = results,
		cheat = {
			travel = cheat.travel,
			course = cheat.course,
			checkpoints = cheat.checkpoints,
			progress = zoneCourse:progress(cheat.key),
			checkpointProgress = checkpoints:progress(cheat.key),
		},
		board = board,
		standings = zoneCourse:standings(),
		recorder = recorder,
		report = telemetry:report(),
		log = log,
	}
end

local function race(): { [string]: any }
	return once("race", raceLoopVehicle)
end

test("race_loop_vehicle: every bot finishes the laps through the gates in order", function(t)
	local run = race()
	t.ok(run.steps < RACE.maxSteps, "the race ends before the step cap")
	for i = 1, RACE.bots do
		local key = "bot_" .. i
		local result = run.results[key]
		t.ok(result.finished, key .. " finished")
		t.eq(#result.laps, RACE.laps, key .. " laps")
		t.eq(result.gates, RACE.laps * run.gateCount, key .. " gates")
		local expected = {}
		for _ = 1, RACE.laps do
			for order = 1, run.gateCount do
				table.insert(expected, order)
			end
		end
		same(t, result.sectors, expected, key .. " crossed the gates in order")
		same(t, result.refusals, {}, key .. " was never refused")
		-- Zones and Checkpoints agree: same stages, same finish time on the same clock.
		t.ok(result.checkpointFinished, key .. " checkpoints finished")
		t.eq(result.checkpointStages, RACE.laps * run.gateCount, key .. " checkpoint stages")
		t.eq(result.checkpointTime, result.total, key .. " same finish time")
		t.ok(result.maxLateral <= run.course.params.width / 2 + 2, key .. " stayed on the track")
	end
	-- The course's standings: finishers by total time, then the cheat (no lap).
	local expected = {}
	for i = 1, RACE.bots do
		table.insert(expected, "bot_" .. i)
	end
	table.sort(expected, function(a: string, b: string): boolean
		local ta, tb = run.results[a].total, run.results[b].total
		return if ta ~= tb then ta < tb else a < b
	end)
	table.insert(expected, "bot_cheat")
	local standings = {}
	for i, entry in run.standings do
		standings[i] = if type(entry) == "table" then entry.key else entry
	end
	same(t, standings, expected, "standings follow the finish times")
end)

test("race_loop_vehicle: the cheat's jump and shortcut are refused by every layer", function(t)
	local cheat = race().cheat
	same(t, cheat.travel, { "teleport", "teleport" }, "the travel check refuses both jumps")
	same(t, cheat.course, { "too_fast", "wrong_gate" }, "the gates refuse a teleport and a skipped gate")
	same(t, cheat.checkpoints, { "too_fast", "skipped" }, "checkpoints refuse the same claims")
	t.eq(cheat.progress.gates, 1, "only the legitimately driven gate counts")
	t.eq(#cheat.progress.laps, 0, "no lap")
	t.eq(cheat.checkpointProgress.stage, 1, "checkpoints stay at gate 1")
end)

test("race_loop_vehicle: the board ranks best laps by time, stably", function(t)
	local run = race()
	local top = run.board:top()
	t.eq(#top, RACE.bots)
	local manual = {}
	for key, result in run.results do
		local best = math.huge
		for _, lap in result.laps do
			best = math.min(best, math.round(lap * 1000))
		end
		table.insert(manual, { key = key, ms = best })
	end
	table.sort(manual, function(a, b)
		return if a.ms ~= b.ms then a.ms < b.ms else a.key < b.key
	end)
	for i, entry in top do
		t.eq(entry.key, manual[i].key, "rank " .. i .. " key")
		t.eq(entry.score, manual[i].ms, "rank " .. i .. " best lap")
		t.ok(i == 1 or top[i - 1].score <= entry.score, "ascending times")
	end
	-- The same entries submitted in reverse rank the same way.
	local again = Leaderboard.new({ order = "asc", ranks = "standard" })
	for i = #manual, 1, -1 do
		again:submit(manual[i].key, manual[i].ms)
	end
	local keys, againKeys = {}, {}
	for i, entry in again:top() do
		againKeys[i] = entry.key
		keys[i] = top[i].key
	end
	t.eq(againKeys, keys, "order does not depend on submission order")
	-- A slower lap never replaces a best; a NaN time is refused.
	t.eq({ run.board:submit(manual[1].key, manual[1].ms + 1) }, { false, "not_better" })
	t.eq({ run.board:submit("bot_x", 0 / 0) }, { false, "not_finite" })
end)

test("race_loop_vehicle: telemetry events validate as kit-event/1 and nothing was rejected", function(t)
	local run = race()
	local events = run.recorder.events
	t.ok(#events > 0)
	for _, event in events do
		t.eq(Events.validate(event), {}, event.name)
		t.eq(event.schema, "kit-event/1")
		t.eq(event.synthetic, true)
	end
	t.eq(run.report.rejected, {}, "Telemetry rejected nothing")
	t.eq(#run.recorder:named("race_finish"), RACE.bots)
	-- Checkpoints report every accepted touch (custom), the start and the completion per bot.
	local checkpoint = run.recorder:named("checkpoint")
	t.eq(
		#checkpoint,
		RACE.bots * (RACE.laps * run.gateCount + 2) + 2,
		"bots plus the cheat's start and gate 1"
	)
end)

-- Golden entry: digests plus the headline numbers a reviewer can read.
local function raceSummary(): { [string]: any }
	local run = race()
	local top = {}
	for _, entry in run.board:top() do
		table.insert(top, { key = entry.key, ms = entry.score, rank = entry.rank })
	end
	local totals = {}
	for key, result in run.results do
		totals[key] = r3(result.total)
	end
	return {
		course = run.course.hash,
		gates = run.gateCount,
		steps = run.steps,
		best_laps = top,
		totals = totals,
		standings = run.standings,
		events = #run.recorder.events,
		digest = Golden.digest(run.log),
		telemetry = Golden.digest(run.recorder:lines()),
	}
end

-- ---------------------------------------------------------------- stalker_ai
-- ProcGen/Dungeon grid -> GameKit/NavAgentRoblox over tests/fakes/FakePathfinding (routes are a
-- 4-neighbour search on the grid), Perception (occlusion is a grid line) and a BehaviorTree (G7)
-- chasing a scripted target -> Vitals on contact and RoundLoop (G2) ends the round ->
-- AVKit/AudioCues cue requests and Feel/Shake under settings/1 reduced motion (G5).

local STALK = { dt = 0.1, maxTicks = 1500, agentSpeed = 12, targetSpeed = 9, reach = 2.5, strike = 40 }

local function stalkerAi(): { [string]: any }
	local dungeon = Dungeon.generate({ seed = "slices:stalker", width = 40, height = 30, cellSize = 4 })
	local grid = dungeon.grid
	local cs = grid.cellSize
	local function cellOf(p: Vec.V3): (number, number)
		return math.floor(p.x / cs) + 1, math.floor(p.z / cs) + 1
	end
	local function centre(x: number, y: number): Vec.V3
		return Vec.new((x - 0.5) * cs, 0, (y - 0.5) * cs)
	end
	local function solid(p: Vec.V3): boolean
		local x, y = cellOf(p)
		return grid:get(x, y) == 0
	end
	-- True when a straight line from a to b passes a solid cell (sampled every quarter cell).
	local function blocked(a: Vec.V3, b: Vec.V3): boolean
		local d = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
		local steps = math.max(1, math.ceil(d / (cs / 4)))
		for i = 0, steps do
			local f = i / steps
			if solid(Vec.new(a.x + (b.x - a.x) * f, 0, a.z + (b.z - a.z) * f)) then
				return true
			end
		end
		return false
	end
	-- Cells from a to b, 4-neighbour breadth-first over floor cells (ties by neighbour order).
	local function cells(fromX: number, fromY: number, toX: number, toY: number): { { number } }?
		local w = grid.width
		local function key(x: number, y: number): number
			return (y - 1) * w + x
		end
		local cameFrom: { [number]: number } = { [key(fromX, fromY)] = 0 }
		local queue, head = { { fromX, fromY } }, 1
		while head <= #queue do
			local cell = queue[head]
			head += 1
			if cell[1] == toX and cell[2] == toY then
				local out = {}
				local k = key(toX, toY)
				while k ~= 0 do
					table.insert(out, 1, { (k - 1) % w + 1, (k - 1) // w + 1 })
					k = cameFrom[k]
				end
				return out
			end
			for _, offset in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local nx, ny = cell[1] + offset[1], cell[2] + offset[2]
				if grid:get(nx, ny) ~= 0 and cameFrom[key(nx, ny)] == nil then
					cameFrom[key(nx, ny)] = key(cell[1], cell[2])
					table.insert(queue, { nx, ny })
				end
			end
		end
		return nil
	end

	local env = FakeEnv.new({ seed = "slices:stalker", roblox = roblox })
	local routes = { count = 0, wallSegments = 0 }
	local pathfinding = FakePathfinding.new({
		roblox = roblox,
		route = function(from: any, to: any): { { pos: any } }
			local a, b = Vec.new(from.X, 0, from.Z), Vec.new(to.X, 0, to.Z)
			local ax, ay = cellOf(a)
			local bx, by = cellOf(b)
			local list = cells(ax, ay, bx, by)
			routes.count += 1
			if list == nil then
				return {}
			end
			-- Where the agent stands, the centres of the cells after its own (two edge-adjacent
			-- cells form a convex rectangle, so each leg stays on their floor), then the goal.
			local points = { a }
			for i = 2, #list do
				table.insert(points, centre(list[i][1], list[i][2]))
			end
			table.insert(points, b)
			local out = {}
			for i, point in points do
				if i > 1 and blocked(points[i - 1], point) then
					routes.wallSegments += 1
				end
				table.insert(out, { pos = roblox.Vector3.new(point.x, 0, point.z) })
			end
			return out
		end,
	})
	env:register("PathfindingService", pathfinding)

	-- The target walks room to room; the agent starts in the last room and patrols backwards.
	local rooms = dungeon.rooms
	local targetRoute: { Vec.V3 } = {}
	for i = 1, #rooms do
		local a, b = rooms[i], rooms[i % #rooms + 1]
		for _, cell in cells(a.cx, a.cy, b.cx, b.cy) :: { { number } } do
			table.insert(targetRoute, centre(cell[1], cell[2]))
		end
	end
	local target = { pos = targetRoute[1], leg = 1, alive = true }
	local patrol: { Vec.V3 } = {}
	for i = #rooms, 1, -1 do
		table.insert(patrol, centre(rooms[i].cx, rooms[i].cy))
	end
	local agentPos = patrol[1]
	local facing = Vec.new(1, 0, 0)
	local humanoid: any = { moveTarget = nil, Jump = false }
	function humanoid.MoveTo(self: any, v: any)
		self.moveTarget = Vec.new(v.X, 0, v.Z)
	end
	local root: any = { CFrame = roblox.CFrame.new(agentPos.x, 0, agentPos.z) }
	local controller = NavAgentRoblox.new(humanoid, root, { arriveRadius = 1, repathDistance = 4 }, env)

	local sight = { fov = 120, sightRange = 48, memory = 3, occluded = blocked }
	local eyes = Perception.new(sight, env)
	local vitals = Vitals.new(Vitals.define({ pools = { health = { max = 100 } } }), nil, env)
	local loop = RoundLoop.new(
		RoundLoop.define({
			durations = { intermission = 1, active = 120, results = 2 },
			minPlayers = 2,
			endOnAlive = 1,
		}),
		nil,
		env
	)
	loop:join("target")
	loop:join("bystander")
	local cues = AudioCues.new(AudioCues.defaults(), {
		seed = "slices:stalker",
		assets = { sfx_hit_heavy = "test://hit_heavy", sfx_ui_notify = "test://ui_notify" },
	})
	local reduced = Settings.effective((Settings.set(Settings.defaults(), "reducedMotion", true)))
	local full = Settings.effective(Settings.defaults())
	local calmShake = Shake.new({ seed = "slices:stalker" })
	local fullShake = Shake.new({ seed = "slices:stalker" })

	local log: { string } = {}
	local now = 0
	local function note(text: string)
		table.insert(log, string.format("%.1f %s", now, text))
	end
	local stats = {
		acquired = 0,
		lost = {} :: { string },
		strikes = 0,
		wallSteps = 0,
		cues = {} :: { string },
		calmPeak = 0,
		fullPeak = 0,
		roundEnds = 0,
		seenMismatch = 0,
		modes = {} :: { [string]: number },
	}

	local mode = "none"
	local goal: Vec.V3? = nil
	local patrolIndex = 1
	local function v3(p: Vec.V3): any
		return roblox.Vector3.new(p.x, 0, p.z)
	end
	-- Starts a move when the mode or goal changes, else steps the controller (a moving goal
	-- repaths when it has moved far enough).
	local function go(newMode: string, to: Vec.V3, moving: boolean)
		if newMode ~= mode or goal == nil or (not moving and Vec.length(Vec.sub(goal, to)) > 0.01) then
			mode = newMode
			goal = to
			controller:moveTo(v3(to))
			return
		end
		local command = controller:step(STALK.dt, if moving then v3(to) else nil)
		-- NavAgent repaths a moving goal only while following; once it has arrived where the
		-- target was, arrival is final until the next moveTo, so a chase re-targets itself.
		if moving and command.kind == "arrived" and Vec.length(Vec.sub(goal :: Vec.V3, to)) > 0.5 then
			goal = to
			controller:moveTo(v3(to))
		elseif newMode == "patrol" and (command.kind == "arrived" or command.kind == "failed") then
			patrolIndex = patrolIndex % #patrol + 1
			goal = patrol[patrolIndex]
			controller:moveTo(v3(patrol[patrolIndex]))
		end
	end
	local function request(cue: string)
		local voice, why = cues:request(cue, now)
		table.insert(stats.cues, cue .. ":" .. (if voice then "admitted" else tostring(why)))
		if voice then
			cues:release(voice.id)
		end
	end

	local bb = BT.blackboard({})
	local tree = BT.new(
		BT.selector({
			BT.sequence({
				BT.condition("in_reach", function(board)
					return board:get("seen") == true and board:get("distance") <= STALK.reach
				end),
				BT.cooldown(
					BT.action("strike", function()
						local record = vitals:damage({
							amount = STALK.strike,
							kind = "contact",
							source = { attacker = "stalker" },
						})
						stats.strikes += 1
						note(string.format("strike %d lethal=%s", record.applied, tostring(record.lethal)))
						request("hit_heavy")
						calmShake:add("hit_heavy")
						fullShake:add("hit_heavy")
						return "success"
					end),
					1
				),
			}, "attack"),
			BT.sequence({
				BT.condition("sees_target", function(board)
					return board:get("seen") == true
				end),
				BT.action("chase", function(board)
					go("chase", board:get("targetPos"), true)
					return "success"
				end),
			}, "chase"),
			BT.sequence({
				BT.condition("remembers_target", function(board)
					return board:get("lastKnown") ~= nil
				end),
				BT.action("investigate", function(board)
					go("investigate", board:get("lastKnown"), false)
					return "success"
				end),
			}, "investigate"),
			BT.action("patrol", function()
				go("patrol", patrol[patrolIndex], false)
				return "success"
			end),
		}),
		{ blackboard = bb },
		env
	)

	local seenBefore = false
	local resultsAt: number? = nil
	local ticks = 0
	while ticks < STALK.maxTicks do
		ticks += 1
		env:advance(STALK.dt)
		now = env.clock()
		for _, event in loop:tick(now) do
			note(string.format("round %s -> %s (%s)", event.from, event.phase, event.reason))
			if event.from == "active" then
				stats.roundEnds += 1
				request("ui_notify")
			end
			if event.phase == "results" then
				resultsAt = now
			end
		end
		if resultsAt and now - resultsAt >= 1 then
			break
		end
		if loop:phase() ~= "active" then
			continue
		end
		-- The target walks its route (it stops when it falls).
		if target.alive then
			local remaining = STALK.targetSpeed * STALK.dt
			while remaining > 0 do
				local nextPoint = targetRoute[target.leg % #targetRoute + 1]
				local delta = Vec.sub(nextPoint, target.pos)
				local length = Vec.length(delta)
				if length <= remaining then
					target.pos = nextPoint
					target.leg = target.leg % #targetRoute + 1
					remaining -= length
				else
					target.pos = Vec.add(target.pos, Vec.scale(delta, remaining / length))
					remaining = 0
				end
			end
		end
		-- Sense, then think.
		local observer = { pos = agentPos, look = facing }
		local targets = if target.alive then { { id = "target", pos = target.pos } } else {}
		eyes:sense(observer, targets)
		local memory = nil
		for _, m in eyes:known() do
			if m.id == "target" then
				memory = m
			end
		end
		local seen = memory ~= nil and memory.seen
		local visible, why = Perception.canSee(observer, target.pos, sight)
		if target.alive and seen ~= visible then
			stats.seenMismatch += 1
		end
		if seen and not seenBefore then
			stats.acquired += 1
			note("acquired")
		elseif seenBefore and not seen and target.alive then
			table.insert(stats.lost, tostring(why))
			note("lost " .. tostring(why))
		end
		seenBefore = seen
		bb:set("seen", seen)
		bb:set("targetPos", target.pos)
		bb:set("lastKnown", if memory then memory.pos else nil)
		bb:set("distance", Vec.length(Vec.sub(target.pos, agentPos)))
		tree:tick()
		stats.modes[mode] = (stats.modes[mode] or 0) + 1
		if not vitals:alive() and target.alive then
			target.alive = false
			local ok, reason = loop:eliminate("target")
			note("target down " .. tostring(ok) .. " " .. tostring(reason))
		end
		-- Move the agent towards its Humanoid's MoveTo goal (what the engine's Humanoid does).
		local moveTarget = humanoid.moveTarget
		if moveTarget then
			local delta = Vec.sub(moveTarget, agentPos)
			local length = Vec.length(delta)
			if length > 1e-6 then
				local stepLength = math.min(length, STALK.agentSpeed * STALK.dt)
				local nextPos = Vec.add(agentPos, Vec.scale(delta, stepLength / length))
				if solid(nextPos) or blocked(agentPos, nextPos) then
					stats.wallSteps += 1
				end
				facing = Vec.scale(delta, 1 / length)
				agentPos = nextPos
				root.CFrame = roblox.CFrame.new(agentPos.x, 0, agentPos.z)
			end
		end
		-- While it sees its target it keeps looking at it (head tracking); otherwise it looks
		-- where it walks.
		if seen and target.alive then
			local toTarget = Vec.sub(target.pos, agentPos)
			if Vec.length(toTarget) > 1e-6 then
				facing = Vec.scale(toTarget, 1 / Vec.length(toTarget))
			end
		end
		for _, value in calmShake:step(STALK.dt, reduced.shakeScale) do
			stats.calmPeak = math.max(stats.calmPeak, math.abs(value))
		end
		for _, value in fullShake:step(STALK.dt, full.shakeScale) do
			stats.fullPeak = math.max(stats.fullPeak, math.abs(value))
		end
	end
	return {
		dungeon = dungeon,
		ticks = ticks,
		stats = stats,
		routes = routes,
		log = log,
		vitals = vitals:snapshot(),
		loop = loop,
		now = now,
		finishAgain = { loop:finish({ reason = "again" }) },
		eliminateAgain = { loop:eliminate("target") },
		cueStats = cues:stats(),
	}
end

local function stalker(): { [string]: any }
	return once("stalker", stalkerAi)
end

test("stalker_ai: the agent loses the target behind walls and reacquires it by sight", function(t)
	local run = stalker()
	local stats = run.stats
	t.ok(stats.acquired >= 2, "acquired at least twice, got " .. stats.acquired)
	t.ok(table.find(stats.lost, "occluded") ~= nil, "lost at least once behind a wall")
	for _, reason in stats.lost do
		t.ok(
			reason == "occluded" or reason == "angle" or reason == "range",
			"a perception reason: " .. reason
		)
	end
	t.eq(stats.seenMismatch, 0, "seen exactly when Perception.canSee holds")
	t.ok((stats.modes.investigate or 0) > 0, "it investigated a last known position")
	t.ok((stats.modes.chase or 0) > 0 and (stats.modes.patrol or 0) > 0, "it patrolled and chased")
end)

test("stalker_ai: no route or step ever passes through a wall", function(t)
	local run = stalker()
	t.ok(run.routes.count >= 3, "paths were computed")
	t.eq(run.routes.wallSegments, 0, "every route segment is on floor cells")
	t.eq(run.stats.wallSteps, 0, "every agent step stays on floor cells")
end)

test(
	"stalker_ai: contact damage ends the round exactly once; cues; no shake under reduced motion",
	function(t)
		local run = stalker()
		local stats = run.stats
		t.eq(stats.strikes, 3, "three strikes of 40 take 100 health")
		t.eq(run.vitals.health, 0)
		t.eq(stats.roundEnds, 1, "the active phase ended once")
		t.eq(run.loop:phase(), "results")
		t.eq(run.loop:result().reason, "last_standing")
		same(t, run.loop:result().survivors, { "bystander" })
		same(t, run.finishAgain, { false, "not_active" })
		same(t, run.eliminateAgain, { false, "not_active" })
		same(
			t,
			stats.cues,
			{ "hit_heavy:admitted", "hit_heavy:admitted", "hit_heavy:admitted", "ui_notify:admitted" }
		)
		t.eq(stats.calmPeak, 0, "reduced motion: every shake offset is 0")
		t.ok(stats.fullPeak > 0, "the same hits shake with full motion")
	end
)

local function stalkerSummary(): { [string]: any }
	local run = stalker()
	return {
		ticks = run.ticks,
		acquired = run.stats.acquired,
		lost = run.stats.lost,
		strikes = run.stats.strikes,
		routes = run.routes.count,
		modes = run.stats.modes,
		digest = Golden.digest(run.log),
	}
end

-- ---------------------------------------------------------------- projectile_arena
-- ProcGen/Course microArena spawns -> GameKit/TeamBalance (G7) splits a seeded party list ->
-- RoundLoop (G2) -> clients fire through GameKit/RemoteGuard (G1) -> Projectile.validateFire /
-- validateHit on Hitbox pose history (G2) -> Vitals -> Wallet reward and Progression (G3) ->
-- Feel/HitStop and Popups (G5). Player 108 is the exploiter: every request it sends is refused.

local ARENA = {
	dt = 1 / 30,
	latency = 0.05,
	fireEvery = 0.5,
	grace = 5,
	stagger = 0.07,
	damage = 25,
	reward = 10,
	xp = 30,
	maxTicks = 1800,
	exploiter = 108,
}

local function projectileArena(): { [string]: any }
	local course = Course.microArena({ seed = "slices:arena", players = 8 })
	local env = FakeEnv.new({ seed = "slices:arena" })
	local recorder = Events.recorder({ strict = true })
	local telemetry =
		Telemetry.new({ sink = recorder, envelope = ENVELOPE, strict = true, budget = false }, env)

	-- A seeded party list: two parties, three solo players and the exploiter.
	local roster = {}
	for i = 1, 8 do
		local id = 100 + i
		local rng = Rng.new("slices:arena:player:" .. id)
		local party = if i <= 2 then "party_a" elseif i >= 5 and i <= 7 then "party_b" else nil
		table.insert(roster, { id = id, skill = rng:int(800, 1600), party = party })
	end
	local split = TeamBalance.split(roster, { teams = 2 })
	local teamOf: { [number]: number } = {}
	local slotOf: { [number]: any } = {}
	for teamIndex, members in split.teams do
		for j, id in members do
			teamOf[id :: number] = teamIndex
			slotOf[id :: number] = course.spawn.slots[(teamIndex - 1) * 4 + j]
		end
	end
	-- Bodies strafe slowly beside their spawn (a scripted, deterministic motion every client
	-- can predict).
	local function bodyAt(id: number, t: number): Vec.V3
		local slot = slotOf[id]
		local yaw = math.rad(slot.yaw)
		local offset = 1.5 * math.sin(t * 1.3 + id)
		return Vec.new(
			slot.pos.x + math.cos(yaw) * offset,
			slot.pos.y + 2,
			slot.pos.z - math.sin(yaw) * offset
		)
	end

	local projectile = Projectile.define({ speed = 120, gravity = 0, maxRange = 200, radius = 0.5 })
	local loop = RoundLoop.new(
		RoundLoop.define({ durations = { intermission = 1, active = 60, results = 2 }, minPlayers = 2 }),
		nil,
		env
	)
	local curve = Progression.curve({ kind = "linear", base = 50, step = 25, maxLevel = 50 })
	local players, ids = {}, {}
	for _, entry in roster do
		local id = entry.id
		table.insert(ids, id)
		players[id] = {
			id = id,
			player = { UserId = id },
			vitals = Vitals.new(Vitals.define({ pools = { health = { max = 100 } } }), nil, env),
			history = Hitbox.history({ capacity = 32 }),
			wallet = Wallet.new({
				currencies = { currency_a = {} },
				sink = telemetry,
				player = tostring(id),
			}, env),
			track = Progression.new(
				{ curve = curve, path = "combat", sink = telemetry, player = tostring(id) },
				env
			),
			nextFire = 0,
			shotSerial = 0,
		}
		loop:join(id)
	end

	local guard = RemoteGuard.new({
		schemas = {
			fire = {
				args = {
					Schema.vector3({ maxMagnitude = 4096 }),
					Schema.vector3({ maxMagnitude = 2 }),
					Schema.number({ min = 0 }),
					Schema.integer({ min = 1, max = 1000000 }),
				},
				rate = { capacity = 3, refillPerSec = 2 },
				dedupe = { arg = 4 },
			},
			hit = {
				args = {
					Schema.integer({ min = 1, max = 1000000 }),
					Schema.vector3({ maxMagnitude = 4096 }),
					Schema.number({ min = 0 }),
					Schema.integer({ min = 1 }),
				},
				rate = { capacity = 6, refillPerSec = 6 },
			},
		},
		telemetry = telemetry,
	}, env)

	local hitStop = HitStop.new()
	local popups = Popups.new()
	local popupTotals: { [number]: number } = {}
	local stats = {
		accepted = 0,
		kills = 0,
		pushes = 0,
		rewardTexts = {} :: { string },
		frozenPeak = 0,
		hitStopCut = 0,
		exploiter = {} :: { string },
		honestRefused = {} :: { string },
		exploiterSent = 0,
		roundEnds = 0,
		winner = nil :: number?,
	}
	local shots: { [string]: any } = {}
	local log: { string } = {}
	local now = 0
	local function note(text: string)
		table.insert(log, string.format("%.3f %s", now, text))
	end
	-- Round transitions come from tick and from finish (a team wipe ends the round at once).
	local activeAt: number? = nil
	local resultsAt: number? = nil
	local function roundEvents(events: { any })
		for _, event in events do
			note(string.format("round %s -> %s (%s)", event.from, event.phase, event.reason))
			if event.phase == "active" then
				activeAt = now
			elseif event.from == "active" then
				stats.roundEnds += 1
				resultsAt = now
			end
		end
	end
	local function outcome(id: number, remote: string, result: string)
		if id == ARENA.exploiter then
			table.insert(stats.exploiter, remote .. ":" .. result)
		elseif result ~= "ok" then
			table.insert(stats.honestRefused, remote .. ":" .. result)
		end
	end
	local function plain(v: any): Vec.V3
		return Vec.new(v.X, v.Y, v.Z)
	end
	local function aliveOn(team: number): { number }
		local out = {}
		for _, id in ids do
			if teamOf[id] == team and players[id].vitals:alive() then
				table.insert(out, id)
			end
		end
		return out
	end

	-- Handlers run only for calls the guard accepted.
	local onFire = guard:wrap(
		"fire",
		function(player: any, origin: any, direction: any, time: number, shotId: number)
			local id = player.UserId
			local me = players[id]
			if loop:phase() ~= "active" or not me.vitals:alive() then
				return outcome(id, "fire", "not_active")
			end
			local claim = { origin = plain(origin), direction = plain(direction), time = time }
			local pose = me.history:at(time)
			local ok, reason = Projectile.validateFire(projectile, claim, { now = now, shooterPose = pose })
			if not ok then
				return outcome(id, "fire", tostring(reason))
			end
			shots[id .. ":" .. shotId] = { owner = id, claim = claim, resolved = false }
			outcome(id, "fire", "ok")
		end
	)
	local onHit = guard:wrap(
		"hit",
		function(player: any, shotId: number, hitPoint: any, time: number, targetId: number)
			local id = player.UserId
			local shot = shots[id .. ":" .. shotId]
			if shot == nil or shot.resolved then
				return outcome(id, "hit", if shot then "resolved" else "unknown_shot")
			end
			local victim = players[targetId]
			if victim == nil or teamOf[targetId] == teamOf[id] then
				return outcome(id, "hit", "bad_target")
			elseif not victim.vitals:alive() then
				-- Two shots in flight at one target: the later one lands on a body already down.
				return outcome(id, "hit", "target_down")
			end
			local pose = victim.history:at(time)
			local ok, reason = Projectile.validateHit(
				projectile,
				shot.claim,
				{ hitPoint = plain(hitPoint), time = time, target = targetId },
				{ now = now, targetPose = pose }
			)
			if not ok then
				return outcome(id, "hit", tostring(reason))
			end
			shot.resolved = true
			stats.accepted += 1
			outcome(id, "hit", "ok")
			local record = victim.vitals:damage({
				amount = ARENA.damage,
				kind = "projectile",
				source = { attacker = id },
			})
			local _, cut = hitStop:request(0.08, now)
			if cut == "budget" then
				stats.hitStopCut += 1
			end
			-- What the popup shows (merged hits add up), read back right after each push.
			local popupId = popups:push(
				{ key = "damage", value = record.applied, anchor = targetId, kind = "damage" },
				now
			)
			for _, visible in popups:step(now) do
				if visible.id == popupId then
					popupTotals[popupId] = visible.value
				end
			end
			stats.pushes += 1
			note(string.format("%d hit %d for %d", id, targetId, record.applied))
			if record.lethal then
				stats.kills += 1
				loop:eliminate(targetId)
				local me = players[id]
				me.wallet:credit("currency_a", ARENA.reward, "Gameplay", { txId = "kill:" .. targetId })
				me.track:addXp(ARENA.xp)
				local rewardId =
					popups:push({ key = "reward", value = ARENA.reward, anchor = id, kind = "reward" }, now)
				for _, visible in popups:step(now) do
					if visible.id == rewardId then
						table.insert(stats.rewardTexts, visible.text)
					end
				end
				note(string.format("%d down by %d", targetId, id))
				for team = 1, 2 do
					if #aliveOn(team) == 0 and loop:phase() == "active" then
						stats.winner = 3 - team
						local _, _, events = loop:finish({ winner = 3 - team })
						roundEvents(events or {})
					end
				end
			end
		end
	)

	-- Messages in flight: a client sends now, the server handles them `latency` later.
	local inbox: { { at: number, seq: number, run: () -> () } } = {}
	local seq = 0
	local function send(fn: () -> ())
		seq += 1
		table.insert(inbox, { at = now + ARENA.latency, seq = seq, run = fn })
	end

	-- An honest client fires at the nearest living enemy, predicts the flight against the
	-- scripted motion and reports the hit when its projectile gets there.
	local function honestFire(me: any)
		local enemies = aliveOn(3 - teamOf[me.id])
		if #enemies == 0 then
			return
		end
		local origin = bodyAt(me.id, now)
		table.sort(enemies, function(a, b)
			local da = Vec.length(Vec.sub(bodyAt(a, now), origin))
			local db = Vec.length(Vec.sub(bodyAt(b, now), origin))
			return if da ~= db then da < db else a < b
		end)
		local direction = Vec.unit(Vec.sub(bodyAt(enemies[1], now), origin))
		me.shotSerial += 1
		local shotId, fireTime = me.shotSerial, now
		local state = Projectile.launch(projectile, origin, direction, { owner = me.id })
		local function cast(from: Vec.V3, delta: Vec.V3, radius: number, s: any): any
			local best = nil
			for _, enemy in enemies do
				local hit, fraction, point =
					Hitbox.segment(Hitbox.sphere(bodyAt(enemy, fireTime + s.age), 2), from, delta, radius)
				if hit and (best == nil or (fraction :: number) < best.fraction) then
					best = { fraction = fraction, position = point, target = enemy }
				end
			end
			return best
		end
		local report = nil
		for _ = 1, 120 do
			local events
			state, events = Projectile.step(projectile, state, 1 / 120, cast)
			for _, event in events do
				if event.kind == "hit" then
					report = event
				end
			end
			if not state.alive then
				break
			end
		end
		send(function()
			onFire(
				me.player,
				roblox.Vector3.new(origin.x, origin.y, origin.z),
				roblox.Vector3.new(direction.x, direction.y, direction.z),
				fireTime,
				shotId
			)
		end)
		if report then
			local p = report.position
			local hitTime = fireTime + report.age
			table.insert(inbox, {
				at = hitTime + ARENA.latency,
				seq = seq + 1000000,
				run = function()
					onHit(me.player, shotId, roblox.Vector3.new(p.x, p.y, p.z), hitTime, report.target)
				end,
			})
		end
	end

	-- The exploiter's script, by tick in the active phase.
	local exploiter = players[ARENA.exploiter]
	local function exploit(step: number)
		local p, origin, sentAt = exploiter.player, bodyAt(ARENA.exploiter, now), now
		local function sendBad(fn: () -> ())
			stats.exploiterSent += 1
			send(fn)
		end
		local forged = roblox.Vector3.new(origin.x, origin.y + 30, origin.z)
		local forward = roblox.Vector3.new(0, 0, 1)
		if step == 1 then
			for shotId = 1, 8 do -- rapid fire with a forged muzzle
				sendBad(function()
					onFire(p, forged, forward, sentAt, shotId)
				end)
			end
		elseif step == 2 then
			sendBad(function()
				onFire(p, forged, roblox.Vector3.new(0 / 0, 0, 0), sentAt, 20) -- NaN direction
			end)
		elseif step == 3 then
			local muzzle = roblox.Vector3.new(origin.x, origin.y, origin.z)
			sendBad(function()
				onFire(p, muzzle, forward, sentAt + 5, 21) -- claims the future
			end)
		elseif step == 4 then
			local muzzle = roblox.Vector3.new(origin.x, origin.y, origin.z)
			sendBad(function()
				onFire(p, muzzle, forward, sentAt - 1, 22) -- too old to rewind
			end)
		elseif step == 5 then
			sendBad(function()
				onFire(p, forged, forward, sentAt, 1) -- replays shot 1
			end)
		elseif step == 6 then
			sendBad(function()
				onHit(p, 99, roblox.Vector3.new(0, 2, 0), sentAt, 101) -- a hit for a shot never fired
			end)
		elseif step == 7 then
			sendBad(function()
				onHit(p, 2, roblox.Vector3.new(0 / 0, 0, 0), sentAt, 101) -- NaN hit point
			end)
		elseif step == 8 then
			sendBad(function()
				(onFire :: any)(p) -- no arguments
			end)
		end
	end
	local function guardRejects(): { [string]: number }
		return guard:stats(exploiter.player).reasons
	end

	local ticks = 0
	while ticks < ARENA.maxTicks do
		ticks += 1
		env:advance(ARENA.dt)
		now = env.clock()
		local wasActive = activeAt
		roundEvents(loop:tick(now))
		if activeAt and not wasActive then
			-- Spawn protection: honest clients hold fire for `grace` seconds, then fire in a
			-- staggered order (so their hits, and the hit-stop requests, do not all coincide).
			for index, id in ids do
				players[id].nextFire = activeAt + ARENA.grace + (index - 1) * ARENA.stagger
			end
		end
		if resultsAt and now - resultsAt > 0.5 then
			break
		end
		for _, id in ids do
			if players[id].vitals:alive() then
				players[id].history:record(now, Hitbox.sphere(bodyAt(id, now), 2))
			end
		end
		-- Deliver what has arrived, in arrival order.
		table.sort(inbox, function(a, b)
			return if a.at ~= b.at then a.at < b.at else a.seq < b.seq
		end)
		while #inbox > 0 and inbox[1].at <= now + 1e-9 do
			table.remove(inbox, 1).run()
		end
		if loop:phase() == "active" and activeAt then
			for _, id in ids do
				local me = players[id]
				if id ~= ARENA.exploiter and me.vitals:alive() and now >= me.nextFire then
					me.nextFire = now + ARENA.fireEvery
					honestFire(me)
				end
			end
			local k = math.round((now - activeAt) / 0.6)
			if math.abs(now - activeAt - k * 0.6) < ARENA.dt / 2 and k >= 1 and k <= 8 then
				exploit(k)
			end
		end
	end
	-- Frozen time per rolling second, sampled at 240 Hz over the run.
	local samples, frozen = {}, 0
	for i = 0, math.floor(now * 240) do
		samples[i] = if hitStop:frozen(i / 240) then 1 else 0
	end
	for i = 0, #samples do
		frozen += samples[i]
		if i >= 240 then
			frozen -= samples[i - 240]
		end
		stats.frozenPeak = math.max(stats.frozenPeak, frozen / 240)
	end

	local balances, levels = {}, {}
	for _, id in ids do
		balances[tostring(id)] = players[id].wallet:balance("currency_a")
		levels[tostring(id)] = { level = players[id].track:level(), xp = players[id].track:xp() }
	end
	return {
		course = course,
		split = split,
		teamOf = teamOf,
		roster = roster,
		ticks = ticks,
		stats = stats,
		guardRejects = guardRejects(),
		guardStats = guard:stats(),
		balances = balances,
		levels = levels,
		curve = curve,
		players = players,
		popupTotals = popupTotals,
		loop = loop,
		recorder = recorder,
		report = telemetry:report(),
		log = log,
	}
end

local function arena(): { [string]: any }
	return once("arena", projectileArena)
end

test("projectile_arena: TeamBalance keeps parties together and the teams even", function(t)
	local run = arena()
	local split = run.split
	t.eq(#split.teams, 2)
	t.ok(math.abs(split.sizes[1] - split.sizes[2]) <= 1, "sizes differ by at most 1")
	t.eq(split.splitParties, {})
	local partyTeam = {}
	for _, entry in run.roster do
		if entry.party then
			local team = run.teamOf[entry.id]
			partyTeam[entry.party] = partyTeam[entry.party] or team
			t.eq(team, partyTeam[entry.party], entry.party .. " stays on one team")
		end
	end
	local totals = { 0, 0 }
	for _, entry in run.roster do
		totals[run.teamOf[entry.id]] += entry.skill
	end
	same(t, totals, split.totals, "team totals")
	t.eq(split.spread, math.abs(totals[1] - totals[2]))
end)

test("projectile_arena: every exploiter request is refused and it never deals damage", function(t)
	local run = arena()
	same(t, run.stats.exploiter, {
		"fire:origin_mismatch",
		"fire:origin_mismatch",
		"fire:origin_mismatch",
		"fire:future_time",
		"fire:too_old",
		"hit:unknown_shot",
	}, "refusals that reached a handler")
	same(t, run.guardRejects, { arity = 1, duplicate = 1, rate = 5, schema = 2 }, "refusals at the guard")
	t.eq(run.guardStats.handlerErrors, 0)
	t.eq(run.balances[tostring(ARENA.exploiter)], 0)
	for _, line in run.log do
		t.ok(not string.find(line, "^%d+%.%d+ " .. ARENA.exploiter .. " hit"), "the exploiter hit nobody")
	end
	local requests = 0
	for _, count in run.guardRejects do
		requests += count
	end
	t.eq(requests + #run.stats.exploiter, run.stats.exploiterSent, "every exploiter request was refused")
	-- Lag compensation never refuses an honest client; the only refusal allowed is a race where a
	-- second shot in flight lands on a target someone else already took down.
	for _, refusal in run.stats.honestRefused do
		t.eq(refusal, "hit:target_down", "honest refusal")
	end
end)

test("projectile_arena: the round ends once; wallet totals equal the granted rewards", function(t)
	local run = arena()
	local stats = run.stats
	t.eq(stats.roundEnds, 1, "the active phase ended once")
	t.ok(stats.winner ~= nil, "one team won")
	t.eq(run.loop:result().winner, stats.winner)
	t.ok(stats.kills >= 4, "a whole team went down")
	local total = 0
	for _, balance in run.balances do
		total += balance
	end
	t.eq(total, stats.kills * ARENA.reward, "currency equals kills x reward")
	local sourced = 0
	for _, event in run.recorder.events do
		if event.category == "economy" then
			t.eq(event.economy.flow, "source")
			t.eq(event.economy.transaction_type, "Gameplay")
			sourced += event.economy.amount
		end
	end
	t.eq(sourced, total, "economy events add up to the balances")
	for key, entry in run.levels do
		t.eq(entry.xp, run.balances[key] // ARENA.reward * ARENA.xp, key .. " xp per kill")
		t.eq(entry.level, (run.curve:levelFor(entry.xp)), key .. " level matches the curve")
	end
	-- A replayed reward transaction does nothing.
	for id, player in run.players do
		if player.wallet:balance("currency_a") > 0 then
			local before = player.wallet:balance("currency_a")
			local victims = {}
			for _, line in run.log do
				local victim, killer = string.match(line, "^%S+ (%d+) down by (%d+)$")
				if killer == tostring(id) then
					table.insert(victims, victim)
				end
			end
			same(t, {
				player.wallet:credit(
					"currency_a",
					ARENA.reward,
					"Gameplay",
					{ txId = "kill:" .. victims[1] }
				),
			}, { true, "duplicate" })
			t.eq(player.wallet:balance("currency_a"), before)
			break
		end
	end
	t.eq(run.report.rejected, {}, "Telemetry rejected nothing")
end)

test("projectile_arena: hit-stop stays in budget, popups add up and gains read as gains", function(t)
	local run = arena()
	local stats = run.stats
	t.ok(stats.frozenPeak <= HitStop.BUDGET + 1 / 240, "frozen time per second within the budget")
	t.ok(stats.hitStopCut > 0, "the burst was cut by the budget")
	local total = 0
	local distinct = 0
	for _, value in run.popupTotals do
		total += value
		distinct += 1
	end
	t.eq(total, stats.accepted * ARENA.damage, "popup values sum to the damage dealt")
	t.ok(distinct <= stats.pushes)
	for _, text in stats.rewardTexts do
		t.eq(text, "+" .. ARENA.reward, "reward text has its sign")
	end
end)

local function arenaSummary(): { [string]: any }
	local run = arena()
	return {
		course = run.course.hash,
		teams = run.split.teams,
		ticks = run.ticks,
		hits = run.stats.accepted,
		kills = run.stats.kills,
		winner = run.stats.winner,
		balances = run.balances,
		digest = Golden.digest(run.log),
		telemetry = Golden.digest(run.recorder:lines()),
	}
end

-- ---------------------------------------------------------------- session_persistence
-- GameKit/PlayerData (G1) memory backend shared by two "servers" -> Wallet, Inventory over
-- ItemDefs and Progression (G3) through session:keyStore -> SettingsStore over Settings (G1) and
-- Onboarding (G3) -> Commerce.receiptProcessor over a game-mode Catalog -> Telemetry (G1).
-- A second server is refused while the first holds the lock; a receipt delivered twice grants
-- once; a stolen lock makes every kit refuse to commit (store_failed, nothing reported); the
-- successor loads version 2 through migrations[1] exactly once and reads back exactly what the
-- first server saved.

local SESSION = {
	userId = 4242,
	player = "4242",
	owner = "p4242",
	plays = 16,
	pack = 1001, -- a fixture id in a game-mode test catalog, never a live product
	packAmount = 100,
	packItems = 3,
	purchaseId = "purchase_slices_1",
}
local SESSION_CURRENCIES = { currency_a = { cap = 100000 }, currency_b = { initial = 5 } }
local SESSION_ITEMS = ItemDefs.registry({
	{ id = "item_a", kind = "material", stackable = true, maxStack = 10 },
	{ id = "item_b", kind = "tool", stackable = false, maxStack = 1, slot = "slot_a" },
})
local SESSION_STEPS = { "step_a", "step_b", "step_c" }

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = deepCopy(child)
	end
	return out
end

local function sessionPersistence(): { [string]: any }
	local env = FakeEnv.new({ seed = "slices:session" })
	local recorder = Events.recorder({ strict = true })
	local telemetry =
		Telemetry.new({ sink = recorder, envelope = ENVELOPE, strict = true, budget = false }, env)
	local shared = { values = {}, locks = {} }
	local backends: { [string]: any } = {}
	local migrated = 0
	-- v1 keeps the combat track at progress.track; v2 names it progress.combat.
	local MIGRATIONS = {
		[1] = function(data: any): any
			migrated += 1
			data.progress = data.progress or {}
			data.progress.combat = data.progress.track
			data.progress.track = nil
			return data
		end,
	}
	local function server(id: string, version: number): any
		backends[id] = PlayerData.memoryBackend({ serverId = id, shared = shared })
		return PlayerData.new({
			template = { economy = {}, progress = {} },
			version = version,
			migrations = if version > 1 then MIGRATIONS else nil,
			backend = backends[id],
			autosave = false,
		}, env)
	end
	local log: { string } = {}
	local function note(text: string)
		table.insert(log, text)
	end

	-- Server A owns the session; server B (already on version 2) is refused while A holds it.
	local storeA, storeB = server("server_a", 1), server("server_b", 2)
	local sessionA = assert(storeA:load(SESSION.userId))
	local heldRefusal = { storeB:load(SESSION.userId) }
	local lost: { string } = {}
	sessionA.onSessionLost:Connect(function(why: string)
		table.insert(lost, why)
	end)

	local economy = sessionA:keyStore("economy")
	local wallet = Wallet.new({
		currencies = SESSION_CURRENCIES,
		sink = telemetry,
		player = SESSION.player,
		store = economy,
	}, env)
	local inventory = Inventory.new({
		items = SESSION_ITEMS,
		owner = SESSION.owner,
		capacity = 12,
		equipSlots = { "slot_a" },
		store = economy,
	}, env)
	local curve = Progression.curve({ kind = "linear", base = 60, step = 30, maxLevel = 40 })
	local track =
		Progression.new({ curve = curve, path = "combat", sink = telemetry, player = SESSION.player }, env)
	local settings = SettingsStore.new({ store = sessionA:keyStore() }, env)
	local _, settingsNotes = settings:load()
	local onboarding = Onboarding.new({
		steps = SESSION_STEPS,
		store = sessionA:keyStore("progress"),
		sink = telemetry,
		player = SESSION.player,
	}, env)

	-- A seeded play script through the kits' public calls.
	local rng = Rng.new("slices:session:play")
	local refusals: { string } = {}
	for round = 1, SESSION.plays do
		env:advance(1)
		local roll = rng:int(1, 5)
		local ok, why
		if roll == 1 then
			ok, why = wallet:credit("currency_a", rng:int(5, 40), "Gameplay", { txId = "play:" .. round })
		elseif roll == 2 then
			ok, why = wallet:debit("currency_a", rng:int(5, 30), "Shop", { txId = "play:" .. round })
		elseif roll == 3 then
			ok, why = inventory:add("item_a", rng:int(1, 6))
		elseif roll == 4 then
			local result
			ok, why, result = inventory:add("item_b")
			if ok and inventory:equipped("slot_a") == nil then
				ok, why = inventory:apply({ { op = "equip", uid = result.created[1], slot = "slot_a" } })
			end
		else
			ok, why = track:addXp(rng:int(20, 90))
			if ok then
				ok, why = sessionA:set("progress.track", track:serialize())
			end
		end
		note(string.format("play %d roll %d %s %s", round, roll, tostring(ok), tostring(why)))
		if not ok then
			table.insert(refusals, tostring(why))
		end
	end
	local settingsResults = {
		{ settings:apply({ reducedMotion = true, volume = { music = 0.4 } }) },
		{ settings:apply({ uiScale = 9 }) }, -- out of range: clamped, noted
	}
	local onboardingSteps = {
		{ onboarding:complete("step_c") }, -- out of order
		{ onboarding:complete("step_a") },
	}

	-- A kit called inside an update would nest a write: the session answers busy, so the kit
	-- refuses instead of committing in memory.
	local busy
	sessionA:update(function(_draft: any): any
		busy = { wallet:credit("currency_a", 1, "Gameplay", { txId = "inside:1" }) }
		return nil
	end)

	-- A developer-product receipt, delivered twice. The writers apply the catalog grants to the
	-- draft through Wallet and Inventory built on the draft's own data, so caps and stacks hold.
	local catalog = Catalog.define({
		schema = "catalog/1",
		mode = "game",
		products = {
			{
				key = "currency_pack_a",
				kind = "devproduct",
				id = SESSION.pack,
				enabled = true,
				ownershipVerified = true,
				grants = {
					{ type = "currency", currency = "currency_a", amount = SESSION.packAmount },
					{ type = "item", item = "item_a", count = SESSION.packItems },
				},
				display = { nameKey = "shop.currency_pack_a.name" },
			},
		},
	})
	local purchaseTx = ""
	local write = Commerce.grantWriter({
		currency = function(draft: any, currency: string, amount: number)
			local scratch = Wallet.new({ currencies = SESSION_CURRENCIES, data = draft.economy.wallet })
			local ok, why = scratch:credit(currency, amount, "IAP", { txId = purchaseTx })
			assert(ok, "currency grant refused: " .. tostring(why))
			draft.economy.wallet = scratch:serialize()
		end,
		item = function(draft: any, item: string, count: number)
			local scratch = Inventory.new({
				items = SESSION_ITEMS,
				owner = SESSION.owner,
				capacity = 12,
				equipSlots = { "slot_a" },
				data = draft.economy.inventory,
			})
			local ok, why = scratch:add(item, count)
			assert(ok, "item grant refused: " .. tostring(why))
			draft.economy.inventory = scratch:serialize()
		end,
	})
	local receipts: { string } = {}
	local stale: { [string]: any } = {}
	local process = Commerce.receiptProcessor({
		catalog = catalog,
		sessionFor = function(playerId: number): any
			return storeA:get(playerId)
		end,
		grant = function(draft: any, product: any, receipt: any)
			purchaseTx = "iap:" .. receipt.PurchaseId
			write(draft, product)
		end,
		onResult = function(result: any)
			table.insert(receipts, result.status)
			local txId = "iap:" .. result.purchaseId
			if result.status == "granted" and not wallet:seen(txId) then
				-- The grant went into the session; the live kits reload before anything else
				-- writes, then the economy event goes out after the durable write.
				stale.balance = wallet:balance("currency_a")
				stale.items = inventory:count("item_a")
				stale.reloads = { { wallet:reload() }, { inventory:reload() } }
				telemetry:economy(
					SESSION.player,
					"source",
					"currency_a",
					SESSION.packAmount,
					wallet:balance("currency_a"),
					"IAP",
					result.productKey
				)
			end
		end,
	}, env)
	local receipt = { PlayerId = SESSION.userId, ProductId = SESSION.pack, PurchaseId = SESSION.purchaseId }
	local delivered = { { process(receipt) }, { process(receipt) } }
	local afterGrant = { balance = wallet:balance("currency_a"), items = inventory:count("item_a") }
	local postCredit = { wallet:credit("currency_a", 7, "Gameplay", { txId = "post:1" }) }
	local postAdd = { inventory:add("item_a", 1) }
	assert(sessionA:saveAsync())
	local savedByA = deepCopy(shared.values[sessionA.key])

	-- Server B takes the lock (an expired lock or a steal); A's next save finds out.
	backends.server_a:steal(sessionA.key, "server_b")
	sessionA:save()
	local balanceBefore = wallet:serialize()
	local itemsBefore = inventory:serialize()
	local eventsBefore = #recorder.events
	local late = {
		wallet = { wallet:credit("currency_a", 50, "Gameplay", { txId = "late:1" }) },
		inventory = { inventory:add("item_a", 1) },
		settings = { settings:apply({ invertY = true }) },
		onboarding = { onboarding:complete("step_b") },
		set = { sessionA:set("progress.flag", true) },
		release = { sessionA:release() },
	}
	local unchanged = {
		wallet = Json.encode(wallet:serialize()) == Json.encode(balanceBefore),
		inventory = Json.encode(inventory:serialize()) == Json.encode(itemsBefore),
		events = #recorder.events - eventsBefore,
	}

	-- B loads version 2: the migration runs once and the data is exactly what A saved.
	local sessionB = assert(storeB:load(SESSION.userId))
	local loadedB = sessionB:get()
	local walletB = Wallet.new({ currencies = SESSION_CURRENCIES, store = sessionB:keyStore("economy") }, env)
	local inventoryB = Inventory.new({
		items = SESSION_ITEMS,
		owner = SESSION.owner,
		capacity = 12,
		equipSlots = { "slot_a" },
		store = sessionB:keyStore("economy"),
	}, env)
	local trackB =
		Progression.new({ curve = curve, path = "combat", data = sessionB:get("progress.combat") }, env)
	local settingsB = SettingsStore.new({ store = sessionB:keyStore() }, env)
	local onboardingB = Onboarding.new({ steps = SESSION_STEPS, store = sessionB:keyStore("progress") }, env)
	local resumed = {
		wallet = walletB:serialize(),
		inventory = inventoryB:serialize(),
		level = trackB:level(),
		xp = trackB:xp(),
		settings = (settingsB:load()),
		onboarding = onboardingB:current(),
	}
	local releasedB = { sessionB:release() }
	local storeC = server("server_c", 2)
	local sessionC = assert(storeC:load(SESSION.userId))
	local loadedC = sessionC:get()
	sessionC:release()

	return {
		heldRefusal = heldRefusal,
		lost = lost,
		refusals = refusals,
		settingsNotes = settingsNotes,
		settingsResults = settingsResults,
		onboardingSteps = onboardingSteps,
		busy = busy,
		receipts = receipts,
		delivered = delivered,
		stale = stale,
		afterGrant = afterGrant,
		postCredit = postCredit,
		postAdd = postAdd,
		savedByA = savedByA,
		late = late,
		unchanged = unchanged,
		loadedB = loadedB,
		loadedC = loadedC,
		resumed = resumed,
		releasedB = releasedB,
		migrated = migrated,
		live = {
			wallet = wallet:serialize(),
			inventory = inventory:serialize(),
			level = track:level(),
			xp = track:xp(),
			settings = settings:get(),
			onboarding = onboarding:current(),
		},
		recorder = recorder,
		report = telemetry:report(),
		log = log,
	}
end

local function session(): { [string]: any }
	return once("session", sessionPersistence)
end

test("session_persistence: a held session is refused, lost on a steal and resumed elsewhere", function(t)
	local run = session()
	same(t, run.heldRefusal, { nil, "locked" }, "second server while the first holds the lock")
	same(t, run.lost, { "lock_lost" }, "the first server learns it lost the lock")
	same(t, run.late.set, { false, "inactive" }, "the lost session refuses writes")
	same(t, run.late.release, { false, "lost" }, "releasing a lost session")
	same(t, run.releasedB, { true }, "the successor releases cleanly")
end)

test(
	"session_persistence: kits refuse to commit on a lost or busy session (store_failed, no event)",
	function(t)
		local run = session()
		-- Failed before the fix: Wallet, Inventory and Onboarding treated a store:set that returned
		-- (false, reason) instead of raising as a successful write.
		same(t, run.late.wallet, { false, "store_failed" }, "wallet credit after the lock was lost")
		same(t, run.late.inventory[1], false, "inventory add after the lock was lost")
		t.eq(run.late.inventory[2], "store_failed")
		same(t, run.late.onboarding, { false, "store_failed" }, "onboarding step after the lock was lost")
		same(t, run.late.settings[1], false, "settings patch after the lock was lost")
		t.eq(run.late.settings[2], "store_failed:inactive")
		same(t, run.busy, { false, "store_failed" }, "wallet credit nested inside an update")
		t.ok(run.unchanged.wallet, "the wallet kept its committed balances")
		t.ok(run.unchanged.inventory, "the inventory kept its committed entries")
		t.eq(run.unchanged.events, 0, "nothing was reported for refused changes")
		same(t, run.live.onboarding, "step_b", "onboarding still waits on step_b")
	end
)

test("session_persistence: a receipt delivered twice grants once and the live kits reload", function(t)
	local run = session()
	same(t, run.delivered, { { "granted" }, { "granted" } }, "both deliveries answer granted")
	same(t, run.receipts, { "granted", "granted" })
	local saved = run.savedByA
	same(t, saved.purchaseIds, { SESSION.purchaseId }, "the purchase id is in the ring once")
	-- The live kits were stale until reload (the grant went straight into the session).
	same(t, run.stale.reloads, { { true }, { true } }, "wallet and inventory reloads")
	t.eq(run.afterGrant.balance, run.stale.balance + SESSION.packAmount, "currency granted once")
	t.eq(run.afterGrant.items, run.stale.items + SESSION.packItems, "items granted once")
	same(t, run.postCredit, { true, nil, 7 }, "a credit after the reload")
	t.eq(
		saved.economy.wallet.balances.currency_a,
		run.stale.balance + SESSION.packAmount + 7,
		"the next commit kept the grant"
	)
	t.ok(
		table.find(saved.economy.wallet.recent, "iap:" .. SESSION.purchaseId) ~= nil,
		"the grant tx id is kept"
	)
	t.eq(run.postAdd[1], true, "an add after the reload")
	local savedItems = 0
	for _, entry in saved.economy.inventory.entries do
		if entry.item == "item_a" then
			savedItems += entry.count
		end
	end
	t.eq(savedItems, run.stale.items + SESSION.packItems + 1, "the next inventory commit kept the grant")
	-- Every reported economy flow adds up to the durable balance.
	local net = 0
	for _, event in run.recorder.events do
		if event.category == "economy" and event.economy.currency == "currency_a" then
			net += if event.economy.flow == "source" then event.economy.amount else -event.economy.amount
		end
	end
	t.eq(net, saved.economy.wallet.balances.currency_a, "economy events reconcile with the saved balance")
	same(t, run.report.rejected, {}, "Telemetry rejected nothing")
end)

test("session_persistence: version 2 migrates once and reads back exactly what was saved", function(t)
	local run = session()
	t.eq(run.migrated, 1, "migrations[1] ran once (server B), not again on server C")
	local expected = deepCopy(run.savedByA)
	expected.schemaVersion = 2
	expected.progress.combat = expected.progress.track
	expected.progress.track = nil
	same(t, run.loadedB, expected, "server B reads A's save, migrated")
	same(t, run.loadedC, expected, "server C reads the same data")
	same(t, run.resumed.wallet, run.live.wallet, "wallet round trip")
	same(t, run.resumed.inventory, run.live.inventory, "inventory round trip")
	t.eq(run.resumed.level, run.live.level)
	t.eq(run.resumed.xp, run.live.xp)
	same(t, run.resumed.settings, run.live.settings, "settings round trip")
	t.eq(run.resumed.onboarding, "step_b", "onboarding resumes at the first open step")
	-- the seeded script exercised the kits and their refusals
	same(t, run.onboardingSteps, { { false, "out_of_order" }, { true } })
	t.eq(run.settingsResults[1][1], true)
	t.eq(run.settingsResults[2][2].uiScale, 1.5, "an out-of-range patch is clamped")
	t.eq(run.live.settings.reducedMotion, true)
	t.ok(run.live.level > 1, "the track levelled")
	t.ok(run.live.inventory.equipped.slot_a ~= nil, "a tool is equipped")
end)

-- The kit fixes this slice needed, at the edges: a store answering (false, reason) is a failed
-- write (nil is still success), and reload refuses without a usable store.
test("session_persistence: store refusals and reload edges in Wallet and Inventory", function(t)
	local values: { [string]: any } = {}
	local refuse: string? = nil
	local down = false
	local store = {
		get = function(_self: any, key: string): any
			if down then
				error("store down")
			end
			return deepCopy(values[key])
		end,
		set = function(_self: any, key: string, value: any): (boolean?, string?)
			if refuse then
				return false, refuse
			end
			values[key] = deepCopy(value)
			return nil -- a store that returns nothing still succeeds
		end,
	}
	same(t, { Wallet.new({ currencies = SESSION_CURRENCIES }):reload() }, { false, "no_store" })
	local wallet = Wallet.new({ currencies = SESSION_CURRENCIES, store = store })
	same(t, { wallet:reload() }, { false, "empty" }, "nothing stored yet")
	same(t, { wallet:credit("currency_a", 10, "Gameplay") }, { true, nil, 10 })
	refuse = "quota"
	same(t, { wallet:credit("currency_a", 5, "Gameplay") }, { false, "store_failed" }, "a refused write")
	refuse = nil
	t.eq(wallet:balance("currency_a"), 10)
	local tx = wallet:prepare({ { currency = "currency_a", delta = 5, reason = "Gameplay" } })
	values.wallet.balances.currency_a = 40 -- another writer (a receipt grant)
	local moved = {}
	wallet.changed:Connect(function(currency: string, balance: number, delta: number)
		table.insert(moved, { currency, balance, delta })
	end)
	same(t, { wallet:reload() }, { true })
	same(t, moved, { { "currency_a", 40, 30 } }, "changed fires for the moved balance only")
	same(t, { wallet:commit(tx) }, { false, "stale" }, "a tx prepared before the reload")
	down = true
	same(t, { wallet:reload() }, { false, "store_failed" })
	t.eq(wallet:balance("currency_a"), 40, "a failed reload changes nothing")
	down = false

	same(
		t,
		{ Inventory.new({ items = SESSION_ITEMS, owner = "p1", capacity = 4 }):reload() },
		{ false, "no_store" }
	)
	local inventory = Inventory.new({ items = SESSION_ITEMS, owner = "p1", capacity = 4, store = store })
	same(t, { inventory:reload() }, { false, "empty" })
	t.eq((inventory:add("item_a", 2)), true)
	refuse = "quota"
	same(t, { inventory:add("item_a", 1) }, { false, "store_failed", { index = 0 } }, "a refused write")
	refuse = nil
	values.inventory.entries[1].count = 9
	local records = {}
	inventory.changed:Connect(function(record: any)
		table.insert(records, record.state)
	end)
	same(t, { inventory:reload() }, { true })
	t.eq(inventory:count("item_a"), 9)
	same(t, records, { "reloaded" })
	down = true
	same(t, { inventory:reload() }, { false, "store_failed" })
	t.eq(inventory:count("item_a"), 9, "a failed reload changes nothing")
end)

local function sessionSummary(): { [string]: any }
	local run = session()
	return {
		balances = run.savedByA.economy.wallet.balances,
		items = #run.savedByA.economy.inventory.entries,
		level = run.live.level,
		xp = run.live.xp,
		refusals = run.refusals,
		saved = Golden.digest({ Json.encode(run.loadedB) }),
		digest = Golden.digest(run.log),
		telemetry = Golden.digest(run.recorder:lines()),
	}
end

-- ---------------------------------------------------------------- ui_onboarding_flow
-- GameKit/Onboarding (G3) over a PlayerData session (G1) with Telemetry (G1) -> Settings (G1)
-- reduced motion -> Cinematics (G4) orbit fixture with hold-to-skip on cinematic.skip ->
-- InputMap and InputMapRoblox contexts (G4) -> UIKit Modal, Button, ProgressBar and
-- KeybindPrompt (G4) driven by FakeUIEvents. The same flow runs with full and with reduced
-- motion; the player leaves after step_b and resumes on another server.

local UI_FLOW = { userId = 5151, dt = 1 / 60, holdFrom = 1.0, steps = { "step_a", "step_b", "step_c" } }

local function uiOnboardingFlow(reducedMotion: boolean): { [string]: any }
	local env = FakeEnv.new({ roblox = roblox, seed = "slices:ui" })
	local hub = FakeUIEvents.new()
	local recorder = Events.recorder({ strict = true })
	local telemetry =
		Telemetry.new({ sink = recorder, envelope = ENVELOPE, strict = true, budget = false }, env)
	local effective = Settings.effective((Settings.set(Settings.defaults(), "reducedMotion", reducedMotion)))
	local map = InputMap.defaults()
	local input = InputMapRoblox.build(map, env, { name = "SliceInput" })
	local log: { string } = {}
	local function contexts(): string
		local out = {}
		for _, name in { "cinematic", "gameplay", "ui" } do
			table.insert(out, name .. "=" .. tostring(input.contexts[name].Enabled))
		end
		return table.concat(out, " ")
	end
	local function note(text: string)
		table.insert(log, string.format("%.3f %s", env.clock(), text))
	end
	note("contexts " .. contexts())

	local shared = { values = {}, locks = {} }
	local function server(id: string): any
		return PlayerData.new({
			template = { progress = {} },
			version = 1,
			backend = PlayerData.memoryBackend({ serverId = id, shared = shared }),
			autosave = false,
		}, env)
	end
	local function onboardingFor(session: any): any
		return Onboarding.new({
			steps = UI_FLOW.steps,
			store = session:keyStore("progress"),
			sink = telemetry,
			player = tostring(UI_FLOW.userId),
		}, env)
	end
	local sessionA = assert(server("server_a"):load(UI_FLOW.userId))
	local onboarding = onboardingFor(sessionA)

	-- 1. The intro cinematic. The cinematic context sinks gameplay and ui input; the scripted
	-- player holds cinematic.skip from holdFrom; reduced motion plays Cinematics.reduce (the
	-- camera holds at each key instead of moving).
	local cin = Cinematics.define(ORBIT)
	local played = if effective.reducedMotion then Cinematics.reduce(cin) else cin
	input:setEnabled("cinematic", true)
	note("cinematic " .. contexts())
	local skipAction = input.actions["cinematic.skip"]
	local cinematic = Cinematics.player(played)
	local firstKey = cin.camera.keys[1].position
	local cameraMoved = false
	local fired: { string } = {}
	local frame
	repeat
		skipAction.BoolState = cinematic:time() >= UI_FLOW.holdFrom
		frame = cinematic:step(UI_FLOW.dt, skipAction.BoolState)
		env:advance(UI_FLOW.dt)
		for _, event in frame.events do
			table.insert(fired, event.name)
		end
		if frame.state == "playing" and frame.sample.t < UI_FLOW.holdFrom then
			local p = frame.sample.position
			if
				math.abs(p[1] - firstKey[1]) + math.abs(p[2] - firstKey[2]) + math.abs(p[3] - firstKey[3])
				> 1e-6
			then
				cameraMoved = true
			end
		end
	until frame.state ~= "playing"
	local cinematicResult = {
		state = frame.state,
		skippedAt = env.clock(),
		finalSample = frame.sample,
		expectedFinal = Cinematics.sample(played, played.duration),
		fired = fired,
		cameraMoved = cameraMoved,
	}
	skipAction.BoolState = false
	input:setEnabled("cinematic", false)
	local stepA = { onboarding:complete("step_a") }
	note("cinematic " .. frame.state .. " step_a " .. tostring(stepA[1]))

	-- 2. The onboarding panel: a Modal with progress, a keybind prompt and two buttons, mounted
	-- with the modal's ctx so destroying the modal cleans them too. Gameplay input is off while
	-- it is open.
	local ctx = Build.context({
		env = env,
		on = hub.on,
		onChanged = hub.onChanged,
		motion = { reducedMotion = effective.reducedMotion },
		inputMap = map,
	})
	local clicks: { string } = {}
	local function progressValue(): number
		local done = 0
		for _, step in UI_FLOW.steps do
			if onboarding:isCompleted(step) then
				done += 1
			end
		end
		return done / #UI_FLOW.steps
	end
	local modal = UIKit.Components.Modal.mount({ textKey = "uikit.continue", dismissable = false }, ctx)
	local bar = UIKit.Components.ProgressBar.mount(
		{ value = progressValue(), showValue = true, text = "Onboarding" },
		modal.ctx,
		modal.parts.content
	)
	local prompt =
		UIKit.Components.KeybindPrompt.mount({ action = "ui.confirm" }, modal.ctx, modal.parts.content)
	local function press(step: string): () -> ()
		return function()
			local ok, why = onboarding:complete(step)
			table.insert(clicks, string.format("%s %s %s", step, tostring(ok), tostring(why)))
			bar:update({ value = progressValue() })
		end
	end
	local nextButton = UIKit.Components.Button.mount(
		{ textKey = "uikit.continue", onActivated = press("step_b") },
		modal.ctx,
		modal.parts.actions
	)
	local confirmButton = UIKit.Components.Button.mount(
		{ textKey = "uikit.confirm", variant = "secondary", onActivated = press("step_c") },
		modal.ctx,
		modal.parts.actions
	)
	input:setEnabled("gameplay", false)
	modal.state.open()
	note("panel " .. contexts())
	local opened = env.clock()
	local scalePeak = 0
	local settle = nil
	for _ = 1, 120 do
		ctx.runner:step(UI_FLOW.dt)
		env:advance(UI_FLOW.dt)
		scalePeak = math.max(scalePeak, math.abs(modal.parts.scale.Scale - 1))
		if settle == nil and ctx.runner:count() == 0 then
			settle = env.clock() - opened
		end
	end
	local panel = {
		settle = settle,
		scalePeak = scalePeak,
		titleAlpha = modal.parts.title.TextTransparency,
		glyphs = { prompt.parts.cap.Key.Text },
	}
	prompt:update({ device = "Gamepad" })
	table.insert(panel.glyphs, prompt.parts.cap.Key.Text)
	panel.barBefore = bar.parts.value.Text
	hub:fire(confirmButton.root, "Activated") -- step_c before step_b
	hub:fire(nextButton.root, "Activated")
	for _ = 1, 60 do
		ctx.runner:step(UI_FLOW.dt)
	end
	panel.barAfter = bar.parts.value.Text

	-- 3. The player leaves before step_c and rejoins on another server: onboarding resumes there.
	modal:destroy()
	input:setEnabled("gameplay", true)
	note("left " .. contexts())
	local released = { sessionA:release() }
	local sessionB = assert(server("server_b"):load(UI_FLOW.userId))
	local resumed = onboardingFor(sessionB)
	local resume = {
		current = resumed:current(),
		again = { resumed:complete("step_a") }, -- done before: no second event
		final = { resumed:complete("step_c") },
		done = resumed:isDone(),
	}
	sessionB:release()
	note("resumed " .. tostring(resume.current) .. " done " .. tostring(resume.done))
	local onboardingSteps = {}
	local completes = 0
	for _, event in recorder.events do
		if event.category == "onboarding" then
			table.insert(onboardingSteps, event.onboarding.step)
		elseif event.name == "onboarding_complete" then
			completes += 1
		end
	end
	return {
		effective = effective,
		cinematic = cinematicResult,
		stepA = stepA,
		panel = panel,
		clicks = clicks,
		released = released,
		resume = resume,
		contexts = contexts(),
		onboardingSteps = onboardingSteps,
		completes = completes,
		uiConnections = hub:count(),
		report = telemetry:report(),
		recorder = recorder,
		log = log,
	}
end

local function uiFlow(reduced: boolean): { [string]: any }
	return once(if reduced then "ui_reduced" else "ui_full", function()
		return uiOnboardingFlow(reduced)
	end)
end

test("ui_onboarding_flow: hold-to-skip ends the cinematic on its final frame", function(t)
	for _, reduced in { false, true } do
		local run = uiFlow(reduced)
		local c = run.cinematic
		t.eq(c.state, "skipped", "held skip")
		local hold = ORBIT.skip.hold
		t.ok(math.abs(c.skippedAt - (UI_FLOW.holdFrom + hold)) <= 2 * UI_FLOW.dt, "skipped after the hold")
		same(t, c.finalSample, c.expectedFinal, "the frame after a skip is the final frame")
		same(t, c.fired, { "started", "done" }, "midpoint is dropped, done fires on skip")
		same(t, run.stepA, { true }, "the cinematic completes step_a")
	end
	t.ok(uiFlow(false).cinematic.cameraMoved, "full motion: the camera moves")
	t.ok(not uiFlow(true).cinematic.cameraMoved, "reduced motion: the camera holds at its key")
end)

test("ui_onboarding_flow: reduced motion settles the panel within the reduced fade", function(t)
	local full, calm = uiFlow(false), uiFlow(true)
	t.eq(calm.effective.reducedMotion, true)
	t.eq(calm.effective.shakeScale, 0, "settings/1: reduced motion turns shake off")
	local reducedFade = 0.15
	t.ok(calm.panel.settle ~= nil and calm.panel.settle <= reducedFade + UI_FLOW.dt + 1e-9, "reduced settle")
	t.ok(full.panel.settle ~= nil and full.panel.settle > reducedFade, "full motion takes longer")
	t.eq(calm.panel.scalePeak, 0, "reduced motion: no scale pop")
	t.ok(full.panel.scalePeak > 0, "full motion pops")
	for _, run in { full, calm } do
		t.eq(run.panel.titleAlpha, 0, "the title is opaque at rest")
	end
end)

test("ui_onboarding_flow: steps go in order through the UI and resume after rejoin", function(t)
	for _, reduced in { false, true } do
		local run = uiFlow(reduced)
		same(t, run.clicks, { "step_c false out_of_order", "step_b true nil" }, "button presses")
		t.eq(run.panel.barBefore, "33%")
		t.eq(run.panel.barAfter, "67%")
		same(t, run.panel.glyphs, {
			InputMap.glyph(InputMap.defaults(), "ui.confirm", "KeyboardAndMouse").text,
			InputMap.glyph(InputMap.defaults(), "ui.confirm", "Gamepad").text,
		}, "the prompt follows the device")
		same(t, run.released, { true })
		t.eq(run.resume.current, "step_c", "resumes at the first open step")
		same(t, run.resume.again, { true, "already" })
		same(t, run.resume.final, { true })
		t.ok(run.resume.done)
		same(t, run.onboardingSteps, { 1, 2, 3 }, "each step reported once, in order")
		t.eq(run.completes, 1)
		t.eq(run.contexts, "cinematic=false gameplay=true ui=true", "input contexts restored")
		t.eq(run.uiConnections, 0, "the destroyed panel left no connection")
		same(t, run.report.rejected, {}, "Telemetry rejected nothing")
	end
end)

local function uiSummary(): { [string]: any }
	local full, calm = uiFlow(false), uiFlow(true)
	return {
		settle = { full = r3(full.panel.settle), reduced = r3(calm.panel.settle) },
		skippedAt = r3(full.cinematic.skippedAt),
		glyphs = full.panel.glyphs,
		digest = { full = Golden.digest(full.log), reduced = Golden.digest(calm.log) },
		telemetry = Golden.digest(full.recorder:lines()),
	}
end

-- ---------------------------------------------------------------- authority_input_client
-- The Studio client script fixtures/kits/client/authority_Input.client.luau run in Lune: its
-- source is loaded with @lune/luau over fake services (game, script, require of the Workbench
-- tree), so the InputMap -> InputMapRoblox -> MovementRoblox -> AuthorityRoblox wiring builds
-- real @lune/roblox Instances, and the payloads it sends go into the real fixture core
-- (fixtures/kits/shared/authority_Arena) on the server side. Engine input is the probe's
-- (authority_simulation_bind); here the InputAction states are set by the test.

local ARENA_KITS = {
	["SceneKit/Vec"] = Vec,
	["GameKit/Hitbox"] = Hitbox,
	["GameKit/Zones"] = Zones,
	["GameKit/Vitals"] = Vitals,
	["GameKit/Cooldowns"] = Cooldowns,
	["GameKit/Movement"] = Movement,
	["GameKit/RoundLoop"] = RoundLoop,
}
local CLIENT_MODULES = {
	["GameKit/AuthorityRoblox"] = AuthorityRoblox,
	["GameKit/InputMap"] = InputMap,
	["GameKit/InputMapRoblox"] = InputMapRoblox,
	["GameKit/MovementRoblox"] = MovementRoblox,
	["KitFixtures/authority_Arena"] = AuthorityArena,
}

local function authorityClient(): { [string]: any }
	-- Server side: the fixture core with two bodies in an active round.
	local env = FakeEnv.new({ seed = 7 })
	local arena = AuthorityArena.new(function(path: string): any
		return assert(ARENA_KITS[path], "unlisted kit " .. path)
	end, env, { minPlayers = 2, durations = { intermission = 1, active = 30, results = 1 } })
	arena:join(1)
	arena:join(2)
	for _ = 1, 66 do
		env:advance(1 / 60)
		arena:step()
	end
	assert(arena.loop:phase() == "active", "the round started")

	-- Client side fakes.
	local sent = { input = {} :: { any }, claim = {} :: { any } }
	local function remote(kind: string): any
		return {
			FireServer = function(_self: any, payload: any)
				table.insert(sent[kind], payload)
			end,
		}
	end
	local holder = {
		WaitForChild = function(_self: any, name: string): any
			return remote(if name == "Input" then "input" else "claim")
		end,
		GetAttribute = function(_self: any, name: string): any
			return if name == "ArenaClock" then env.clock() else nil
		end,
	}
	local function v3(p: any): any
		return roblox.Vector3.new(p.x, p.y, p.z)
	end
	local function marker(id: number): any
		return {
			CFrame = roblox.CFrame.new(v3(arena:position(id))),
			GetAttribute = function(_self: any, name: string): any
				return if name == "BodyId" then id else nil
			end,
		}
	end
	local bodies = {
		FindFirstChild = function(_self: any, name: string): any
			return if name == "1" then marker(1) else nil
		end,
	}
	-- The camera sits on body 1 looking at body 2 (axes given directly: Lune 0.10's
	-- CFrame.lookAt mirrors the look direction).
	local from, to = arena:position(1), arena:position(2)
	local look = Vec.unit(Vec.sub(to, from))
	local camera = {
		CFrame = { LookVector = v3(look), RightVector = roblox.Vector3.new(-look.z, 0, look.x) },
		CameraSubject = nil :: any,
	}
	local casts = 0
	local workspace = {
		CurrentCamera = camera,
		GetAttribute = function(_self: any, name: string): any
			return if name == "SETUP_ONLY_KitFixture" then "authority" else nil
		end,
		WaitForChild = function(_self: any, name: string): any
			assert(name == "SETUP_ONLY_AuthorityArena", name)
			return {
				WaitForChild = function(_inner: any, child: string): any
					assert(child == "Bodies", child)
					return bodies
				end,
			}
		end,
		Raycast = function(_self: any, _origin: any, _direction: any, params: any): any
			casts += 1
			assert(params.FilterType == roblox.Enum.RaycastFilterType.Include, "include filter")
			return { Instance = marker(2), Position = v3(arena:position(2)) }
		end,
	}
	local function node(path: string): any
		return {
			module = CLIENT_MODULES[path],
			WaitForChild = function(_self: any, name: string): any
				return node(if path == "" then name else path .. "/" .. name)
			end,
		}
	end
	local step: ((dt: number) -> ())? = nil
	local services = {
		Players = { LocalPlayer = { UserId = 1 } },
		ReplicatedStorage = {
			WaitForChild = function(_self: any, name: string): any
				if name == "SETUP_ONLY_Authority" then
					return holder
				end
				return node(if name == "Workbench" then "" else name)
			end,
		},
		RunService = {
			BindToSimulation = function(_self: any, fn: (dt: number) -> ()): any
				step = fn
				return { Disconnect = function() end }
			end,
		},
		Workspace = workspace,
	}
	local script = roblox.Instance.new("LocalScript")
	local clock = 0
	local warnings = {}
	local source = fs.readFile(ROOT .. "/fixtures/kits/client/authority_Input.client.luau")
	local main = luau.load(source, {
		debugName = "authority_Input.client",
		environment = {
			game = {
				GetService = function(_self: any, name: string): any
					return assert((services :: any)[name], "unknown service " .. name)
				end,
			},
			script = script,
			Instance = roblox.Instance,
			Enum = roblox.Enum,
			Vector3 = roblox.Vector3,
			RaycastParams = {
				new = function(): any
					return {}
				end,
			},
			os = {
				clock = function(): number
					return clock
				end,
			},
			warn = function(...: any)
				table.insert(warnings, table.concat({ ... }, " "))
			end,
			require = function(target: any): any
				return assert(target.module, "the fixture required an unlisted module")
			end,
		},
	})
	main()

	-- The tree the client built: one context, the arena's four actions plus jump and slide.
	local folder = script:FindFirstChild("SETUP_ONLY_AuthorityInput")
	local context = folder and folder:FindFirstChild("gameplay")
	local actions = {}
	local byName: { [string]: any } = {}
	for _, action in if context then context:GetChildren() else {} do
		table.insert(actions, action:GetAttribute("Action"))
		byName[action:GetAttribute("Action")] = action
	end
	table.sort(actions)
	local primaryKeys = {}
	for _, item in byName["gameplay.primary"]:GetChildren() do
		table.insert(primaryKeys, item:GetAttribute("Device") .. ":" .. item.KeyCode.Name)
	end
	table.sort(primaryKeys)
	local touchBindings = 0
	for _, action in byName do
		for _, item in action:GetChildren() do
			if item:GetAttribute("Device") == "Touch" then
				touchBindings += 1
			end
		end
	end

	-- Drive the simulation step: idle, then forward + sprint, a dash press, a primary press,
	-- then idle until the keep-alive.
	local stepper = assert(step, "the client bound a simulation step")
	local function frames(n: number)
		for _ = 1, n do
			clock += 1 / 60
			stepper(1 / 60)
		end
	end
	frames(1)
	byName["gameplay.move"].Direction2DState = roblox.Vector2.new(0, 1)
	byName["gameplay.sprint"].BoolState = true
	byName["gameplay.dash"].BoolState = false
	byName["gameplay.primary"].BoolState = false
	frames(6)
	byName["gameplay.dash"].BoolState = true
	frames(2)
	byName["gameplay.primary"].BoolState = true
	frames(2)
	byName["gameplay.primary"].BoolState = false
	frames(20)

	-- Server side: every payload goes through the fixture core's own validation.
	local inputResults, claimResults = {}, {}
	for _, payload in sent.input do
		table.insert(inputResults, { arena:input(1, payload) })
	end
	for _, payload in sent.claim do
		local ok, why = arena:claim(1, payload)
		table.insert(claimResults, { ok, why })
	end
	local before = arena:position(1)
	for _ = 1, 30 do
		env:advance(1 / 60)
		arena:step()
	end
	local after = arena:position(1)
	return {
		actions = actions,
		contextEnabled = context and context.Enabled,
		primaryKeys = primaryKeys,
		touchBindings = touchBindings,
		sent = sent,
		look = look,
		inputResults = inputResults,
		claimResults = claimResults,
		casts = casts,
		followed = camera.CameraSubject ~= nil,
		moved = Vec.sub(after, before),
		warnings = warnings,
	}
end

test(
	"authority_input_client: the Studio client builds its input from InputMap and the server accepts it",
	function(t)
		local run = once("authority_client", authorityClient)
		same(t, run.warnings, {}, "no warnings")
		same(t, run.actions, {
			"gameplay.dash",
			"gameplay.jump",
			"gameplay.move",
			"gameplay.primary",
			"gameplay.slide",
			"gameplay.sprint",
		}, "InputMap's gameplay context with the arena's actions plus jump and slide")
		t.eq(run.contextEnabled, true)
		same(
			t,
			run.primaryKeys,
			{ "Gamepad:ButtonR2", "KeyboardAndMouse:MouseLeftButton" },
			"primary bindings"
		)
		t.eq(run.touchBindings, 0, "touch buttons stay pending: the fixture mounts none")
		t.ok(run.followed, "the camera follows the own body marker")
		-- Inputs: the keep-alive first, then the forward + sprint change, then the dash press.
		local inputs = run.sent.input
		t.ok(#inputs >= 4, "keep-alive, change, dash and a later keep-alive")
		same(t, { inputs[1].move.x, inputs[1].move.z, inputs[1].sprint, inputs[1].seq }, { 0, 0, false, 1 })
		t.ok(
			math.abs(inputs[2].move.x - run.look.x) < 1e-6 and math.abs(inputs[2].move.z - run.look.z) < 1e-6,
			"camera-relative forward"
		)
		t.eq(inputs[2].sprint, true)
		t.eq(inputs[3].dash, true, "a dash press is sent at once")
		local dashes = 0
		for index, payload in inputs do
			t.eq(payload.seq, index, "seq counts up")
			if payload.dash then
				dashes += 1
			end
		end
		t.eq(dashes, 1, "a held dash is one press")
		for index, result in run.inputResults do
			same(t, result, { true }, "input " .. index .. " accepted by the arena")
		end
		t.eq(#run.sent.claim, 1, "one primary press, one claim")
		t.eq(run.casts, 1)
		local claim = run.sent.claim[1]
		t.eq(claim.target, 2)
		t.eq(claim.shotId, 1)
		same(t, run.claimResults, { { true } }, "the claim passes the server's rewind validation")
		t.ok(Vec.dot(run.moved, run.look) > 1, "the server moved body 1 the way the camera looks")
	end
)

-- ProcGen/Rng hashes string seeds (FNV-1a) but uses small numeric seeds as the xorshift state
-- almost directly, so Rng.new(i) for consecutive i gives nearly the same first draw. Slices seed
-- per-index streams with strings ("slices:race:bot:" .. i); this pins that those differ.
test("seeds: string-derived seeds give consecutive indices unrelated first draws", function(t)
	local seen: { [number]: boolean } = {}
	local quartiles: { [number]: boolean } = {}
	local gap = 0
	local previous = nil
	for i = 1, 16 do
		local value = Rng.new("bot:" .. i):next()
		t.ok(not seen[value], "distinct first draw for bot:" .. i)
		seen[value] = true
		quartiles[math.floor(value * 4)] = true
		if previous then
			gap += math.abs(value - previous)
		end
		previous = value
	end
	local hit = 0
	for _ in quartiles do
		hit += 1
	end
	t.eq(hit, 4, "first draws land in every quartile")
	t.ok(gap / 15 > 0.15, "consecutive indices are far apart on average")
	t.ok(Rng.new("bot:1"):next() == Rng.new("bot:1"):next(), "the same string, the same stream")
end)

local function authoritySummary(): { [string]: any }
	local run = once("authority_client", authorityClient)
	local inputs = {}
	for _, payload in run.sent.input do
		table.insert(inputs, {
			move = { r3(payload.move.x), r3(payload.move.z) },
			sprint = payload.sprint,
			dash = payload.dash,
			seq = payload.seq,
		})
	end
	return {
		actions = run.actions,
		inputs = inputs,
		claims = #run.sent.claim,
		moved = { r3(run.moved.x), r3(run.moved.z) },
	}
end

-- ---------------------------------------------------------------- golden

test("golden slices-integration: each slice's headline numbers and digests", function(t)
	local ok, message = Golden.check("slices-integration", {
		schema = "slices-integration/1",
		race_loop_vehicle = raceSummary(),
		stalker_ai = stalkerSummary(),
		projectile_arena = arenaSummary(),
		session_persistence = sessionSummary(),
		ui_onboarding_flow = uiSummary(),
		authority_input_client = authoritySummary(),
	})
	t.ok(ok, message)
end)

return cases
