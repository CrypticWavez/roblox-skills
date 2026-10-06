--!strict
-- G2 Projectile: definition checks, closed-form parity (many small steps land where one big
-- step lands), gapless swept segments, drag, range and lifetime truncation, pierce and
-- dedupe, the simulation's ids and cap, and the two-phase server validation of
-- client-predicted shots (bad claims, rewind window, teleported muzzle, impossible distance,
-- off-trajectory points, target mismatch).
local Hitbox = require("../packages/GameKit/Hitbox")
local Projectile = require("../packages/GameKit/Projectile")
local Vec = require("../packages/SceneKit/Vec")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function v(x: number, y: number, z: number)
	return { x = x, y = y, z = z }
end

local function has(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local NAN = 0 / 0

-- A fake world: targets { id, shape, pierceable? }; the cast honours state.hitSet like the
-- adapter's filter does unless `sticky` is set (then the core's own dedupe must cope).
local function world(targets: { any }, sticky: boolean?): (any, { any })
	local calls = {}
	local function cast(origin: any, delta: any, radius: number, state: any): any
		table.insert(calls, { origin = origin, delta = delta })
		local best = nil
		for _, target in targets do
			if not sticky and state.hitSet[target.id] then
				continue
			end
			local hit, fraction, point = Hitbox.segment(target.shape, origin, delta, radius)
			if hit and (best == nil or (fraction :: number) < best.fraction) then
				best = {
					fraction = fraction,
					position = point,
					target = target.id,
					pierceable = target.pierceable,
				}
			end
		end
		return best
	end
	return cast, calls
end

local function nearVec(t: any, actual: any, expected: any, tol: number, message: string)
	t.near(actual.x, expected.x, tol, message .. ".x")
	t.near(actual.y, expected.y, tol, message .. ".y")
	t.near(actual.z, expected.z, tol, message .. ".z")
end

-- ---------------------------------------------------------------- definitions

