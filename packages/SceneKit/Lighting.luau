--!strict
-- Neutral lighting profiles for fixtures and visual QA captures. Values are plain data so
-- they can be diffed; apply() writes them onto the Lighting service (and an Atmosphere).
local LightingProfiles = {}

local PROFILES = {
	["neutral-day"] = {
		lighting = {
			ClockTime = 14,
			Brightness = 2,
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 1,
			ExposureCompensation = 0,
			GlobalShadows = true,
			Ambient = { 70, 70, 70 },
			OutdoorAmbient = { 128, 128, 128 },
		},
		atmosphere = { Density = 0.3, Offset = 0.25, Haze = 0, Glare = 0 },
	},
	overcast = {
		lighting = {
			ClockTime = 13,
			Brightness = 1.2,
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 0.5,
			ExposureCompensation = 0.2,
			GlobalShadows = true,
			Ambient = { 90, 90, 95 },
			OutdoorAmbient = { 140, 140, 145 },
		},
		atmosphere = { Density = 0.45, Offset = 0.1, Haze = 2, Glare = 0 },
	},
	["golden-hour"] = {
		lighting = {
			ClockTime = 17.6,
			Brightness = 2.5,
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 1,
			ExposureCompensation = 0,
			GlobalShadows = true,
			Ambient = { 60, 50, 45 },
			OutdoorAmbient = { 140, 115, 95 },
		},
		atmosphere = { Density = 0.35, Offset = 0.2, Haze = 1.5, Glare = 0.4 },
	},
	night = {
		lighting = {
			ClockTime = 0,
			Brightness = 0.5,
			EnvironmentDiffuseScale = 0.5,
			EnvironmentSpecularScale = 0.5,
			ExposureCompensation = 0.5,
			GlobalShadows = true,
			Ambient = { 25, 25, 40 },
			OutdoorAmbient = { 50, 50, 75 },
		},
		atmosphere = { Density = 0.35, Offset = 0, Haze = 0.5, Glare = 0 },
	},
	["inspection-flat"] = {
		lighting = {
			ClockTime = 12,
			Brightness = 1,
			EnvironmentDiffuseScale = 0,
			EnvironmentSpecularScale = 0,
			ExposureCompensation = 0,
			GlobalShadows = false,
			Ambient = { 150, 150, 150 },
			OutdoorAmbient = { 150, 150, 150 },
		},
		atmosphere = { Density = 0, Offset = 0, Haze = 0, Glare = 0 },
	},
}

function LightingProfiles.get(id: string)
	local profile = (PROFILES :: any)[id]
	assert(profile, "unknown lighting profile " .. id)
	return profile
end

function LightingProfiles.list(): { string }
	local ids = {}
	for id in PROFILES do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- env supplies Color3/Instance when running outside Roblox (Lune).
function LightingProfiles.apply(lighting: any, id: string, env: any?)
	local e = env or { Color3 = Color3 :: any, Instance = Instance :: any }
	local profile = LightingProfiles.get(id)
	for key, value in profile.lighting do
		lighting[key] = if type(value) == "table"
			then e.Color3.fromRGB(value[1], value[2], value[3])
			else value
	end
	local atmosphere = lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere == nil then
		atmosphere = e.Instance.new("Atmosphere")
		atmosphere.Parent = lighting
	end
	for key, value in profile.atmosphere do
		atmosphere[key] = value
	end
	lighting:SetAttribute("SceneKitLightingProfile", id)
end

function LightingProfiles.inspect(lighting: any): { [string]: any }
	local result = { profile = lighting:GetAttribute("SceneKitLightingProfile") }
	for key in PROFILES["neutral-day"].lighting do
		local value = lighting[key]
		result[key] = if typeof(value) == "Color3"
			then { math.round(value.R * 255), math.round(value.G * 255), math.round(value.B * 255) }
			else value
	end
	return result
end

return LightingProfiles
