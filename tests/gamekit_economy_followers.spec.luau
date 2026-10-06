--!strict
-- GameKit/Followers: formation offsets, stable slots, step with speed, catch-up and teleport,
-- yaw conventions, validation; FollowersRoblox wiring against tests/fakes/FakeEconomyEngine
-- (constraints, apply, read-back, BindToSimulation and its PreSimulation fallback).
local Followers = require("../packages/GameKit/Followers")
local FollowersRoblox = require("../packages/GameKit/FollowersRoblox")
local FakeEconomyEngine = require("./fakes/FakeEconomyEngine")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function near(t: any, a: any, b: any, what: string?)
	t.near(a.x, b.x, 1e-9, what)
	t.near(a.y, b.y, 1e-9, what)
	t.near(a.z, b.z, 1e-9, what)
end

local ORIGIN = { x = 0, y = 0, z = 0 }

test("line and grid offsets depend on the slot alone", function(t)
	local line = Followers.new({ spacing = 2, distance = 3, height = 1 })
	near(t, line:offset(1), { x = 0, y = 1, z = 3 })
	near(t, line:offset(4), { x = 0, y = 1, z = 9 })
	local grid = Followers.new({ formation = "grid", spacing = 2, distance = 3, columns = 3 })
	near(t, grid:offset(1), { x = -2, y = 0, z = 3 })
	near(t, grid:offset(2), { x = 0, y = 0, z = 3 })
	near(t, grid:offset(3), { x = 2, y = 0, z = 3 })
	near(t, grid:offset(4), { x = -2, y = 0, z = 5 })
end)

test("arc and ring spread evenly and grow to keep spacing", function(t)
	local arc = Followers.new({ formation = "arc", spacing = 1, distance = 10, arc = 90 })
	near(t, arc:offset(1, 1), { x = 0, y = 0, z = 10 }, "one follower sits straight behind")
	local left, right = arc:offset(1, 3), arc:offset(3, 3)
	t.near(left.x, -right.x, 1e-9)
	t.near(left.z, right.z, 1e-9)
	t.near(math.sqrt(left.x ^ 2 + left.z ^ 2), 10, 1e-9)
	local ring = Followers.new({ formation = "ring", spacing = 4, distance = 2 })
	local count = 8
	local radius = 4 * count / (2 * math.pi)
	for slot = 1, count do
		local o = ring:offset(slot, count)
		t.near(math.sqrt(o.x ^ 2 + o.z ^ 2), radius, 1e-9, "radius grows past distance")
	end
	near(t, ring:offset(1, count), { x = 0, y = 0, z = radius })
end)

test("slots are stable: removal leaves a gap that the next add reuses", function(t)
	local group = Followers.new()
	t.eq({ group:add("a") }, { 1, nil })
	t.eq({ group:add("b") }, { 2, nil })
	t.eq({ group:add("c") }, { 3, nil })
	t.ok(group:remove("b"))
	t.eq(group:ids(), { "a", "c" })
	t.eq(group:slotOf("c"), 3, "c keeps its slot")
	t.eq({ group:add("d") }, { 2, nil })
	t.eq({ group:add("d") }, { nil, "duplicate" })
	t.eq({ group:add("") }, { nil, "invalid_id" })
	t.ok(not group:remove("zzz"))
	group:remove("a")
	group:compact()
	t.eq({ group:slotOf("d"), group:slotOf("c") }, { 1, 2 })
	local small = Followers.new({ maxFollowers = 1 })
	small:add("x")
	t.eq({ small:add("y") }, { nil, "full" })
end)

test("targets turn with the leader's yaw and lookVector (yaw 0 faces -Z)", function(t)
	local group = Followers.new({ distance = 5 })
	group:add("a")
	near(t, group:targets({ position = ORIGIN, yaw = 0 }).a, { x = 0, y = 0, z = 5 }, "behind is +Z")
	near(
		t,
		group:targets({ position = ORIGIN, yaw = 90 }).a,
		{ x = 5, y = 0, z = 0 },
		"facing -X, behind is +X"
	)
	near(
		t,
		group:targets({ position = ORIGIN, lookVector = { x = -1, y = 0, z = 0 } }).a,
		{ x = 5, y = 0, z = 0 }
	)
	t.near(Followers.leaderYaw({ position = ORIGIN, lookVector = { x = 0, y = 0, z = 1 } }), 180, 1e-9)
	t.eq(Followers.leaderYaw({ position = ORIGIN }), 0)
	t.throws(function()
		group:targets({ position = { x = 0 / 0, y = 0, z = 0 } } :: any)
	end)
end)

