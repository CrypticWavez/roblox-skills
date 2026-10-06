--!strict
-- SceneKit/Lighting schema 2: the 15 function-named presets validate and audit clean, schema 1 ids
-- keep their values, validate rejects bad input, blend is exact at its ends and continuous
-- between, apply -> inspect round-trips on a @lune/roblox DataModel (Lighting, owned post effects,
-- Clouds under Terrain, GlobalWind), apply is order-independent, foreign instances are never
-- edited, and the module stays a require-free leaf.
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local Budgets = require("../packages/SceneKit/Budgets")
local Lighting = require("../packages/SceneKit/Lighting")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local EXPECTED_IDS = {
	"blue_hour",
	"bright_noon",
	"dense_fog",
	"flat_capture",
	"golden_hour",
	"interior_cool",
	"interior_warm",
	"lookdev_contrast",
	"lookdev_neutral",
	"low_light",
	"night_clear",
	"overcast",
	"perf_low",
	"readability_max",
	"storm_dim",
}
local POST = { "bloom", "colorCorrection", "depthOfField", "sunRays", "colorGrading" }

local function place()
	local game = roblox.Instance.new("DataModel")
	local lighting = game:GetService("Lighting")
	local workspace = game:GetService("Workspace")
	local terrain = roblox.Instance.new("Terrain")
	terrain.Parent = workspace
	return game, lighting, workspace, terrain
end

