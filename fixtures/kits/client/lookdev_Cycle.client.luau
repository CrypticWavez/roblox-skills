--!strict
-- Lookdev fixture (G5), client side: cycles the 15 SceneKit/Lighting presets over the server's
-- swatches (local Lighting only), plays the 21 AVKit/VfxLibrary presets on a labelled grid (bursts
-- repeat, loops keep running) and fires Feel cues on a marker part so popups, flashes and shake
-- can be judged. Runs only when Workspace:GetAttribute("SETUP_ONLY_KitFixture") == "lookdev" in
-- the unpublished kits diagnostic place. Keys: L next lighting preset, P pause the cycle.
-- Reduced motion follows GuiService.ReducedMotionEnabled through GameKit/Settings.effective.
-- Stills prove looks, not motion: record motion with the owner's window capture.
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

if Workspace:GetAttribute("SETUP_ONLY_KitFixture") ~= "lookdev" then
	return
end

local workbench = ReplicatedStorage:WaitForChild("Workbench", 10)
local function kit(path: string): any
	local node = workbench
	for _, part in string.split(path, "/") do
		node = node:WaitForChild(part, 10)
	end
	return (require :: any)(node)
end

local EnvRoblox = kit("GameKit/EnvRoblox")
local Settings = kit("GameKit/Settings")
local SceneLighting = kit("SceneKit/Lighting")
local VfxLibrary = kit("AVKit/VfxLibrary")
local VfxPoolRoblox = kit("AVKit/VfxPoolRoblox")
local FeelRoblox = kit("Feel/FeelRoblox")

local env = EnvRoblox.studio()
local effective = Settings.effective(Settings.defaults(), { reducedMotion = GuiService.ReducedMotionEnabled })
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local folder = Instance.new("Folder")
folder.Name = "SETUP_ONLY_LookdevVfx"
folder.Parent = Workspace

-- VFX grid: 7 x 3 labelled pads at z = 60
local pool = VfxPoolRoblox.new(env, { parent = folder, effective = effective, capacity = 32 })
local pads = {}
for index, id in VfxLibrary.list() do
	local column, row = (index - 1) % 7, (index - 1) // 7
	local pad = Instance.new("Part")
	pad.Name = "Pad_" .. id
	pad.Anchored = true
	pad.Size = Vector3.new(6, 0.4, 6)
	pad.CFrame = CFrame.new((column - 3) * 12, 0.2, 60 + row * 12)
	pad.Color = Color3.fromRGB(90, 90, 90)
	pad.Parent = folder
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(8, 1.2)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
	gui.MaxDistance = 90
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Text = id
	text.Parent = gui
	gui.Parent = pad
	pads[id] = pad
end

local function playAll(loopsToo: boolean)
	for _, id in VfxLibrary.list() do
		local preset = VfxLibrary.get(id)
		if preset.mode == "burst" or loopsToo then
			pool:play(id, pads[id].CFrame * CFrame.new(0, 3, 0))
		end
	end
end
playAll(true)

-- Feel: a marker part receives cues (popups, flashes, shake) every few seconds
local marker = Instance.new("Part")
marker.Name = "FeelMarker"
marker.Anchored = true
marker.Size = Vector3.new(3, 3, 3)
marker.CFrame = CFrame.new(0, 1.5, 48)
marker.Parent = folder
local feel = FeelRoblox.new(env, {
	camera = camera,
	guiParent = player:WaitForChild("PlayerGui"),
	effective = effective,
	vfx = pool,
})

-- Lighting cycle HUD
local hud = Instance.new("ScreenGui")
hud.Name = "SETUP_ONLY_LookdevHud"
hud.ResetOnSpawn = false
local caption = Instance.new("TextLabel")
caption.Size = UDim2.new(1, -40, 0, 56)
caption.Position = UDim2.new(0, 20, 1, -76)
caption.BackgroundTransparency = 0.35
caption.BackgroundColor3 = Color3.new(0, 0, 0)
caption.TextColor3 = Color3.new(1, 1, 1)
caption.TextWrapped = true
caption.TextScaled = true
caption.Parent = hud
hud.Parent = player:WaitForChild("PlayerGui")

local presets = SceneLighting.list()
local current = 0
local paused = false
local function nextPreset()
	current = current % #presets + 1
	local id = presets[current]
	SceneLighting.apply(Lighting, id, env)
	caption.Text = string.format("%d/%d %s: %s", current, #presets, id, SceneLighting.get(id).intent)
end
nextPreset()

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.L then
		nextPreset()
	elseif input.KeyCode == Enum.KeyCode.P then
		paused = not paused
	end
end)

local cueOrder = { "hit_light", "hit_heavy", "heal", "pickup", "reward", "blast", "level_up" }
local cueIndex = 0
local sinceCycle, sinceBurst, sinceCue = 0, 0, 0
RunService:BindToRenderStep("SETUP_ONLY_Lookdev", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	pool:step(dt)
	feel:step(dt)
	sinceCycle += dt
	sinceBurst += dt
	sinceCue += dt
	if sinceBurst >= 3 then
		sinceBurst = 0
		playAll(false)
	end
	if sinceCue >= 2.5 then
		sinceCue = 0
		cueIndex = cueIndex % #cueOrder + 1
		feel:fire(
			cueOrder[cueIndex],
			{ at = marker.Position + Vector3.new(0, 2, 0), anchor = marker, value = 25 * cueIndex }
		)
	end
	if not paused and sinceCycle >= 8 then
		sinceCycle = 0
		nextPreset()
	end
end)
