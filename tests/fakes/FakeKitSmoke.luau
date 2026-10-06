--!strict
-- FakeKitSmoke (G9b): the Lune side of Pipeline/KitSmoke, shared by tools/lune/kit_smoke.luau and
-- tests/pipeline_kitsmoke.spec.luau so both produce the same kit-smoke golden.
--   env(side)          FakeEnv for "server" or "client" with fake RunService, Stats, Workspace and
--                      Enum.DeveloperMemoryTag (FakePerfEngine), on the unpublished Studio place
--   withGame(env, fn)  runs fn with a fake global `game` whose RunService answers from env.place
--                      (the Creator inspectors read the real globals), then restores it
--   drive(env, fn)     runs fn on an env thread, stepping Heartbeat at 60 Hz until it returns
--   sources(sides, filter?)  registries on disk (KitSmoke.fromFiles over @lune/fs)
--   loader, preload()  kit("GameKit/Probe") -> packages/GameKit/Probe; PRELOAD loads before a run
--   golden()           the deterministic G9b run: server and client kitsmoke_ registries
local fs = require("@lune/fs")
local FakeEnv = require("./FakeEnv")
local FakePerfEngine = require("./FakePerfEngine")
local KitSmoke = require("../../packages/Pipeline/KitSmoke")

local FakeKitSmoke = {}

local TESTS = string.match(debug.info(1, "s"), "^(.*)[/\\]fakes[/\\][^/\\]*$") or "tests"
FakeKitSmoke.ROOT = TESTS .. "/.."
FakeKitSmoke.STEP = 1 / 60
FakeKitSmoke.MAX_STEPS = 600

-- Modules the G9b registries load. Lune's require yields, and a yield on an env thread looks like
-- env.wait to FakeEnv, so modules are loaded on the main thread before a run (preload) and the
-- loader refuses an unloaded module while driving instead of hanging.
FakeKitSmoke.PRELOAD = {
	"GameKit/Probe",
	"GameKit/Env",
	"GameKit/EnvRoblox",
	"GameKit/DebugCommands",
	"Creator/Observation",
	"Creator/AnimationInspector",
	"Creator/WorldInspector",
	"Diagnostics/PerfProbe",
	"Diagnostics/PerfProbeRoblox",
}

local loaded: { [string]: any } = {}
local driving = false

function FakeKitSmoke.loader(path: string): any
	local module = loaded[path]
	if module ~= nil then
		return module
	end
	if driving then
		error("FakeKitSmoke: add " .. path .. " to FakeKitSmoke.PRELOAD (modules load before the run)", 2)
	end
	module = (require :: any)("../../packages/" .. path)
	loaded[path] = module
	return module
end

-- Loads PRELOAD on the calling (main) thread; call it inside withGame so modules that read the
-- `game` global at load time see the fake.
function FakeKitSmoke.preload()
	for _, path in FakeKitSmoke.PRELOAD do
		FakeKitSmoke.loader(path)
	end
end

local function loadFixture(path: string): any
	return (require :: any)("../../" .. path)
end

function FakeKitSmoke.env(side: string): any
	local client = side == "client"
	local runService = FakePerfEngine.runService()
	local workspace = FakePerfEngine.folder({
		FakePerfEngine.instance("Part"),
		FakePerfEngine.instance("Part"),
		FakePerfEngine.instance("MeshPart"),
		FakePerfEngine.instance("PointLight", { Shadows = true, Enabled = true }),
		FakePerfEngine.instance("ParticleEmitter", { Rate = 15, Enabled = true }),
		FakePerfEngine.instance("Sound", { IsPlaying = true }),
		FakePerfEngine.instance("Highlight", { Enabled = true }),
	})
	local tags = { FakePerfEngine.tag("LuaHeap"), FakePerfEngine.tag("GraphicsTexture") }
	local env = FakeEnv.new({
		seed = "kitsmoke",
		place = { isStudio = true, gameId = 0, placeId = 0, isServer = not client, isClient = client },
		services = {
			RunService = runService,
			Stats = FakePerfEngine.stats({
				total = if client then 640 else 480,
				byTag = { LuaHeap = 32, GraphicsTexture = if client then 96 else 0 },
				instances = 2048,
				triangles = if client then 15000 else nil,
			}),
			Workspace = workspace,
		},
		roblox = {
			Enum = {
				DeveloperMemoryTag = {
					GetEnumItems = function(_: any): { any }
						return tags
					end,
				},
			},
		},
	})
	return env
