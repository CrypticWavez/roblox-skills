--!strict
-- The G5 probe registry (fixtures/kits/shared/lookdev_probes.luau) runs against FakeEnv on an
-- @lune/roblox DataModel, with env.engineOverrides standing in for the engine methods Lune
-- lacks. This proves the probes load and their logic holds against fakes; it is not Studio
-- evidence (the probes stay pending until a Studio run prints their ENGINE_DONE line).
local roblox = require("@lune/roblox")
local FakeEnv = require("./fakes/FakeEnv")
local Probe = require("../packages/GameKit/Probe")
local registry = require("../fixtures/kits/shared/lookdev_probes")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

-- Lune's require can yield, and a yield inside a FakeEnv thread would park it for good, so the
-- kit modules the probes load are required up front and served from this table.
local KITS = {
	["AVKit/AudioGraphRoblox"] = require("../packages/AVKit/AudioGraphRoblox"),
	["AVKit/VfxLibrary"] = require("../packages/AVKit/VfxLibrary"),
	["AVKit/VfxPoolRoblox"] = require("../packages/AVKit/VfxPoolRoblox"),
	["Feel/FeelRoblox"] = require("../packages/Feel/FeelRoblox"),
	["GameKit/Env"] = require("../packages/GameKit/Env"),
	["GameKit/WorldCycle"] = require("../packages/GameKit/WorldCycle"),
	["SceneKit/Lighting"] = require("../packages/SceneKit/Lighting"),
	["SceneKit/Materials"] = require("../packages/SceneKit/Materials"),
}

local function kitLoader(path: string): any
	local module = KITS[path]
	assert(module ~= nil, "avkit_probes: add " .. path .. " to KITS")
	return module
end

local function fakeTrack(env: any)
	local handlers: { [string]: any } = {}
	local track: any = { Speed = 1 }
	function track:GetMarkerReachedSignal(name: string)
		return {
			Connect = function(_signal: any, fn: any)
				handlers[name] = fn
				return { Disconnect = function() end }
			end,
		}
	end
	function track:AdjustSpeed(speed: number)
		self.Speed = speed
	end
	function track:Play()
		env.spawn(function()
			env.wait(0.2)
			if handlers.Hit then
				handlers.Hit("probe")
			end
		end)
	end
	return track
end

local function world(isClient: boolean, place: any?)
	local game = roblox.Instance.new("DataModel")
	local workspace = game:GetService("Workspace")
	local terrain = roblox.Instance.new("Terrain")
	terrain.Parent = workspace
	local camera = roblox.Instance.new("Camera")
	camera.Parent = workspace
	workspace.CurrentCamera = camera
	local env = FakeEnv.new({
		seed = "lookdev",
		roblox = roblox,
		place = place
			or { isStudio = true, gameId = 0, placeId = 0, isServer = not isClient, isClient = isClient },
	})
	env:register("Workspace", workspace)
	env:register("Lighting", game:GetService("Lighting"))
	env:register("SoundService", game:GetService("SoundService"))
	local materialService = game:GetService("MaterialService")
	env:register("MaterialService", materialService)
	env:register("KeyframeSequenceProvider", {
		RegisterKeyframeSequence = function(_self: any, _sequence: any): string
			return "probe-temporary-sequence"
		end,
	})
	local overridesSet: { [string]: string } = {}
	local playing: { [any]: boolean } = {}
	env.engineOverrides = {
		vfx = {
			pivot = function() end,
			emit = function() end,
			clear = function() end,
			adorn = function() end,
			cframeOf = function()
				return roblox.CFrame.new()
			end,
		},
		audio = {
			play = function(player: any)
				playing[player] = true
			end,
			stop = function(player: any)
				playing[player] = nil
			end,
			isPlaying = function(player: any): boolean
				return playing[player] == true
			end,
			mixerTime = function(): number
				return env.clock()
			end,
			levels = function(): (number, number)
				return if next(playing) then 0.3 else 0, 0.1
			end,
			connected = function(wire: any): boolean
				return wire.SourceInstance ~= nil and wire.TargetInstance ~= nil
			end,
		},
		feel = {
			now = function(): number
				return env.clock()
			end,
			haptic = function() end,
		},
		loadTrack = function(): any
			return fakeTrack(env)
		end,
		serverTime = function(): number
			return 12345
		end,
		materialApi = {
			FindFirstChild = function(_self: any, name: string): any
				return materialService:FindFirstChild(name)
			end,
			SetBaseMaterialOverride = function(_self: any, material: any, name: string)
				overridesSet[tostring(material)] = name
			end,
			GetBaseMaterialOverride = function(_self: any, material: any): string
				return overridesSet[tostring(material)] or ""
			end,
		},
	}
	env.lookdevAudioContent = "rbxasset://sounds/probe.ogg"
	return env, game
end

local function run(env: any, only: { string }?, loader: ((path: string) -> any)?): (any, { string })
	local lines = {}
	local summary
	env.spawn(function()
		summary = Probe.runAll(registry, {
			env = env,
			kit = loader or kitLoader,
			only = only,
			emit = function(line: string)
				table.insert(lines, line)
			end,
		})
	end)
	for _ = 1, 80 do
		env:flush()
		env:advance(0.05)
	end
	return summary, lines
end

