--!strict
-- Packages spec (factory-managed): the factory packages copied into this repo match starter.json and
-- behave as they did in the factory.
--   * every .luau file under packages/ is recorded in starter.json "modules", with the tier its
--     `-- @tier` header declares (the record is what tools/new_project.py --update compares against);
--   * every module recorded as lune = true loads in Lune (cores of any tier, authoring and legacy
--     modules); engine adapters (*Roblox) and the legacy Roblox-only modules are never loaded here,
--     they wait for their Studio probes (starter.json "pending_probes");
--   * behaviour checks per package: ProcGen and SceneKit determinism, Pipeline's smoke hashes (the
--     values Studio reproduced in the factory), GameKit's number checks and Signal.
-- Add specs for this game's own logic next to this file as tests/<area>.spec.luau (skill
-- roblox-luau-testing).
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local load = require :: any
local starter = serde.decode("json", fs.readFile("starter.json"))
local recorded: { [string]: any } = starter.modules or {}

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local packageNames = {}
for name in starter.packages do
	table.insert(packageNames, name)
end
table.sort(packageNames)

-- "Pkg/Sub/Module" for every .luau file under packages/<Pkg>, recursively.
local function onDisk(): { string }
	local out = {}
	local function walk(dir: string, prefix: string)
		for _, entry in fs.readDir(dir) do
			local path = dir .. "/" .. entry
			if fs.isDir(path) then
				walk(path, prefix .. entry .. "/")
			else
				local module = string.match(entry, "^(.+)%.luau$")
				if module then
					table.insert(out, prefix .. module)
				end
			end
		end
	end
	for _, name in packageNames do
		if fs.isDir("packages/" .. name) then
			walk("packages/" .. name, name .. "/")
		end
	end
	table.sort(out)
	return out
end

local function headerTier(source: string): string?
	local lines = string.split(source, "\n")
	local index = if lines[1] and string.sub(lines[1], 1, 3) == "--!" then 2 else 1
	while lines[index] and string.sub(lines[index], 1, 2) == "--" do
		local tier = string.match(lines[index], "^%-%-%s*@tier%s+(T[0-4])")
		if tier then
			return tier
		end
		index += 1
	end
	return nil
end

-- Every Lune-loadable module is required once, here, in name order. A module that fails to load
-- fails the whole run with its error (requiring a module again after it failed hangs Lune 0.10, so no
-- case below calls require).
local modules: { [string]: { [string]: any } } = {}
local loadOrder = {}
for name, record in recorded do
	if record.lune then
		table.insert(loadOrder, name)
	end
end
table.sort(loadOrder)
for _, name in loadOrder do
	local pkg, module = string.match(name, "^([^/]+)/(.+)$")
	if pkg and module and fs.isFile("packages/" .. name .. ".luau") then
		modules[pkg] = modules[pkg] or {}
		modules[pkg][module] = load("../packages/" .. name)
	end
end

