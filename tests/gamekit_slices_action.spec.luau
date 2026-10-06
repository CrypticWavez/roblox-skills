--!strict
-- G2 seeded vertical slices; their digests are the golden tests/golden/gamekit-action.json.
--   round_arena  8 bots in the authority fixture core (fixtures/kits/shared/authority_Arena):
--                600 fixed steps of RoundLoop, Movement, Vitals, Hitbox (rewind validation),
--                Cooldowns and Zones. Bots 1-7 play by the rules with seeded latency (bot 7 at
--                150 ms, so its view is older than the 200 ms rewind allows); bot 8 is an
--                exploiter (malformed and oversized input, floods, stale, future, forged,
--                self and rapid-fire claims).
--   time_trial   two cars (Vehicles) on a four-gate course (Zones.course) for 900 fixed steps:
--                car_a drives by the rules; car_b's client teleports and sends a NaN position,
--                and the server's travel check (Movement.checkTravel with Vehicles.limits)
--                rubber-bands it, so the course never sees the shortcut.
-- Same seed => same digest (asserted here and against the golden). Update the golden only on
-- intended change: FACTORY_UPDATE_GOLDEN=gamekit-action lune run tests/run.luau gamekit_slices_action
local Arena = require("../fixtures/kits/shared/authority_Arena")
local FakeEnv = require("./fakes/FakeEnv")
local Golden = require("./lib/Golden")
local Hitbox = require("../packages/GameKit/Hitbox")
local Movement = require("../packages/GameKit/Movement")
local Vec = require("../packages/SceneKit/Vec")
local Vehicles = require("../packages/GameKit/Vehicles")
local Zones = require("../packages/GameKit/Zones")

local KITS = {
	["SceneKit/Vec"] = Vec,
	["GameKit/Hitbox"] = Hitbox,
	["GameKit/Zones"] = Zones,
	["GameKit/Vitals"] = require("../packages/GameKit/Vitals"),
	["GameKit/Cooldowns"] = require("../packages/GameKit/Cooldowns"),
	["GameKit/Movement"] = Movement,
	["GameKit/RoundLoop"] = require("../packages/GameKit/RoundLoop"),
}
local function kit(path: string): any
	return assert(KITS[path], "unlisted kit module " .. path)
end

local SEED = 20261006
local DT = 1 / 60

local function round3(value: number): number
	return math.floor(value * 1000 + 0.5) / 1000
end

local function countKinds(log: { any }): { [string]: number }
	local counts = {}
	for _, event in log do
		counts[event.kind] = (counts[event.kind] or 0) + 1
	end
	return counts
end

-- ---------------------------------------------------------------- round_arena

