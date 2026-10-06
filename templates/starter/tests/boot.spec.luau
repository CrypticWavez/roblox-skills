--!strict
-- Boot skeleton specs: the phase runner (src/shared/Boot), the optional-kit loader (KitLoader), the
-- TBD config (Config) and both sides' phases (src/server/Phases, src/client/Phases) driven with fakes.
-- Covers phase order, the first failure stopping later phases, per-phase timeouts, cleanup on failure,
-- absent kits, and the report line. The real engine run is release item S07 (owner, Studio).
local Boot = require("../src/shared/Boot")
local Config = require("../src/shared/Config")
local KitLoader = require("../src/shared/KitLoader")
local ClientPhases = require("../src/client/Phases")
local ServerPhases = require("../src/server/Phases")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

-- A manual clock with a tiny scheduler: threads started by spawn park in wait() until the main
-- thread's wait() (the runner's poll) advances the clock past their wake time.
local function fakeEnv()
	local env = { now = 0, parked = {}, threads = {}, cancelled = 0 }
	function env.clock(): number
		return env.now
	end
	local function resume(thread: thread)
		local ok, err = coroutine.resume(thread)
		if not ok then
			error(err, 0)
		end
	end
	function env.spawn(fn: () -> ()): thread
		local thread = coroutine.create(fn)
		env.threads[thread] = true
		resume(thread)
		return thread
	end
	function env.wait(seconds: number)
		local current = coroutine.running()
		if env.threads[current] then
			table.insert(env.parked, { thread = current, at = env.now + seconds })
			coroutine.yield()
			return
		end
		env.now += seconds
		local due = {}
		for index = #env.parked, 1, -1 do
			if env.parked[index].at <= env.now + 1e-9 then
				table.insert(due, 1, table.remove(env.parked, index).thread)
			end
		end
		for _, thread in due do
			resume(thread)
		end
	end
	function env.cancel(thread: thread)
		for index = #env.parked, 1, -1 do
			if env.parked[index].thread == thread then
				table.remove(env.parked, index)
			end
		end
		env.cancelled += 1
		coroutine.close(thread)
	end
	return env
end

-- Minimal Instance-like nodes for KitLoader and the phases.
local function node(name: string, className: string, value: any?, children: { any }?): any
	local self = { Name = name, ClassName = className, value = value, children = {} }
	for _, child in children or {} do
		self.children[child.Name] = child
	end
	function self.FindFirstChild(this: any, childName: string): any
		return this.children[childName]
	end
	return self
end

local function loader(module: any): any
	if module.value == "boom" then
		error("module raised while loading")
	end
	return module.value
end

local function statuses(report: any): { string }
	local out = {}
	for _, phase in report.phases do
		table.insert(out, phase.name .. "=" .. phase.status)
	end
	return out
end

-- A Config stand-in with chosen values (the real module reads its own values table).
local function configWith(patch: { [string]: any }): any
	local values = table.clone(Config.values)
	for key, value in patch do
		local section, field = string.match(key, "^(%w+)%.(%w+)$")
		if section then
			values[section] = table.clone(values[section])
			values[section][field] = value
		else
			values[key] = value
		end
	end
	return {
		get = function(path: string, default: any?): any
			return Config.get(path, default, values)
		end,
		validate = function(): { string }
			return Config.validate(values)
		end,
		undecided = function(): number
			return Config.undecided(values)
		end,
	}
end

-- ------------------------------------------------------------------ Boot

