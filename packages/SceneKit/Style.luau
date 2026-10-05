--!strict
-- Neutral style profiles for fixtures and greyboxes. Production art direction belongs in a
-- game repository; these exist so authoring code never hard-codes colours or materials.
local Style = {}

export type Profile = {
	id: string,
	materials: { [string]: string }, -- role -> Enum.Material name
	colors: { [string]: { number } }, -- role -> {r, g, b} 0..255
	trim: boolean,
	windowTransparency: number,
}

local PROFILES: { [string]: Profile } = {
	greybox = {
		id = "greybox",
		materials = {
			wall = "SmoothPlastic",
			floor = "SmoothPlastic",
			roof = "SmoothPlastic",
			trim = "SmoothPlastic",
			stair = "SmoothPlastic",
			glass = "Glass",
			prop = "SmoothPlastic",
			foliage = "SmoothPlastic",
			trunk = "SmoothPlastic",
			road = "SmoothPlastic",
			fence = "SmoothPlastic",
			foundation = "SmoothPlastic",
		},
		colors = {
			wall = { 200, 200, 200 },
			floor = { 150, 150, 150 },
			roof = { 110, 110, 120 },
			trim = { 90, 90, 90 },
			stair = { 170, 170, 170 },
			glass = { 160, 200, 230 },
			prop = { 230, 180, 60 },
			foliage = { 90, 160, 90 },
			trunk = { 110, 85, 60 },
			road = { 70, 70, 75 },
			fence = { 120, 100, 80 },
			foundation = { 120, 120, 120 },
		},
		trim = false,
		windowTransparency = 0.6,
	},
	["neutral-stone"] = {
		id = "neutral-stone",
		materials = {
			wall = "Brick",
			floor = "WoodPlanks",
			roof = "Slate",
			trim = "Concrete",
			stair = "Concrete",
			glass = "Glass",
			prop = "Wood",
			foliage = "Grass",
			trunk = "Wood",
			road = "Cobblestone",
			fence = "Wood",
			foundation = "Cobblestone",
		},
		colors = {
			wall = { 176, 160, 140 },
			floor = { 140, 105, 75 },
			roof = { 85, 80, 90 },
			trim = { 205, 200, 190 },
			stair = { 160, 155, 150 },
			glass = { 170, 205, 225 },
			prop = { 150, 110, 70 },
			foliage = { 85, 130, 70 },
			trunk = { 95, 70, 50 },
			road = { 120, 115, 110 },
			fence = { 120, 95, 70 },
			foundation = { 110, 105, 100 },
		},
		trim = true,
		windowTransparency = 0.5,
	},
	["neutral-timber"] = {
		id = "neutral-timber",
		materials = {
			wall = "WoodPlanks",
			floor = "WoodPlanks",
			roof = "WoodPlanks",
			trim = "Wood",
			stair = "Wood",
			glass = "Glass",
			prop = "Wood",
			foliage = "LeafyGrass",
			trunk = "Wood",
			road = "Ground",
			fence = "Wood",
			foundation = "Rock",
		},
		colors = {
			wall = { 160, 120, 85 },
			floor = { 120, 90, 60 },
			roof = { 90, 60, 45 },
			trim = { 70, 50, 35 },
			stair = { 130, 95, 65 },
			glass = { 180, 210, 220 },
			prop = { 140, 100, 60 },
			foliage = { 80, 140, 70 },
			trunk = { 90, 65, 45 },
			road = { 125, 100, 75 },
			fence = { 105, 80, 55 },
			foundation = { 105, 100, 95 },
		},
		trim = true,
		windowTransparency = 0.5,
	},
}

function Style.get(id: string?): Profile
	local profile = PROFILES[id or "greybox"]
	assert(profile, "unknown style profile " .. tostring(id))
	return profile
end

function Style.list(): { string }
	local ids = {}
	for id in PROFILES do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

return Style
