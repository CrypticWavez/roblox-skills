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

local function world(isClient: boolean)
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
		place = { isStudio = true, gameId = 0, placeId = 0, isServer = not isClient, isClient = isClient },
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

local function run(env: any, only: { string }): (any, { string })
	local lines = {}
	local summary
	env.spawn(function()
		summary = Probe.runAll(registry, {
			env = env,
			kit = kitLoader,
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