local function mentions(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

-- Preset block over the engine defaults, as apply writes it.
local function expectedBlock(name: string, block: any): { [string]: any }
	local out = table.clone(Lighting.DEFAULTS[name])
	for key, value in block or {} do
		out[key] = value
	end
	if out.Enabled ~= nil then
		out.Enabled = true
	end
	return out
end

local function round(value: any): any
	if type(value) == "number" then
		return math.round(value * 1e4) / 1e4
	elseif type(value) == "table" then
		local out = {}
		for key, child in value do
			out[key] = round(child)
		end
		return out
	end
	return value
end

test("the 15 presets exist by function name, validate, carry intent and tags, and audit clean", function(t)
	t.eq(Lighting.list(), EXPECTED_IDS)
	for _, id in Lighting.list() do
		local preset = Lighting.get(id)
		t.eq(Lighting.validate(preset), {}, id)
		t.ok(type(preset.intent) == "string" and #preset.intent > 40, id .. " documents its intent")
		t.ok(#preset.tags > 0, id .. " has tags")
		t.eq(preset.id, id)
		-- Every preset covers each block the schema owns (DepthOfField stays off: Cinematics/Feel own it).
		for _, block in { "lighting", "atmosphere", "sky", "clouds", "wind" } do
			t.ok(preset[block] ~= nil, id .. " covers " .. block)
		end
		for _, block in { "bloom", "colorCorrection", "depthOfField", "sunRays" } do
			t.ok(preset.post[block] ~= nil, id .. " covers post." .. block)
		end
		t.eq(preset.post.depthOfField.Enabled, false, id .. " keeps depth of field off")
		t.eq(Lighting.audit(id), {}, id .. " audit")
		t.ok(table.isfrozen(preset) and table.isfrozen(preset.lighting), id .. " is frozen")
	end
	-- Per-device post budgets (SceneKit/Budgets): perf_low fits the weakest class.
	t.eq(Lighting.audit("perf_low", { postEffects = Budgets.CLASSES.phone_low.post_effects }), {})
	t.eq(Lighting.cost("perf_low").postEffects, 0)
	t.eq(Lighting.get("perf_low").requires, { LightingStyle = "Soft", PrioritizeLightingQuality = false })
	local warned = Lighting.audit("golden_hour", { postEffects = Budgets.CLASSES.phone_low.post_effects })
	t.ok(mentions(warned, "3 post effects over the device budget of 1"), table.concat(warned, "; "))
end)

test("schema 1 ids resolve and keep their Lighting and Atmosphere numbers", function(t)
	local schema1 = {
		["neutral-day"] = {
			lighting = { ClockTime = 14, Brightness = 2, ExposureCompensation = 0, Ambient = { 70, 70, 70 } },
			atmosphere = { Density = 0.3, Offset = 0.25, Haze = 0, Glare = 0 },
		},
		overcast = {
			lighting = {
				ClockTime = 13,
				Brightness = 1.2,
				ExposureCompensation = 0.2,
				Ambient = { 90, 90, 95 },
			},
			atmosphere = { Density = 0.45, Offset = 0.1, Haze = 2, Glare = 0 },
		},
		["golden-hour"] = {
			lighting = { ClockTime = 17.6, Brightness = 2.5, OutdoorAmbient = { 140, 115, 95 } },
			atmosphere = { Density = 0.35, Offset = 0.2, Haze = 1.5, Glare = 0.4 },
		},
		night = {
			lighting = {
				ClockTime = 0,
				Brightness = 0.5,
				ExposureCompensation = 0.5,
				OutdoorAmbient = { 50, 50, 75 },
			},
			atmosphere = { Density = 0.35, Offset = 0, Haze = 0.5, Glare = 0 },
		},
		["inspection-flat"] = {
			lighting = {
				ClockTime = 12,
				GlobalShadows = false,
				EnvironmentDiffuseScale = 0,
				Ambient = { 150, 150, 150 },
			},
			atmosphere = { Density = 0, Offset = 0, Haze = 0, Glare = 0 },
		},
	}
	for legacy, values in schema1 do
		local preset = Lighting.get(legacy)
		t.eq(preset.id, Lighting.LEGACY[legacy])
		for block, fields in values do
			for key, value in fields do
				t.eq(preset[block][key], value, legacy .. " " .. block .. "." .. key)
			end
		end
	end
	t.eq(Lighting.resolve("night"), "night_clear")
	t.eq(Lighting.resolve("missing"), nil)
	t.throws(function()
		Lighting.get("missing")
	end)
end)

test("validate rejects unknown keys, bad ranges, colours, enums, requires and wind", function(t)
	local function problems(mutate: (any) -> ()): { string }
		local preset = Lighting.copy("bright_noon")
		mutate(preset)
		return Lighting.validate(preset)
	end
	local function rejects(needle: string, mutate: (any) -> ())
		local found = problems(mutate)
		t.ok(mentions(found, needle), needle .. " -> " .. table.concat(found, "; "))
	end
	rejects("theme is not a preset key", function(p)
		p.theme = "x"
	end)
	rejects("lighting.Technology is not a lighting field", function(p)
		p.lighting.Technology = "Future"
	end)
	rejects("ExposureCompensation 6 outside -5..5", function(p)
		p.lighting.ExposureCompensation = 6
	end)
	rejects("ClockTime must be below 24", function(p)
		p.lighting.ClockTime = 24
	end)
	rejects("ClockTime must be a finite number", function(p)
		p.lighting.ClockTime = 0 / 0
	end)
	rejects("Ambient must be { r, g, b }", function(p)
		p.lighting.Ambient = { 10, 300, 10 }
	end)
	rejects("Color must be { r, g, b }", function(p)
		p.atmosphere.Color = { 1, 2 }
	end)
	rejects("Haze 11 outside 0..10 (convention)", function(p)
		p.atmosphere.Haze = 11
	end)
	rejects("StarCount must be a whole number", function(p)
		p.sky.StarCount = 10.5
	end)
	rejects("clouds.Cover 1.5 outside 0..1", function(p)
		p.clouds.Cover = 1.5
	end)
	rejects("sunRays.Spread 2 outside 0..1", function(p)
		p.post.sunRays.Spread = 2
	end)
	rejects("TonemapperPreset must be one of", function(p)
		p.post.colorGrading = { TonemapperPreset = "Vivid" }
	end)
	rejects("post.blur is not a post-processing block", function(p)
		p.post.blur = { Size = 4 }
	end)
	rejects("bloom.Enabled must be a boolean", function(p)
		p.post.bloom.Enabled = "yes"
	end)
	rejects("requires.LightingStyle must be Realistic or Soft", function(p)
		p.requires = { LightingStyle = "Future" }
	end)
	rejects("requires.Technology is not a checked Lighting setting", function(p)
		p.requires = { Technology = "Future" }
	end)
	rejects("wind.x must be finite within", function(p)
		p.wind = { x = 500, y = 0, z = 0 }
	end)
	rejects("wind.w is not x, y or z", function(p)
		p.wind = { w = 1 }
	end)
	rejects("tag Outdoor is not a label", function(p)
		p.tags = { "Outdoor" }
	end)
	t.eq(Lighting.validate(5), { "preset must be a table" })
	t.throws(function()
		Lighting.apply(
			roblox.Instance.new("DataModel"):GetService("Lighting"),
			{ lighting = { Brightness = -1 } },
			roblox
		)
	end, "apply refuses an invalid preset")
end)

test("blend: exact at t = 0 and 1, continuous between, ClockTime on the shortest arc", function(t)
	for _, pair in
		{ { "bright_noon", "night_clear" }, { "interior_warm", "storm_dim" }, { "perf_low", "golden_hour" } }
	do
		local a, b = pair[1], pair[2]
		t.eq(Lighting.blend(a, b, 0), Lighting.get(a), a .. " at t = 0")
		t.eq(Lighting.blend(a, b, 1), Lighting.get(b), b .. " at t = 1")
		t.eq(Lighting.blend(a, b, -3), Lighting.get(a), "t clamps below")
		t.eq(Lighting.blend(a, b, 7), Lighting.get(b), "t clamps above")
		for _, step in { 0.1, 0.5, 0.9 } do
			local mid = Lighting.blend(a, b, step)
			t.eq(Lighting.validate(mid), {}, a .. ">" .. b .. " at " .. step)
			t.eq(mid, Lighting.blend(a, b, step), "deterministic")
			t.eq(mid.blendOf, { from = a, to = b, t = step })
		end
	end
	local mid = Lighting.blend("bright_noon", "overcast", 0.5)
	t.near(mid.lighting.Brightness, (3 + 1.2) / 2, 1e-9)
	t.near(mid.lighting.Ambient[3], (45 + 95) / 2, 1e-9)
	t.near(mid.clouds.Cover, (0.45 + 0.9) / 2, 1e-9)
	t.eq(mid.sky.CelestialBodiesShown, false, "booleans switch at t >= 0.5")
	t.eq(Lighting.blend("bright_noon", "overcast", 0.49).sky.CelestialBodiesShown, true)
	-- A disabled block fades from zero effect: bright_noon has sun rays, overcast does not.
	t.near(mid.post.sunRays.Intensity, 0.06 / 2, 1e-9)
	t.eq(mid.post.sunRays.Enabled, true)
	-- night_clear (0) to blue_hour (18.4): the short way round is back through 21.2.
	local dusk = Lighting.blend("night_clear", "blue_hour", 0.5)
	t.near(dusk.lighting.ClockTime, 21.2, 1e-9)
	local custom = Lighting.copy("lookdev_neutral")
	custom.lighting.ClockTime = 23
	local other = Lighting.copy("lookdev_neutral")
	other.lighting.ClockTime = 1
	t.near(Lighting.blend(custom, other, 0.5).lighting.ClockTime, 0, 1e-9)
	t.near(Lighting.blend(custom, other, 0.25).lighting.ClockTime, 23.5, 1e-9)
	t.throws(function()
		Lighting.blend("bright_noon", "overcast", 0 / 0)
	end, "NaN t raises")
	t.throws(function()
		Lighting.blend({ lighting = { Brightness = 99 } }, "overcast", 0.5)
	end, "invalid endpoints raise")
end)

test("apply then inspect round-trips every preset on a Lune Lighting service", function(t)
	for _, id in Lighting.list() do
		local _, lighting, workspace, terrain = place()
		local preset = Lighting.get(id)
		local report = Lighting.apply(lighting, id, roblox)
		t.eq(report.preset, id)
		t.eq(report.conflicts, {}, id)
		t.eq(report.skipped, {}, id)
		local seen = Lighting.inspect(lighting)
		t.eq(seen.profile, id)
		t.eq(seen.lighting, round(expectedBlock("lighting", preset.lighting)), id .. " lighting")
		t.eq(seen.atmosphere, round(expectedBlock("atmosphere", preset.atmosphere)), id .. " atmosphere")
		t.eq(seen.sky, round(expectedBlock("sky", preset.sky)), id .. " sky")
		t.eq(seen.foreign, {}, id)
		for _, name in POST do
			local block = preset.post[name]
			if block == nil or block.Enabled == false then
				t.eq(seen.post[name], nil, id .. " " .. name .. " absent when disabled")
			else
				t.eq(seen.post[name], round(expectedBlock(name, block)), id .. " " .. name)
			end
		end
		if preset.clouds.Enabled == false then
			t.eq(seen.clouds, nil, id .. " clouds absent")
			t.eq(terrain:FindFirstChildOfClass("Clouds"), nil)
		else
			t.eq(seen.clouds, round(expectedBlock("clouds", preset.clouds)), id .. " clouds")
			t.eq(terrain:FindFirstChildOfClass("Clouds").Parent, terrain, "Clouds render only under Terrain")
		end
		t.eq(seen.wind, round(preset.wind), id .. " wind")
		t.eq(workspace.GlobalWind, roblox.Vector3.new(preset.wind.x, preset.wind.y, preset.wind.z))
		-- Owned instances are named and tagged, one per class.
		for _, child in lighting:GetChildren() do
			t.eq(child:GetAttribute("SceneKitOwned"), true, child.Name)
			t.eq(child.Name, "SceneKit" .. child.ClassName)
		end
	end
end)

test("requires_ok reports LightingStyle and PrioritizeLightingQuality, which scripts cannot set", function(t)
	local _, lighting = place()
	t.eq(Lighting.inspect(lighting).requires_ok, nil, "nothing applied yet")
	Lighting.apply(lighting, "bright_noon", roblox)
	-- Lune's default is Soft with quality off, so a Realistic preset is not satisfied.
	local seen = Lighting.inspect(lighting)
	t.eq(seen.requires.expected, { LightingStyle = "Realistic", PrioritizeLightingQuality = true })
	t.eq(seen.requires.actual, { LightingStyle = "Soft", PrioritizeLightingQuality = false })
	t.eq(seen.requires_ok, false)
	lighting.LightingStyle = roblox.Enum.LightingStyle.Realistic
	lighting.PrioritizeLightingQuality = true
	t.eq(Lighting.inspect(lighting).requires_ok, true, "the owner set them in Studio")
	Lighting.apply(lighting, "perf_low", roblox)
	t.eq(Lighting.inspect(lighting).requires_ok, false, "perf_low expects Soft")
	Lighting.apply(lighting, "flat_capture", roblox)
	t.eq(Lighting.inspect(lighting).requires_ok, nil, "flat_capture declares nothing")
	-- apply never writes them.
	t.eq(lighting.LightingStyle, roblox.Enum.LightingStyle.Realistic)
end)

test("apply is order independent and removes owned instances a preset disables", function(t)
	local _, fresh = place()
	Lighting.apply(fresh, "lookdev_neutral", roblox)
	local _, reused = place()
	Lighting.apply(reused, "golden_hour", roblox)
	t.ok(reused:FindFirstChild("SceneKitSunRaysEffect"), "golden_hour has sun rays")
	local report = Lighting.apply(reused, "lookdev_neutral", roblox)
	t.eq(Lighting.inspect(reused), Lighting.inspect(fresh))
	t.ok(table.find(report.removed, "SunRaysEffect") and table.find(report.removed, "BloomEffect"), "removed")
	t.eq(reused:FindFirstChild("SceneKitSunRaysEffect"), nil)
	-- Re-applying updates in place: no duplicates.
	Lighting.apply(reused, "golden_hour", roblox)
	local again = Lighting.apply(reused, "golden_hour", roblox)
	t.eq(again.created, {})
	local classes = {}
	for _, child in reused:GetChildren() do
		t.eq(classes[child.ClassName], nil, "one " .. child.ClassName)
		classes[child.ClassName] = true
	end
	-- A blended preset applies and is recorded as such.
	Lighting.apply(reused, Lighting.blend("golden_hour", "blue_hour", 0.25), roblox)
	t.eq(reused:GetAttribute("SceneKitLightingProfile"), "custom")
	t.eq(reused:GetAttribute("SceneKitLightingBlend"), "golden_hour>blue_hour@0.250")
end)

test("foreign instances are reported, never edited; adopt takes them over", function(t)
	local _, lighting = place()
	local atmosphere = roblox.Instance.new("Atmosphere")
	atmosphere.Name = "PlaceAtmosphere"
	atmosphere.Density = 0.9
	atmosphere.Parent = lighting
	local bloom = roblox.Instance.new("BloomEffect")
	bloom.Name = "PlaceBloom"
	bloom.Intensity = 1
	bloom.Parent = lighting
	local grading = roblox.Instance.new("ColorGradingEffect")
	grading.Name = "PlaceGrading"
	grading.Parent = lighting
	local custom = Lighting.copy("golden_hour")
	custom.post.colorGrading = { Enabled = true, TonemapperPreset = "Retro" }
	local report = Lighting.apply(lighting, custom, roblox)
	t.ok(
		mentions(report.conflicts, "Atmosphere: non-owned PlaceAtmosphere"),
		table.concat(report.conflicts, "; ")
	)
	t.ok(mentions(report.conflicts, "ColorGradingEffect: non-owned PlaceGrading"), "only one grading applies")
	t.eq(report.stacked, { "BloomEffect PlaceBloom" })
	t.near(atmosphere.Density, 0.9, 1e-6, "foreign atmosphere untouched")
	t.near(bloom.Intensity, 1, 1e-6, "foreign bloom untouched")
	t.eq(lighting:FindFirstChild("SceneKitAtmosphere"), nil, "no second atmosphere")
	t.ok(lighting:FindFirstChild("SceneKitBloomEffect"), "owned bloom created beside the foreign one")
	local seen = Lighting.inspect(lighting)
	t.eq(
		seen.foreign,
		{ "Atmosphere PlaceAtmosphere", "BloomEffect PlaceBloom", "ColorGradingEffect PlaceGrading" }
	)
	local adopted = Lighting.apply(lighting, custom, roblox, { adopt = true })
	t.ok(table.find(adopted.adopted, "Atmosphere PlaceAtmosphere"), table.concat(adopted.adopted, "; "))
	t.ok(table.find(adopted.adopted, "ColorGradingEffect PlaceGrading"))
	t.near(atmosphere.Density, 0.35, 1e-6, "adopted atmosphere now follows the preset")
	t.eq(grading.TonemapperPreset, roblox.Enum.TonemapperPreset.Retro)
end)

test("without Terrain or Workspace, clouds and wind are skipped and listed", function(t)
	local game = roblox.Instance.new("DataModel")
	local lighting = game:GetService("Lighting")
	local report = Lighting.apply(lighting, "storm_dim", roblox)
	t.eq(report.skipped, { "clouds (no Terrain)", "wind (no Workspace)" })
	t.ok(lighting:FindFirstChildOfClass("Atmosphere"))
	-- A GameKit-style env with .roblox works too.
	local ok = pcall(Lighting.apply, lighting, "overcast", { roblox = roblox })
	t.ok(ok, "env.roblox is accepted")
end)

test("preview hints: sun overhead at noon on the equator, below the horizon at midnight", function(t)
	local noon = Lighting.sunDirection(12, 0)
	t.near(noon.y, 1, 1e-9)
	local six = Lighting.sunDirection(6, 0)
	t.near(six.y, 0, 1e-9)
	t.near(math.abs(six.x), 1, 1e-9)
	t.ok(Lighting.sunDirection(0, 41.7).y < 0)
	local night = Lighting.preview("night_clear")
	t.eq(night.sun.strength, 0)
	local day = Lighting.preview("bright_noon")
	t.ok(day.sun.strength > 2, "noon sun is strong")
	t.ok(day.fog.density > 0)
	t.eq(Lighting.preview("flat_capture").sun.shadows, false)
end)

test("audit flags readability, persistent depth of field and aggressive bloom", function(t)
	local dark = Lighting.copy("low_light")
	dark.tags = { "interior" }
	t.ok(mentions(Lighting.audit(dark), "readability floor"), "dark without local_lights")
	local dof = Lighting.copy("bright_noon")
	dof.post.depthOfField = { Enabled = true, FarIntensity = 0.2 }
	t.ok(mentions(Lighting.audit(dof), "DepthOfField enabled in a persistent preset"))
	local glow = Lighting.copy("bright_noon")
	glow.post.bloom.Threshold = 0.5
	glow.post.sunRays.Intensity = 0.6
	glow.atmosphere.Haze = 0
	local warnings = Lighting.audit(glow)
	t.ok(mentions(warnings, "Bloom.Threshold below 0.8"), table.concat(warnings, "; "))
	t.ok(mentions(warnings, "SunRays.Intensity above 0.25"))
	t.ok(mentions(warnings, "Glare has no effect without Haze"))
	local clamped = Lighting.copy("lookdev_neutral")
	clamped.lighting.OutdoorAmbient = { 10, 200, 200 }
	t.ok(mentions(Lighting.audit(clamped), "engine clamps it up to Ambient"))
end)

test("the module is a leaf: no requires, and kits may require it", function(t)
	local source = fs.readFile(ROOT .. "/packages/SceneKit/Lighting.luau")
	for line in string.gmatch(source, "[^\n]+") do
		local code = string.gsub(line, "%-%-.*$", "")
		t.ok(
			not string.find(code, "require%s*%(") and not string.find(code, 'require%s*"'),
			"requires: " .. line
		)
		t.ok(not string.find(code, "GetService", 1, true), "GetService: " .. line)
	end
end)

return cases
