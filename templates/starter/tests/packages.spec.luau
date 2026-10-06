-- Starter spec: the factory packages copied into this repo load in Lune and behave as they did in
-- the factory. starter.json lists the packages and, with Pipeline, the factory's smoke hashes (the
-- values Studio reproduced). Add specs for this game's own logic next to this file as
-- tests/<area>.spec.luau (see the roblox-luau-testing skill).
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local load = require :: any
local starter = serde.decode("json", fs.readFile("starter.json"))

-- Modules that use `script`, `game` or Roblox datatypes while loading; they only run inside Roblox.
local ROBLOX_ONLY =
	{ ["Creator/Effects"] = true, ["Creator/Observation"] = true, ["Runtime/NativeUI"] = true }

local names = {}
for name in starter.packages do
	table.insert(names, name)
end
table.sort(names)

-- Every module of every copied package is required once, here. A module that fails to load fails
-- the whole run with its error. (Requiring a module again after it failed hangs Lune 0.10, so no
-- case below calls require.)
local modules = {}
for _, name in names do
	modules[name] = {}
	for _, file in fs.readDir("packages/" .. name) do
		local module = string.match(file, "^(.+)%.luau$")
		if module and not ROBLOX_ONLY[name .. "/" .. module] then
			modules[name][module] = load("../packages/" .. name .. "/" .. module)
		end
	end
end

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local behaviour = {}

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

for _, name in names do
	test(name .. ": every module loads", function(t)
		local count = 0
		for module, value in modules[name] do
			t.ok(value ~= nil, module .. " returned nil")
			count += 1
		end
		t.ok(count > 0, "packages/" .. name .. " has no modules")
	end)
	local check = behaviour[name]
	if check then
		test(name .. ": " .. check.name, check.fn)
	end
end

return cases