end

function FakeKitSmoke.withGame(env: any, fn: () -> ()): (boolean, string?)
	local place = env.place
	local runService = {
		IsStudio = function(_: any): boolean
			return place.isStudio
		end,
		IsServer = function(_: any): boolean
			return place.isServer == true
		end,
		IsClient = function(_: any): boolean
			return place.isClient == true
		end,
	}
	local fakeGame = {
		GameId = place.gameId,
		PlaceId = place.placeId,
		GetService = function(_: any, name: string): any
			if name == "RunService" then
				return runService
			end
			return env.services[name]
		end,
	}
	local globals = getfenv(0)
	local previous = globals.game
	globals.game = fakeGame
	local ok, err = pcall(fn)
	globals.game = previous
	return ok, if ok then nil else tostring(err)
end

-- Runs fn on an env thread; each step fires Heartbeat with the frame time, flushes deferred work
-- and advances the clock one step. Raises when fn raised or did not finish.
function FakeKitSmoke.drive(env: any, fn: () -> any): any
	local done, result = false, nil
	driving = true
	env.spawn(function()
		result = fn()
		done = true
	end)
	local steps = 0
	while not done and steps < FakeKitSmoke.MAX_STEPS and #env.errors == 0 do
		steps += 1
		-- Every tenth frame is a long one, so the percentiles differ.
		env.services.RunService:fire(if steps % 10 == 0 then 2 * FakeKitSmoke.STEP else FakeKitSmoke.STEP)
		env:flush()
		env:advance(FakeKitSmoke.STEP)
	end
	driving = false
	if #env.errors > 0 then
		error("FakeKitSmoke.drive: " .. env.errors[1], 2)
	end
	if not done then
		error("FakeKitSmoke.drive: did not finish in " .. FakeKitSmoke.MAX_STEPS .. " steps", 2)
	end
	return result
end

local files = {
	readDir = fs.readDir,
	isDir = fs.isDir,
	isFile = fs.isFile,
}

-- Registries on disk for these sides, optionally only those whose name passes filter(name).
function FakeKitSmoke.sources(sides: { string }?, filter: ((name: string) -> boolean)?): { any }
	local found = KitSmoke.fromFiles(files, FakeKitSmoke.ROOT, loadFixture, sides)
	if filter == nil then
		return found
	end
	local kept = {}
	for _, source in found do
		if filter(source.name) then
			table.insert(kept, source)
		end
	end
	return kept
end

local function ownRegistry(name: string): boolean
	return string.sub(name, 1, #"kitsmoke_") == "kitsmoke_"
end

-- One side's run of the G9b registries: { lines, summary, problems }.
function FakeKitSmoke.runSide(side: string, sideSources: { any }?): any
	local env = FakeKitSmoke.env(side)
	local sources = sideSources or FakeKitSmoke.sources({ side }, ownRegistry)
	local lines: { string } = {}
	local out: any = nil
	local ok, err = FakeKitSmoke.withGame(env, function()
		FakeKitSmoke.preload()
		out = FakeKitSmoke.drive(env, function(): any
			local summary, problems = KitSmoke.run(sources, {
				env = env,
				kit = FakeKitSmoke.loader,
				emit = function(line: string)
					table.insert(lines, line)
				end,
			})
			return { summary = summary, problems = problems }
		end)
	end)
	if not ok then
		error("FakeKitSmoke.runSide(" .. side .. "): " .. tostring(err), 2)
	end
	return { lines = lines, summary = out.summary, problems = out.problems }
end

-- The kit-smoke golden value: both sides' ENGINE lines (G9b registries only, so other groups'
-- registries never change it) and their summaries.
function FakeKitSmoke.golden(): any
	local value = {}
	for _, side in { "server", "client" } do
		local run = FakeKitSmoke.runSide(side)
		value[side] = { lines = run.lines, summary = run.summary }
	end
	return value
end

return FakeKitSmoke