test("every module on disk is recorded in starter.json with its header tier", function(t)
	t.ok(
		starter.schema == "starter/2",
		"starter.json schema " .. tostring(starter.schema) .. "; run tools/new_project.py --update"
	)
	local problems = {}
	local seen = {}
	for _, name in onDisk() do
		seen[name] = true
		local record = recorded[name]
		if record == nil then
			table.insert(problems, name .. ": not in starter.json")
		else
			local tier = headerTier(fs.readFile("packages/" .. name .. ".luau"))
			if tier ~= record.tier then
				table.insert(
					problems,
					`{name}: header tier {tier or "none"}, starter.json {record.tier or "none"}`
				)
			end
		end
	end
	for name in recorded do
		if not seen[name] then
			table.insert(problems, name .. ": in starter.json but missing on disk")
		end
	end
	table.sort(problems)
	t.ok(#problems == 0, table.concat(problems, "\n"))
end)

test("engine adapters are never loaded in Lune and T3 modules name a probe", function(t)
	for name, record in recorded do
		if string.match(name, "Roblox$") then
			t.ok(record.lune == false, name .. " is an adapter but recorded as Lune-loadable")
		end
		if record.tier == "T3" then
			t.ok(type(record.probe) == "string", name .. " is T3 without a probe")
		end
	end
end)

local behaviour: { [string]: { name: string, fn: (t: any) -> () } } = {}

behaviour.ProcGen = {
	name = "same seed gives the same dungeon and it passes the room validators",
	fn = function(t)
		local P = modules.ProcGen
		local layout = P.Dungeon.generate({ seed = 7 })
		local hash = P.Manifest.fromLayout(layout).hash
		t.eq(P.Manifest.fromLayout(P.Dungeon.generate({ seed = 7 })).hash, hash, "same seed")
		t.ok(P.Manifest.fromLayout(P.Dungeon.generate({ seed = 8 })).hash ~= hash, "another seed differs")
		local placement = P.Placement.assign(layout, { encounters = 2, landmarks = 1 })
		local summary = P.Validate.summary(P.Validate.rooms(layout, placement))
		t.ok(summary.pass, "validators failed: " .. table.concat(summary.failed, ", "))
	end,
}

behaviour.SceneKit = {
	name = "a building plan validates and applies (dry run) to the same hash twice",
	fn = function(t)
		local SceneKit = modules.SceneKit.SceneKit
		local function plan()
			local scene = SceneKit.Scene.new({ name = "STARTER_Building", seed = 11, style = "greybox" })
			SceneKit.Building.create(scene, { footprint = { x = 0, z = 0, w = 24, d = 20 }, storeys = 2 })
			return scene
		end
		local scene = plan()
		local summary = SceneKit.Validate.summary(SceneKit.Validate.scene(scene))
		t.ok(summary.pass, "validators failed: " .. table.concat(summary.failed, ", "))
		local first = SceneKit.Apply.scene(scene, nil, { dryRun = true })
		local second = SceneKit.Apply.scene(plan(), nil, { dryRun = true })
		t.ok(first.parts > 0, "plan has parts")
		t.eq(second.hash, first.hash, "same plan, same hash")
	end,
}

behaviour.Pipeline = {
	name = "FactorySmoke scenes validate and match the factory's smoke hashes",
	fn = function(t)
		t.ok(starter.smoke ~= nil, "starter.json has no smoke hashes")
		for key, result in modules.Pipeline.FactorySmoke.run(nil) do
			local expected = starter.smoke[key]
			t.ok(expected ~= nil, key .. " missing from starter.json smoke")
			t.ok(result.pass, key .. " validators failed")
			t.eq(result.hash, expected.hash, key .. " hash")
			t.eq(result.parts, expected.parts, key .. " parts")
		end
	end,
}

behaviour.GameKit = {
	name = "Check refuses NaN and inf, and a Signal reaches its listener",
	fn = function(t)
		local Check, Signal = modules.GameKit.Check, modules.GameKit.Signal
		t.ok(Check ~= nil and Signal ~= nil, "GameKit/Check and GameKit/Signal are Stage 0 modules")
		t.ok(Check.finite(1) and not Check.finite(0 / 0) and not Check.finite(math.huge), "finite")
		local got = nil
		local signal = Signal.new()
		signal:Connect(function(value)
			got = value
		end)
		signal:Fire(42)
		t.eq(got, 42, "listener")
	end,
}

for _, name in packageNames do
	test(name .. ": every Lune-loadable module loads", function(t)
		local count = 0
		for module, value in modules[name] or {} do
			t.ok(value ~= nil, module .. " returned nil")
			count += 1
		end
		local any = false
		for recordName, record in recorded do
			any = any or (record.lune and string.sub(recordName, 1, #name + 1) == name .. "/")
		end
		-- A kit without modules yet (only its README) passes; one with loadable modules must load some.
		t.ok(count > 0 or not any, "packages/" .. name .. " has loadable modules but none loaded")
	end)
	local check = behaviour[name]
	if check and modules[name] then
		test(name .. ": " .. check.name, check.fn)
	end
end

return cases
