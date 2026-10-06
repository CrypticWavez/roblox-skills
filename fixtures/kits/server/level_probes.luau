--!strict
-- G7 probe registry (prefixes level_, lvl_). Run in a play session on the unpublished diagnostic
-- place built from fixtures/kits.project.json (tests/engine/lvl_<name>.luau are the RunScript
-- entries); each probe builds what it needs under Workspace.SETUP_ONLY_LevelProbe and removes it.
--   lvl_pathfinding_probe  PathfindingService with NavAgentRoblox parameters: a wall with a gap,
--                          a PathfindingModifier label priced out (Costs = math.huge) and a
--                          PathfindingLink; the path succeeds, ends at the goal and avoids the zone
--   lvl_navagent_door      a door in a wall marked PassThrough: the path crosses the door and a
--                          NavAgentRoblox controller walks it to "arrived" (the root part is moved
--                          to each MoveTo target, so no physics timing is involved)
--   lvl_kit_swap           SceneKit Apply.swap with the engine's PivotTo: kit pieces replace course
--                          placeholders at their CFrames and keep their attributes
--   lvl_course_run         StarterPlayer and Workspace physics match SceneKit Measure.ENGINE, and a
--                          generated linear course built in the engine has every landing pad under
--                          its manifest position and every jump arc clear (Workspace:Raycast)
-- No requires: modules come through ctx.kit. In Lune the registry runs against fakes
-- (tests/gamekit_world_probes.spec.luau); that is not Studio evidence.
local probes = {}

local FOLDER = "SETUP_ONLY_LevelProbe"

local function stage(ctx: any): any
	local workspace = ctx.env.services.Workspace
	-- A Lune runner passes a Workspace stand-in table (Raycast over Lune parts); its `instance`
	-- is the real parent. In Studio Workspace is the service itself.
	local parent = if type(workspace) == "table" then workspace.instance else workspace
	local old = parent:FindFirstChild(FOLDER)
	if old then
		old:Destroy()
	end
	local folder = ctx.env.roblox.Instance.new("Folder")
	folder.Name = FOLDER
	folder.Parent = parent
	return folder
end

local function block(ctx: any, parent: any, name: string, size: { number }, pos: { number }): any
	local R = ctx.env.roblox
	local part = R.Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = R.Vector3.new(size[1], size[2], size[3])
	part.CFrame = R.CFrame.new(pos[1], pos[2], pos[3])
	part.Parent = parent
	return part
end

