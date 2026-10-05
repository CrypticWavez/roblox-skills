--!strict
-- Instantiates a Scene. Runs in Roblox Studio (ChangeHistoryService undo waypoint) and in
-- Lune (pass env = require("@lune/roblox")) so fixtures can be written as .rbxlx files.
local Manifest = require("../ProcGen/Manifest")
local Scene = require("./Scene")

local Apply = {}
type Scene = Scene.Scene

local CLASS =
	{ Block = "Part", Ball = "Part", Cylinder = "Part", Wedge = "WedgePart", CornerWedge = "CornerWedgePart" }

local function defaultEnv(): any
	return { Instance = Instance, Vector3 = Vector3, CFrame = CFrame, Color3 = Color3, Enum = Enum }
end

function Apply.cframe(env: any, spec: Scene.PartSpec): any
	local rot = spec.rot or { x = 0, y = 0, z = 0 }
	return env.CFrame.new(spec.pos.x, spec.pos.y, spec.pos.z)
		* env.CFrame.fromOrientation(math.rad(rot.x), math.rad(rot.y), math.rad(rot.z))
end

local function folderFor(env: any, root: any, path: string, cache: { [string]: any }): any
	if path == "" then
		return root
	end
	if cache[path] then
		return cache[path]
	end
	local parentPath, name = string.match(path, "^(.*)/([^/]+)$")
	local parent = folderFor(env, root, parentPath or "", cache)
	local model = env.Instance.new("Model")
	model.Name = name or path
	model.Parent = parent
	cache[path] = model
	return model
end

-- Re-applying replaces the previous SceneKit model with the same name under `parent` unless
-- options.replace == false (models without a SceneKitHash attribute are never touched).
-- options.dryRun returns the summary without creating anything.
function Apply.scene(scene: Scene, parent: any, options: { env: any?, dryRun: boolean?, replace: boolean? }?)
	local manifest = scene:manifest()
	local hash = Manifest.hash(manifest.parts)
	local summary = {
		name = scene.name,
		parts = #scene.specs,
		hash = hash,
		counts = manifest.counts,
		dryRun = options and options.dryRun or false,
	}
	if options and options.dryRun then
		return summary, nil
	end
	local env = options and options.env or defaultEnv()
	local replace = not (options and options.replace == false)
	local history, recording = nil, nil
	local okHistory, service = pcall(function()
		return (game :: any):GetService("ChangeHistoryService")
	end)
	if okHistory and service then
		history = service
		local okRecord, id = pcall(function()
			return service:TryBeginRecording("SceneKit " .. scene.name)
		end)
		recording = if okRecord then id else nil
	end
	local ok, result = pcall(function()
		if replace then
			local existing = parent:FindFirstChild(scene.name)
			if existing and existing:GetAttribute("SceneKitHash") ~= nil then
				existing:Destroy()
			end
		end
		local root = env.Instance.new("Model")
		root.Name = scene.name
		root:SetAttribute("SceneKitHash", hash)
		root:SetAttribute("SceneKitSeed", tostring(scene.seed))
		root:SetAttribute("SceneKitStyle", scene.style.id)
		root:SetAttribute("Provenance", tostring(scene.provenance.source or "SceneKit"))
		local cache = {}
		for _, spec in scene.specs do
			local part = env.Instance.new(CLASS[spec.shape or "Block"] or "Part")
			if spec.shape == "Ball" then
				part.Shape = env.Enum.PartType.Ball
			elseif spec.shape == "Cylinder" then
				part.Shape = env.Enum.PartType.Cylinder
			end
			part.Name = spec.name or spec.role
			part.Size = env.Vector3.new(spec.size.x, spec.size.y, spec.size.z)
			part.CFrame = Apply.cframe(env, spec)
			part.Anchored = true
			part.CanCollide = spec.canCollide ~= false
			part.Material = env.Enum.Material[spec.material or "SmoothPlastic"]
			local c = spec.color or { 200, 200, 200 }
			part.Color = env.Color3.fromRGB(c[1], c[2], c[3])
			part.Transparency = spec.transparency or 0
			part:SetAttribute("SceneKitId", spec.id)
			part:SetAttribute("Role", spec.role)
			for key, value in spec.attributes or {} do
				part:SetAttribute(key, value)
			end
			part.Parent = folderFor(env, root, spec.group or "", cache)
		end
		root.Parent = parent
		return root
	end)
	if history and recording then
		history:FinishRecording(
			recording,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		error(result, 0)
	end
	return summary, result
end

-- Replays Terrain ops onto a Terrain instance (Studio only; Lune has no voxel engine).
function Apply.terrain(ops: { any }, terrain: any, env: any?)
	local e = env or defaultEnv()
	for _, op in ops do
		local material = e.Enum.Material[op.material]
		if op.op == "FillBlock" then
			terrain:FillBlock(
				e.CFrame.new(op.pos[1], op.pos[2], op.pos[3]),
				e.Vector3.new(op.size[1], op.size[2], op.size[3]),
				material
			)
		elseif op.op == "FillBall" then
			terrain:FillBall(e.Vector3.new(op.pos[1], op.pos[2], op.pos[3]), op.radius, material)
		else
			error("unknown terrain op " .. tostring(op.op))
		end
	end
	return #ops
end

return Apply