test("validate accepts each side's own phases and rejects the rest", function(t)
	local fn = function() end
	t.eq(
		Boot.validate({ side = "server", phases = { config = fn, data = fn, telemetry = fn } }),
		{},
		"server"
	)
	t.eq(Boot.validate({ side = "client", phases = { ui = fn, input = fn, remotes = fn } }), {}, "client")
	local problems =
		Boot.validate({ side = "client", phases = { data = fn, warp = fn, ui = 3 }, timeouts = { ui = -1 } })
	t.eq(#problems, 4, table.concat(problems, " | "))
	t.ok(
		string.find(table.concat(problems, " | "), "does not run on the client", 1, true) ~= nil,
		"side rule"
	)
	t.eq(
		Boot.validate({ side = "both", phases = {} })[1],
		'side must be "server" or "client", got both',
		"side"
	)
	t.eq(Boot.validate(nil), { "spec must be a table" }, "nil spec")
end)

test("phases run in the fixed order; absent phases are skipped", function(t)
	local env, order = fakeEnv(), {}
	local function phase(name: string)
		return function()
			table.insert(order, name)
			return name .. " done"
		end
	end
	-- Declared out of order on purpose: the runner owns the order.
	local report = Boot.run({
		side = "server",
		phases = {
			telemetry = phase("telemetry"),
			config = phase("config"),
			remotes = phase("remotes"),
			kits = phase("kits"),
		},
	}, env)
	t.ok(report.ok, tostring(report.reason))
	t.eq(order, { "config", "kits", "remotes", "telemetry" }, "order")
	t.eq(statuses(report), {
		"config=ok",
		"kits=ok",
		"data=skipped",
		"remotes=ok",
		"telemetry=ok",
		"ui=skipped",
		"input=skipped",
	}, "statuses")
	t.eq(report.phases[1].note, "config done", "note")
	t.eq(report.schema, "boot-report/1", "schema")
end)

test("the first failure stops later phases and runs cleanups in reverse order", function(t)
	local env, ran, cleaned = fakeEnv(), {}, {}
	local report = Boot.run({
		side = "server",
		phases = {
			config = function(ctx)
				ctx.addCleanup(function()
					table.insert(cleaned, "first")
				end)
				ctx.addCleanup(function()
					table.insert(cleaned, "second")
				end)
			end,
			kits = function()
				error("kit exploded", 0)
			end,
			data = function()
				table.insert(ran, "data")
			end,
			remotes = function()
				table.insert(ran, "remotes")
			end,
		},
	}, env)
	t.ok(not report.ok, "failed")
	t.eq(report.failed, "kits", "failed phase")
	t.eq(report.reason, "failed: kit exploded", "reason")
	t.eq(ran, {}, "later phases did not run")
	t.eq(statuses(report)[3], "data=not_run", "data not run")
	t.eq(statuses(report)[4], "remotes=not_run", "remotes not run")
	t.eq(cleaned, { "second", "first" }, "LIFO cleanup")
	t.eq(report.cleanups, 2, "cleanup count")
end)

test("a phase that yields past its timeout is cancelled and stops the boot", function(t)
	local env, resumed = fakeEnv(), false
	local report = Boot.run({
		side = "server",
		timeouts = { data = 2 },
		phases = {
			config = function() end,
			data = function()
				env.wait(100)
				resumed = true
			end,
			remotes = function() end,
		},
	}, env)
	t.ok(not report.ok, "timed out")
	t.eq(report.failed, "data", "failed phase")
	t.eq(report.phases[3].status, "timeout", "status")
	t.near(report.phases[3].seconds, 2, 1e-6, "stopped at the deadline")
	t.eq(report.phases[4].status, "not_run", "remotes")
	t.eq(env.cancelled, 1, "thread cancelled")
	env.wait(200)
	t.ok(not resumed, "a cancelled phase never resumes")
end)

test("a slow phase inside its timeout succeeds; the default timeout applies", function(t)
	local env = fakeEnv()
	local report = Boot.run({
		side = "client",
		defaultTimeout = 5,
		phases = {
			remotes = function()
				env.wait(3)
				return "late but fine"
			end,
		},
	}, env)
	t.ok(report.ok, tostring(report.reason))
	t.eq(report.phases[4].note, "late but fine", "note")
	t.near(report.seconds, 3, 0.06, "elapsed")
	local slowEnv = fakeEnv()
	local slow = Boot.run({
		side = "client",
		phases = {
			ui = function()
				slowEnv.wait(Boot.DEFAULT_TIMEOUT + 1)
			end,
		},
	}, slowEnv)
	t.eq(slow.failed, "ui", "default timeout")
end)

test("an invalid spec or env returns a failed report instead of raising", function(t)
	local report = Boot.run({ side = "server", phases = { ui = function() end } }, fakeEnv())
	t.eq(report.failed, "spec", "spec")
	t.ok(
		string.find(report.reason or "", "does not run on the server", 1, true) ~= nil,
		tostring(report.reason)
	)
	local noEnv = Boot.run({ side = "server", phases = {} }, {} :: any)
	t.eq(noEnv.failed, "spec", "env")
end)

test("onPhase sees every phase, and the report line is canonical JSON", function(t)
	local seen = {}
	local report = Boot.run({
		side = "server",
		phases = {
			config = function()
				return 'say "hi"'
			end,
		},
		onPhase = function(result)
			table.insert(seen, result.name)
		end,
	}, fakeEnv())
	t.eq(#seen, #Boot.PHASES, "callbacks")
	local line = Boot.line(report)
	t.eq(string.sub(line, 1, 12), "BOOT_REPORT ", "prefix")
	t.ok(
		string.find(
			line,
			'{"cleanups":0,"ok":true,"phases":[{"name":"config","note":"say \\"hi\\"",',
			1,
			true
		) ~= nil,
		line
	)
	t.eq(Boot.line(report), line, "same report, same line")
	t.eq(Boot.encode({ b = { 1, 2.5 }, a = {} }), '{"a":[],"b":[1,2.5]}', "encode")
end)

-- ------------------------------------------------------------------ KitLoader and Config

test("KitLoader finds present kits and reports absent, wrong-class and broken ones", function(t)
	local root = node("Kits", "Folder", nil, {
		node("GameKit", "Folder", nil, {
			node("Signal", "ModuleScript", { kind = "signal" }),
			node("Broken", "ModuleScript", "boom"),
			node("Notes", "Folder"),
		}),
	})
	t.eq(KitLoader.find(root, "GameKit/Signal", loader), { kind = "signal" }, "present")
	t.eq(select(2, KitLoader.find(root, "GameKit/Fsm", loader)), "absent", "absent")
	t.eq(select(2, KitLoader.find(root, "UIKit/Tokens", loader)), "absent", "absent kit")
	t.eq(select(2, KitLoader.find(root, "GameKit/Notes", loader)), "not_a_module", "folder")
	t.ok(
		string.find(select(2, KitLoader.find(root, "GameKit/Broken", loader)) or "", "load_error", 1, true)
			~= nil,
		"error"
	)
	t.eq(select(2, KitLoader.find(nil, "GameKit/Signal", loader)), "no_root", "no kits folder")
	local collected = KitLoader.collect(root, { "GameKit/Signal", "GameKit/Fsm", "GameKit/Broken" }, loader)
	t.eq(collected.present, { "GameKit/Signal" }, "present list")
	t.eq(collected.absent, { "GameKit/Fsm" }, "absent list")
	t.ok(collected.errors["GameKit/Broken"] ~= nil, "errors")
	t.eq(collected.modules.Signal, { kind = "signal" }, "short name")
	t.eq(
		KitLoader.missing(collected, { "GameKit/Signal", "GameKit/Fsm" }),
		{ "GameKit/Fsm: absent" },
		"missing"
	)
end)

test("the kits phase passes with no kits installed and fails on a missing required kit", function(t)
	local ctx = {}
	local note = KitLoader.phase({ config = Config, root = nil, loader = loader })(ctx)
	t.eq(note, "0 of 5 kit modules present", "no kits")
	t.eq(#ctx.kitStatus.absent, #KitLoader.STAGE0, "all absent")
	local strict = configWith({ ["kits.required"] = { "GameKit/Signal" } })
	t.throws(function()
		KitLoader.phase({ config = strict, root = nil, loader = loader })({})
	end, "required kit")
	local broken = node(
		"Kits",
		"Folder",
		nil,
		{ node("GameKit", "Folder", nil, { node("Fsm", "ModuleScript", "boom") }) }
	)
	t.throws(function()
		KitLoader.phase({ config = Config, root = broken, loader = loader })({})
	end, "an installed kit that fails to load fails the phase")
end)

test("Config starts with every field TBD and only rejects wrong types", function(t)
	t.eq(Config.validate(), {}, "template")
	t.eq(Config.undecided(), 9, "every field but the name is TBD")
	t.eq(Config.get("data.enabled", false), false, "TBD gives the default")
	t.eq(Config.get("missing.path", 7), 7, "absent gives the default")
	local values = table.clone(Config.values)
	values.data = { enabled = "yes" }
	values.kits = { required = { "GameKit/Signal", 3 } }
	values.loading = { timeoutSeconds = -1 }
	t.eq(Config.validate(values), {
		'data.enabled must be a boolean or "TBD"',
		'kits.required must be a list or "TBD"',
		'loading.timeoutSeconds must be a number or "TBD"',
	}, "type problems")
	values = table.clone(Config.values)
	values.ui = nil
	t.eq(Config.validate(values), { 'ui.root is missing (use "TBD" when undecided)' }, "missing field")
end)

-- ------------------------------------------------------------------ the starter's own phases

local function serverDeps(config: any, replicated: any): any
	return {
		config = config,
		kitLoader = KitLoader,
		kitsRoot = nil,
		loader = loader,
		replicatedStorage = replicated,
		newFolder = function(name: string, parent: any): any
			local folder = node(name, "Folder")
			parent.children[name] = folder
			return folder
		end,
	}
end

test("the server phases boot with every Config field TBD and no kits", function(t)
	local replicated = node("ReplicatedStorage", "ReplicatedStorage")
	local ctx = {}
	local report = Boot.run(
		{ side = "server", phases = ServerPhases.server(serverDeps(Config, replicated)), context = ctx },
		fakeEnv()
	)
	t.ok(report.ok, tostring(report.reason))
	t.ok(replicated.children.Remotes ~= nil, "Remotes folder created")
	t.eq(ctx.remotes, replicated.children.Remotes, "ctx.remotes")
	t.eq(select(2, ctx.events:emit({})), "no_sink", "null sink")
	t.eq(report.phases[3].note, "no data layer: Config.data.enabled is TBD", "data note")
end)

test("a server switch set to true without wiring fails its phase on purpose", function(t)
	local replicated = node("ReplicatedStorage", "ReplicatedStorage")
	local report = Boot.run({
		side = "server",
		phases = ServerPhases.server(serverDeps(configWith({ ["data.enabled"] = true }), replicated)),
	}, fakeEnv())
	t.eq(report.failed, "data", "data phase")
	t.eq(report.phases[4].status, "not_run", "remotes not run")
	local telemetry = Boot.run({
		side = "server",
		phases = ServerPhases.server(serverDeps(configWith({ ["telemetry.enabled"] = true }), replicated)),
	}, fakeEnv())
	t.eq(telemetry.failed, "telemetry", "telemetry phase")
end)

local function clientDeps(env: any, replicated: any, settingsKit: any?): any
	local playerGui = node("PlayerGui", "PlayerGui")
	function replicated.WaitForChild(this: any, name: string): any
		while this.children[name] == nil do
			env.wait(0.1)
		end
		return this.children[name]
	end
	local kitsRoot = if settingsKit
		then node(
			"Kits",
			"Folder",
			nil,
			{ node("GameKit", "Folder", nil, { node("Settings", "ModuleScript", settingsKit) }) }
		)
		else nil
	return {
		config = Config,
		kitLoader = KitLoader,
		kitsRoot = kitsRoot,
		loader = loader,
		replicatedStorage = replicated,
		playerGui = playerGui,
		systemReducedMotion = function(): boolean
			return true
		end,
		newScreenGui = function(name: string, parent: any): any
			local gui = node(name, "ScreenGui")
			parent.children[name] = gui
			return gui
		end,
	}
end

test("the client phases boot, mount an empty UI root and record motion preferences", function(t)
	local env = fakeEnv()
	local replicated = node("ReplicatedStorage", "ReplicatedStorage", nil, { node("Remotes", "Folder") })
	local ctx = {}
	local deps = clientDeps(env, replicated)
	local report = Boot.run({ side = "client", phases = ClientPhases.client(deps), context = ctx }, env)
	t.ok(report.ok, tostring(report.reason))
	t.eq(ctx.motion, { reducedMotion = true, allowFlashes = true }, "system reduced motion, flashes allowed")
	t.ok(deps.playerGui.children.GameRoot ~= nil, "root ScreenGui")
	t.eq(statuses(report)[3], "data=skipped", "data is server-only")
end)

test("the client reads motion through GameKit/Settings when it is installed", function(t)
	local fakeSettings = {
		defaults = function()
			return { reduceFlashing = true }
		end,
		effective = function(values: any, system: any): any
			return { reducedMotion = system.reducedMotion, allowFlashes = not values.reduceFlashing }
		end,
	}
	t.eq(
		ClientPhases.motion(fakeSettings, false),
		{ reducedMotion = false, allowFlashes = false },
		"settings"
	)
	t.eq(ClientPhases.motion(nil, false), { reducedMotion = false, allowFlashes = true }, "fallback")
	local env = fakeEnv()
	local replicated = node("ReplicatedStorage", "ReplicatedStorage", nil, { node("Remotes", "Folder") })
	local ctx = {}
	local report = Boot.run({
		side = "client",
		phases = ClientPhases.client(clientDeps(env, replicated, fakeSettings)),
		context = ctx,
	}, env)
	t.ok(report.ok, tostring(report.reason))
	t.eq(ctx.motion.allowFlashes, false, "reduceFlashing honoured")
end)

test("a client whose server never made Remotes times out in the remotes phase", function(t)
	local env = fakeEnv()
	local replicated = node("ReplicatedStorage", "ReplicatedStorage")
	local report = Boot.run({
		side = "client",
		phases = ClientPhases.client(clientDeps(env, replicated)),
		timeouts = { remotes = 1 },
	}, env)
	t.eq(report.failed, "remotes", "remotes phase")
	t.eq(report.phases[4].status, "timeout", "timeout")
	t.eq(report.phases[6].status, "not_run", "ui not run")
end)

return cases
