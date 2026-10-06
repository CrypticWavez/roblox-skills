-- SceneKit Kit (kit/1 validate, define, fit, resolve, placeholders) and Apply.swap on real
-- @lune/roblox instances: pieces replace course placeholders keeping each placeholder's CFrame
-- and gameplay attributes, procedural pieces stay, unknown keys are reported, a failing loader
-- and a stretched model fail with the exact reason, and the swap is one ChangeHistory recording.
-- Lune has no PivotTo, so the specs pass pivotTo (Studio uses the engine's: probe lvl_kit_swap).
local roblox = require("@lune/roblox")
local Apply = require("../packages/SceneKit/Apply")
local Course = require("../packages/ProcGen/Course")
local Kit = require("../packages/SceneKit/Kit")

local Instance, Vector3, CFrame = roblox.Instance, roblox.Vector3, roblox.CFrame

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

-- The kit/1 example of docs/runtime-kits.md section 9.5.
local function exampleKit()
	return {
		schema = "kit/1",
		id = "greybox_course",
		pieces = {
			{
				key = "checkpoint_gate",
				source = "blender_template:checkpoint_gate",
				file = "checkpoint_gate.glb",
				bounds = { min = { -6, 0, -1 }, max = { 6, 10, 1 } },
				pivot = "base_center",
				materials = { "atlas:checkpoint_gate_atlas.png" },
				provenance = "local-template",
				sockets = { { name = "respawn", position = { 0, 0, -4 }, yaw = 180 } },
				collision = "box",
				triangles = 412,
			},
			{
				key = "floor_tile",
				source = "procedural",
				bounds = { min = { -4, 0, -4 }, max = { 4, 1, 4 } },
				pivot = "base_center",
				materials = { "builtin:SmoothPlastic" },
				provenance = "local-template",
			},
		},
	}
end

local function recorder()
	local calls = {}
	return {
		calls = calls,
		TryBeginRecording = function(_, name)
			table.insert(calls, "begin:" .. name)
			return "rec"
		end,
		FinishRecording = function(_, id, operation)
			table.insert(calls, "finish:" .. id .. ":" .. operation.Name)
		end,
	}
end

local function nearCFrame(t, a, b, label)
	local ac, bc = { a:GetComponents() }, { b:GetComponents() }
	for i = 1, 12 do
		t.near(ac[i], bc[i], 1e-3, label .. " component " .. i)
	end
end

test("the documented kit/1 example validates and defines", function(t)
	t.eq(Kit.validate(exampleKit()), {})
	local kit = Kit.define(exampleKit())
	t.eq((Kit.find(kit, "floor_tile") :: any).source, "procedural")
	t.eq(Kit.find(kit, "missing"), nil)
	t.ok(table.isfrozen(kit))
end)

test("a broken kit lists every problem by piece", function(t)
	local kit = exampleKit()
	kit.schema = "kit/2"
	local gate, tile = kit.pieces[1] :: any, kit.pieces[2] :: any
	gate.source = "blender:gate"
	gate.bounds = { min = { 0, 0, 0 }, max = { 1, 0, 1 } }
	gate.pivot = "corner"
	gate.materials = { "paint:red" }
	gate.sockets = { { name = "respawn", position = { 0, 0 } } }
	gate.collision = "mesh"
	gate.triangles = 1.5
	tile.file = "tile.glb"
	tile.provenance = "polyhaven/x"
	table.insert(kit.pieces, { key = "floor_tile", source = "cc0:polyhaven:abc", file = "../escape.glb" })
	t.eq(Kit.validate(kit), {
		"schema must be kit/1 (got kit/2)",
		"piece checkpoint_gate: source must be procedural, blender_template:<template> or cc0:<source>:<id> (got blender:gate)",
		"piece checkpoint_gate: bounds max must exceed min on every axis",
		"piece checkpoint_gate: pivot must be base_center, center or origin",
		"piece checkpoint_gate: material paint:red must be library:<name>, builtin:<Enum.Material>, atlas:<file> or vertex_color",
		"piece checkpoint_gate: socket 1 needs name (label), position [x, y, z] and yaw",
		"piece checkpoint_gate: collision must be box, hull, default or none",
		"piece checkpoint_gate: triangles must be a whole number >= 0",
		"piece floor_tile: procedural pieces have no file",
		"piece floor_tile: procedural pieces have provenance local-template",
		"piece floor_tile: duplicate key",
		"piece floor_tile: file must be relative to the kit file, inside it",
		"piece floor_tile: bounds must be { min = [x, y, z], max = [x, y, z] }",
		"piece floor_tile: materials must be a list",
		"piece floor_tile: provenance must be local-template or an asset-sources/1 key",
	})
	local ok, err = pcall(Kit.define, kit)
	t.eq(ok, false)
	t.ok(string.find(tostring(err), "Kit.define: schema must be kit/1", 1, true) ~= nil, tostring(err))
	t.eq(Kit.validate({ schema = "kit/1", id = "x", pieces = {} }), { "pieces must be a non-empty list" })
end)

test("fit: none keeps size and reports mismatches, uniform and stretch scale, bottoms level", function(t)
	local gate = (Kit.define(exampleKit()) :: any).pieces[1]
	local scale, offset, problems =
		Kit.fit(gate, { asset = "checkpoint_gate", size = { x = 12, y = 10, z = 2 } })
	t.eq(scale, { x = 1, y = 1, z = 1 })
	t.eq(offset, { x = 0, y = -5, z = 0 }, "base_center pivot at the placeholder bottom")
	t.eq(problems, {})
	scale, offset, problems = Kit.fit(gate, { asset = "checkpoint_gate", size = { x = 24, y = 10, z = 2 } })
	t.eq(problems, { "x size 12.00 differs from the placeholder's 24.00" })
	scale, offset = Kit.fit(gate, { asset = "checkpoint_gate", size = { x = 24, y = 30, z = 4 } }, "uniform")
	t.eq(scale, { x = 2, y = 2, z = 2 })
	t.eq(offset, { x = 0, y = -15, z = 0 })
	scale = Kit.fit(gate, { asset = "checkpoint_gate", size = { x = 6, y = 5, z = 4 } }, "stretch")
	t.eq(scale, { x = 0.5, y = 0.5, z = 2 })
	local centred = { bounds = { min = { -1, -1, -1 }, max = { 3, 1, 1 } } }
	local _, off = Kit.fit(centred, { asset = "a", size = { x = 4, y = 2, z = 2 } })
	t.eq(off, { x = -1, y = 0, z = 0 }, "bounds centre over the placeholder centre")
	t.throws(function()
		Kit.fit(gate, { asset = "checkpoint_gate", size = { x = 1, y = 1, z = 1 } }, "squash")
	end)
end)

test("resolve matches placeholders, flags procedural pieces, lists missing and unused", function(t)
	local kit = Kit.define(exampleKit())
	local matches, missing, unused = Kit.resolve(kit, {
		{ asset = "floor_tile", size = { x = 8, y = 1, z = 8 }, id = "a" },
		{ asset = "course_platform", size = { x = 6, y = 1, z = 6 }, id = "b" },
	})
	t.eq(#matches, 1)
	t.eq(matches[1].key, "floor_tile")
	t.eq(matches[1].procedural, true)
	t.eq(#missing, 1)
	t.eq(missing[1].id, "b")
	t.eq(unused, { "checkpoint_gate" })
end)

test("course scenes carry placeholders with course_* keys", function(t)
	local scene = Course.toScene(Course.linear({ seed = 701, length = 12 }))
	local placeholders = Kit.placeholders(scene)
	t.eq(#placeholders, #scene.specs)
	local keys = {}
	for _, p in placeholders do
		keys[p.asset] = true
	end
	t.ok(keys.course_platform and keys.course_checkpoint and keys.course_spawn and keys.course_finish)
end)

-- A linear course applied in a Lune DataModel; the kit swaps platforms and checkpoints.
local function appliedCourse()
	local course = Course.linear({ seed = 701, length = 12 })
	local scene = Course.toScene(course)
	local game = Instance.new("DataModel")
	local _, root = Apply.scene(scene, game:GetService("Workspace"), { env = roblox })
	return course, root
end

local function padKit()
	return {
		schema = "kit/1",
		id = "pads",
		pieces = {
			{
				key = "course_platform",
				source = "blender_template:pad",
				file = "pad.glb",
				bounds = { min = { -3, -0.5, -3 }, max = { 3, 0.5, 3 } },
				pivot = "center",
				materials = { "builtin:Concrete" },
				provenance = "local-template",
			},
			{
				key = "course_checkpoint",
				source = "blender_template:checkpoint_pad",
				file = "checkpoint_pad.glb",
				bounds = { min = { -6, 0, -6 }, max = { 6, 1, 6 } },
				pivot = "base_center",
				materials = { "vertex_color" },
				provenance = "local-template",
				collision = "none",
			},
			{
				key = "course_spawn",
				source = "procedural",
				bounds = { min = { -6, -0.5, -6 }, max = { 6, 0.5, 6 } },
				materials = { "builtin:SmoothPlastic" },
				provenance = "local-template",
			},
		},
	}
end

local function partTemplate(name: string, size)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Anchored = true
	return p
end

local function partPivot(instance, cframe)
	instance.CFrame = cframe
end

test("Apply.swap replaces placeholders, keeps CFrames and attributes, one undo recording", function(t)
	local course, root = appliedCourse()
	local before = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			before[d:GetAttribute("SceneKitId")] =
				{ cframe = d.CFrame, size = d.Size, asset = d:GetAttribute("asset") }
		end
	end
	local templates = {
		course_platform = partTemplate("PadTemplate", Vector3.new(6, 1, 6)),
		course_checkpoint = partTemplate("CheckpointTemplate", Vector3.new(12, 1, 12)),
	}
	local history = recorder()
	local report = Apply.swap(root, padKit(), {
		load = function(piece)
			return templates[piece.key]
		end,
		fit = "stretch",
		env = roblox,
		history = history,
		pivotTo = partPivot,
	})
	t.eq(history.calls, { "begin:SceneKit kit swap pads", "finish:rec:Commit" })
	local platforms, checkpoints = 0, 0
	for _, pad in course.pads do
		platforms += if pad.role == "platform" then 1 else 0
		checkpoints += if pad.role == "checkpoint" then 1 else 0
	end
	t.eq(report.swapped, platforms + checkpoints)
	t.eq(report.procedural, 1, "the spawn pad stays procedural")
	t.eq(report.missing, { "course_finish" })
	t.eq(report.failed, {})
	t.eq(report.unused, {})
	local swapped = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("KitId") == "pads" then
			swapped += 1
			local old = before[d:GetAttribute("SceneKitId")]
			t.ok(old ~= nil, "attributes copied")
			t.eq(d:GetAttribute("asset"), old.asset)
			if old.asset == "course_platform" then
				nearCFrame(t, d.CFrame, old.cframe, "platform keeps its CFrame")
			else
				-- base_center pivot: bottoms level, so the pivot sits half a pad below the centre.
				nearCFrame(t, d.CFrame, old.cframe * CFrame.new(0, -0.5, 0), "checkpoint pivot at its base")
				t.ok(d:GetAttribute("Checkpoint") ~= nil, "Checkpoint binding survives")
				t.eq(d.CanCollide, false, "collision none")
			end
			t.near(d.Size.X, old.size.X, 1e-4, "stretched to the placeholder")
			t.near(d.Size.Z, old.size.Z, 1e-4, "stretched to the placeholder")
		end
	end
	t.eq(swapped, report.swapped)
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			local asset = d:GetAttribute("asset")
			if asset == "course_platform" or asset == "course_checkpoint" then
				t.eq(d:GetAttribute("KitId"), "pads", "no placeholder left behind")
			end
		end
	end
end)

test("Apply.swap keeps hidden placeholders on request and reports a failing loader", function(t)
	local _, root = appliedCourse()
	local report = Apply.swap(root, padKit(), {
		load = function(piece)
			if piece.key == "course_checkpoint" then
				error("no such file", 0)
			end
			return partTemplate("Pad", Vector3.new(6, 1, 6))
		end,
		keepPlaceholders = true,
		env = roblox,
		history = recorder(),
		pivotTo = partPivot,
	})
	t.ok(#report.failed >= 1)
	t.ok(
		string.match(
			report.failed[1],
			"^linear/Pads/p%d+#1: load failed for course_checkpoint %(no such file%)$"
		) ~= nil,
		report.failed[1]
	)
	t.ok(#report.warnings > 0, "size mismatches reported without a fit")
	local hidden = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("KitSwapped") then
			hidden += 1
			t.eq(d.Transparency, 1)
			t.eq(d.CanCollide, false)
		end
	end
	t.eq(hidden, report.swapped)
end)

test("Apply.swap scales models uniformly and refuses to stretch them", function(t)
	local _, root = appliedCourse()
	local function modelTemplate()
		local model = Instance.new("Model")
		local p = partTemplate("Body", Vector3.new(6, 1, 6))
		p.CFrame = CFrame.new(0, 0, 0)
		p.Parent = model
		return model
	end
	local scaled, moved = {}, 0
	local options = {
		load = function()
			return modelTemplate()
		end,
		fit = "uniform",
		env = roblox,
		history = recorder(),
		pivotTo = function(model, cframe)
			moved += 1
			for _, child in model:GetChildren() do
				child.CFrame = cframe
			end
		end,
		scaleTo = function(_, s)
			table.insert(scaled, s)
		end,
	}
	local report = Apply.swap(root, padKit(), options)
	t.eq(report.failed, {})
	t.eq(moved, report.swapped)
	t.ok(#scaled > 0, "non-unit uniform scales go through scaleTo")
	local _, root2 = appliedCourse()
	options.fit = "stretch"
	local refused = Apply.swap(root2, padKit(), options)
	t.ok(#refused.failed > 0)
	t.ok(
		string.find(refused.failed[1], "stretch needs a BasePart piece (models scale uniformly)", 1, true)
			~= nil
	)
	t.throws(function()
		Apply.swap(root2, padKit(), {} :: any)
	end, "load is required")
	t.throws(function()
		Apply.swap(root2, { schema = "kit/1" }, options)
	end, "an invalid kit raises")
end)

return cases
