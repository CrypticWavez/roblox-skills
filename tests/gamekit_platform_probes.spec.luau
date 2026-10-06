--!strict
-- G1 probe registry in Lune: runs every probe in fixtures/kits/server/platform_probes.luau with
-- FakeEnv and the G1 fakes registered as services, and checks each prints only passing
-- ENGINE_CHECK lines and one ENGINE_DONE line. This proves the registry loads and its logic holds
-- against fakes; it is not Studio evidence (the probes stay pending until the owner's run).
-- It also checks every probe has a tests/engine/<probe>.luau entry naming it.
local fs = require("@lune/fs")

local Probe = require("../packages/GameKit/Probe")
local FakeEnv = require("./fakes/FakeEnv")
local FakePlatformRoblox = require("./fakes/FakePlatformRoblox")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."
local registry = require("../fixtures/kits/server/platform_probes")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

-- Lune's require yields inside a coroutine it did not start, and probes run on FakeEnv threads,
-- so every kit module (adapters included: they touch no globals at load time) and the Rng leaf
-- are required here, on the main thread.
local preloaded: { [string]: any } = {}
for _, kit in { "GameKit", "UIKit", "AVKit", "Feel", "Cinematics" } do
	local dir = ROOT .. "/packages/" .. kit
	if fs.isDir(dir) then
		for _, file in fs.readDir(dir) do
			local name = string.match(file, "^(.+)%.luau$")
			if name then
				preloaded[kit .. "/" .. name] = (require :: any)("../packages/" .. kit .. "/" .. name)
			end
		end
	end
end
preloaded["ProcGen/Rng"] = require("../packages/ProcGen/Rng")

local function kitLoader(path: string): any
	local module = preloaded[path]
	if module == nil then
		error("kit module not preloaded: " .. path, 2)
	end
	return module
end

-- The env a probe sees in Lune: FakeEnv with fake Players (one player), a fake
-- ReplicatedStorage and the fake Instance factory; extra services per probe.
local function probeEnv(services: { [string]: any }?): any
	local env = FakeEnv.new({ roblox = FakePlatformRoblox.roblox() })
	env:register("Players", FakePlatformRoblox.players({ 101 }))
	env:register("ReplicatedStorage", FakePlatformRoblox.instance("Folder", "ReplicatedStorage"))
	for name, service in services or {} do
		env:register(name, service)
	end
	return env
end

-- Runs one probe on its own thread (probes may wait) and returns the summary and lines.
local function runProbe(name: string, env: any): (any, { string })
	local lines = {}
	local summary = nil
	env.spawn(function()
		summary = Probe.runAll(registry, {
			env = env,
			kit = kitLoader,
			only = { name },
			emit = function(line: string)
				table.insert(lines, line)
			end,
		})
	end)
	for _ = 1, 600 do
		if summary ~= nil then
			break
		end
		env:advance(0.1)
		env:flush()
	end
	return summary, lines
end

local function expectPass(t: any, name: string, env: any)
	local summary, lines = runProbe(name, env)
	t.ok(summary ~= nil, name .. " did not finish: " .. table.concat(env.errors, "\n"))
	t.ok(summary.ok, name .. " failed:\n" .. table.concat(lines, "\n"))
	t.ok(summary.checks >= 3, name .. " checks too little")
	t.eq(#env.errors, 0, table.concat(env.errors, "\n"))
	t.ok(string.find(lines[#lines], Probe.DONE_PREFIX, 1, true) == 1, "last line is ENGINE_DONE")
end

test("every platform probe has a valid name and a Studio entry", function(t)
	local names = {}
	for name in registry do
		table.insert(names, name)
		t.ok(Probe.validName(name) and string.sub(name, 1, 9) == "platform_", name)
		local entry = ROOT .. "/tests/engine/" .. name .. ".luau"
		t.ok(fs.isFile(entry), "missing " .. entry)
		local source = fs.readFile(entry)
		t.ok(
			string.find(source, '"' .. name .. '"', 1, true) ~= nil,
			entry .. " must run only = { " .. name .. " }"
		)
		t.ok(string.find(source, "platform_probes", 1, true) ~= nil, entry .. " loads the platform registry")
	end
	t.ok(#names >= 1)
end)

test("probes refuse to run outside the diagnostic place", function(t)
	for name in registry do
		local env = probeEnv()
		env.place = { isStudio = true, gameId = 42, placeId = 7 }
		local summary, lines = runProbe(name, env)
		t.ok(summary ~= nil, name .. " did not finish: " .. table.concat(env.errors, "\n"))
		t.ok(not summary.ok, name .. " ran on a published place")
		t.ok(string.find(lines[1], '"place_is_diagnostic"', 1, true) ~= nil, name .. ": " .. lines[1])
	end
end)

test("platform_remoteguard_flood passes against fakes", function(t)
	expectPass(t, "platform_remoteguard_flood", probeEnv())
end)

test("platform_playerdata_memory passes against fakes", function(t)
	expectPass(t, "platform_playerdata_memory", probeEnv())
end)

test("platform_telemetry_recorder passes against fakes", function(t)
	expectPass(t, "platform_telemetry_recorder", probeEnv())
end)

return cases
