--!strict
-- Pipeline/KitSmoke: registry merging and its problems, the built-in kitsmoke_registries probe,
-- Studio discovery (collect, studioLoader) against fake instances, disk discovery (fromFiles),
-- every repository registry loading, and the G9b registries' ENGINE lines against golden kit-smoke
-- (tests/fakes/FakeKitSmoke.luau; tools/lune/kit_smoke.luau prints the same run).
local FakeKitSmoke = require("./fakes/FakeKitSmoke")
local Golden = require("./lib/Golden")
local KitSmoke = require("../packages/Pipeline/KitSmoke")
local Probe = require("../packages/GameKit/Probe")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function mentions(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function kit(path: string): any
	assert(path == "GameKit/Probe", "only Probe is loaded here")
	return Probe
end

local function noop() end

local function runLines(sources: { any }, only: { string }?): ({ string }, any)
	local lines = {}
	local summary = KitSmoke.run(sources, {
		kit = kit,
		only = only,
		emit = function(line: string)
			table.insert(lines, line)
		end,
	})
	return lines, summary
end

test("merge orders sources by side then name and names every problem", function(t)
	local registry, problems, inventory = KitSmoke.merge({
		{ side = "server", name = "b_probes", registry = { b_one = noop } },
		{ side = "shared", name = "a_probes", registry = { a_two = noop, a_one = noop } },
		{ side = "client", name = "c_probes", error = "boom" },
		{ side = "server", name = "d_probes", registry = { a_one = noop, ["Bad-Name"] = noop, d_value = 5 } },
		{ side = "server", name = "e_probes", registry = "nope" },
		{ side = "server", name = "f_probes", registry = { kitsmoke_registries = noop } },
		{ side = "elsewhere", name = "g_registry", registry = {} },
	})
	t.eq(registry.a_one, noop)
	t.eq(registry.b_one, noop)
	t.eq(registry.d_value, nil)
	local order = {}
	for _, entry in inventory do
		table.insert(order, entry.side .. "/" .. entry.name)
	end
	t.eq(order, {
		"shared/a_probes",
		"server/b_probes",
		"server/d_probes",
		"server/e_probes",
		"server/f_probes",
		"client/c_probes",
		"elsewhere/g_registry",
	})
	t.eq(inventory[1].probes, { "a_one", "a_two" })
	for _, needle in
		{
			"client/c_probes: failed to load",
			"server/d_probes: probe a_one is already registered by shared/a_probes",
			"server/d_probes: invalid probe name Bad-Name",
			"server/d_probes: probe d_value is not a function",
			"server/e_probes: a registry returns",
			"server/f_probes: probe kitsmoke_registries is already registered by KitSmoke",
			"elsewhere/g_registry: side must be shared, server or client",
			"elsewhere/g_registry: registry names end in _probes",
		}
	do
		t.ok(mentions(problems, needle), needle .. " in " .. table.concat(problems, "; "))
	end
	t.eq(#problems, 8)
end)

test("run prints every probe and the registry checks; problems fail the run", function(t)
	local lines, summary = runLines({
		{
			side = "shared",
			name = "a_probes",
			registry = {
				a_pass = function(ctx: any)
					ctx.check("fine", true)
				end,
			},
		},
	})
	t.ok(summary.ok, table.concat(lines, "\n"))
	t.eq(summary.probes, { "a_pass", "kitsmoke_registries" })
	t.eq(summary.checks, 4)
	t.ok(string.find(lines[#lines], "ENGINE_DONE ", 1, true) == 1)
	t.ok(
		string.find(lines[2], '"check":"loaded shared/a_probes","detail":{"probes":1}', 1, true) ~= nil,
		lines[2]
	)

	local badLines, bad = runLines({ { side = "server", name = "x_probes", error = "syntax" } })
	t.ok(not bad.ok)
	t.eq(bad.failed, 2, table.concat(badLines, "\n"))
	t.ok(mentions(badLines, '"detail":{"error":"load_failed"}'))
	t.ok(mentions(badLines, '"check":"no_problems","detail":["server/x_probes: failed to load"],"ok":false'))
	t.ok(not mentions(badLines, "syntax"), "raw load errors (paths) stay out of the lines")

	local _, empty = runLines({})
	t.ok(not empty.ok, "no registries found is a failure")

	local onlyLines, only = runLines({
		{
			side = "shared",
			name = "a_probes",
			registry = {
				a_pass = function(ctx: any)
					ctx.check("fine", true)
				end,
			},
		},
	}, { "a_pass" })
	t.eq(only.probes, { "a_pass" })
	t.eq(#onlyLines, 2)
	t.throws(function()
		KitSmoke.run({}, {} :: any)
	end, "a kit loader is required")
end)

-- Fake Studio instances: folders with GetDescendants, ModuleScripts with IsA and Name.
local function module(name: string, value: any): any
	return {
		Name = name,
		value = value,
		IsA = function(_: any, className: string): boolean
			return className == "ModuleScript"
		end,
	}
end
local function script(name: string): any
	return {
		Name = name,
		IsA = function(_: any, className: string): boolean
			return className == "Script"
		end,
	}
end
local function folder(children: { any }): any
	return {
		GetDescendants = function(_: any): { any }
			return children
		end,
	}
end

test("collect requires every *_probes ModuleScript in the given folders", function(t)
	local registry = { s_probe = noop }
	local sources = KitSmoke.collect({
		{
			side = "shared",
			folder = folder({ module("s_probes", registry), module("helper", {}), script("x_probes") }),
		},
		{ side = "server", folder = folder({ module("broken_probes", "raise") }) },
		{ side = "client", folder = nil :: any },
	}, function(instance: any): any
		if instance.value == "raise" then
			error("cannot require")
		end
		return instance.value
	end)
	t.eq(#sources, 2)
	t.eq(sources[1].name, "s_probes")
	t.eq(sources[1].registry, registry)
	t.eq(sources[2].side, "server")
	t.eq(sources[2].registry, nil)
	t.ok(string.find(sources[2].error :: string, "cannot require", 1, true) ~= nil)
end)

test("studioLoader walks Workbench by path and fails on a missing step", function(t)
	local leaf = { Name = "Signal" }
	local tree: any = {
		GameKit = {
			Signal = leaf,
		},
	}
	local function node(value: any): any
		return {
			value = value,
			WaitForChild = function(self: any, name: string, _timeout: number?): any
				local child = self.value[name]
				return if type(child) == "table" then node(child) else nil
			end,
		}
	end
	local loader = KitSmoke.studioLoader(node(tree), function(instance: any): any
		return instance.value
	end, 0)
	t.eq(loader("GameKit/Signal"), leaf)
	t.throws(function()
		loader("GameKit/Missing")
	end)
end)

test("fromFiles finds registries under each side, nested folders included", function(t)
	local dirs: { [string]: { string } } = {
		["root/fixtures/kits/shared"] = { "nested", "a_probes.luau", "readme.md", "a_Runner.server.luau" },
		["root/fixtures/kits/shared/nested"] = { "b_probes.luau" },
		["root/fixtures/kits/server"] = { "bad_probes.luau" },
	}
	local files = {
		readDir = function(path: string): { string }
			return table.clone(dirs[path])
		end,
		isDir = function(path: string): boolean
			return dirs[path] ~= nil
		end,
		isFile = function(path: string): boolean
			return dirs[path] == nil
		end,
	}
	local loads = {}
	local sources = KitSmoke.fromFiles(files, "root", function(path: string): any
		table.insert(loads, path)
		if path == "fixtures/kits/server/bad_probes" then
			error("bad registry")
		end
		return { [string.match(path, "([^/]+)$") :: string] = true }
	end)
	t.eq(loads, {
		"fixtures/kits/shared/a_probes",
		"fixtures/kits/shared/nested/b_probes",
		"fixtures/kits/server/bad_probes",
	})
	t.eq(#sources, 3)
	t.eq(sources[3].registry, nil)
	t.ok(sources[3].error ~= nil)
end)

test("every probe registry in the repository loads without problems", function(t)
	local _, problems, inventory = KitSmoke.merge(FakeKitSmoke.sources())
	t.eq(problems, {}, table.concat(problems, "; "))
	local names = {}
	for _, entry in inventory do
		table.insert(names, entry.side .. "/" .. entry.name)
	end
	t.ok(table.find(names, "shared/foundation_probes") ~= nil)
	t.ok(table.find(names, "server/kitsmoke_probes") ~= nil)
	t.ok(table.find(names, "client/kitsmoke_client_probes") ~= nil)
end)

test("the G9b registries pass on a fake server and client and match golden kit-smoke", function(t)
	local value = FakeKitSmoke.golden()
	t.ok(value.server.summary.ok, table.concat(value.server.lines, "\n"))
	t.ok(value.client.summary.ok, table.concat(value.client.lines, "\n"))
	t.eq(
		value.server.summary.probes,
		{ "kitsmoke_debug_commands", "kitsmoke_inspector_target", "kitsmoke_registries", "perf_capture" }
	)
	t.eq(value.client.summary.probes, { "kitsmoke_registries", "perf_capture_client" })
	Golden.assert("kit-smoke", value)
end)

test("the same probes fail honestly off the diagnostic place and when Edit mode skips frames", function(t)
	local env = FakeKitSmoke.env("server")
	env.place = { isStudio = true, gameId = 4242, placeId = 0, isServer = true, isClient = false }
	local sources = FakeKitSmoke.sources({ "server" }, function(name: string): boolean
		return name == "kitsmoke_probes"
	end)
	local lines = {}
	local summary
	FakeKitSmoke.withGame(env, function()
		FakeKitSmoke.preload()
		summary = FakeKitSmoke.drive(env, function(): any
			return KitSmoke.run(sources, {
				env = env,
				kit = FakeKitSmoke.loader,
				only = { "kitsmoke_debug_commands", "kitsmoke_inspector_target" },
				emit = function(line: string)
					table.insert(lines, line)
				end,
			})
		end)
	end)
	t.ok(not summary.ok)
	t.ok(
		mentions(
			lines,
			'"check":"active_on_diagnostic_place","detail":{"active":false,"reason":"published_game"}'
		)
	)
	t.ok(
		mentions(
			lines,
			'"check":"WorldInspector_target_accepted","detail":{"reached_options_check":false,"refused":true}'
		)
	)
end)

return cases
