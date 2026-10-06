--!strict
-- Preset digests (golden tests/golden/av-presets.json): every shipped look, sound and feel preset
-- table is pinned, so a changed value is an intended change (rerun with
-- FACTORY_UPDATE_GOLDEN=av-presets or python3 tools/check.py --update-golden=av-presets) and
-- never a silent one. Also checks that ids stay function-named labels and that digests are
-- stable across two reads.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local AudioCues = require("../packages/AVKit/AudioCues")
local AudioGraph = require("../packages/AVKit/AudioGraph")
local Budgets = require("../packages/SceneKit/Budgets")
local Cues = require("../packages/Feel/Cues")
local Golden = require("./lib/Golden")
local Lighting = require("../packages/SceneKit/Lighting")
local Popups = require("../packages/Feel/Popups")
local Shake = require("../packages/Feel/Shake")
local VfxLibrary = require("../packages/AVKit/VfxLibrary")
local WorldCycle = require("../packages/GameKit/WorldCycle")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."

local function digests(map: { [string]: any }): { [string]: string }
	local out = {}
	for id, value in map do
		out[id] = Golden.digest(value)
	end
	return out
end

local function snapshot(): any
	local lighting = {}
	for _, id in Lighting.list() do
		lighting[id] = Golden.digest(Lighting.get(id))
	end
	local library = serde.decode("json", fs.readFile(ROOT .. "/assets/material-library.json"))
	local materials = {}
	for _, material in library.materials do
		materials[material.name] = Golden.digest(material)
	end
	return {
		schema = "av-presets/1",
		lighting = lighting,
		vfx = digests(VfxLibrary.all()),
		audio_graph = Golden.digest(AudioGraph.default()),
		audio_cues = digests(AudioCues.defaults()),
		feel_cues = digests(Cues.defaults()),
		shake = Golden.digest(Shake.PRESETS),
		shake_defaults = Golden.digest(Shake.DEFAULTS),
		popups = Golden.digest(Popups.DEFAULTS),
		world_cycle = Golden.digest(WorldCycle.DEFAULT),
		perf_budgets = Golden.digest(Budgets.document()),
		materials = materials,
	}
end

test("preset digests match tests/golden/av-presets.json", function(t)
	local first = snapshot()
	t.eq(snapshot(), first, "digests are stable")
	Golden.assert("av-presets", first)
end)

test("preset ids are function-named labels", function(t)
	local function labels(ids: { string })
		for _, id in ids do
			t.ok(string.match(id, "^[a-z][a-z0-9_]*$") ~= nil and #id <= 64, id)
		end
	end
	labels(Lighting.list())
	labels(VfxLibrary.list())
	local cueIds = {}
	for id in AudioCues.defaults() do
		table.insert(cueIds, id)
	end
	labels(cueIds)
	t.eq(#Lighting.list(), 15)
	t.eq(#VfxLibrary.list(), 21)
end)

test("every VFX preset sound and every Feel cue id resolves to a shipped preset", function(t)
	local cues = AudioCues.defaults()
	for _, id in VfxLibrary.list() do
		local sound = VfxLibrary.get(id).sound
		t.ok(sound == nil or cues[sound] ~= nil, id .. " sound " .. tostring(sound))
	end
	t.eq(Cues.validate(Cues.defaults(), { vfx = VfxLibrary.all(), sounds = cues }), {})
	t.eq(AudioCues.validate(cues, AudioGraph.default()), {})
end)

return cases
