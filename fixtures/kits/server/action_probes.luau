--!strict
-- G2 probe registry (prefix action_), server side. Each probe builds a small neutral setup far
-- above the place's content (y = 800, a convention), runs one adapter against the engine,
-- checks what only the engine can show, and removes what it built.
--   action_round_replication  RoundLoopRoblox steps from BindToSimulation and replicates
--                             phase, round and fsm/1 state as attributes.
--   action_hitbox_shapecast   HitboxRoblox: box/sphere bounds queries with the exact Hitbox
--                             narrow phase, Raycast/Spherecast/Blockcast casters, Shapecast,
--                             swept queries.
--   action_authority_projectile  a Projectile simulation stepped from BindToSimulation hits a
--                             wall through HitboxRoblox.caster, and the server accepts it.
--   action_interact_prompt    InteractRoblox builds a ProximityPrompt; Interact times a hold;
--                             the line-of-sight hook sees a blocking wall.
--   action_animset_clip       AnimSet plays a local procedural KeyframeSequence through a
--                             Studio-only temporary id (no upload) and receives its marker.
--   action_vehicle_drive      VehicleRigRoblox builds the constraint car on a plate and drives
--                             it forward (-Z).
--   action_zones_enter_exit   ZonesRoblox reads a kill-zone part; the tracker sees enter, kill
--                             and exit from a scripted path stepped in the simulation.
--   action_movement_humanoid  MovementRoblox sets WalkSpeed (sprint) and the jump launch speed
--                             on a minimal Humanoid.
-- No requires: modules come from ctx.kit. Every probe refuses to run outside an unpublished
-- Studio place (Env.assertDiagnostic). In Lune the registry runs against FakeEnv + FakeWorld
-- (tests/gamekit_action_adapters.spec.luau); engine-only checks are listed there.
local probes = {}

local function waitFor(ctx: any, predicate: () -> boolean, seconds: number): boolean
	local env = ctx.env
	local started = env.clock()
	while not predicate() do
		if env.clock() - started > seconds then
			return false
		end
		env.wait(1 / 30)
	end
	return true
end

-- A folder in Workspace for the probe's parts (fake worlds mount instead of parenting).
local function stage(ctx: any, name: string): any
	ctx.kit("GameKit/Env").assertDiagnostic(ctx.env, ctx.probe)
	local folder = ctx.env.roblox.Instance.new("Folder")
	folder.Name = "SETUP_ONLY_" .. name
	local workspace = ctx.env.services.Workspace
	if typeof(workspace) == "Instance" then
		folder.Parent = workspace
	else
		workspace:mount(folder)
	end
	return folder
end

local function unstage(ctx: any, folder: any)
	local workspace = ctx.env.services.Workspace
	if typeof(workspace) ~= "Instance" then
		workspace:unmount(folder)
	end
	folder:Destroy()
end

-- Wraps a probe body: stages its folder, runs it, then always runs its deferred cleanups (in
-- reverse) and removes the folder, so a probe that raises leaves nothing bound or built. The
-- error is re-raised for Probe.runAll to record as check "error".
local function staged(name: string, body: (ctx: any, folder: any, defer: (fn: () -> ()) -> ()) -> ())
	return function(ctx: any)
		local folder = stage(ctx, name)
		local cleanups = {}
		local ok, err = pcall(body, ctx, folder, function(fn: () -> ())
			table.insert(cleanups, fn)
		end)
		for index = #cleanups, 1, -1 do
			pcall(cleanups[index])
		end
		unstage(ctx, folder)
		if not ok then
			error(err, 0)
		end
	end
end

local function block(roblox: any, folder: any, name: string, cframe: any, size: any, anchored: boolean?): any
	local part = roblox.Instance.new("Part")
	part.Name = name
	part.Anchored = anchored ~= false
	part.CFrame = cframe
	part.Size = size
	part.Parent = folder
	return part
end

local function origin(roblox: any): any
	return roblox.CFrame.new(0, 800, 0)
end