test("every registered probe has the G5 prefixes and a Studio runner or registry entry", function(t)
	local names = {}
	for name in registry do
		table.insert(names, name)
		t.ok(Probe.validName(name), name)
		local prefixed = string.match(name, "^lookdev_")
			or string.match(name, "^av_")
			or string.match(name, "^feel_")
			or string.match(name, "^worldcycle_")
		t.ok(prefixed, name .. " prefix")
	end
	table.sort(names)
	t.eq(names, {
		"av_audio_master_level",
		"av_audiograph_wires",
		"av_lighting_presets",
		"av_vfx_grid",
		"feel_marker_cue",
		"lookdev_material_override",
		"worldcycle_phases",
	})
end)

for _, name in
	{
		"av_lighting_presets",
		"av_vfx_grid",
		"av_audiograph_wires",
		"av_audio_master_level",
		"feel_marker_cue",
		"worldcycle_phases",
		"lookdev_material_override",
	}
do
	test(name .. " passes against FakeEnv with Lune engine overrides", function(t)
		local env = world(true)
		local summary, lines = run(env, { name })
		t.ok(summary ~= nil, "probe finished: " .. table.concat(env.errors, "; "))
		t.eq(summary.failed, 0, table.concat(lines, "\n"))
		t.eq(summary.errors, 0, table.concat(lines, "\n"))
		t.ok(summary.checks >= 2, "checks " .. summary.checks)
		t.ok(string.find(lines[#lines], "ENGINE_DONE ", 1, true) == 1)
	end)
end

local function errorLines(lines: { string }): { string }
	local out = {}
	for _, line in lines do
		if string.find(line, '"check":"error"', 1, true) then
			table.insert(out, line)
		end
	end
	return out
end

-- Every child name under the services the probes build in.
local function built(env: any): { string }
	local names = {}
	for _, service in { "Workspace", "SoundService", "MaterialService", "Lighting" } do
		for _, child in env.services[service]:GetChildren() do
			table.insert(names, service .. "." .. child.Name)
		end
	end
	table.sort(names)
	return names
end

test("every lookdev probe refuses a published place before it changes anything", function(t)
	local published = { isStudio = true, gameId = 4242, placeId = 99, isServer = false, isClient = true }
	local env = world(true, published)
	local before = built(env)
	local summary, lines = run(env, nil)
	t.eq(summary.errors, 7, table.concat(lines, "\n"))
	t.eq(summary.passed, 0, "no check ran on a published place")
	for _, line in errorLines(lines) do
		t.ok(string.find(line, "diagnostic places only", 1, true) ~= nil, line)
	end
	t.eq(built(env), before, "nothing built or removed")
	t.eq(env.services.Lighting:GetAttributes(), {}, "Lighting untouched")
end)

test("the lookdev probes leave nothing behind and restore Lighting and the Sand override", function(t)
	local env = world(true)
	local Lighting = KITS["SceneKit/Lighting"]
	local lighting = env.services.Lighting
	-- the place's own look: a preset, a hand edit, a foreign attribute and an override
	Lighting.apply(lighting, "night_clear", env)
	lighting.ClockTime = 9.25
	lighting:SetAttribute("PlaceNote", "keep")
	local ownedBefore = {}
	for _, child in lighting:GetChildren() do
		table.insert(ownedBefore, child)
	end
	local api = env.engineOverrides.materialApi
	api:SetBaseMaterialOverride(roblox.Enum.Material.Sand, "place_sand")
	local inspected = Lighting.inspect(lighting)
	local attributes = lighting:GetAttributes()
	local before = built(env)
	local summary, lines = run(env, nil)
	t.eq(summary.failed + summary.errors, 0, table.concat(lines, "\n"))
	t.eq(built(env), before, "probe instances removed, the place's own put back")
	t.eq(Lighting.inspect(lighting), inspected)
	t.eq(lighting:GetAttributes(), attributes)
	t.eq(lighting.ClockTime, 9.25)
	for _, child in ownedBefore do
		t.eq(child.Parent, lighting, "the same instance is back: " .. child.Name)
	end
	t.eq(api:GetBaseMaterialOverride(roblox.Enum.Material.Sand), "place_sand")
end)

test("a lookdev probe that raises still restores Lighting", function(t)
	local env = world(true)
	local Lighting = KITS["SceneKit/Lighting"]
	local lighting = env.services.Lighting
	Lighting.apply(lighting, "golden_hour", env)
	local inspected = Lighting.inspect(lighting)
	local overcast = 0
	local shim = setmetatable({
		apply = function(target: any, id: any, ...: any): any
			if id == "overcast" then
				overcast += 1
				if overcast == 2 then
					error("apply exploded")
				end
			end
			return Lighting.apply(target, id, ...)
		end,
	}, { __index = Lighting })
	local summary, lines = run(env, { "av_lighting_presets" }, function(path: string): any
		return if path == "SceneKit/Lighting" then shim else kitLoader(path)
	end)
	t.eq(summary.errors, 1, table.concat(lines, "\n"))
	t.ok(string.find(table.concat(errorLines(lines), "\n"), "apply exploded", 1, true) ~= nil)
	t.eq(Lighting.inspect(lighting), inspected)
end)

test("client-side probes fail honestly on the server", function(t)
	local env = world(false)
	local summary, lines = run(env, { "av_audiograph_wires" })
	t.eq(summary.failed, 1, table.concat(lines, "\n"))
	t.ok(string.find(lines[1], '"check":"client_side"', 1, true) ~= nil, lines[1])
end)

test("the material probe reports a missing variant instead of passing", function(t)
	local env = world(true)
	env.engineOverrides.materialApi.FindFirstChild = function()
		return nil
	end
	local summary = run(env, { "lookdev_material_override" })
	t.ok(summary.failed >= 1)
end)

return cases
