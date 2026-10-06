--!strict
-- G2 adapters in Lune: the pure mappings and Instance builders of the *Roblox modules with
-- @lune/roblox (T1 parts of T3 modules), and both G2 probe registries run against FakeEnv +
-- FakeWorld. A fake world proves wiring and probe logic only; checks that need the engine
-- (signals, physics, Animator playback, the place's AuthorityMode) are listed in ENGINE_ONLY
-- and must fail here for the stated reason, and every other check must pass. Studio runs of
-- the probes are the evidence for the modules' T3 status.
local AnimSet = require("../packages/GameKit/AnimSet")
local AnimSetRoblox = require("../packages/GameKit/AnimSetRoblox")
local AuthorityRoblox = require("../packages/GameKit/AuthorityRoblox")
local FakeEnv = require("./fakes/FakeEnv")
local FakeWorld = require("./fakes/FakeWorld")
local Hitbox = require("../packages/GameKit/Hitbox")
local HitboxRoblox = require("../packages/GameKit/HitboxRoblox")
local Interact = require("../packages/GameKit/Interact")
local InteractRoblox = require("../packages/GameKit/InteractRoblox")
local Movement = require("../packages/GameKit/Movement")
local MovementRoblox = require("../packages/GameKit/MovementRoblox")
local Probe = require("../packages/GameKit/Probe")
local RoundLoop = require("../packages/GameKit/RoundLoop")
local RoundLoopRoblox = require("../packages/GameKit/RoundLoopRoblox")
local VehicleRigRoblox = require("../packages/GameKit/VehicleRigRoblox")
local Vehicles = require("../packages/GameKit/Vehicles")
local Zones = require("../packages/GameKit/Zones")
local ZonesRoblox = require("../packages/GameKit/ZonesRoblox")
local lune = require("@lune/roblox")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local roblox = FakeWorld.roblox(lune)
local Instance, Vector3, CFrame, Enum = lune.Instance, lune.Vector3, lune.CFrame, lune.Enum

local function world(options: any?)
	local env = FakeEnv.new(options or { roblox = roblox })
	return FakeWorld.new(env, roblox), env
end

local function part(cframe: any, size: any, shape: string?): any
	local p = Instance.new("Part")
	p.CFrame = cframe
	p.Size = size
	if shape then
		p.Shape = Enum.PartType[shape]
	end
	return p
end

-- ---------------------------------------------------------------- AuthorityRoblox

test("AuthorityRoblox: attribute budget, changed-only writes, bad names and non-finite values", function(t)
	local folder = Instance.new("Folder")
	local values = {}
	for index = 1, 70 do
		values[string.format("A%02d", index)] = index
	end
	local written, problems = AuthorityRoblox.writeAttributes(folder, values)
	t.eq(written, 64)
	t.eq(#problems, 6)
	t.ok(string.find(problems[1], "A65", 1, true) ~= nil, "sorted order: A65 is the first refused")
	t.eq(AuthorityRoblox.count(folder), 64)
	t.eq((AuthorityRoblox.writeAttributes(folder, { A01 = 1 })), 0, "unchanged values are not rewritten")
	local _, bad = AuthorityRoblox.writeAttributes(folder, { ["x y"] = 1, RBXThing = 1, A02 = 0 / 0 })
	t.eq(#bad, 3)
	t.ok(AuthorityRoblox.validName("Round_Phase") and not AuthorityRoblox.validName(""))
	t.eq(AuthorityRoblox.mode(Instance.new("Workspace")), "Automatic")
	t.eq(AuthorityRoblox.mode({}), "unknown")
end)

test("AuthorityRoblox: bindStep prefers BindToSimulation and only falls back when asked", function(t)
	local w = world()
	local calls = 0
	local stop, how = AuthorityRoblox.bindStep(w.runService, function()
		calls += 1
	end)
	t.eq(how, "simulation")
	w:step(1 / 60, 3)
	t.eq(calls, 3);
	(stop :: any)()
	w:step(1 / 60, 3)
	t.eq(calls, 3, "unbound")
	local legacy = { PostSimulation = FakeWorld.signal() }
	local none, reason = AuthorityRoblox.bindStep(legacy, function() end)
	t.eq(none, nil)
	t.eq(reason, "no_bind_to_simulation")
	local fallback, kind = AuthorityRoblox.bindStep(legacy, function() end, { allowFallback = true })
	t.eq(kind, "fallback")
	t.eq(legacy.PostSimulation:Count(), 1);
	(fallback :: any)()
	t.eq(legacy.PostSimulation:Count(), 0)
end)

test("AuthorityRoblox: raw IAS build from data; bad specs are refused", function(t)
	local context, actions = AuthorityRoblox.buildActions({
		context = "test_context",
		priority = 2,
		sink = true,
		actions = {
			{
				name = "gameplay.jump",
				type = "Bool",
				bindings = { { keyCode = "Space" }, { keyCode = "ButtonA" } },
			},
			{
				name = "gameplay.move",
				type = "Direction2D",
				bindings = { { up = "W", down = "S", left = "A", right = "D" } },
			},
		},
	}, lune, nil)
	t.eq(context.ClassName, "InputContext")
	t.eq(context.Priority, 2)
	t.eq(context.Sink, true)
	t.eq(actions["gameplay.jump"].Type, Enum.InputActionType.Bool)
	local bindings = actions["gameplay.jump"]:GetChildren()
	t.eq(#bindings, 2)
	t.eq(actions["gameplay.move"]:GetChildren()[1].Up, Enum.KeyCode.W)
	-- Lune InputActions have no default state; set one, as the engine's input would.
	actions["gameplay.jump"].BoolState = false
	actions["gameplay.move"].Direction2DState = lune.Vector2.new(0.5, -1)
	t.eq(AuthorityRoblox.readAction(actions["gameplay.jump"]), false)
	t.eq(AuthorityRoblox.readAction(actions["gameplay.move"]), { x = 0.5, y = -1 })
	local problems = AuthorityRoblox.validateActions({
		context = "",
		actions = {
			{ name = "Jump", type = "Bool", bindings = {} },
			{ name = "a.b", type = "Wheel", bindings = { {} } },
		},
	})
	t.eq(#problems, 3, table.concat(problems, " | "))
	t.throws(function()
		AuthorityRoblox.buildActions({ context = "x", actions = {} } :: any, lune)
	end)
end)

-- ---------------------------------------------------------------- RoundLoopRoblox

test("RoundLoopRoblox: snapshot to attributes and back; start steps, joins and leaves", function(t)
	local w, env = world()
	local loop = RoundLoop.new(
		RoundLoop.define({ durations = { intermission = 1, active = 2, results = 1 }, minPlayers = 1 }),
		nil,
		env
	)
	local holder = Instance.new("Folder")
	w.players.list = { { UserId = 101 } }
	local phases = {}
	local stop, how = RoundLoopRoblox.start(loop, {
		holder = holder,
		players = w.players,
		runService = w.runService,
		onEvents = function(events)
			for _, event in events do
				table.insert(phases, event.phase)
			end
		end,
	}, env)
	t.eq(how, "simulation")
	t.eq(loop:players(), { 101 }, "present players join at start")
	w.players.PlayerAdded:Fire({ UserId = 102 })
	t.eq(#loop:players(), 2)
	w:step(1 / 60)
	t.eq(holder:GetAttribute("RoundPhase"), "intermission")
	t.eq(holder:GetAttribute("RoundTimeLeft"), 1)
	w:step(1 / 60, 90)
	local view = RoundLoopRoblox.read(holder)
	t.eq(view.phase, "active")
	t.eq(view.round, 1)
	t.eq(view.players, 2)
	t.eq(view.state, "fsm/1:round:active")
	t.eq(AuthorityRoblox.count(holder), 6)
	w.players.PlayerRemoving:Fire({ UserId = 101 })
	t.eq(loop:players(), { 102 })
	stop()
	t.eq(w:boundCount(), 0)
	t.eq(w.players.PlayerAdded:Count(), 0)
	t.eq(phases, { "intermission", "active" })
	local attrs = RoundLoopRoblox.attributes(
		{ phase = "lobby", timeLeft = -1, round = 0, players = 0, alive = 0, state = "s" },
		"Arena"
	)
	t.eq(attrs.ArenaPhase, "lobby")
	t.throws(function()
		RoundLoopRoblox.start(loop, { holder = holder, runService = {} }, env)
	end, "no BindToSimulation and no fallback")
end)

-- ---------------------------------------------------------------- HitboxRoblox

test("HitboxRoblox: shapeOf matches the pure box and sphere; frame round-trips", function(t)
	local p = part(CFrame.new(3, 4, 5) * CFrame.Angles(0, math.rad(30), 0), Vector3.new(2, 4, 6))
	local shape = HitboxRoblox.shapeOf(p)
	t.eq(shape.kind, "box")
	-- A point 2.9 studs along the part's local +Z (back) axis is inside; 3.1 is not.
	local back = Vector3.new(0, 0, 1)
	local inside = (p.CFrame * CFrame.new(back * 2.9)).Position
	local outside = (p.CFrame * CFrame.new(back * 3.1)).Position
	t.ok(Hitbox.contains(shape, { x = inside.X, y = inside.Y, z = inside.Z }))
	t.ok(not Hitbox.contains(shape, { x = outside.X, y = outside.Y, z = outside.Z }))
	local ball = HitboxRoblox.shapeOf(part(CFrame.new(0, 10, 0), Vector3.new(4, 4, 4), "Ball"))
	t.eq(ball.kind, "sphere")
	t.eq(ball.radius, 2)
	local cframe, size = HitboxRoblox.frame(shape, lune)
	t.near((cframe.Position - p.CFrame.Position).Magnitude, 0, 1e-5)
	t.near(cframe.LookVector:Dot(p.CFrame.LookVector), 1, 1e-5)
	t.near(size.Z, 6, 1e-6)
	local _, radius = HitboxRoblox.frame(Hitbox.sphere({ x = 0, y = 0, z = 0 }, 3), lune)
	t.eq(radius, 3)
	local capsuleFrame, capsuleSize =
		HitboxRoblox.frame(Hitbox.capsule({ x = 0, y = 0, z = 0 }, { x = 0, y = 4, z = 0 }, 1), lune)
	t.near(capsuleFrame.Position.Y, 2, 1e-6)
	t.near(capsuleSize.Y, 6, 1e-6)
end)

test(
	"HitboxRoblox: queries keep only exact overlaps; casters exclude what a projectile already hit",
	function(t)
		local w = world()
		local folder = Instance.new("Folder")
		local a = part(CFrame.new(0, 0, -10), Vector3.new(4, 4, 4))
		a.Name = "a"
		a.Parent = folder
		local b = part(CFrame.new(0, 0, -20), Vector3.new(4, 4, 4))
		b.Name = "b"
		b.Parent = folder
		local thin = part(CFrame.new(20, 0, -10) * CFrame.Angles(0, math.rad(45), 0), Vector3.new(6, 4, 1))
		thin.Name = "thin"
		thin.Parent = folder
		w.workspace:mount(folder)
		local overlap = roblox.OverlapParams.new()
		t.eq(
			#HitboxRoblox.query(
				w.workspace,
				Hitbox.sphere({ x = 22.4, y = 0, z = -7.6 }, 0.3),
				overlap,
				roblox
			),
			0
		)
		t.eq(
			HitboxRoblox.query(
				w.workspace,
				Hitbox.box({ x = 0, y = 0, z = -8 }, { x = 2, y = 2, z = 2 }),
				overlap,
				roblox
			)[1],
			a
		)
		local rp = roblox.RaycastParams.new()
		local cast = HitboxRoblox.caster(w.workspace, rp, roblox, {
			resolve = function(instance: any)
				return if instance.Name == "thin" then nil else instance.Name
			end,
		})
		local state = {}
		local first = cast({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = -30 }, 0, state)
		t.eq(first.target, "a")
		t.near(first.fraction, 8 / 30, 1e-9)
		t.eq(first.pierceable, true)
		local second = cast({ x = 0, y = 0, z = -9 }, { x = 0, y = 0, z = -21 }, 0, state)
		t.eq(second.target, "b", "a is excluded for this projectile")
		t.eq(#rp.FilterDescendantsInstances, 0, "the shared params are untouched")
		local other = cast({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = -30 }, 0, {})
		t.eq(other.target, "a", "another projectile still hits a")
		local wall = cast({ x = 20, y = 0, z = 0 }, { x = 0, y = 0, z = -30 }, 0, {})
		t.eq(wall.target, nil, "unresolved instances are world geometry")
		t.eq(wall.pierceable, false)
		t.eq(cast({ x = 0, y = 50, z = 0 }, { x = 0, y = 0, z = -30 }, 0, {}), nil)
		t.eq(
			#HitboxRoblox.sweepQuery(
				w.workspace,
				Hitbox.box({ x = -10, y = 0, z = -10 }, { x = 0.5, y = 1, z = 1 }),
				Hitbox.box({ x = 10, y = 0, z = -10 }, { x = 0.5, y = 1, z = 1 }),
				overlap,
				roblox
			),
			1
		)
	end
)

-- ---------------------------------------------------------------- ZonesRoblox

test("ZonesRoblox: parts become AABBs, prisms and spheres; tilted parts and bad ids are refused", function(t)
	local box = part(CFrame.new(0, 5, 0), Vector3.new(10, 4, 20))
	box.Name = "Spawn_Area"
	local turned = part(CFrame.new(50, 5, 0) * CFrame.Angles(0, math.rad(90), 0), Vector3.new(10, 4, 20))
	turned.Name = "turned"
	local angled = part(CFrame.new(100, 5, 0) * CFrame.Angles(0, math.rad(30), 0), Vector3.new(10, 4, 20))
	angled.Name = "angled"
	angled:SetAttribute("ZoneKind", "hazard")
	angled:SetAttribute("HazardAmount", 5)
	angled:SetAttribute("HazardInterval", 0.5)
	local ball = part(CFrame.new(0, 50, 0), Vector3.new(8, 8, 8), "Ball")
	ball.Name = "orb"
	ball:SetAttribute("ZoneKind", "gate")
	ball:SetAttribute("GateOrder", 1)
	ball:SetAttribute("GateFinish", true)
	ball:SetAttribute("GateDirectional", true)
	local tilted = part(CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(20), 0, 0), Vector3.new(4, 4, 4))
	tilted.Name = "tilted"
	local unnamed = part(CFrame.new(0, 0, 0), Vector3.new(4, 4, 4))
	unnamed.Name = "9lives"
	local defs, problems = ZonesRoblox.fromParts({ tilted, ball, angled, turned, box, unnamed })
	t.eq(#defs, 4)
	t.eq(#problems, 2, table.concat(problems, " | "))
	local byId = {}
	for _, def in defs do
		byId[def.id] = def
	end
	t.eq(byId.spawn_area.shape.kind, "aabb")
	t.eq(byId.spawn_area.shape.max.z, 10)
	t.near(byId.turned.shape.max.x, 60, 1e-4, "90 degrees swaps the X and Z extents")
	t.near(byId.turned.shape.max.z, 5, 1e-4)
	t.eq(byId.angled.shape.kind, "prism")
	t.eq(byId.angled.hazard.amount, 5)
	t.eq(byId.orb.shape.kind, "sphere")
	t.eq(byId.orb.gate.finish, true)
	t.near(byId.orb.gate.direction.z, -1, 1e-6)
	local set = Zones.define(defs :: any)
	-- The prism matches the rotated part: a point along its long axis is inside.
	local tip = (angled.CFrame * CFrame.new(0, 0, -9.5)).Position
	t.ok(Zones.contains(set.zones.angled.shape, { x = tip.X, y = tip.Y, z = tip.Z }))
	local past = (angled.CFrame * CFrame.new(0, 0, -10.5)).Position
	t.ok(not Zones.contains(set.zones.angled.shape, { x = past.X, y = past.Y, z = past.Z }))
end)

test("ZonesRoblox: start feeds character positions to the tracker and the course", function(t)
	local w, env = world()
	local set = Zones.define({
		{
			id = "goal",
			shape = Zones.box({ x = 0, y = 0, z = -50 }, { x = 20, y = 10, z = 2 }),
			kind = "gate",
			gate = { order = 1, finish = true },
		},
	})
	local tracker = Zones.tracker(set, nil, env)
	local course = Zones.course(set, nil, env)
	course:start(7)
	local root = part(CFrame.new(0, 0, 0), Vector3.new(2, 2, 1))
	root.Name = "HumanoidRootPart"
	local character = Instance.new("Model")
	root.Parent = character
	w.players.list = { { UserId = 7, Character = character } }
	local log = {}
	local stop = ZonesRoblox.start(tracker, {
		players = w.players,
		runService = w.runService,
		course = course,
		onEvents = function(events, courseEvents)
			for _, event in events do
				table.insert(log, event.kind)
			end
			for _, event in courseEvents do
				table.insert(log, event.kind)
			end
		end,
	}, env)
	w:step(1 / 60)
	root.CFrame = CFrame.new(0, 0, -100)
	w:step(1 / 60)
	t.eq(log, { "enter", "exit", "sector", "lap", "finish" }, "a swept pass through the finish gate")
	w.players.PlayerRemoving:Fire({ UserId = 7 })
	t.eq(tracker:count(), 0)
	stop()
end)

-- ---------------------------------------------------------------- VehicleRigRoblox

test("VehicleRigRoblox: the constraint car and its drive mapping", function(t)
	local spec = Vehicles.define({
		maxSpeed = 30,
		acceleration = 20,
		brake = 40,
		steerRate = 2,
		grip = 8,
		rig = { wheelRadius = 1.5 },
	})
	local plan = Vehicles.rigPlan(spec)
	local rig = VehicleRigRoblox.build(plan, lune, { name = "TestCar" })
	t.eq(rig.model.Name, "TestCar")
	t.eq(rig.model.PrimaryPart, rig.chassis)
	t.eq(rig.seat.MaxSpeed, 30)
	local motors, servos, springs = 0, 0, 0
	for name, entry in rig.wheels do
		t.eq(entry.wheel.Shape, Enum.PartType.Cylinder, name)
		t.eq(entry.wheel.Size.Y, 3)
		motors += if entry.axle.ActuatorType == Enum.ActuatorType.Motor then 1 else 0
		servos += if entry.steer then 1 else 0
		springs += if entry.spring.Stiffness == 4000 then 1 else 0
		t.ok(entry.slider.LimitsEnabled)
	end
	t.eq({ motors, servos, springs }, { 2, 2, 4 })
	VehicleRigRoblox.drive(rig, plan, 0.5, -1)
	t.near(rig.wheels.rear_left.axle.AngularVelocity, -0.5 * 20, 1e-4)
	t.near(rig.wheels.front_right.steer.TargetAngle, -30, 1e-4)
	VehicleRigRoblox.drive(rig, plan, 0 / 0, 9)
	t.eq(rig.wheels.rear_left.axle.AngularVelocity, 0, "NaN throttle is 0")
	t.near(rig.wheels.front_left.steer.TargetAngle, 30, 1e-4, "steer clamps to 1")
	rig.seat.ThrottleFloat = 1
	t.eq(VehicleRigRoblox.seatInput(rig.seat).throttle, 1)
end)

-- ---------------------------------------------------------------- InteractRoblox, AnimSetRoblox, MovementRoblox

test("InteractRoblox: prompt mapping and the line-of-sight hook", function(t)
	local set = Interact.define({
		{
			id = "door_a",
			position = { x = 0, y = 0, z = 0 },
			holdDuration = 1.5,
			maxDistance = 8,
			lineOfSight = false,
		},
	})
	local prompt = InteractRoblox.prompt(set.targets.door_a, lune, { action = "Open", object = "Door" })
	t.eq(prompt.Name, "door_a")
	t.eq(prompt.HoldDuration, 1.5)
	t.eq(prompt.MaxActivationDistance, 8)
	t.eq(prompt.RequiresLineOfSight, false)
	t.eq(prompt.ActionText, "Open")
	t.throws(function()
		InteractRoblox.prompt({ id = "kill_a", kind = "touch" } :: any, lune)
	end)
	local w = world()
	local wall = part(CFrame.new(0, 0, -5), Vector3.new(10, 10, 1))
	w.workspace:mount(wall)
	local los = InteractRoblox.lineOfSight(w.workspace, roblox, {})
	t.eq(los({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = -10 }, "x"), false)
	t.eq(los({ x = 20, y = 0, z = 0 }, { x = 20, y = 0, z = -10 }, "x"), true)
	local character = Instance.new("Model")
	local root = part(CFrame.new(1, 2, 3), Vector3.new(2, 2, 1))
	root.Name = "HumanoidRootPart"
	root.Parent = character
	t.eq(InteractRoblox.rootPosition({ Character = character }), { x = 1, y = 2, z = 3 })
	t.eq(InteractRoblox.rootPosition({ Character = nil }), nil)
end)

test("AnimSetRoblox: id hooks build Animations; preview refuses published places; priorities map", function(t)
	local hook = AnimSetRoblox.animationHook({ idle = "rbxassetid://0" }, lune)
	local a = hook({ name = "idle" }, nil)
	t.eq(a.ClassName, "Animation")
	t.eq(a.AnimationId, "rbxassetid://0")
	t.eq(hook({ name = "idle" }, nil), a, "cached")
	t.throws(function()
		hook({ name = "walk" }, nil)
	end, "no id for a clip is an error, not a silent blank")
	local published = FakeEnv.new({ roblox = roblox, place = { isStudio = true, gameId = 5, placeId = 6 } })
	t.throws(function()
		AnimSetRoblox.previewHook({}, published)
	end)
	local w, env = world()
	local preview = AnimSetRoblox.previewHook({ idle = Instance.new("KeyframeSequence") }, env)
	local temp = preview({ name = "idle" }, nil)
	t.eq(temp.AnimationId, "rbxtemp://fake/1")
	t.ok(w ~= nil)
	local track: any = {}
	AnimSetRoblox.configure(lune)(track, "Action2", true)
	t.eq(track.Priority, Enum.AnimationPriority.Action2)
	t.eq(track.Looped, true)
	local humanoid = Instance.new("Humanoid")
	local animator = AnimSetRoblox.animator(humanoid, lune)
	t.eq(animator.ClassName, "Animator")
	t.eq(AnimSetRoblox.animator(humanoid, lune), animator, "found, not duplicated")
	t.eq(#AnimSet.SLOTS, 17)
end)

test("MovementRoblox: IAS actions map to input and pressed edges", function(t)
	local _, actions = AuthorityRoblox.buildActions({
		context = "move_test",
		actions = {
			{ name = "gameplay.move", type = "Direction2D", bindings = { { up = "W" } } },
			{ name = "gameplay.sprint", type = "Bool", bindings = { { keyCode = "LeftShift" } } },
			{ name = "gameplay.jump", type = "Bool", bindings = { { keyCode = "Space" } } },
		},
	}, lune)
	local env = FakeEnv.new()
	local controller = Movement.new(Movement.define({ sprint = { multiplier = 2 } }), nil, env)
	local last = {}
	actions["gameplay.move"].Direction2DState = lune.Vector2.new(0, 1)
	actions["gameplay.sprint"].BoolState = true
	actions["gameplay.jump"].BoolState = true
	t.eq(MovementRoblox.readInput(controller, actions, last), { "jump" })
	t.eq(MovementRoblox.readInput(controller, actions, last), {}, "held, not pressed again")
	local out = controller:step()
	t.eq(out.walkSpeed, 32, "forward on the stick (-Z) with sprint held")
	actions["gameplay.jump"].BoolState = false
	MovementRoblox.readInput(controller, actions, last)
	actions["gameplay.jump"].BoolState = true
	t.eq(MovementRoblox.readInput(controller, actions, last), { "jump" })
end)

-- ---------------------------------------------------------------- probe registries in Lune

-- Checks that need the engine and fail against FakeWorld, with the reason.
local ENGINE_ONLY = {
	authority_mode_server = "the fake world reports Automatic, like a place the owner has not switched",
	bool_reads_false = "Lune InputActions have no default BoolState",
	direction_reads_zero = "Lune InputActions have no default Direction2DState",
	pressed_signal = "Lune InputActions have no Pressed signal",
	prompt_signals = "Lune ProximityPrompts have no signals",
	drives_forward = "no physics in Lune",
	sprint_walkspeed = "Lune Humanoids have no FloorMaterial, so the step raises before applying",
	error = "a probe raised on an engine-only member (Animator:LoadAnimation, Humanoid.FloorMaterial)",
}

-- The probe loader. Modules are required up front: a first require inside a probe thread
-- (resumed by FakeEnv, not by Lune's scheduler) would park that thread forever.
local KITS = {
	["GameKit/AnimSet"] = AnimSet,
	["GameKit/AnimSetRoblox"] = AnimSetRoblox,
	["GameKit/AuthorityRoblox"] = AuthorityRoblox,
	["GameKit/Env"] = require("../packages/GameKit/Env"),
	["GameKit/Hitbox"] = Hitbox,
	["GameKit/HitboxRoblox"] = HitboxRoblox,
	["GameKit/Interact"] = Interact,
	["GameKit/InteractRoblox"] = InteractRoblox,
	["GameKit/Movement"] = Movement,
	["GameKit/MovementRoblox"] = MovementRoblox,
	["GameKit/Projectile"] = require("../packages/GameKit/Projectile"),
	["GameKit/RoundLoop"] = RoundLoop,
	["GameKit/RoundLoopRoblox"] = RoundLoopRoblox,
	["GameKit/VehicleRigRoblox"] = VehicleRigRoblox,
	["GameKit/Vehicles"] = Vehicles,
	["GameKit/Zones"] = Zones,
	["GameKit/ZonesRoblox"] = ZonesRoblox,
}

local function runRegistry(registry: any): ({ string }, any, any)
	local w, env = world()
	local lines = {}
	local summary = nil
	env.spawn(function()
		summary = Probe.runAll(registry, {
			env = env,
			kit = function(path: string)
				return assert(KITS[path], "probe asked for an unlisted kit module " .. path)
			end,
			emit = function(line: string)
				table.insert(lines, line)
			end,
		})
	end)
	local guard = 0
	while summary == nil and guard < 2000 do
		w:step(1 / 60)
		env:flush()
		guard += 1
	end
	return lines, summary, w
end

local function failedChecks(lines: { string }): { [string]: { string } }
	local failed = {}
	for _, line in lines do
		local probe = string.match(line, '"probe":"([%w_]+)"')
		local check = string.match(line, '"check":"([%w_]+)"')
		if probe and check and string.find(line, '"ok":false', 1, true) then
			failed[probe] = failed[probe] or {}
			table.insert(failed[probe], check)
		end
	end
	return failed
end

test("authority_probes: every check passes against fakes except the engine-only ones", function(t)
	local lines, summary = runRegistry(require("../fixtures/kits/shared/authority_probes"))
	t.ok(summary ~= nil, "the registry finished")
	t.eq(summary.probes, {
		"authority_attribute_budget",
		"authority_input_actions",
		"authority_mode",
		"authority_simulation_bind",
	})
	t.ok(string.find(lines[#lines], "ENGINE_DONE ", 1, true) == 1)
	local failed = failedChecks(lines)
	t.eq(failed, {
		authority_input_actions = { "bool_reads_false", "direction_reads_zero", "pressed_signal" },
		authority_mode = { "authority_mode_server" },
	}, table.concat(lines, "\n"))
	for _, checks in failed do
		for _, check in checks do
			t.ok(ENGINE_ONLY[check] ~= nil, check)
		end
	end
	t.eq(summary.checks - summary.failed, summary.passed)
	t.ok(summary.passed >= 14, "passed " .. summary.passed)
end)

test("action_probes: every check passes against fakes except the engine-only ones", function(t)
	local lines, summary, w = runRegistry(require("../fixtures/kits/server/action_probes"))
	t.ok(
		summary ~= nil,
		"the registry finished:\n" .. table.concat(lines, "\n") .. "\n" .. table.concat(w.errors, "\n")
	)
	t.eq(#summary.probes, 8)
	local failed = failedChecks(lines)
	t.eq(failed, {
		action_animset_clip = { "error" },
		action_interact_prompt = { "prompt_signals" },
		action_movement_humanoid = { "sprint_walkspeed", "error" },
		action_vehicle_drive = { "drives_forward" },
	}, table.concat(lines, "\n"))
	for _, checks in failed do
		for _, check in checks do
			t.ok(ENGINE_ONLY[check] ~= nil, check)
		end
	end
	local errors = {}
	for _, line in lines do
		if string.find(line, '"check":"error"', 1, true) then
			table.insert(errors, line)
		end
	end
	t.ok(string.find(errors[1], "LoadAnimation", 1, true) ~= nil, errors[1])
	t.ok(string.find(errors[2], "FloorMaterial", 1, true) ~= nil, errors[2])
	t.eq(#w.mounted, 0, "probes unmount what they stage, also when they raise")
	t.eq(w:boundCount(), 0, "and unbind their simulation steps")
end)

return cases