function probes.action_round_replication(ctx: any)
	local RoundLoop = ctx.kit("GameKit/RoundLoop")
	local RoundLoopRoblox = ctx.kit("GameKit/RoundLoopRoblox")
	local AuthorityRoblox = ctx.kit("GameKit/AuthorityRoblox")
	local env, roblox = ctx.env, ctx.env.roblox
	ctx.kit("GameKit/Env").assertDiagnostic(env, ctx.probe)
	local loop = RoundLoop.new(
		RoundLoop.define({ phases = { "lobby", "active" }, durations = { active = 0.5 }, minPlayers = 1 }),
		nil,
		env
	)
	loop:join("probe_player")
	local holder = roblox.Instance.new("Folder")
	holder.Name = "SETUP_ONLY_RoundProbe"
	holder.Parent = env.services.ReplicatedStorage
	local stop, how =
		RoundLoopRoblox.start(loop, { holder = holder, runService = env.services.RunService }, env)
	ctx.check("bound_to_simulation", how == "simulation", { how = how })
	ctx.check(
		"phase_replicated",
		waitFor(ctx, function()
			return holder:GetAttribute("RoundPhase") == "active"
		end, 2),
		{ phase = holder:GetAttribute("RoundPhase") }
	)
	ctx.check(
		"rounds_advance",
		waitFor(ctx, function()
			return (holder:GetAttribute("RoundNumber") or 0) >= 2
		end, 3),
		{ round = holder:GetAttribute("RoundNumber") }
	)
	local snapshot = RoundLoopRoblox.read(holder)
	ctx.check(
		"fsm_state_attribute",
		type(snapshot.state) == "string" and string.sub(snapshot.state, 1, 12) == "fsm/1:round:",
		snapshot
	)
	ctx.check(
		"attribute_budget",
		AuthorityRoblox.count(holder) <= AuthorityRoblox.MAX_ATTRIBUTES,
		{ count = AuthorityRoblox.count(holder) }
	)
	stop()
	holder:Destroy()
end

