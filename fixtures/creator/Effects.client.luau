--!strict
-- Run only as a LocalScript in the explicitly unpublished workbench diagnostic.
-- Parent syncs Effects + EffectsPool to ReplicatedStorage.Workbench.Creator first.
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local Effects = require(game:GetService("ReplicatedStorage").Workbench.Creator.Effects)
local player = assert(Players.LocalPlayer, "client player required")
local camera = workspace.CurrentCamera
local deadline = os.clock() + 20
while
	(camera == nil or camera.ViewportSize.X < 240 or camera.ViewportSize.Y < 240)
	and os.clock() < deadline
do
	game:GetService("RunService").RenderStepped:Wait()
	camera = workspace.CurrentCamera
end
camera = assert(camera, "native client camera required")
assert(camera.ViewportSize.X >= 240 and camera.ViewportSize.Y >= 240, "usable native viewport required")
local root = Instance.new("Folder")
root.Name, root.Parent = "CreatorEffectsDiagnostic", workspace
local evidence = Instance.new("StringValue")
evidence.Name, evidence.Parent = "WorkbenchCreatorEffectsEvidence", player.PlayerScripts
local report = {
	mode = "SETUP_ONLY",
	method = "assisted_native_diagnostic",
	status = "partially_verified",
	particle_texture = "rbxasset://textures/particles/sparkles_main.dds",
	external_assets = false,
	checks = {},
	samples = {},
	inspection_seconds = { normal = 3.8, reduced_from = 3.8, teardown = 7.5 },
}
local function check(name, passed)
	table.insert(report.checks, { name = name, status = if passed then "passed" else "failed" })
end
local viewport = camera.ViewportSize
local zone = { x = 16, y = 56, width = viewport.X - 32, height = viewport.Y - 72 }
local screen = player.PlayerGui:FindFirstChild("WorkbenchPanel")
local panel = if screen then screen:FindFirstChild("Panel") else nil
if panel and panel:IsA("GuiObject") then
	local p, size = panel.AbsolutePosition, panel.AbsoluteSize
	local candidates = {
		{ x = 16, y = 56, width = p.X - 32, height = viewport.Y - 72 },
		{ x = p.X + size.X + 16, y = 56, width = viewport.X - p.X - size.X - 32, height = viewport.Y - 72 },
		{ x = 16, y = 56, width = viewport.X - 32, height = p.Y - 72 },
		{ x = 16, y = p.Y + size.Y + 16, width = viewport.X - 32, height = viewport.Y - p.Y - size.Y - 32 },
	}
	zone = { x = 0, y = 0, width = 0, height = 0 }
	for _, candidate in candidates do
		if
			candidate.width >= 60
			and candidate.height >= 60
			and candidate.width * candidate.height > zone.width * zone.height
		then
			zone = candidate
		end
	end
end
if zone.width < 60 or zone.height < 60 then
	root:Destroy()
	evidence:Destroy()
	error("no inspection band outside diagnostic panel; use a separate fixture view", 0)
end
report.viewport, report.inspection_band = { width = viewport.X, height = viewport.Y }, zone
local originalType, originalCFrame, originalFOV = camera.CameraType, camera.CFrame, camera.FieldOfView
local closed = false
local effects: any = nil
local destroying: RBXScriptConnection? = nil
report.camera = {
	inspection_type = "Scriptable",
	original_type = tostring(originalType),
	original_fov = originalFOV,
	restored = false,
}
local function cleanup()
	if closed then
		return
	end
	closed = true
	if effects then
		pcall(function()
			effects:destroy()
		end)
	end
	-- Restore each owned property even if another restoration fails or the camera was removed.
	local typeOK = pcall(function()
		camera.CameraType = originalType
	end)
	local frameOK = pcall(function()
		camera.CFrame = originalCFrame
	end)
	local fovOK = pcall(function()
		camera.FieldOfView = originalFOV
	end)
	report.camera.restored = typeOK and frameOK and fovOK
	if destroying then
		destroying:Disconnect()
	end
	root:Destroy()
end
local function protect(action)
	if closed then
		return
	end
	local ok, failure = xpcall(action, debug.traceback)
	if not ok then
		cleanup()
		report.status, report.failure = "blocked", tostring(failure)
		evidence.Value = HttpService:JSONEncode(report)
	end
