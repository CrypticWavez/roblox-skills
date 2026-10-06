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
	return {
		Instance = Instance,
		Vector3 = Vector3,
		CFrame = CFrame,
		Color3 = Color3,
		Enum = Enum,
		UDim2 = UDim2,
	}
end
Apply.defaultEnv = defaultEnv

-- Runs `body` inside one ChangeHistoryService recording named `name`, so a single Studio undo
-- reverts everything it changed; the recording is committed on success and cancelled when `body`
-- errors (the error is re-raised). Without a ChangeHistoryService (Lune) `body` simply runs.
-- options.history injects a service (specs record the calls); options.env supplies Enum.
function Apply.withUndo(name: string, body: () -> any, options: { history: any?, env: any? }?): any
	local history = options and options.history
	if history == nil then
		local okHistory, service = pcall(function()
			return (game :: any):GetService("ChangeHistoryService")
		end)
		history = if okHistory then service else nil
	end
	local recording = nil
	if history then
		local okRecord, id = pcall(function()
			return history:TryBeginRecording(name)
		end)
		recording = if okRecord then id else nil
	end
	local ok, result = pcall(body)
	if history and recording then
		local enum = (options and options.env and options.env.Enum) or Enum
		history:FinishRecording(
			recording,
			if ok then enum.FinishRecordingOperation.Commit else enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		error(result, 0)
	end
	return result
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

local LIGHT_CLASSES = { PointLight = true, SpotLight = true, SurfaceLight = true }

-- Light instance for a part's `light` spec, parented to the part (the fixture).
function Apply.light(env: any, part: any, light: Scene.LightSpec): any
	assert(LIGHT_CLASSES[light.class], "unknown light class " .. tostring(light.class))
	local instance = env.Instance.new(light.class)
	instance.Brightness = light.brightness or 1
	instance.Range = light.range or 16
	local c = light.color or { 255, 244, 229 }
	instance.Color = env.Color3.fromRGB(c[1], c[2], c[3])
	instance.Shadows = light.shadows == true
	if light.class ~= "PointLight" then
		instance.Face = env.Enum.NormalId[light.face or "Front"]
		instance.Angle = light.angle or 90
	end
	instance.Parent = part
	return instance
end

-- SurfaceGui + TextLabel for a part's `sign` spec (placeholder text only).
function Apply.sign(env: any, part: any, sign: Scene.SignSpec): any
	local gui = env.Instance.new("SurfaceGui")
	gui.Face = env.Enum.NormalId[sign.face or "Front"]
	gui.SizingMode = env.Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = sign.pixelsPerStud or 50
	local label = env.Instance.new("TextLabel")
	label.Size = env.UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = sign.text
	label.TextScaled = true
	label.Font = env.Enum.Font.SourceSansBold
	local c = sign.textColor or { 25, 25, 25 }
	label.TextColor3 = env.Color3.fromRGB(c[1], c[2], c[3])
	label.Parent = gui
	gui.Parent = part
	return gui
end

-- Re-applying replaces the previous SceneKit model with the same name under `parent` unless
-- options.replace == false (models without a SceneKitHash attribute are never touched).
-- options.dryRun returns the summary without creating anything.
function Apply.scene(
	scene: Scene,
	parent: any,
	options: { env: any?, dryRun: boolean?, replace: boolean?, history: any? }?
)
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
	local result = Apply.withUndo("SceneKit " .. scene.name, function()
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
			if spec.light then
				Apply.light(env, part, spec.light)
			end
			if spec.sign then
				Apply.sign(env, part, spec.sign)
			end
			part.Parent = folderFor(env, root, spec.group or "", cache)
		end
		root.Parent = parent
		return root
	end, { history = options and options.history, env = env })
	return summary, result
end

-- Replays Terrain ops onto a Terrain instance (Studio only; Lune has no voxel engine). Every op is
-- checked first (known op, material, positive size/radius), so a broken list errors before the
-- first voxel changes; the replay is one ChangeHistory recording.
function Apply.terrain(ops: { any }, terrain: any, env: any?, options: { history: any? }?)
	local e = env or defaultEnv()
	local materials = {}
	for index, op in ops do
		local okMaterial, material = pcall(function()
			return e.Enum.Material[op.material]
		end)
		assert(
			okMaterial and material ~= nil,
			string.format("terrain op %d: unknown material %s", index, tostring(op.material))
		)
		materials[index] = material
		if op.op == "FillBlock" then
			assert(
				op.size[1] > 0 and op.size[2] > 0 and op.size[3] > 0,
				string.format("terrain op %d: FillBlock size must be positive", index)
			)
		elseif op.op == "FillBall" then
			assert(op.radius > 0, string.format("terrain op %d: FillBall radius must be positive", index))
		else
			error(string.format("terrain op %d: unknown terrain op %s", index, tostring(op.op)))
		end
	end
	Apply.withUndo("SceneKit terrain", function()
		for index, op in ops do
			if op.op == "FillBlock" then
				terrain:FillBlock(
					e.CFrame.new(op.pos[1], op.pos[2], op.pos[3]),
					e.Vector3.new(op.size[1], op.size[2], op.size[3]),
					materials[index]
				)
			else
				terrain:FillBall(e.Vector3.new(op.pos[1], op.pos[2], op.pos[3]), op.radius, materials[index])
			end
		end
	end, { history = options and options.history, env = e })
	return #ops
end

return Apply