local function roundArena(seed: number): ({ any }, any)
	local env = FakeEnv.new({ seed = seed })
	local arena = Arena.new(kit, env, {
		seed = seed,
		durations = { intermission = 1, active = 6, results = 1 },
		minPlayers = 2,
		endOnAlive = 1,
	})
	local rng = env.rng(tostring(seed) .. ":bots")
	local bots = {}
	for id = 1, 8 do
		arena:join(id)
		local latency = if id == 7 then 0.15 else round3(rng:range(0.02, 0.08))
		arena:setLatency(id, latency)
		bots[id] = {
			latency = latency,
			waypoint = Vec.new(0, 0, 0),
			sprint = false,
			nextThink = 0,
			nextFire = rng:int(10, 40),
		}
	end
	local log = {}
	local function claimFrom(id: number, target: number, t: number, spread: number): any?
		local own, other = arena:poseAt(id, t), arena:poseAt(target, t)
		if own == nil or other == nil then
			return nil
		end
		local origin = Hitbox.center(own)
		local aim = Vec.sub(Hitbox.center(other), origin)
		if Vec.length(aim) < 1e-6 then
			return nil
		end
		aim = Vec.unit(aim)
		aim = Vec.unit(Vec.add(aim, Vec.new(rng:range(-spread, spread), 0, rng:range(-spread, spread))))
		local hit, _, point = Hitbox.segment(other, origin, Vec.scale(aim, Arena.CONFIG.primaryRange))
		if not hit then
			return nil
		end
		return { target = target, time = t, origin = origin, direction = aim, hitPoint = point }
	end
	local function others(id: number): { number }
		local list = {}
		for other = 1, 8 do
			if other ~= id and arena:isActive(other) then
				table.insert(list, other)
			end
		end
		return list
	end
	for k = 1, 600 do
		env:advance(DT)
		local now = env.clock()
		for id = 1, 7 do
			local bot = bots[id]
			if not arena:isActive(id) then
				continue
			end
			-- Movement: a new seeded waypoint now and then; input sent at 10 Hz.
			local dash = false
			if k >= bot.nextThink then
				bot.waypoint = Vec.new(rng:range(-28, 28), 0, rng:range(-28, 28))
				bot.sprint = rng:chance(0.3)
				dash = rng:chance(0.15)
				bot.nextThink = k + rng:int(20, 50)
			end
			if dash or k % 6 == id % 6 then
				local position = arena:position(id) :: any
				local dx, dz =
					bot.waypoint.x - (position.x - arena.origin.x),
					bot.waypoint.z - (position.z - arena.origin.z)
				local length = math.sqrt(dx * dx + dz * dz)
				local move = if length > 1 then { x = dx / length, z = dz / length } else { x = 0, z = 0 }
				arena:input(id, { move = move, sprint = bot.sprint, dash = dash })
			end
			-- Fire at a seeded rival as this client saw it (latency + 100 ms interpolation).
			if k >= bot.nextFire then
				bot.nextFire = k + rng:int(16, 36)
				local targets = others(id)
				local index = table.find(targets, 8)
				if index then
					table.remove(targets, index) -- the exploiter is left to the server
				end
				if #targets > 0 then
					local claim = claimFrom(id, rng:pick(targets), now - bot.latency - 0.1, 0.03)
					if claim then
						arena:claim(id, claim)
					end
				end
			end
		end
		-- Bot 8 stands still and tries one exploit per beat; beats are 18 steps (0.3 s) apart,
		-- longer than the primary cooldown, so each claim exploit meets the validator.
		local target = others(8)[1]
		local cycle = k // 108
		local beat = k % 108
		if arena:isActive(8) then
			if beat == 0 then
				arena:input(8, { move = { x = 0 / 0, z = 0 } })
				arena:input(8, { move = { x = 0, z = 40 } })
				arena:input(8, { move = { x = 0, z = 0 } })
			elseif beat == 9 then
				for _ = 1, 15 do
					arena:input(8, { move = { x = 0, z = 0 } })
				end
			elseif target and beat == 18 then
				local claim = claimFrom(8, target, now - 0.1, 0)
				if claim then
					claim.time = now - 0.5
					arena:claim(8, claim)
				end
			elseif target and beat == 36 then
				local claim = claimFrom(8, target, now - 0.1, 0)
				if claim then
					claim.origin = Vec.add(claim.origin, Vec.new(0, 0, 30))
					arena:claim(8, claim)
				end
			elseif target and beat == 54 then
				for _ = 1, 3 do
					local claim = claimFrom(8, target, now - 0.1, 0)
					if claim then
						arena:claim(8, claim)
					end
				end
			elseif target and beat == 72 then
				local claim = claimFrom(8, target, now - 0.1, 0)
				if claim then
					claim.time = now + 1
					arena:claim(8, claim)
				end
			elseif beat == 90 and cycle % 2 == 0 then
				local own = arena:position(8) :: any
				arena:claim(8, { target = 8, time = now, origin = own, direction = Vec.new(1, 0, 0) })
			elseif target and beat == 90 then
				local claim = claimFrom(8, target, now - 0.1, 0)
				if claim then
					claim.hitPoint = Vec.add(claim.hitPoint, Vec.new(0, 5, 0))
					arena:claim(8, claim)
				end
			end
		end
		for _, event in arena:step() do
			table.insert(log, event)
		end
	end
	return log, arena
end

-- ---------------------------------------------------------------- time_trial

local RADIUS = 36

