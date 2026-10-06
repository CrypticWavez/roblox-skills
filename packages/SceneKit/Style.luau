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
			-- course roles (ProcGen CourseScene)
			platform = "SmoothPlastic",
			checkpoint = "SmoothPlastic",
			spawn = "SmoothPlastic",
			finish = "SmoothPlastic",
			hazard = "Neon",
			structure = "SmoothPlastic",
			track = "SmoothPlastic",
			gate = "SmoothPlastic",
			lane = "SmoothPlastic",
			slot = "SmoothPlastic",
			ground = "SmoothPlastic",
			cover = "SmoothPlastic",
			barrier = "SmoothPlastic",
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
			-- course roles (ProcGen CourseScene)
			platform = { 175, 175, 180 },
			checkpoint = { 90, 160, 230 },
			spawn = { 90, 190, 120 },
			finish = { 235, 195, 70 },
			hazard = { 220, 75, 65 },
			structure = { 125, 125, 130 },
			track = { 85, 85, 90 },
			gate = { 235, 235, 235 },
			lane = { 190, 175, 145 },
			slot = { 120, 150, 205 },
			ground = { 125, 140, 115 },
			cover = { 150, 150, 165 },
			barrier = { 200, 200, 200 },
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
			-- course roles (ProcGen CourseScene)
			platform = "Concrete",
			checkpoint = "Concrete",
			spawn = "Concrete",
			finish = "Concrete",
			hazard = "Neon",
			structure = "Brick",
			track = "Asphalt",
			gate = "Metal",
			lane = "Cobblestone",
			slot = "Slate",
			ground = "Grass",
			cover = "Brick",
			barrier = "Concrete",
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
			-- course roles (ProcGen CourseScene)
			platform = { 170, 165, 155 },
			checkpoint = { 95, 150, 210 },
			spawn = { 100, 175, 120 },
			finish = { 225, 190, 80 },
			hazard = { 210, 80, 65 },
			structure = { 176, 160, 140 },
			track = { 80, 80, 85 },
			gate = { 205, 200, 190 },
			lane = { 150, 140, 125 },
			slot = { 110, 120, 150 },
			ground = { 105, 135, 85 },
			cover = { 160, 150, 135 },
			barrier = { 205, 200, 190 },
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
			-- course roles (ProcGen CourseScene)
			platform = "WoodPlanks",
			checkpoint = "WoodPlanks",
			spawn = "WoodPlanks",
			finish = "WoodPlanks",
			hazard = "Neon",
			structure = "Wood",
			track = "Ground",
			gate = "Wood",
			lane = "Ground",
			slot = "WoodPlanks",
			ground = "LeafyGrass",
			cover = "Wood",
			barrier = "Wood",
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
			-- course roles (ProcGen CourseScene)
			platform = { 150, 115, 80 },
			checkpoint = { 95, 145, 200 },
			spawn = { 105, 165, 105 },
			finish = { 215, 180, 80 },
			hazard = { 205, 85, 60 },
			structure = { 110, 80, 55 },
			track = { 110, 95, 75 },
			gate = { 90, 65, 45 },
			lane = { 140, 115, 85 },
			slot = { 105, 115, 140 },
			ground = { 80, 130, 70 },
			cover = { 120, 90, 60 },
			barrier = { 105, 80, 55 },
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