test("step moves at speed, catches up when far and teleports beyond the threshold", function(t)
	local group = Followers.new({
		distance = 0.000001,
		speed = 10,
		catchUpDistance = 20,
		catchUpMultiplier = 3,
		teleportDistance = 100,
		maxStep = 1,
	})
	group:add("a", { x = 0, y = 0, z = 10 })
	local first = group:step(0.5, { position = ORIGIN, yaw = 0 })[1]
	t.near(first.position.z, 5, 1e-5, "10 studs/s for 0.5 s")
	t.eq(first.teleported, false)
	t.eq(first.catchingUp, false)
	t.near(first.yaw, 0, 1e-9, "moving toward -Z faces yaw 0")
	group:place("a", { x = 0, y = 0, z = 50 })
	local far = group:step(0.5, { position = ORIGIN, yaw = 0 })[1]
	t.ok(far.catchingUp)
	t.near(far.position.z, 35, 1e-5, "3x speed beyond catchUpDistance")
	local clamped = group:step(5, { position = ORIGIN, yaw = 0 })[1]
	t.near(clamped.position.z, 5, 1e-5, "dt is clamped to maxStep (30 studs at 3x)")
	local done = group:step(1, { position = ORIGIN, yaw = 45 })[1]
	t.ok(done.settled)
	t.eq(done.yaw, 45, "a settled follower faces the leader's way")
	local jump = group:step(0.1, { position = { x = 500, y = 0, z = 0 }, yaw = 0 })[1]
	t.ok(jump.teleported, "beyond teleportDistance snaps")
	near(t, jump.position, jump.target)
	local fresh = Followers.new()
	fresh:add("new")
	t.ok(fresh:step(0, { position = ORIGIN })[1].teleported, "first placement snaps to the slot")
	t.throws(function()
		fresh:step(-1, { position = ORIGIN })
	end)
end)

test("invalid options are refused", function(t)
	local problems = Followers.validate({
		formation = "blob",
		spacing = 0,
		speed = -1,
		catchUpDistance = 50,
		teleportDistance = 40,
		columns = 1.5,
		arc = 400,
		settleDistance = -1,
		colour = "red",
	})
	for _, needle in
		{
			"formation must be line, grid, arc or ring",
			"spacing must be a finite number > 0",
			"speed must be a finite number > 0",
			"catchUpDistance must be below teleportDistance",
			"columns must be an integer >= 1",
			"arc must be in (0, 360] degrees",
			"settleDistance must be a finite number >= 0",
			'unknown option "colour"',
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	t.throws(function()
		Followers.new({ formation = "blob" } :: any)
	end)
end)

test("FollowersRoblox maps CFrames, attaches constraints and applies frames", function(t)
	local engine = FakeEconomyEngine.new()
	local env = FakeEconomyEngine.env(engine)
	local r = env.roblox
	local leader = FollowersRoblox.leaderFrom(r.CFrame.new(1, 2, 3) * r.CFrame.Angles(0, math.rad(90), 0))
	t.eq(leader.position, { x = 1, y = 2, z = 3 })
	t.near(Followers.leaderYaw(leader), 90, 1e-9)
	local part = r.Instance.new("Part")
	part.Position = r.Vector3.new(0, 0, 20)
	local handle = FollowersRoblox.attach(part, { responsiveness = 30 }, env)
	t.eq(handle.align.Mode.Name, "OneAttachment")
	t.eq(handle.align.Responsiveness, 30)
	t.ok(handle.orient.Attachment0 == handle.attachment)
	t.ok(handle.attachment.Parent == part)
	local core = Followers.new({ distance = 5, catchUpDistance = 50 })
	core:add("a", { x = 0, y = 0, z = 20 })
	local frames = FollowersRoblox.stepOnce(core, { a = handle }, 0.25, r.CFrame.new(0, 0, 0), env)
	t.near(handle.align.Position.Z, 16, 1e-9, "16 studs/s for 0.25 s toward z = 5")
	t.eq(frames[1].teleported, false)
	-- Physics pushed the part elsewhere: read-back moves the core before the next step.
	part.Position = r.Vector3.new(0, 0, 30)
	FollowersRoblox.stepOnce(core, { a = handle }, 0.25, r.CFrame.new(0, 0, 0), env)
	t.near(handle.align.Position.Z, 26, 1e-9)
	FollowersRoblox.stepOnce(core, { a = handle }, 0.1, r.CFrame.new(1000, 0, 0), env)
	t.near(part.Position.X, 1000, 1e-9, "teleported followers are pivoted")
	t.throws(function()
		FollowersRoblox.attach(part, nil, {})
	end)
end)

test("start binds to simulation, falls back to PreSimulation with a report, and stops", function(t)
	for _, bind in { true, false } do
		local engine = FakeEconomyEngine.new({ bindToSimulation = bind })
		local env = FakeEconomyEngine.env(engine)
		local r = env.roblox
		local part = r.Instance.new("Part")
		part.Position = r.Vector3.new(30, 0, 0)
		local core = Followers.new({ distance = 4 })
		core:add("a", { x = 30, y = 0, z = 0 })
		local handles = { a = FollowersRoblox.attach(part, nil, env) }
		local stop = FollowersRoblox.start(core, handles, function(): any
			return r.CFrame.new(0, 0, 0)
		end, env)
		FakeEconomyEngine.run(engine, env, 4)
		t.ok((part.Position - r.Vector3.new(0, 0, 4)).Magnitude < 0.5, "the part reaches its slot")
		t.eq(contains(env.reports, "BindToSimulation unavailable"), not bind)
		stop()
		part.Position = r.Vector3.new(50, 0, 0)
		local before = handles.a.align.Position
		FakeEconomyEngine.run(engine, env, 0.5)
		t.ok(handles.a.align.Position == before, "stop() ends stepping")
	end
end)

return cases