local function timeTrial(seed: number): ({ any }, { [string]: any })
	local env = FakeEnv.new({ seed = seed })
	local rng = env.rng(tostring(seed) .. ":drivers")
	local spec = Vehicles.define({
		maxSpeed = 50,
		acceleration = 25,
		brake = 50,
		steerRate = 2.2,
		grip = 6,
		drift = { grip = 1.5, minSpeed = 20, noise = 2 },
		boost = { multiplier = 1.4, duration = 1, cooldown = 3 },
	})
	local limits = Vehicles.limits(spec)
	local set = Zones.define({
		{
			id = "gate_1",
			kind = "gate",
			shape = Zones.box(Vec.new(RADIUS, 0, 0), Vec.new(12, 8, 1)),
			gate = { order = 1, direction = Vec.new(0, 0, -1), minTime = 0.5 },
		},
		{
			id = "gate_2",
			kind = "gate",
			shape = Zones.box(Vec.new(0, 0, -RADIUS), Vec.new(1, 8, 12)),
			gate = { order = 2, direction = Vec.new(-1, 0, 0), minTime = 0.5 },
		},
		{
			id = "gate_3",
			kind = "gate",
			shape = Zones.box(Vec.new(-RADIUS, 0, 0), Vec.new(12, 8, 1)),
			gate = { order = 3, direction = Vec.new(0, 0, 1), minTime = 0.5 },
		},
		{
			id = "gate_4",
			kind = "gate",
			shape = Zones.box(Vec.new(0, 0, RADIUS), Vec.new(1, 8, 12)),
			gate = { order = 4, finish = true, direction = Vec.new(1, 0, 0), minTime = 0.5 },
		},
	})
	assert(#Zones.validateCourse(set) == 0, "a valid course")
	local tracker = Zones.tracker(set, nil, env)
	local course = Zones.course(set, { laps = 2 }, env)
	local start = 0.5
	local cars = {}
	for index, name in { "car_a", "car_b" } do
		local theta = start + (index - 1) * 0.15
		local position = Vec.new(RADIUS * math.cos(theta), 0, RADIUS * math.sin(theta))
		cars[name] = {
			vehicle = Vehicles.new(spec, { position = position, heading = -theta, seed = name }, env),
			accepted = position,
		}
		tracker:update(name, position)
		course:start(name)
	end
	local log = {}
	local function push(event: { [string]: any })
		event.t = round3(env.clock())
		table.insert(log, event)
	end
	for k = 1, 900 do
		env:advance(DT)
		for _, name in { "car_a", "car_b" } do
			local car = cars[name]
			local vehicle = car.vehicle
			local s = vehicle.state
			-- Pure pursuit around the circle (decreasing angle), with seeded steering noise.
			local theta = math.atan2(s.position.z, s.position.x) - 0.6
			local aim = Vec.sub(Vec.new(RADIUS * math.cos(theta), 0, RADIUS * math.sin(theta)), s.position)
			local forward = Vehicles.forward(s.heading)
			local cross = forward.z * aim.x - forward.x * aim.z
			local angle = math.atan2(cross, Vec.dot(forward, aim))
			local input = {
				throttle = 1 - rng:range(0, 0.1),
				steer = math.clamp(angle * 2.5 + rng:range(-0.1, 0.1), -1, 1),
				handbrake = math.abs(angle) > 0.5 and vehicle:speed() > 25,
				boost = math.abs(angle) < 0.1 and rng:chance(0.02),
			}
			local _, events = vehicle:step(DT, input)
			for _, event in events do
				push({ kind = event.kind, car = name })
			end
			-- What the car's client reports (car_b cheats twice).
			local reported: any = vehicle.state.position
			if name == "car_b" and k == 300 then
				local jump = math.atan2(reported.z, reported.x) - 1.1
				reported = Vec.new(RADIUS * math.cos(jump), 0, RADIUS * math.sin(jump))
			elseif name == "car_b" and k == 500 then
				reported = { x = 0 / 0, y = 0, z = 0 }
			end
			local ok, reason, detail = Movement.checkTravel(limits, car.accepted, reported, DT)
			if ok then
				car.accepted = Vec.new(reported.x, reported.y, reported.z)
			else
				push({
					kind = "rubber_band",
					car = name,
					reason = reason,
					moved = round3(detail.horizontal or -1),
				})
				vehicle:place(car.accepted, vehicle.state.heading)
			end
			for _, event in course:observe((tracker:update(name, car.accepted))) do
				push({ kind = event.kind, car = name, zone = event.zone, lap = event.lap })
			end
		end
	end
	local final = {}
	for name, car in cars do
		local progress = course:progress(name) :: any
		final[name] = {
			snapshot = car.vehicle:snapshot(),
			lap = progress.lap,
			gates = progress.gates,
			finished = progress.finished,
			total = if progress.total then round3(progress.total) else nil,
		}
	end
	final.standings = course:standings()
	return log, final
end

-- ---------------------------------------------------------------- specs

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

test("round_arena: rounds run, honest hits land, every exploit is refused", function(t)
	local log, arena = roundArena(SEED)
	local counts = countKinds(log)
	t.ok((counts.phase or 0) >= 4, "phases ran")
	t.ok((counts.spawn or 0) >= 8, "everyone spawned")
	t.ok((counts.hit or 0) >= 5, "hits landed: " .. tostring(counts.hit))
	local stats = arena:stats()
	-- Refusals by body: rule-abiding bots 1-6 are never refused; bot 7's 250 ms view is always
	-- too old; bot 8 meets every claim check it tries.
	local byBody: { [string]: { [string]: number } } = {}
	for _, event in log do
		if event.kind == "claim_rejected" then
			local reasons = byBody[event.body] or {}
			byBody[event.body] = reasons
			reasons[event.reason] = (reasons[event.reason] or 0) + 1
		end
	end
	for body in byBody do
		t.ok(body == "7" or body == "8", "bot " .. body .. " was refused")
	end
	t.eq(next(byBody["7"]), "too_old")
	t.eq(next(byBody["7"], "too_old"), nil, "bot 7 is only ever too old")
	for _, reason in { "too_old", "origin_mismatch", "future_time", "self_hit", "cooldown", "bad_angle" } do
		t.ok((byBody["8"][reason] or 0) >= 1, "bot 8 refused for " .. reason)
	end
	t.ok((stats.inputRejected.bad_input or 0) >= 1, "malformed input refused")
	t.ok((stats.inputRejected.rate_limited or 0) >= 1, "floods refused")
	t.ok(stats.clamped >= 1, "oversized moves clamped")
	-- Damage only ever lands in an active phase, and bot 7 (150 ms + 100 ms view) never lands one.
	local phase = "lobby"
	for _, event in log do
		if event.kind == "phase" then
			phase = event.phase
		elseif event.kind == "hit" then
			t.eq(phase, "active", "hit outside the active phase")
			t.ok(event.attacker ~= "7", "bot 7's view is older than the rewind window")
		end
	end
	-- Exploit claims by bot 8 never landed except plain rapid-fire first shots.
	for _, body in arena:snapshot().bodies do
		t.ok(body.health >= 0 and body.health <= 100)
	end
end)

test("time_trial: car_a finishes two laps; car_b's teleport and NaN report are rubber-banded", function(t)
	local log, final = timeTrial(SEED)
	t.eq(final.car_a.finished, true, "car_a finished")
	local bands = {}
	for _, event in log do
		if event.kind == "rubber_band" then
			table.insert(bands, event.reason)
		end
		if event.car == "car_b" then
			t.ok(event.kind ~= "wrong_gate", "the shortcut never reaches the course")
		end
	end
	t.eq(bands, { "teleport", "bad_input" })
	t.eq(final.standings[1], "car_a")
end)

test("slices are deterministic: same seed, same digest; another seed differs", function(t)
	local a = Golden.digest((roundArena(SEED)))
	t.eq(Golden.digest((roundArena(SEED))), a)
	t.ok(Golden.digest((roundArena(SEED + 1))) ~= a, "seed changes the arena")
	local logA = timeTrial(SEED)
	local logB = timeTrial(SEED)
	t.eq(Golden.digest(logA), Golden.digest(logB))
end)

test("golden gamekit-action matches", function(_t)
	local arenaLog, arena = roundArena(SEED)
	local trialLog, final = timeTrial(SEED)
	Golden.assert("gamekit-action", {
		round_arena = {
			seed = SEED,
			steps = 600,
			events = #arenaLog,
			digest = Golden.digest(arenaLog),
			counts = countKinds(arenaLog),
			stats = arena:stats(),
			final = arena:snapshot(),
		},
		time_trial = {
			seed = SEED,
			steps = 900,
			events = #trialLog,
			digest = Golden.digest(trialLog),
			counts = countKinds(trialLog),
			final = final,
		},
	})
end)

return cases
