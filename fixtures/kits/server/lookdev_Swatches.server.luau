--!strict
-- Lookdev fixture (G5), server side: material swatches for judging lighting presets. Runs only
-- when Workspace:GetAttribute("SETUP_ONLY_KitFixture") == "lookdev" in the unpublished kits
-- diagnostic place (fixtures/kits.project.json sets "none"). Builds a row of neutral grey cubes,
-- spheres and ramps (value steps for exposure), a row of every built-in Enum.Material that can
-- carry a MaterialVariant, and a ground plate; applies SceneKit/Lighting "lookdev_neutral".
-- The client fixture (lookdev_Cycle) then cycles presets and plays the VFX grid.
-- Nothing here is game content; every part is anchored and tagged SETUP_ONLY_Lookdev.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

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

local SceneLighting = kit("SceneKit/Lighting")
local Materials = kit("SceneKit/Materials")

local root = Instance.new("Folder")
root.Name = "SETUP_ONLY_Lookdev"
root.Parent = Workspace

local function part(name: string, size: Vector3, cframe: CFrame, props: { [string]: any }?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	local assigned: { [string]: any } = props or {}
	for key, value in assigned do
		(p :: any)[key] = value
	end
	p:SetAttribute("SETUP_ONLY_Lookdev", true)
	p.Parent = root
	return p
end

local function label(target: BasePart, text: string)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(6, 1.2)
	gui.StudsOffsetWorldSpace = Vector3.new(0, target.Size.Y / 2 + 1.2, 0)
	gui.MaxDistance = 80
	gui.LightInfluence = 0
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.TextScaled = true
	textLabel.TextColor3 = Color3.new(1, 1, 1)
	textLabel.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Parent = textLabel
	textLabel.Parent = gui
	gui.Parent = target
end

-- ground plate
part("Ground", Vector3.new(200, 1, 140), CFrame.new(0, -0.5, 20), {
	Material = Enum.Material.Concrete,
	Color = Color3.fromRGB(128, 128, 128),
})

-- value steps: albedo 10% .. 90% grey on cubes, spheres and ramps (exposure and shadow reading)
for index, value in { 0.1, 0.3, 0.5, 0.7, 0.9 } do
	local grey = Color3.new(value, value, value)
	local x = (index - 3) * 8
	local cube = part("Cube_" .. index, Vector3.new(4, 4, 4), CFrame.new(x, 2, -20), { Color = grey })
	label(cube, string.format("albedo %d%%", value * 100))
	part(
		"Sphere_" .. index,
		Vector3.new(4, 4, 4),
		CFrame.new(x, 2, -28),
		{ Color = grey, Shape = Enum.PartType.Ball }
	)
	local ramp = Instance.new("WedgePart")
	ramp.Name = "Ramp_" .. index
	ramp.Size = Vector3.new(4, 3, 6)
	ramp.CFrame = CFrame.new(x, 1.5, -36)
	ramp.Color = grey
	ramp.Anchored = true
	ramp.Parent = root
end

-- material swatches: every Enum.Material that can carry a MaterialVariant
local columns = 9
local index = 0
for _, name in Materials.ENUM do
	if name ~= "Air" and name ~= "Water" and name ~= "ForceField" then
		local material = (Enum.Material :: any)[name]
		local column, row = index % columns, index // columns
		local swatch = part(
			"Swatch_" .. name,
			Vector3.new(5, 5, 1),
			CFrame.new((column - (columns - 1) / 2) * 7, 3, row * 9 + 6),
			{ Material = material, Color = Color3.fromRGB(163, 162, 165) }
		)
		label(swatch, name)
		index += 1
	end
end

local report = SceneLighting.apply(Lighting, "lookdev_neutral")
Workspace:SetAttribute("SETUP_ONLY_LookdevReady", true)
print(
	string.format(
		"LOOKDEV swatches=%d lighting=%s conflicts=%d requires_ok=%s",
		index,
		report.preset,
		#report.conflicts,
		tostring(SceneLighting.inspect(Lighting).requires_ok)
	)
)