end
destroying = script.Destroying:Connect(function()
	cleanup()
	if evidence.Parent then
		evidence.Value = HttpService:JSONEncode(report)
	end
end)
protect(function()
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame, camera.FieldOfView = originalCFrame, originalFOV
	local function pose(index)
		local vertical = zone.height > zone.width
		local x = zone.x + zone.width * (if vertical then 0.5 else index / 4)
		local y = zone.y + zone.height * (if vertical then index / 4 else 0.5)
		local ray = camera:ViewportPointToRay(x, y)
		local position = ray.Origin + ray.Direction * 10
		return CFrame.new(position) * camera.CFrame.Rotation * CFrame.Angles(math.pi / 2, 0, 0), x, y
	end
	local _, centerX, centerY = pose(2)
	local ray0 = camera:ViewportPointToRay(centerX, centerY)
	local ray1 = camera:ViewportPointToRay(centerX + math.min(zone.width, zone.height, 120) / 6, centerY)
	local radius = math.clamp(
		((ray1.Origin + ray1.Direction * 10) - (ray0.Origin + ray0.Direction * 10)).Magnitude,
		0.05,
		1
	)
	effects = Effects.new(root, { capacity = 3, particleStyle = "sparkles" })
	local kinds = { "telegraph", "impact", "reward" }
	local leases = {}
	for index, kind in kinds do
		leases[index] = assert(effects:emit(kind, {
			cframe = pose(index),
		}, { duration = 5, radius = radius }))
	end
	task.wait(0.15)
	local classes = { Beam = 0, Trail = 0, ParticleEmitter = 0, Attachment = 0 }
	local builtInTextures, validAttachments = true, true
	for _, instance in root:GetDescendants() do
		if classes[instance.ClassName] ~= nil then
			classes[instance.ClassName] += 1
		end
		if instance:IsA("Beam") or instance:IsA("Trail") or instance:IsA("ParticleEmitter") then
			local expected = if instance:IsA("ParticleEmitter") then report.particle_texture else ""
			builtInTextures = builtInTextures and instance.Texture == expected
		end
		if instance:IsA("Beam") or instance:IsA("Trail") then
			validAttachments = validAttachments
				and instance.Attachment0 ~= nil
				and instance.Attachment1 ~= nil
		end
	end
	report.samples[1] = { phase = "three_recipes_active", classes = classes, stats = effects:stats() }
	check(
		"three neutral recipes own bounded resources",
		effects:stats().active == 3 and effects:stats().allocated == 3
	)
	check(
		"native Beam Trail ParticleEmitter Attachment nodes exist",
		classes.Beam == 6 and classes.Trail == 3 and classes.ParticleEmitter == 3 and classes.Attachment == 18
	)
	check("native endpoints reference attachments", validAttachments)
	check("only packaged particle texture and untextured beams trails configured", builtInTextures)
	leases[2]:cancel()
	assert(effects:emit("impact", { cframe = pose(2) }, { duration = 5, radius = radius }))
	check(
		"native resource reuse avoids a fourth allocation",
		effects:stats().created == 3 and effects:stats().reused == 1
	)
	evidence.Value = HttpService:JSONEncode(report)
	task.delay(3.8, function()
		protect(function()
			effects:setReducedEffects(true)
			report.samples[2] = { phase = "reduced_effects", stats = effects:stats() }
			check(
				"reduced effects preserve critical cue and remove lower priorities",
				effects:stats().active == 1
			)
			leases[1]:cancel()
			assert(effects:emit("telegraph", { cframe = pose(1) }, { duration = 3.2, radius = radius }))
			evidence.Value = HttpService:JSONEncode(report)
		end)
	end)
	task.delay(7.5, function()
		protect(function()
			check("lifetime expiry removes native active resources", effects:stats().active == 0)
			effects:destroy()
			effects:destroy()
			check("idempotent teardown removes every owned native descendant", #root:GetDescendants() == 0)
			report.samples[3] = { phase = "destroyed", stats = effects:stats() }
			report.rendered_visibility =
				"requires separately inspected native capture; object counts do not prove appearance"
			cleanup()
			check("owned inspection camera properties restored", report.camera.restored)
			evidence.Value = HttpService:JSONEncode(report)
		end)
	end)
end)