function probes.lvl_pathfinding_probe(ctx: any)
	local NavAgentRoblox = ctx.kit("GameKit/NavAgentRoblox")
	local R = ctx.env.roblox
	local folder = stage(ctx)
	-- Floor 120 x 60; a wall across x = 0 with a gap at z in [16, 26]; an avoid zone at z ~ 0.
	block(ctx, folder, "Floor", { 120, 1, 60 }, { 0, -0.5, 0 })
	block(ctx, folder, "WallA", { 2, 10, 44 }, { 0, 5, -8 })
	block(ctx, folder, "WallB", { 2, 10, 4 }, { 0, 5, 28 })
	local zone = block(ctx, folder, "AvoidZone", { 20, 0.2, 20 }, { -30, 0.1, 0 })
	zone.CanCollide = false
	NavAgentRoblox.modifier(zone, "avoid", false, ctx.env)
	local a0 = R.Instance.new("Attachment")
	a0.Parent = block(ctx, folder, "LinkFrom", { 2, 1, 2 }, { 40, 0.5, -20 })
	local a1 = R.Instance.new("Attachment")
	a1.Parent = block(ctx, folder, "LinkTo", { 2, 1, 2 }, { 50, 0.5, -20 })
	local link = NavAgentRoblox.link(folder, a0, a1, "shortcut", true, ctx.env)
	ctx.check(
		"link_created",
		link.ClassName == "PathfindingLink" and link.Label == "shortcut",
		link.ClassName
	)

	local params = NavAgentRoblox.parameters({ costs = { avoid = math.huge } })
	local path = ctx.env.services.PathfindingService:CreatePath(params)
	local from, to = R.Vector3.new(-50, 3, 0), R.Vector3.new(50, 3, 0)
	local ok, err = pcall(function()
		path:ComputeAsync(from, to)
	end)
	ctx.check("compute_ok", ok, if ok then nil else tostring(err))
	local status = if ok then path.Status.Name else "error"
	ctx.check("status_success", status == "Success", status)
	local points = NavAgentRoblox.waypoints(if ok then path:GetWaypoints() else {})
	ctx.check("waypoints", #points >= 2, #points)
	local last = points[#points]
	local endGap = if last then math.sqrt((last.pos.x - 50) ^ 2 + (last.pos.z - 0) ^ 2) else math.huge
	ctx.check("ends_at_goal", endGap <= 4, endGap)
	local inZone, throughGap = 0, false
	for _, p in points do
		if math.abs(p.pos.x + 30) < 10 and math.abs(p.pos.z) < 10 then
			inZone += 1
		end
		if math.abs(p.pos.x) < 2 and p.pos.z > 14 and p.pos.z < 28 then
			throughGap = true
		end
	end
	ctx.check("avoids_priced_out_zone", inZone == 0, inZone)
	ctx.check("crosses_wall_at_gap", throughGap, "a waypoint near x = 0 inside the gap")
	folder:Destroy()
end

function probes.lvl_navagent_door(ctx: any)
	local NavAgentRoblox = ctx.kit("GameKit/NavAgentRoblox")
	local R = ctx.env.roblox
	local folder = stage(ctx)
	block(ctx, folder, "Floor", { 80, 1, 40 }, { 0, -0.5, 0 })
	block(ctx, folder, "WallA", { 2, 10, 17 }, { 0, 5, -11.5 })
	block(ctx, folder, "WallB", { 2, 10, 17 }, { 0, 5, 11.5 })
	local door = block(ctx, folder, "Door", { 1, 9, 6 }, { 0, 4.5, 0 })
	NavAgentRoblox.modifier(door, "door", true, ctx.env)
	local root = block(ctx, folder, "Root", { 2, 2, 1 }, { -30, 3, 0 })
	root.CanCollide = false
	-- A stand-in Humanoid that records MoveTo; the probe moves the root itself.
	local moves = {}
	local humanoid = {
		Jump = false,
		MoveTo = function(_, target: any)
			table.insert(moves, target)
		end,
	}
	local controller = NavAgentRoblox.new(humanoid, root, { stuckTime = 5 }, ctx.env)
	local finished = nil
	controller.finished:Connect(function(kind: string)
		finished = kind
	end)
	controller:moveTo(R.Vector3.new(30, 3, 0))
	local crossed, last = false, nil
	for _ = 1, 400 do
		local command = controller:step(0.1)
		if command.kind == "move" or command.kind == "jump" then
			local to = command.to
			root.CFrame = R.CFrame.new(to.x, to.y, to.z)
			if math.abs(to.x) < 1.5 and math.abs(to.z) < 3 then
				crossed = true
			end
		elseif command.kind == "arrived" or command.kind == "failed" then
			last = command
			break
		elseif command.kind == "wait" then
			ctx.env.wait(0.1)
		end
	end
	ctx.check("path_through_door", crossed, "a waypoint inside the door opening")
	ctx.check("arrived", last ~= nil and last.kind == "arrived", last and last.reason)
	ctx.check("moved", #moves >= 2, #moves)
	ctx.check("finished_signal", finished == "arrived", finished)
	controller:destroy()
	folder:Destroy()
end

function probes.lvl_kit_swap(ctx: any)
	local Course = ctx.kit("ProcGen/Course")
	local Apply = ctx.kit("SceneKit/Apply")
	local R = ctx.env.roblox
	local folder = stage(ctx)
	local scene = Course.toScene(Course.linear({ seed = 701, length = 8 }))
	local _, root = Apply.scene(scene, folder, { env = R })
	local before = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("asset") == "course_platform" then
			before[d:GetAttribute("SceneKitId")] = d.CFrame
		end
	end
	local template = R.Instance.new("Part")
	template.Name = "PadPiece"
	template.Anchored = true
	template.Size = R.Vector3.new(6, 1, 6)
	local kit = {
		schema = "kit/1",
		id = "probe_pads",
		pieces = {
			{
				key = "course_platform",
				source = "blender_template:pad",
				file = "pad.glb",
				bounds = { min = { -3, -0.5, -3 }, max = { 3, 0.5, 3 } },
				pivot = "center",
				materials = { "builtin:SmoothPlastic" },
				provenance = "local-template",
			},
		},
	}
	local report = Apply.swap(root, kit, {
		load = function()
			return template
		end,
		fit = "stretch",
		env = R,
	})
	local expected = 0
	for _ in before do
		expected += 1
	end
	ctx.check(
		"swapped_all_platforms",
		report.swapped == expected and expected > 0,
		{ swapped = report.swapped, expected = expected }
	)
	ctx.check("no_failures", #report.failed == 0, report.failed)
	local worst, kept = 0, 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("KitId") == "probe_pads" then
			local old = before[d:GetAttribute("SceneKitId")]
			if old then
				kept += 1
				local a, b = { d.CFrame:GetComponents() }, { old:GetComponents() }
				for i = 1, 12 do
					worst = math.max(worst, math.abs(a[i] - b[i]))
				end
			end
		end
	end
	ctx.check("attributes_kept", kept == expected, kept)
	ctx.check("cframes_kept", worst < 1e-3, worst)
	folder:Destroy()
end

function probes.lvl_course_run(ctx: any)
	local Course = ctx.kit("ProcGen/Course")
	local Measure = ctx.kit("SceneKit/Measure")
	local Apply = ctx.kit("SceneKit/Apply")
	local R = ctx.env.roblox
	local services = ctx.env.services
	local player, workspace = services.StarterPlayer, services.Workspace
	local jump = if player.CharacterUseJumpPower
		then player.CharacterJumpPower ^ 2 / (2 * workspace.Gravity)
		else player.CharacterJumpHeight
	ctx.check(
		"gravity_matches",
		math.abs(workspace.Gravity - Measure.ENGINE.gravity) < 0.05,
		workspace.Gravity
	)
	ctx.check(
		"walkspeed_matches",
		math.abs(player.CharacterWalkSpeed - Measure.ENGINE.walkSpeed) < 0.05,
		player.CharacterWalkSpeed
	)
	ctx.check("jump_height_matches", math.abs(jump - Measure.ENGINE.jumpHeight) < 0.05, {
		jumpHeight = jump,
		useJumpPower = player.CharacterUseJumpPower,
	})

	local folder = stage(ctx)
	local course = Course.linear({ seed = 701, length = 16 })
	local _, root = Apply.scene(Course.toScene(course), folder, { env = R })
	local params = R.RaycastParams.new()
	params.FilterType = R.Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { root }
	local missed, blocked = {}, {}
	local g = workspace.Gravity
	for _, segment in course.segments do
		local a, b = course.pads[segment.from], course.pads[segment.to]
		local hit =
			workspace:Raycast(R.Vector3.new(b.pos.x, b.pos.y + 20, b.pos.z), R.Vector3.new(0, -40, 0), params)
		if hit == nil or math.abs(hit.Position.Y - b.pos.y) > 0.05 then
			table.insert(missed, segment.index)
		end
		-- Arc from the take-off pad centre to the landing pad centre at the course physics,
		-- 1.5 studs over the pads (a standing character's hips), sampled in 12 chords.
		local vy = math.sqrt(2 * g * course.profile.jumpHeight)
		local rise = b.pos.y - a.pos.y
		local tAir = (vy + math.sqrt(math.max(vy * vy - 2 * g * rise, 0))) / g
		local function at(t: number): any
			local f = t / tAir
			return R.Vector3.new(
				a.pos.x + (b.pos.x - a.pos.x) * f,
				a.pos.y + 1.5 + vy * t - g * t * t / 2,
				a.pos.z + (b.pos.z - a.pos.z) * f
			)
		end
		for k = 1, 12 do
			local p, q = at(tAir * (k - 1) / 12), at(tAir * k / 12)
			local chord = workspace:Raycast(p, q - p, params)
			if
				chord
				and chord.Instance:GetAttribute("CoursePad") ~= b.id
				and chord.Instance:GetAttribute("CoursePad") ~= a.id
			then
				table.insert(blocked, segment.index)
				break
			end
		end
	end
	ctx.check("landings_in_place", #missed == 0, missed)
	ctx.check("arcs_clear", #blocked == 0, blocked)
	folder:Destroy()
end

return probes