test("define: defaults, number gravity and every problem listed", function(t)
	local spec = Projectile.define({ speed = 100, maxRange = 50 })
	t.eq(spec.gravity.y, -Projectile.DEFAULT_GRAVITY, "default gravity is Workspace.Gravity downward")
	t.eq(spec.drag, 0)
	t.eq(spec.pierce, 0)
	t.eq(spec.maxLifetime, 2, "lifetime covers maxRange four times at muzzle speed")
	t.ok(table.isfrozen(spec) and table.isfrozen(spec.gravity))
	t.eq(Projectile.define({ speed = 1, maxRange = 1, gravity = 10 }).gravity.y, -10)
	t.eq(Projectile.define({ speed = 1, maxRange = 1, gravity = v(1, 2, 3) }).gravity.x, 1)

	local problems = Projectile.validate({
		speed = 0,
		maxRange = NAN,
		drag = -1,
		radius = 300,
		pierce = 1.5,
		gravity = "down",
		maxLifetime = 0,
	})
	t.eq(#problems, 7, table.concat(problems, " | "))
	t.ok(has(problems, "speed") and has(problems, "maxRange") and has(problems, "Spherecast"))
	t.eq(Projectile.validate("x")[1], "definition must be a table")
	t.ok(#Projectile.validate({ speed = Projectile.MAX_SPEED + 1, maxRange = 1 }) == 1)
	local ok, err = pcall(Projectile.define, { speed = -1, maxRange = 0 } :: any)
	t.ok(
		not ok
			and string.find(tostring(err), "speed", 1, true)
			and string.find(tostring(err), "maxRange", 1, true)
	)
end)

-- ---------------------------------------------------------------- closed form

test("closed form: 60 steps of 1/60 s land where one 1 s step lands, with and without drag", function(t)
	for _, drag in { 0, 0.8 } do
		local spec = Projectile.define({ speed = 50, drag = drag, maxRange = 10000, maxLifetime = 10 })
		local small = Projectile.launch(spec, v(0, 10, 0), v(1, 1, 0.25))
		local big = Projectile.launch(spec, v(0, 10, 0), v(1, 1, 0.25))
		for _ = 1, 60 do
			Projectile.step(spec, small, 1 / 60)
		end
		Projectile.step(spec, big, 1)
		nearVec(t, small.position, big.position, 1e-9, "position drag=" .. drag)
		nearVec(t, small.velocity, big.velocity, 1e-9, "velocity drag=" .. drag)
		t.near(small.age, 1, 1e-12)
		local analytic = Projectile.positionAt(spec, v(0, 10, 0), Vec.scale(Vec.unit(v(1, 1, 0.25)), 50), 1)
		nearVec(t, big.position, analytic, 1e-12, "analytic")
		-- Range is the sum of chords: finer steps measure more of the arc, and approach the
		-- sampled path length.
		t.ok(small.travelled >= big.travelled)
		local path = Projectile.pathLength(spec, v(0, 10, 0), Vec.scale(Vec.unit(v(1, 1, 0.25)), 50), 1, 60)
		t.near(small.travelled, path, 1e-9, "chord sum equals 60-sample path length")
	end
end)

test("closed form: no-drag motion is p0 + v t + g t^2 / 2 and drag reaches terminal velocity", function(t)
	local spec = Projectile.define({ speed = 10, maxRange = 100, gravity = 20 })
	local p = Projectile.positionAt(spec, v(1, 2, 3), v(10, 0, 0), 0.5)
	nearVec(t, p, v(6, 2 - 2.5, 3), 1e-12, "kinematics")
	local dragged = Projectile.define({ speed = 100, maxRange = 1000, drag = 2 })
	local terminal = Projectile.velocityAt(dragged, v(100, 0, 0), 10)
	nearVec(t, terminal, v(0, -Projectile.DEFAULT_GRAVITY / 2, 0), 1e-5, "terminal velocity g/k")
	-- Drag slows the projectile: the same 1 s covers less ground.
	local free = Projectile.define({ speed = 100, maxRange = 1000, gravity = 0 })
	local slowed = Projectile.define({ speed = 100, maxRange = 1000, gravity = 0, drag = 1 })
	local a = Projectile.positionAt(free, v(0, 0, 0), v(100, 0, 0), 1)
	local b = Projectile.positionAt(slowed, v(0, 0, 0), v(100, 0, 0), 1)
	t.near(a.x, 100, 1e-12)
	t.near(b.x, 100 * (1 - math.exp(-1)), 1e-9)
end)

test("step: every swept segment starts exactly where the previous one ended", function(t)
	local spec = Projectile.define({ speed = 80, drag = 0.4, maxRange = 1000, maxLifetime = 5 })
	local cast, calls = world({})
	local state = Projectile.launch(spec, v(0, 5, 0), v(1, 0.5, 0))
	local dts = { 1 / 60, 1 / 30, 0.05, 1 / 60, 0.2, 0.001 }
	for _, dt in dts do
		Projectile.step(spec, state, dt, cast)
	end
	t.eq(#calls, #dts)
	nearVec(t, calls[1].origin, v(0, 5, 0), 0, "first segment starts at the muzzle")
	for index = 2, #calls do
		local previousEnd = Vec.add(calls[index - 1].origin, calls[index - 1].delta)
		nearVec(t, calls[index].origin, previousEnd, 1e-12, "segment " .. index)
	end
	local lastEnd = Vec.add(calls[#calls].origin, calls[#calls].delta)
	nearVec(t, state.position, lastEnd, 1e-12, "state ends on the last segment")
end)

test("step: range truncates mid-step at exactly maxRange; lifetime truncates at maxLifetime", function(t)
	local spec = Projectile.define({ speed = 100, gravity = 0, maxRange = 50 })
	local state = Projectile.launch(spec, v(0, 0, 0), v(1, 0, 0), { id = 7, owner = "p1" })
	local events
	for _ = 1, 4 do
		_, events = Projectile.step(spec, state, 0.15)
	end
	t.ok(not state.alive)
	t.eq(state.reason, "range")
	t.near(state.position.x, 50, 1e-9)
	t.near(state.travelled, 50, 1e-9)
	t.near(state.age, 0.5, 1e-9, "age stops where the range ran out")
	t.eq(#events, 1)
	t.eq(events[1].kind, "expired")
	t.eq(events[1].reason, "range")
	t.eq(events[1].id, 7)
	t.eq(events[1].owner, "p1")
	-- A dead projectile does not move or emit again.
	local _, again = Projectile.step(spec, state, 1)
	t.eq(#again, 0)
	t.near(state.position.x, 50, 1e-9)

	local short = Projectile.define({ speed = 100, gravity = 0, maxRange = 1000, maxLifetime = 0.25 })
	local s2 = Projectile.launch(short, v(0, 0, 0), v(0, 0, -1))
	for _ = 1, 3 do
		Projectile.step(short, s2, 0.1)
	end
	t.eq(s2.reason, "lifetime")
	t.near(s2.age, 0.25, 1e-12)
	t.near(s2.position.z, -25, 1e-9)
end)

test("step: hits stop the projectile at the contact with the right age", function(t)
	local spec = Projectile.define({ speed = 100, gravity = 0, maxRange = 1000 })
	local cast = world({ { id = "wall", shape = Hitbox.box(v(30, 0, 0), v(2, 20, 20)) } })
	local state = Projectile.launch(spec, v(0, 0, 0), v(1, 0, 0), { id = 1, owner = "p1" })
	local all = {}
	for _ = 1, 5 do
		local _, events = Projectile.step(spec, state, 0.1, cast)
		for _, event in events do
			table.insert(all, event)
		end
	end
	t.eq(#all, 1)
	t.eq(all[1].kind, "hit")
	t.eq(all[1].target, "wall")
	t.eq(all[1].pierced, false)
	t.near(all[1].position.x, 29, 1e-9)
	t.near(all[1].age, 0.29, 1e-9)
	t.ok(not state.alive and state.reason == "hit")
	t.near(state.position.x, 29, 1e-9)
	t.near(state.age, 0.29, 1e-9)
	t.near(state.travelled, 29, 1e-9)
end)

test("step: pierce passes through pierceable targets once each and stops at the budget or a wall", function(t)
	local spec = Projectile.define({ speed = 100, gravity = 0, maxRange = 1000, pierce = 1 })
	local targets = {
		{ id = "a", shape = Hitbox.sphere(v(10, 0, 0), 1) },
		{ id = "b", shape = Hitbox.sphere(v(14, 0, 0), 1) },
		{ id = "c", shape = Hitbox.sphere(v(18, 0, 0), 1) },
	}
	local cast = world(targets)
	local state = Projectile.launch(spec, v(0, 0, 0), v(1, 0, 0))
	local _, events = Projectile.step(spec, state, 1, cast)
	t.eq(#events, 2, "a is pierced, b stops it (budget 1)")
	t.eq(events[1].target, "a")
	t.eq(events[1].pierced, true)
	t.eq(events[2].target, "b")
	t.eq(events[2].pierced, false)
	t.eq(state.reason, "hit")
	t.eq(state.hits, { "a", "b" })
	t.near(state.position.x, 13, 1e-9)

	-- A non-pierceable target stops it even with budget left.
	local wide = Projectile.define({ speed = 100, gravity = 0, maxRange = 1000, pierce = 5 })
	local walled = world({
		{ id = "a", shape = Hitbox.sphere(v(10, 0, 0), 1) },
		{ id = "wall", shape = Hitbox.box(v(14, 0, 0), v(1, 10, 10)), pierceable = false },
		{ id = "c", shape = Hitbox.sphere(v(18, 0, 0), 1) },
	})
	local s2 = Projectile.launch(wide, v(0, 0, 0), v(1, 0, 0))
	local _, e2 = Projectile.step(wide, s2, 1, walled)
	t.eq(#e2, 2)
	t.eq(e2[2].target, "wall")
	t.eq(s2.pierced, 1)

	-- A target spanning several steps is hit once per flight, even when the cast ignores
	-- state.hitSet and keeps returning it (the core skips repeats a bounded number of times).
	local thick = world({ { id = "slab", shape = Hitbox.box(v(10, 0, 0), v(6, 10, 10)) } }, true)
	local s3 = Projectile.launch(wide, v(0, 0, 0), v(1, 0, 0))
	local hits = 0
	for _ = 1, 20 do
		local _, e3 = Projectile.step(wide, s3, 0.01, thick)
		hits += #e3
	end
	t.eq(hits, 1)
	t.ok(s3.alive and s3.pierced == 1)
end)

test("step: malformed cast results, bad dt and bad launches raise (server code, not input)", function(t)
	local spec = Projectile.define({ speed = 100, gravity = 0, maxRange = 1000 })
	local state = Projectile.launch(spec, v(0, 0, 0), v(1, 0, 0))
	local function badFraction(): any
		return { fraction = 2, position = v(0, 0, 0) }
	end
	local function nanPosition(): any
		return { fraction = 0.5, position = v(NAN, 0, 0) }
	end
	t.throws(function()
		Projectile.step(spec, state, 0.1, badFraction)
	end)
	t.throws(function()
		Projectile.step(spec, Projectile.launch(spec, v(0, 0, 0), v(1, 0, 0)), 0.1, nanPosition)
	end)
	t.throws(function()
		Projectile.step(spec, Projectile.launch(spec, v(0, 0, 0), v(1, 0, 0)), -0.1)
	end)
	t.throws(function()
		Projectile.step(spec, Projectile.launch(spec, v(0, 0, 0), v(1, 0, 0)), NAN)
	end)
	t.throws(function()
		Projectile.launch(spec, v(0, 0, 0), v(0, 0, 0))
	end)
	t.throws(function()
		Projectile.launch(spec, v(NAN, 0, 0), v(1, 0, 0))
	end)
	local inherited = Projectile.launch(spec, v(0, 0, 0), v(1, 0, 0), { inherit = v(0, 0, 25) })
	nearVec(t, inherited.velocity, v(100, 0, 25), 0, "inherited velocity adds to the muzzle velocity")
end)

-- ---------------------------------------------------------------- simulation

test("simulation: stable ids, cap, bad input, id-ordered events and removal", function(t)
	local spec = Projectile.define({ speed = 100, gravity = 0, maxRange = 1000, maxLifetime = 1 })
	local sim = Projectile.simulation(spec, { maxActive = 2 })
	local a = sim:fire(v(0, 0, 0), v(1, 0, 0), { owner = "p1" })
	local b = sim:fire(v(0, 0, 0), v(0, 0, 1), { owner = "p2" })
	t.eq(a, 1)
	t.eq(b, 2)
	local none, reason = sim:fire(v(0, 0, 0), v(1, 0, 0))
	t.eq(none, nil)
	t.eq(reason, "full")
	t.eq(sim:count(), 2)
	t.eq(sim:remove(1), true)
	t.eq(sim:remove(1), false)
	t.eq(select(2, sim:fire(v(NAN, 0, 0), v(1, 0, 0))), "bad_input")
	t.eq(select(2, sim:fire(v(0, 0, 0), v(0, 0, 0))), "bad_input")
	t.eq(select(2, sim:fire(v(0, 0, 0), "up" :: any)), "bad_input")
	t.eq(select(2, sim:fire(v(0, 0, 0), v(1, 0, 0), { inherit = v(0, math.huge, 0) })), "bad_input")
	t.eq(sim:fire(v(0, 0, 0), v(-1, 0, 0), { owner = "p3" }), 3, "ids are never reused")
	local events = sim:step(2)
	t.eq(#events, 2)
	t.eq(events[1].id, 2)
	t.eq(events[2].id, 3)
	t.eq(events[2].owner, "p3")
	t.eq(sim:count(), 0)
	t.eq(sim:get(2), nil)

	t.throws(function()
		Projectile.simulation({ speed = 1 } :: any)
	end)
	t.throws(function()
		Projectile.simulation(spec, { maxActive = 0 })
	end)
end)

-- ---------------------------------------------------------------- server validation

local SHOT_SPEC = Projectile.define({ speed = 100, gravity = 0, maxRange = 50, maxLifetime = 2 })

test(
	"validateFire: accepts a fresh shot from the rewound muzzle; refuses bad, future, old and teleported",
	function(t)
		local shooter = Hitbox.capsule(v(0, 0, 0), v(0, 4, 0), 1)
		local claim = { origin = v(0.5, 3, 0), direction = v(1, 0, 0), time = 9.9 }
		local ok, reason, detail =
			Projectile.validateFire(SHOT_SPEC, claim, { now = 10, shooterPose = shooter })
		t.ok(ok, reason)
		t.near(detail.originError :: number, 0, 1e-9)

		t.eq(select(2, Projectile.validateFire(SHOT_SPEC, nil :: any, { now = 10 })), "bad_claim")
		t.eq(
			select(
				2,
				Projectile.validateFire(
					SHOT_SPEC,
					{ origin = v(0, 0, 0), direction = v(0, 0, 0), time = 10 },
					{ now = 10 }
				)
			),
			"bad_claim"
		)
		t.eq(
			select(
				2,
				Projectile.validateFire(
					SHOT_SPEC,
					{ origin = v(0, 0, 0), direction = v(1, 0, 0), time = NAN },
					{ now = 10 }
				)
			),
			"bad_claim"
		)
		t.eq(
			select(
				2,
				Projectile.validateFire(
					SHOT_SPEC,
					{ origin = v(0, 0, 0), direction = v(1, 0, 0), time = 10.5 },
					{ now = 10 }
				)
			),
			"future_time"
		)
		-- Rewind edge: 0.2 s accepted, beyond refused, and a larger window option is clamped to 0.2.
		t.ok(
			Projectile.validateFire(
				SHOT_SPEC,
				{ origin = v(0, 0, 0), direction = v(1, 0, 0), time = 9.8 },
				{ now = 10 }
			)
		)
		t.eq(
			select(
				2,
				Projectile.validateFire(
					SHOT_SPEC,
					{ origin = v(0, 0, 0), direction = v(1, 0, 0), time = 9.75 },
					{ now = 10, window = 1 }
				)
			),
			"too_old"
		)
		-- Teleport exploit: the muzzle is 30 studs from where the shooter was.
		local ok2, reason2, detail2 = Projectile.validateFire(
			SHOT_SPEC,
			{ origin = v(30, 3, 0), direction = v(1, 0, 0), time = 9.95 },
			{ now = 10, shooterPose = shooter }
		)
		t.ok(not ok2)
		t.eq(reason2, "origin_mismatch")
		t.ok((detail2.originError :: number) > 28)
	end
)

test("validateShot: on-trajectory points pass within the time tolerance; impossible ones fail", function(t)
	local base = { origin = v(0, 0, 0), direction = v(1, 0, 0), fireTime = 5 }
	local function claim(point: any, hitTime: number): any
		return {
			origin = base.origin,
			direction = base.direction,
			fireTime = base.fireTime,
			hitTime = hitTime,
			hitPoint = point,
		}
	end
	local ok, reason, detail = Projectile.validateShot(SHOT_SPEC, claim(v(40, 0, 0), 5.45))
	t.ok(ok, reason)
	t.near(detail.flightTime :: number, 0.4, 1e-6, "search finds the true flight time")
	t.near(detail.pathLength :: number, 40, 1e-6)

	t.eq(select(2, Projectile.validateShot(SHOT_SPEC, claim(v(40, 5, 0), 5.4))), "off_trajectory")
	-- Impossible distance: the point is on the line but past maxRange (50 + tolerance).
	local farOk, farReason, farDetail = Projectile.validateShot(SHOT_SPEC, claim(v(80, 0, 0), 5.8))
	t.ok(not farOk)
	t.eq(farReason, "out_of_range")
	t.near(farDetail.pathLength :: number, 80, 1e-6)
	-- Claimed time too far from where the point is on the path (0.4 s vs 0.8 s).
	t.eq(select(2, Projectile.validateShot(SHOT_SPEC, claim(v(40, 0, 0), 5.8))), "off_trajectory")
	t.eq(select(2, Projectile.validateShot(SHOT_SPEC, claim(v(0, 0, 0), 4.5))), "bad_timing")
	t.eq(select(2, Projectile.validateShot(SHOT_SPEC, claim(v(0, 0, 0), 7.5))), "too_late")
	t.eq(select(2, Projectile.validateShot(SHOT_SPEC, claim(v(NAN, 0, 0), 5.4))), "bad_claim")
	t.eq(select(2, Projectile.validateShot(SHOT_SPEC, "shot" :: any)), "bad_claim")
	-- A tighter tolerance turns a near miss into a refusal.
	t.ok(Projectile.validateShot(SHOT_SPEC, claim(v(40, 1.5, 0), 5.4)))
	t.eq(
		select(
			2,
			Projectile.validateShot(SHOT_SPEC, claim(v(40, 1.5, 0), 5.4), { now = 0, positionTolerance = 1 })
		),
		"off_trajectory"
	)
end)

test(
	"validateHit: a simulated ballistic hit is accepted; stale, future and mismatched reports fail",
	function(t)
		local spec = Projectile.define({ speed = 120, drag = 0.3, maxRange = 300, radius = 0.5 })
		local target = Hitbox.box(v(60, 0, 0), v(2, 40, 6))
		local cast = world({ { id = "target", shape = target } })
		local sim = Projectile.simulation(spec)
		local origin, direction = v(0, 5, 0), v(1, 0.2, 0)
		sim:fire(origin, direction, { owner = "p1" })
		local hit = nil
		for _ = 1, 120 do
			for _, event in sim:step(1 / 60, cast) do
				if event.kind == "hit" then
					hit = event
				end
			end
			if hit then
				break
			end
		end
		assert(hit, "the simulated projectile reaches the target")
		t.eq(hit.target, "target")
		local fireTime = 20
		local shot = { origin = origin, direction = direction, time = fireTime }
		local report = { hitPoint = hit.position, time = fireTime + hit.age, target = "target" }
		local ok, reason, detail =
			Projectile.validateHit(spec, shot, report, { now = report.time + 0.1, targetPose = target })
		t.ok(ok, reason)
		t.ok((detail.error :: number) < 0.01, "the server recomputes the same trajectory")

		t.eq(
			select(
				2,
				Projectile.validateHit(spec, shot, report, { now = report.time + 0.3, targetPose = target })
			),
			"too_old"
		)
		t.eq(
			select(
				2,
				Projectile.validateHit(spec, shot, report, { now = report.time - 0.1, targetPose = target })
			),
			"future_time"
		)
		t.eq(
			select(
				2,
				Projectile.validateHit(
					spec,
					shot,
					report,
					{ now = report.time, targetPose = Hitbox.translate(target, v(15, 0, 0)) }
				)
			),
			"target_mismatch"
		)
		t.eq(select(2, Projectile.validateHit(spec, shot, { time = NAN } :: any, { now = 21 })), "bad_claim")
		-- A forged report claiming the target was hit through the floor of the trajectory.
		local forged = { hitPoint = Vec.add(hit.position, v(0, -6, 0)), time = report.time }
		t.eq(select(2, Projectile.validateHit(spec, shot, forged, { now = report.time })), "off_trajectory")
	end
)

return cases