probes.action_hitbox_shapecast = staged("HitboxProbe", function(ctx: any, folder: any)
	local Hitbox = ctx.kit("GameKit/Hitbox")
	local HitboxRoblox = ctx.kit("GameKit/HitboxRoblox")
	local env, roblox = ctx.env, ctx.env.roblox
	local base = origin(roblox)
	local Vector3, CFrame = roblox.Vector3, roblox.CFrame
	local target = block(roblox, folder, "Target", base * CFrame.new(0, 0, -10), Vector3.new(4, 4, 4))
	block(
		roblox,
		folder,
		"Rotated",
		base * CFrame.new(20, 0, -10) * CFrame.Angles(0, math.rad(45), 0),
		Vector3.new(6, 4, 1)
	)
	local workspace = env.services.Workspace
	local overlap = roblox.OverlapParams.new()
	overlap.FilterType = roblox.Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = { folder }
	local p = base.Position
	local boxHits = HitboxRoblox.query(
		workspace,
		Hitbox.box({ x = p.X + 1, y = p.Y, z = p.Z - 8 }, { x = 2, y = 2, z = 2 }),
		overlap,
		roblox
	)
	ctx.check("box_query_hits", #boxHits == 1 and boxHits[1] == target, { hits = #boxHits })
	-- Inside the rotated part's bounding box, outside the part: the narrow phase drops it.
	local cornerHits = HitboxRoblox.query(
		workspace,
		Hitbox.sphere({ x = p.X + 22.4, y = p.Y, z = p.Z - 7.6 }, 0.3),
		overlap,
		roblox
	)
	ctx.check("narrow_phase_drops_bounds_only", #cornerHits == 0, { hits = #cornerHits })
	local raycast = roblox.RaycastParams.new()
	raycast.FilterType = roblox.Enum.RaycastFilterType.Include
	raycast.FilterDescendantsInstances = { folder }
	local cast = HitboxRoblox.caster(workspace, raycast, roblox, {
		resolve = function(instance: any)
			return instance.Name
		end,
	})
	local from = { x = p.X, y = p.Y, z = p.Z }
	local ray = cast(from, { x = 0, y = 0, z = -20 }, 0, {})
	ctx.check(
		"raycast_hits_face",
		ray ~= nil and ray.target == "Target" and math.abs(ray.fraction - 0.4) < 0.01,
		ray and { fraction = ray.fraction }
	)
	local sphere = cast(from, { x = 0, y = 0, z = -20 }, 1, {})
	ctx.check(
		"spherecast_hits_earlier",
		sphere ~= nil and math.abs(sphere.fraction - 0.35) < 0.01,
		sphere and { fraction = sphere.fraction }
	)
	-- A 1-stud block (front face 0.5 ahead of its centre) meets the face at z = -8 after 7.5.
	local blockCast = HitboxRoblox.caster(workspace, raycast, roblox, { block = { x = 1, y = 1, z = 1 } })
	local okBlock, block = pcall(blockCast, from, { x = 0, y = 0, z = -20 }, 0, {})
	ctx.check(
		"blockcast_hits_face",
		okBlock and block ~= nil and math.abs(block.fraction - 0.375) < 0.01,
		if okBlock then block and { fraction = block.fraction } else tostring(block)
	)
	-- The same through Shapecast with an unparented 2-stud ball: contact after 7.
	local ball = roblox.Instance.new("Part")
	ball.Shape = roblox.Enum.PartType.Ball
	ball.Size = Vector3.new(2, 2, 2)
	ball.Anchored = true
	ball.CFrame = base
	local okShape, shaped =
		pcall(HitboxRoblox.shapecast, workspace, ball, { x = 0, y = 0, z = -20 }, raycast, roblox)
	ball:Destroy()
	ctx.check(
		"shapecast_hits_face",
		okShape and shaped ~= nil and math.abs(shaped.fraction - 0.35) < 0.01,
		if okShape then shaped and { fraction = shaped.fraction } else tostring(shaped)
	)
	local swept = HitboxRoblox.sweepQuery(
		workspace,
		Hitbox.box({ x = p.X - 10, y = p.Y, z = p.Z - 10 }, { x = 0.5, y = 1, z = 1 }),
		Hitbox.box({ x = p.X + 10, y = p.Y, z = p.Z - 10 }, { x = 0.5, y = 1, z = 1 }),
		overlap,
		roblox
	)
	ctx.check("swept_query_no_tunnelling", table.find(swept, target) ~= nil, { hits = #swept })
end)

probes.action_authority_projectile = staged("ProjectileProbe", function(ctx: any, folder: any, defer: any)
	local Projectile = ctx.kit("GameKit/Projectile")
	local HitboxRoblox = ctx.kit("GameKit/HitboxRoblox")
	local AuthorityRoblox = ctx.kit("GameKit/AuthorityRoblox")
	local env, roblox = ctx.env, ctx.env.roblox
	local base = origin(roblox)
	block(roblox, folder, "Wall", base * roblox.CFrame.new(0, 0, -30), roblox.Vector3.new(10, 10, 1))
	local raycast = roblox.RaycastParams.new()
	raycast.FilterType = roblox.Enum.RaycastFilterType.Include
	raycast.FilterDescendantsInstances = { folder }
	local cast = HitboxRoblox.caster(env.services.Workspace, raycast, roblox, {
		resolve = function(instance: any)
			return instance.Name
		end,
	})
	local spec = Projectile.define({ speed = 100, gravity = 0, maxRange = 100 })
	local sim = Projectile.simulation(spec, nil, env)
	local p = base.Position
	local muzzle = { x = p.X, y = p.Y, z = p.Z }
	sim:fire(muzzle, { x = 0, y = 0, z = -1 }, { owner = "probe" })
	local events = {}
	local stop, how = AuthorityRoblox.bindStep(env.services.RunService, function(dt: number)
		for _, event in sim:step(dt, cast) do
			table.insert(events, event)
		end
	end)
	ctx.check("bound_to_simulation", how == "simulation", { how = how })
	if stop == nil then
		return
	end
	defer(stop)
	waitFor(ctx, function()
		return #events > 0
	end, 2)
	local hit = events[1]
	ctx.check(
		"hit_wall",
		hit ~= nil and hit.kind == "hit" and hit.target == "Wall",
		hit and { kind = hit.kind, target = hit.target }
	)
	if hit and hit.kind == "hit" then
		ctx.check("hit_on_face", math.abs(hit.position.z - (p.Z - 29.5)) < 0.1, { z = hit.position.z })
		local ok, reason = Projectile.validateShot(spec, {
			origin = muzzle,
			direction = { x = 0, y = 0, z = -1 },
			fireTime = 0,
			hitTime = hit.age,
			hitPoint = hit.position,
		})
		ctx.check("server_accepts_own_shot", ok, { reason = reason })
	end
end)

probes.action_interact_prompt = staged("InteractProbe", function(ctx: any, folder: any)
	local Interact = ctx.kit("GameKit/Interact")
	local InteractRoblox = ctx.kit("GameKit/InteractRoblox")
	local env, roblox = ctx.env, ctx.env.roblox
	local base = origin(roblox)
	local p = base.Position
	local set = Interact.define({
		{ id = "probe_prompt", position = { x = p.X, y = p.Y, z = p.Z }, holdDuration = 0.5 },
	})
	local anchor = block(roblox, folder, "PromptAnchor", base, roblox.Vector3.new(2, 2, 2))
	local prompt = InteractRoblox.prompt(set.targets.probe_prompt, roblox, { action = "Use" })
	prompt.Parent = anchor
	ctx.check(
		"prompt_properties",
		prompt.HoldDuration == 0.5
			and prompt.MaxActivationDistance == 10
			and prompt.RequiresLineOfSight == true
	)
	local hasSignals = pcall(function()
		return prompt.PromptButtonHoldBegan, prompt.PromptButtonHoldEnded, prompt.Triggered
	end)
	ctx.check(
		"prompt_signals",
		hasSignals,
		"PromptButtonHoldBegan, PromptButtonHoldEnded, Triggered (engine only)"
	)
	local server = Interact.server(set, nil, env)
	local near = { x = p.X + 3, y = p.Y, z = p.Z }
	ctx.check("hold_begins", (server:begin(1, "probe_prompt", near)))
	env.wait(0.6)
	local ok, reason = server:finish(1, "probe_prompt", near)
	ctx.check("hold_finishes_on_server_clock", ok, { reason = reason })
	block(roblox, folder, "Blocker", base * roblox.CFrame.new(0, 0, -6), roblox.Vector3.new(10, 10, 1))
	local los = InteractRoblox.lineOfSight(env.services.Workspace, roblox, {})
	ctx.check(
		"line_of_sight_blocked",
		los({ x = p.X, y = p.Y, z = p.Z - 12 }, { x = p.X, y = p.Y, z = p.Z - 2 }, "probe_prompt") == false
	)
	ctx.check(
		"line_of_sight_clear",
		los({ x = p.X + 20, y = p.Y, z = p.Z - 12 }, { x = p.X + 20, y = p.Y, z = p.Z - 2 }, "probe_prompt")
			== true
	)
end)

probes.action_animset_clip = staged("AnimSetProbe", function(ctx: any, folder: any, defer: any)
	local AnimSet = ctx.kit("GameKit/AnimSet")
	local AnimSetRoblox = ctx.kit("GameKit/AnimSetRoblox")
	local env, roblox = ctx.env, ctx.env.roblox
	local Instance = roblox.Instance
	-- A local, procedural clip: three keyframes of the root pose and a marker at 0.5 s.
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "probe_idle"
	sequence.Loop = true
	for _, time in { 0, 0.5, 1 } do
		local keyframe = Instance.new("Keyframe")
		keyframe.Time = time
		local pose = Instance.new("Pose")
		pose.Name = "HumanoidRootPart"
		pose.Parent = keyframe
		if time == 0.5 then
			local marker = Instance.new("KeyframeMarker")
			marker.Name = "probe_mark"
			marker.Parent = keyframe
		end
		keyframe.Parent = sequence
	end
	local rig = Instance.new("Model")
	rig.Name = "ProbeRig"
	local root = block(roblox, rig, "HumanoidRootPart", origin(roblox), roblox.Vector3.new(2, 2, 1))
	rig.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = rig
	rig.Parent = folder
	local set = AnimSet.define({
		clips = {
			schema = "clips/1",
			asset = "probe_rig",
			rig = "custom",
			fps = 30,
			files = {},
			clips = {
				{
					name = "probe_idle",
					slot = "idle",
					start = 0,
					["end"] = 30,
					loop = true,
					root_motion = false,
					markers = { { name = "probe_mark", frame = 15 } },
				},
			},
		},
		slots = { idle = { markers = { "probe_mark" } } },
		states = { idle = "idle" },
	})
	local animator = AnimSetRoblox.animator(humanoid, roblox)
	local player = AnimSet.player(set, animator, {
		animation = AnimSetRoblox.previewHook({ probe_idle = sequence }, env),
		configure = AnimSetRoblox.configure(roblox),
	}, env)
	defer(function()
		player:destroy()
	end)
	local marks = 0
	player:onMarker("probe_mark", function()
		marks += 1
	end)
	local ok, reason = player:setState("idle")
	ctx.check("plays_temporary_id", ok, { reason = reason })
	ctx.check(
		"marker_reached",
		waitFor(ctx, function()
			return marks > 0
		end, 3),
		{ marks = marks }
	)
	local playing = animator:GetPlayingAnimationTracks()
	ctx.check("track_cap", #playing >= 1 and #playing <= AnimSet.MAX_PLAYING, { playing = #playing })
end)

probes.action_vehicle_drive = staged("VehicleProbe", function(ctx: any, folder: any, defer: any)
	local Vehicles = ctx.kit("GameKit/Vehicles")
	local VehicleRigRoblox = ctx.kit("GameKit/VehicleRigRoblox")
	local AuthorityRoblox = ctx.kit("GameKit/AuthorityRoblox")
	local env, roblox = ctx.env, ctx.env.roblox
	local base = origin(roblox)
	block(roblox, folder, "Plate", base * roblox.CFrame.new(0, -5, 0), roblox.Vector3.new(400, 1, 400))
	local plan = Vehicles.rigPlan(
		Vehicles.define({ maxSpeed = 30, acceleration = 20, brake = 40, steerRate = 2, grip = 8 })
	)
	local rig = VehicleRigRoblox.build(plan, roblox, { cframe = base, parent = folder })
	local counts = { motor = 0, servo = 0, spring = 0, slider = 0 }
	for _, entry in rig.wheels do
		counts.motor += if entry.axle.ActuatorType.Name == "Motor" then 1 else 0
		counts.servo += if entry.steer then 1 else 0
		counts.spring += if entry.spring then 1 else 0
		counts.slider += if entry.slider then 1 else 0
	end
	ctx.check(
		"rig_built",
		counts.motor == 2 and counts.servo == 2 and counts.spring == 4 and counts.slider == 4,
		counts
	)
	ctx.check("seat_configured", rig.seat.ClassName == "VehicleSeat" and rig.seat.MaxSpeed == 30)
	env.wait(1) -- settle on the plate
	local start = rig.chassis.CFrame.Position
	local stop, how = AuthorityRoblox.bindStep(env.services.RunService, function()
		VehicleRigRoblox.drive(rig, plan, 1, 0)
	end)
	ctx.check("bound_to_simulation", how == "simulation", { how = how })
	if stop then
		defer(stop)
	end
	env.wait(2)
	local moved = rig.chassis.CFrame.Position - start
	ctx.check("drives_forward", moved.Z < -1, { dx = moved.X, dy = moved.Y, dz = moved.Z })
end)

probes.action_zones_enter_exit = staged("ZonesProbe", function(ctx: any, folder: any, defer: any)
	local Zones = ctx.kit("GameKit/Zones")
	local ZonesRoblox = ctx.kit("GameKit/ZonesRoblox")
	local AuthorityRoblox = ctx.kit("GameKit/AuthorityRoblox")
	local env, roblox = ctx.env, ctx.env.roblox
	local base = origin(roblox)
	local part = block(
		roblox,
		folder,
		"ProbeKill",
		base * roblox.CFrame.Angles(0, math.rad(30), 0),
		roblox.Vector3.new(10, 10, 10)
	)
	part:SetAttribute("ZoneId", "probe_kill")
	part:SetAttribute("ZoneKind", "kill")
	local defs, problems = ZonesRoblox.fromParts({ part })
	ctx.check("part_reads_as_zone", #problems == 0 and #defs == 1 and defs[1].shape.kind == "prism", problems)
	if #defs == 0 then
		return
	end
	local tracker = Zones.tracker(Zones.define(defs), nil, env)
	local p = base.Position
	local path = { -20, -2, 0, 3, 20 }
	local index = 0
	local kinds = {}
	local stop, how = AuthorityRoblox.bindStep(env.services.RunService, function()
		index += 1
		local x = path[index]
		if x then
			for _, event in tracker:update("probe_body", { x = p.X + x, y = p.Y, z = p.Z }) do
				table.insert(kinds, event.kind)
			end
		end
	end)
	ctx.check("bound_to_simulation", how == "simulation", { how = how })
	if stop then
		defer(stop)
	end
	waitFor(ctx, function()
		return index >= #path
	end, 2)
	ctx.check("enter_kill_exit", table.concat(kinds, ",") == "enter,kill,exit", kinds)
	ctx.check("positions_read", type(ZonesRoblox.positions(env.services.Players)) == "table")
end)

probes.action_movement_humanoid = staged("MovementProbe", function(ctx: any, folder: any, defer: any)
	local Movement = ctx.kit("GameKit/Movement")
	local MovementRoblox = ctx.kit("GameKit/MovementRoblox")
	local env, roblox = ctx.env, ctx.env.roblox
	local base = origin(roblox)
	block(roblox, folder, "Plate", base * roblox.CFrame.new(0, -5, 0), roblox.Vector3.new(100, 1, 100))
	local character = roblox.Instance.new("Model")
	character.Name = "ProbeCharacter"
	local root = block(roblox, character, "HumanoidRootPart", base, roblox.Vector3.new(2, 2, 1), false)
	character.PrimaryPart = root
	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.Parent = character
	character.Parent = folder
	local controller = Movement.new(Movement.define({ sprint = { multiplier = 1.5 } }), nil, env)
	controller:setInput({ x = 0, y = 0, z = -1 }, true)
	local jumped = nil
	local stop, how = MovementRoblox.start(controller, {
		humanoid = humanoid,
		root = root,
		runService = env.services.RunService,
		roblox = roblox,
		onOutput = function(output: any)
			for _, event in output.events do
				if event.kind == "jump" then
					jumped = event.velocity
				end
			end
		end,
	}, env)
	ctx.check("bound_to_simulation", how == "simulation", { how = how })
	if stop then
		defer(stop)
	end
	ctx.check(
		"sprint_walkspeed",
		waitFor(ctx, function()
			return humanoid.WalkSpeed == 24
		end, 1),
		{ walkSpeed = humanoid.WalkSpeed }
	)
	ctx.check(
		"grounded_read",
		waitFor(ctx, function()
			return MovementRoblox.grounded(humanoid)
		end, 3),
		{ floor = humanoid.FloorMaterial.Name }
	)
	controller:request("jump")
	waitFor(ctx, function()
		return jumped ~= nil
	end, 1)
	env.wait(1 / 30)
	ctx.check("jump_launch_speed", jumped ~= nil and root.AssemblyLinearVelocity.Y > 0, { launch = jumped })
end)

return probes
