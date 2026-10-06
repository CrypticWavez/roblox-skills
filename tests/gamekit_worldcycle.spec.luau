--!strict
-- GameKit/WorldCycle: the server-time clock, phase lookup with wrap-around, blend windows
-- between Lighting presets, the weather overlay ramp, the apply rate limit, validation
-- failures, and apply onto an @lune/roblox Lighting service.
local roblox = require("@lune/roblox")
local Lighting = require("../packages/SceneKit/Lighting")
local WorldCycle = require("../packages/GameKit/WorldCycle")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(list: { string }, needle: string): boolean
	for _, text in list do
		if string.find(text, needle, 1, true) then
			return true
		end
	end
	return false
end

local DAY = WorldCycle.DEFAULT.dayLength

local function at(hour: number): number
	return hour / 24 * DAY
end

test("the default config validates and every phase preset exists", function(t)
	t.eq(WorldCycle.validate(WorldCycle.DEFAULT), {})
	for _, phase in WorldCycle.DEFAULT.phases do
		t.ok(Lighting.resolve(phase.preset), phase.preset)
	end
end)

test("the clock follows server time and wraps each day", function(t)
	t.near(WorldCycle.clock(0, WorldCycle.DEFAULT), 0)
	t.near(WorldCycle.clock(at(6), WorldCycle.DEFAULT), 6)
	t.near(WorldCycle.clock(DAY + at(13), WorldCycle.DEFAULT), 13)
	local shifted = table.clone(WorldCycle.DEFAULT) :: any
	shifted.offset = at(2)
	t.near(WorldCycle.clock(at(23), shifted), 1)
end)

test("phases hold their preset and blend into the next inside the window", function(t)
	local noon = WorldCycle.state(at(12), WorldCycle.DEFAULT)
	t.eq(noon.phase, "day")
	t.eq(noon.t, 0)
	t.eq(noon.preset.id, "bright_noon")
	t.near(noon.preset.lighting.ClockTime, 12)
	-- 17:00 - 0.375 h is halfway through the 0.75 h window before evening
	local blend = WorldCycle.state(at(17 - 0.375), WorldCycle.DEFAULT)
	t.eq(blend.phase, "day")
	t.eq(blend.next, "evening")
	t.near(blend.t, 0.5)
	t.eq(blend.preset.blendOf.from, "bright_noon")
	t.eq(blend.preset.blendOf.to, "golden_hour")
	t.near(blend.preset.lighting.ClockTime, 17 - 0.375, 1e-9, "ClockTime follows the clock, not the blend")
	local expected = Lighting.blend("bright_noon", "golden_hour", 0.5)
	t.near(blend.preset.lighting.Brightness, expected.lighting.Brightness)
	-- wrap: just before midnight the late_night phase blends into night
	local late = WorldCycle.state(at(23.9), WorldCycle.DEFAULT)
	t.eq(late.phase, "late_night")
	t.eq(late.next, "night")
	t.ok(late.t > 0)
	t.eq(WorldCycle.state(at(3), WorldCycle.DEFAULT).phase, "night")
end)

test("a weather overlay ramps in over seconds and blends on top of the phase", function(t)
	local cycle = WorldCycle.new()
	local start = at(12)
	cycle:setWeather("storm_dim", 1, 10, start)
	local half = cycle:state(start + 5)
	t.near((half.weather :: any).amount, 0.5)
	local full = cycle:state(start + 20)
	t.near((full.weather :: any).amount, 1)
	t.near(full.preset.lighting.Brightness, Lighting.get("storm_dim").lighting.Brightness, 1e-9)
	t.near(full.preset.lighting.ClockTime, WorldCycle.clock(start + 20, WorldCycle.DEFAULT), 1e-9)
	cycle:setWeather(nil, 0, 4, start + 20)
	t.near((cycle:state(start + 22).weather :: any).amount, 0.5)
	t.eq(cycle:state(start + 30).preset.id, "bright_noon", "cleared weather leaves the phase preset")
	t.throws(function()
		cycle:setWeather("acid_rain", 1, 1, 0)
	end)
end)

test("step is rate-limited unless the phase changes", function(t)
	local cycle = WorldCycle.new()
	t.ok(cycle:step(at(12)))
	t.eq(cycle:step(at(12) + 0.5), nil)
	t.ok(cycle:step(at(12) + 1))
	t.ok(cycle:step(at(17) + 0.01), "a phase change applies at once")
end)

test("validation rejects unordered phases, unknown presets and short phases", function(t)
	local problems = WorldCycle.validate({
		dayLength = 5,
		blend = 2,
		phases = {
			{ name = "a", at = 6, preset = "bright_noon" },
			{ name = "a", at = 5, preset = "sunset_purple" },
		},
		colour = "red",
	})
	t.ok(has(problems, "colour is not a WorldCycle key"))
	t.ok(has(problems, "dayLength"))
	t.ok(has(problems, "used twice"))
	t.ok(has(problems, "after the previous phase"))
	t.ok(has(problems, "sunset_purple is not a Lighting preset"))
	t.ok(has(
		WorldCycle.validate({
			dayLength = 60,
			blend = 2,
			phases = {
				{ name = "a", at = 0, preset = "overcast" },
				{ name = "b", at = 1, preset = "night_clear" },
			},
		}),
		"shorter than the blend window"
	))
	t.throws(function()
		WorldCycle.new({ dayLength = 60, phases = {} })
	end)
end)

test("apply writes the blended preset onto an @lune/roblox Lighting service", function(t)
	local game = roblox.Instance.new("DataModel")
	local lighting = game:GetService("Lighting")
	local workspace = game:GetService("Workspace")
	local terrain = roblox.Instance.new("Terrain")
	terrain.Parent = workspace
	local state = WorldCycle.state(at(17 - 0.375), WorldCycle.DEFAULT)
	local report = WorldCycle.apply(lighting, state, roblox)
	t.eq(report.preset, "custom")
	t.near(lighting.ClockTime, 17 - 0.375, 1e-4)
	t.eq(lighting:GetAttribute("SceneKitLightingBlend"), "bright_noon>golden_hour@0.500")
	t.ok(lighting:FindFirstChild("SceneKitAtmosphere"))
end)

return cases
