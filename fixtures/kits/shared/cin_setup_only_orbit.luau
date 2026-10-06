--!strict
-- Neutral cinematics/1 fixture (G4): a camera orbit around the origin for the kits diagnostic
-- place and the Lune golden (tests/golden/cinematics-orbit.json). No content: the target is the
-- world origin, subtitles are placeholder keys and events carry no game meaning. No requires
-- (fixtures load in Studio from ReplicatedStorage.KitFixtures and in Lune by path).
local RADIUS = 30
local keys = {}
for index = 0, 8 do
	local angle = math.rad(index * 45)
	table.insert(keys, {
		t = index,
		position = {
			math.floor(math.sin(angle) * RADIUS * 1000 + 0.5) / 1000,
			12 - index * 0.5,
			math.floor(-math.cos(angle) * RADIUS * 1000 + 0.5) / 1000,
		},
		lookAt = { 0, 4, 0 },
		fov = 70 - index * 2,
		ease = if index == 0 then "Sine.Out" elseif index == 7 then "Sine.In" else nil,
	})
end

return {
	schema = "cinematics/1",
	id = "setup_only_orbit",
	duration = 8,
	space = "anchor",
	camera = { interpolation = "catmull_rom", timing = "keys", keys = keys },
	letterbox = {
		{ t = 0, v = 0 },
		{ t = 0.6, v = 0.12, ease = "Quad.Out" },
		{ t = 7.2, v = 0.12 },
		{ t = 8, v = 0, ease = "Quad.In" },
	},
	fades = {
		{ t = 0, v = 1 },
		{ t = 0.5, v = 0, ease = "Quad.Out" },
		{ t = 7.4, v = 0 },
		{ t = 8, v = 1, ease = "Quad.In" },
	},
	subtitles = {
		{ t = 1, duration = 2.5, key = "cin.setup_only.caption_1" },
		{ t = 4, duration = 2.5, key = "cin.setup_only.caption_2" },
	},
	events = {
		{ t = 0, name = "started", onSkip = "drop" },
		{ t = 4, name = "midpoint", payload = { lap = 0.5 }, onSkip = "drop" },
		{ t = 8, name = "done", onSkip = "fire" },
	},
	skip = { allowed = true, after = 0.75, hold = 0.5 },
}
