--!strict
-- G1 player data: GameKit/PlayerData (core, memory, DataStore and ProfileStore backends) and
-- GameKit/PlayerDataRoblox (bind, chooseBackend) against FakeEnv, FakeDataStore,
-- FakeProfileStore and FakePlatformRoblox. Covers migrations v1 to v3, template reconcile,
-- refused loads that leave stored data untouched, session conflicts (ProfileStore handoff,
-- DataStore lock wait, expiry and takeover), release on leave, serial saves, retries and
-- fatal errors, grant-once receipts, the autosave scheduler and the shutdown flush.
local FakeDataStore = require("./fakes/FakeDataStore")
local FakeEnv = require("./fakes/FakeEnv")
local FakePlatformRoblox = require("./fakes/FakePlatformRoblox")
local FakeProfileStore = require("./fakes/FakeProfileStore")
local PlayerData = require("../packages/GameKit/PlayerData")
local PlayerDataRoblox = require("../packages/GameKit/PlayerDataRoblox")
local Schema = require("../packages/GameKit/Schema")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

local function anyReport(env: any, needle: string): boolean
	for _, line in env.reports do
		if has(line, needle) then
			return true
		end
	end
	return false
end

-- Starts fn on an env thread; the getter returns its packed results once it finished.
local function go(env: any, fn: () -> ...any): () -> any
	local out = nil
	env.spawn(function()
		out = table.pack(fn())
	end)
	return function(): any
		return out
	end
end

local function settle(env: any, done: () -> boolean, steps: number?)
	for _ = 1, steps or 3000 do
		if done() then
			return
		end
		env:advance(0.1)
		env:flush()
	end
	error("did not settle: " .. table.concat(env.errors, "\n"), 2)
end

-- Runs fn on an env thread to completion (advancing the fake clock) and returns its results.
local function run(env: any, fn: () -> ...any): ...any
	local result = go(env, fn)
	settle(env, function(): boolean
		return result() ~= nil
	end)
	local out = result()
	return table.unpack(out, 1, out.n)
end

local TEMPLATE = { visits = 0, flags = {}, inventory = { slots = 4, items = {} } }

local function memoryOptions(shared: any?, serverId: string?, extra: { [string]: any }?): any
	local options: { [string]: any } = {
		template = TEMPLATE,
		version = 1,
		backend = PlayerData.memoryBackend({ serverId = serverId or "a", shared = shared }),
		autosave = { interval = 10, jitter = 0, seed = 1 },
	}
	for key, value in extra or {} do
		options[key] = value
	end
	return options
end

local function newShared(): any
	return { values = {}, locks = {} }
end

-- ---------------------------------------------------------------- options and pure helpers

test("validate lists every problem and new raises with all of them", function(t)
	local problems = PlayerData.validate({
		template = { schemaVersion = 1, bad = 0 / 0 },
		version = 0,
		firstVersion = 2,
		migrations = { [7] = function() end },
		backend = {},
		keyPrefix = "has space",
		sizeBudget = 5000000,
		receiptRing = 0,
		autosave = { interval = -1, jitter = 1 },
		closeDeadline = 0,
	})
	local text = table.concat(problems, "\n")
	for _, needle in
		{
			"template is not storable",
			"reserved key schemaVersion",
			"version must be",
			"firstVersion",
			"unused step 7",
			"backend must have an open function",
			"keyPrefix",
			"sizeBudget",
			"receiptRing",
			"autosave.interval",
			"autosave.jitter",
			"closeDeadline",
		}
	do
		t.ok(has(text, needle), "missing problem: " .. needle .. "\n" .. text)
	end
	t.eq(PlayerData.validate(nil), { "options must be a table" })
	local missing = PlayerData.validate({ template = {}, version = 3, backend = PlayerData.memoryBackend() })
	t.ok(has(table.concat(missing, "\n"), "migrations[1] (version 1 to 2) is missing"))
	t.ok(has(table.concat(missing, "\n"), "migrations[2] (version 2 to 3) is missing"))
	local err = errorText(function()
		PlayerData.new(
			{ template = 5, version = 1, backend = PlayerData.memoryBackend() } :: any,
			FakeEnv.new()
		)
	end)
	t.ok(has(err, "PlayerData.new") and has(err, "template must be a table"), err)
	t.ok(has(
		errorText(function()
			PlayerData.new(memoryOptions(), nil)
		end),
		"env with clock, spawn and wait"
	))
	t.eq(#PlayerData.validate(memoryOptions()), 0)
end)

test("validate keeps the DataStore lock refreshed by autosave", function(t)
	local env = FakeEnv.new()
	local backend = PlayerData.dataStoreBackend(
		FakeDataStore.new(),
		{ serverId = "a", now = env.clock, lockTimeout = 100 },
		env
	)
	local off = PlayerData.validate({ template = {}, version = 1, backend = backend, autosave = false })
	t.ok(has(table.concat(off, "\n"), "autosave = false lets the dataStoreBackend lock expire"))
	local slow =
		PlayerData.validate({ template = {}, version = 1, backend = backend, autosave = { interval = 95 } })
	t.ok(has(table.concat(slow, "\n"), "shorter than the backend lockTimeout"))
	t.eq(
		PlayerData.validate({ template = {}, version = 1, backend = backend, autosave = { interval = 60 } }),
		{}
	)
	-- the memory backend has no lock to refresh
	t.eq(
		PlayerData.validate({
			template = {},
			version = 1,
			backend = PlayerData.memoryBackend(),
			autosave = false,
		}),
		{}
	)
end)

test("reconcile fills missing keys deeply and never overwrites or removes", function(t)
	local data = { visits = 7, flags = { seen = true }, extra = "kept", inventory = { items = { "a" } } }
	PlayerData.reconcile(data, TEMPLATE)
	t.eq(
		data,
		{ visits = 7, flags = { seen = true }, extra = "kept", inventory = { slots = 4, items = { "a" } } }
	)
	-- a template list is not merged into an existing list
	local listed = { order = { 3 } }
	PlayerData.reconcile(listed, { order = { 1, 2 } })
	t.eq(listed.order, { 3 })
	-- filled values are copies, not the template's tables
	local fresh = PlayerData.reconcile({}, TEMPLATE)
	fresh.inventory.items[1] = "x"
	t.eq(TEMPLATE.inventory.items, {})
	-- a value of another type is left alone
	local typed = PlayerData.reconcile({ flags = "legacy" }, TEMPLATE)
	t.eq(typed.flags, "legacy")
end)

test("scheduler spreads first saves by jitter and keeps a steady cadence", function(t)
	local env = FakeEnv.new()
	local scheduler = PlayerData.scheduler({ interval = 100, jitter = 0.2, rng = env.rng("s") })
	local firsts = {}
	for id = 1, 50 do
		local at = scheduler:add(id, 0)
		t.ok(at >= 80 and at <= 120, "first save within interval +- jitter: " .. at)
		firsts[id] = at
	end
	t.eq(scheduler:size(), 50)
	t.eq(#scheduler:due(79.9), 0)
	local due = scheduler:due(120)
	t.eq(#due, 50)
	for index = 2, #due do
		t.ok(firsts[due[index - 1]] <= firsts[due[index]], "due oldest first")
	end
	t.eq(scheduler:nextAt(1), firsts[1] + 100)
	scheduler:remove(1)
	t.eq(scheduler:nextAt(1), nil)
	t.eq(scheduler:size(), 49)
	-- a stalled server (far behind) restarts from now instead of saving in a burst
	local steady = PlayerData.scheduler({ interval = 10, jitter = 0, rng = env.rng("t") })
	steady:add("p", 0)
	t.eq(steady:due(10), { "p" })
	t.eq(steady:nextAt("p"), 20)
	t.eq(steady:due(1000), { "p" })
	t.eq(steady:nextAt("p"), 1010)
	t.throws(function()
		PlayerData.scheduler({ interval = 0, rng = env.rng("x") })
	end)
	t.throws(function()
		PlayerData.scheduler({ interval = 1, jitter = 1, rng = env.rng("x") })
	end)
	t.throws(function()
		PlayerData.scheduler({ interval = 1 } :: any)
	end)
end)

-- ---------------------------------------------------------------- migrations and refused loads

local function v3Options(shared: any): any
	return {
		template = { visits = 0, profile = { title = "" }, settings = { volume = 1 } },
		version = 3,
		migrations = {
			-- v1 stored a flat `count`; v2 calls it visits
			[1] = function(data: any): any
				data.visits = data.count or 0
				data.count = nil
				data.trail = { 1 }
				return data
			end,
			-- v2 kept the title at the top; v3 nests it
			[2] = function(data: any): any
				data.profile = { title = data.title or "" }
				data.title = nil
				table.insert(data.trail, 2)
				return data
			end,
		},
		backend = PlayerData.memoryBackend({ serverId = "a", shared = shared }),
	}
end

test("migrations run v1 to v3 in order on a copy and reconcile the template", function(t)
	local env = FakeEnv.new()
	local shared = newShared()
	shared.values.player_11 = { schemaVersion = 1, count = 9, title = "t" }
	shared.values.player_12 = { schemaVersion = 2, visits = 3, title = "u", trail = { 1 } }
	shared.values.player_13 = { count = 2 } -- written before versioning: treated as version 1
	local store = PlayerData.new(v3Options(shared), env)
	local a = run(env, function()
		return store:load(11)
	end)
	t.eq(a:get(), {
		schemaVersion = 3,
		purchaseIds = {},
		visits = 9,
		profile = { title = "t" },
		settings = { volume = 1 },
		trail = { 1, 2 },
	})
	-- stored data is untouched until a save
	t.eq(shared.values.player_11, { schemaVersion = 1, count = 9, title = "t" })
	local b = run(env, function()
		return store:load(12)
	end)
	t.eq(b:get("profile.title"), "u")
	t.eq(b:get("trail"), { 1, 2 }, "only the v2 to v3 step ran")
	local c = run(env, function()
		return store:load(13)
	end)
	t.eq(c:get("visits"), 2)
	t.eq(c:get("schemaVersion"), 3)
	t.ok(run(env, function()
		return a:release()
	end))
	t.eq(shared.values.player_11.schemaVersion, 3)
	t.eq(shared.values.player_11.count, nil)
	-- a fresh user gets the template at the current version
	local fresh = run(env, function()
		return store:load(14)
	end)
	t.eq(fresh:get(), {
		schemaVersion = 3,
		purchaseIds = {},
		visits = 0,
		profile = { title = "" },
		settings = { volume = 1 },
	})
end)

test("refused loads leave stored data untouched and free the lock", function(t)
	local env = FakeEnv.new()
	local shared = newShared()
	local cases: { { value: any, reason: string } } = {
		{ value = { schemaVersion = 4 }, reason = "newer_schema" },
		{ value = "text", reason = "corrupt" },
		{ value = { schemaVersion = "2" }, reason = "corrupt" },
		{ value = { schemaVersion = 0 }, reason = "corrupt" },
		{ value = { schemaVersion = 3, purchaseIds = { [2] = "x" } }, reason = "corrupt" },
		{ value = { schemaVersion = 3, purchaseIds = { "bad id!" } }, reason = "corrupt" },
		{ value = { schemaVersion = 3, visits = 0 / 0 }, reason = "invalid" },
	}
	local store = PlayerData.new(v3Options(shared), env)
	for index, case in cases do
		local key = "player_" .. (100 + index)
		shared.values[key] = case.value
		local session, reason = run(env, function()
			return store:load(100 + index)
		end)
		t.eq(session, nil, case.reason)
		t.eq(reason, case.reason, key)
		t.ok(shared.values[key] == case.value, key .. " untouched")
		t.eq(shared.locks[key], nil, key .. " lock released")
	end
	t.ok(anyReport(env, "stored data left untouched"))
	-- a migration that raises or returns a non-table
	local failing = v3Options(shared)
	failing.migrations[2] = function(): any
		error("boom")
	end
	local failStore = PlayerData.new(failing, env)
	shared.values.player_200 = { schemaVersion = 2, visits = 1 }
	local _, reason = run(env, function()
		return failStore:load(200)
	end)
	t.eq(reason, "migration_failed")
	t.ok(anyReport(env, "step 2"))
	failing.migrations[2] = function(): any
		return 5
	end
	local _, reason2 = run(env, function()
		return PlayerData.new(failing, env):load(200)
	end)
	t.eq(reason2, "migration_failed")
	-- schema and size budget on load
	local strict = v3Options(shared)
	strict.schema = Schema.struct({
		visits = Schema.integer({ min = 0 }),
		profile = Schema.struct({ title = Schema.string({ maxLen = 8 }) }),
		settings = Schema.any(),
	})
	shared.values.player_201 = { schemaVersion = 3, visits = -1 }
	local _, schemaReason = run(env, function()
		return PlayerData.new(strict, env):load(201)
	end)
	t.eq(schemaReason, "invalid")
	local small = v3Options(shared)
	small.sizeBudget = 40
	shared.values.player_202 = { schemaVersion = 3, visits = 1, profile = { title = string.rep("x", 60) } }
	local _, sizeReason = run(env, function()
		return PlayerData.new(small, env):load(202)
	end)
	t.eq(sizeReason, "too_large")
end)

test("load refuses bad users, repeats return the same session, closed stores refuse", function(t)
	local env = FakeEnv.new()
	local store = PlayerData.new(memoryOptions(newShared()), env)
	for _, bad in { 0, -1, 1.5, 0 / 0, "5" :: any } do
		local session, reason = run(env, function()
			return store:load(bad)
		end)
		t.eq(session, nil)
		t.eq(reason, "invalid_user", tostring(bad))
	end
	local first = run(env, function()
		return store:load(5)
	end)
	local second = run(env, function()
		return store:load(5)
	end)
	t.ok(first ~= nil and first == second, "the same session")
	t.eq(store:loaded(), { 5 })
	t.eq(store:keyFor(5), "player_5")
	t.throws(function()
		store:keyFor(0)
	end)
	local summary = run(env, function()
		return store:releaseAll()
	end)
	t.eq(summary.released, { 5 })
	local _, reason = run(env, function()
		return store:load(6)
	end)
	t.eq(reason, "closed")
end)

test("a second load while the first is running reports loading", function(t)
	local env = FakeEnv.new()
	local ds = FakeDataStore.new({ env = env, latency = 1 })
	local store = PlayerData.new({
		template = TEMPLATE,
		version = 1,
		backend = PlayerData.dataStoreBackend(ds, { serverId = "a", now = env.clock }, env),
	}, env)
	local first = go(env, function()
		return store:load(8)
	end)
	local _, reason = run(env, function()
		return store:load(8)
	end)
	t.eq(reason, "loading")
	settle(env, function(): boolean
		return first() ~= nil
	end)
	t.ok(first()[1] ~= nil)
end)

-- ---------------------------------------------------------------- session updates

test("update commits a validated copy and failed updates change nothing", function(t)
	local env = FakeEnv.new()
	local options = memoryOptions(newShared())
	options.schema = Schema.struct({
		visits = Schema.integer({ min = 0, max = 1000 }),
		flags = Schema.map(Schema.string({ maxLen = 16 }), Schema.boolean()),
		inventory = Schema.any(),
	})
	options.sizeBudget = 400
	local store = PlayerData.new(options, env)
	local session = run(env, function()
		return store:load(1)
	end)
	local changes = 0
	session.changed:Connect(function()
		changes += 1
	end)
	t.ok(session:update(function(data: any): any
		data.visits += 1
		return nil
	end))
	t.eq(session:get("visits"), 1)
	-- returning a new table works too
	t.ok(session:update(function(data: any): any
		return { visits = 2, flags = data.flags, inventory = data.inventory }
	end))
	t.eq(session:get("visits"), 2)
	t.eq(changes, 2)
	local before = session:get()
	local function expectRefused(fn: any, reason: string)
		local ok, why, detail = session:update(fn)
		t.eq(ok, false, reason)
		t.eq(why, reason, tostring(detail))
		t.eq(session:get(), before, reason .. " left data unchanged")
	end
	expectRefused(function(data: any): any
		data.visits = 99
		error("halfway")
	end, "update_failed")
	expectRefused(function(): any
		return 5
	end, "update_failed")
	expectRefused(function(data: any): any
		data.visits = 0 / 0
		return nil
	end, "not_storable")
	expectRefused(function(data: any): any
		data.flags = { [1] = true, x = true }
		return nil
	end, "not_storable")
	expectRefused(function(data: any): any
		data.visits = -5
		return nil
	end, "schema")
	expectRefused(function(data: any): any
		data.flags = { a = "yes" }
		return nil
	end, "schema")
	expectRefused(function(data: any): any
		data.inventory.items = table.create(200, "abc")
		return nil
	end, "too_large")
	t.eq(changes, 2, "no change events for refused updates")
	-- the reserved keys cannot be changed through update
	t.ok(session:update(function(data: any): any
		data.schemaVersion = 99
		data.purchaseIds = { "forged" }
		return nil
	end))
	t.eq(session:get("schemaVersion"), 1)
	t.eq(session:get("purchaseIds"), {})
	-- re-entering update from inside fn is refused
	local inner = nil
	session:update(function(data: any): any
		inner = table.pack(session:update(function(): any
			return nil
		end))
		return nil
	end)
	t.eq(inner[2], "busy")
end)

test("committed data never aliases tables the caller kept", function(t)
	local env = FakeEnv.new()
	local session = run(env, function()
		return PlayerData.new(memoryOptions(newShared()), env):load(1)
	end)
	local kept = nil
	session:update(function(data: any): any
		kept = data.flags
		data.flags.ok = true
		return nil
	end)
	kept.ok = false
	kept.injected = 0 / 0
	t.eq(session:get("flags"), { ok = true })
	-- get returns copies
	local copy = session:get("inventory")
	copy.slots = 999
	t.eq(session:get("inventory.slots"), 4)
	t.eq(session:get({ "inventory", "slots" }), 4)
	t.eq(session:get("missing.path"), nil)
	t.eq(session:get("visits.deeper"), nil)
end)

test("set builds paths, refuses reserved keys and keyStore scopes keys", function(t)
	local env = FakeEnv.new()
	local session = run(env, function()
		return PlayerData.new(memoryOptions(newShared()), env):load(1)
	end)
	t.ok(session:set("a.b.c", 3))
	t.eq(session:get("a"), { b = { c = 3 } })
	t.ok(session:set({ "flags", "tutorial" }, true))
	t.eq(session:get("flags.tutorial"), true)
	local ok, reason, detail = session:set("purchaseIds", {})
	t.eq({ ok, reason, detail }, { false, "reserved_key", "purchaseIds" })
	t.eq(select(2, session:set("schemaVersion", 9)), "reserved_key")
	t.eq(select(2, session:set("x", 0 / 0)), "not_storable")
	local settings = session:keyStore("settings")
	t.ok(settings:set("volume", 0.5))
	t.eq(settings:get("volume"), 0.5)
	t.eq(session:get("settings"), { volume = 0.5 })
	local root = session:keyStore()
	t.eq(root:get("visits"), 0)
	t.throws(function()
		settings:set("a.b", 1)
	end)
	t.throws(function()
		settings:get("")
	end)
end)

-- ---------------------------------------------------------------- receipts

test("grantReceipt grants once, records the id and needs a durable save", function(t)
	local env = FakeEnv.new()
	local shared = newShared()
	local options = memoryOptions(shared)
	options.receiptRing = 3
	local store = PlayerData.new(options, env)
	local session = run(env, function()
		return store:load(1)
	end)
	local grants = 0
	local function grant(data: any): any
		grants += 1
		data.visits += 10
		return nil
	end
	t.eq(
		run(env, function()
			return session:grantReceipt("p1", grant)
		end),
		"granted"
	)
	t.eq(
		run(env, function()
			return session:grantReceipt("p1", grant)
		end),
		"granted",
		"a repeated receipt is acknowledged"
	)
	t.eq(grants, 1)
	t.eq(shared.values.player_1.visits, 10)
	t.eq(shared.values.player_1.purchaseIds, { "p1" })
	t.ok(session:hasReceipt("p1"))
	-- invalid ids and a failing grant are not processed
	local status, why = run(env, function()
		return session:grantReceipt("bad id", grant)
	end)
	t.eq({ status, why }, { "not_processed", "invalid_purchase_id" })
	status, why = run(env, function()
		return session:grantReceipt("p2", function(): any
			error("grant failed")
		end)
	end)
	t.eq({ status, why }, { "not_processed", "update_failed" })
	t.ok(not session:hasReceipt("p2"), "a failed grant records nothing")
	-- the ring keeps the newest receiptRing ids
	for _, id in { "p3", "p4", "p5" } do
		run(env, function()
			return session:grantReceipt(id, grant)
		end)
	end
	t.eq(session:get("purchaseIds"), { "p3", "p4", "p5" })
	-- a failed save leaves the receipt not processed; the retry does not grant again
	options.backend.failSaves = 1
	local before = grants
	status, why = run(env, function()
		return session:grantReceipt("p6", grant)
	end)
	t.eq({ status, why }, { "not_processed", "save_failed" })
	t.eq(
		run(env, function()
			return session:grantReceipt("p6", grant)
		end),
		"granted"
	)
	t.eq(grants, before + 1)
	-- an inactive session never grants
	run(env, function()
		return session:release()
	end)
	status, why = run(env, function()
		return session:grantReceipt("p7", grant)
	end)
	t.eq({ status, why }, { "not_processed", "inactive" })
end)

-- ---------------------------------------------------------------- memory backend sessions

test("release on leave saves, unlocks and is idempotent", function(t)
	local env = FakeEnv.new()
	local shared = newShared()
	local store = PlayerData.new(memoryOptions(shared), env)
	local session = run(env, function()
		return store:load(3)
	end)
	session:set("visits", 4)
	t.eq(shared.locks.player_3, "a")
	t.eq({
		run(env, function()
			return session:release()
		end),
	}, { true })
	t.eq(shared.values.player_3.visits, 4)
	t.eq(shared.locks.player_3, nil)
	t.ok(not session:isActive())
	t.eq(store:get(3), nil)
	t.eq(store:loaded(), {})
	t.eq(
		select(
			2,
			session:update(function(): any
				return nil
			end)
		),
		"inactive"
	)
	t.eq({
		run(env, function()
			return session:release()
		end),
	}, { true }, "second release is a no-op")
	t.eq({
		run(env, function()
			return store:release(99)
		end),
	}, { true }, "releasing an unknown user is a no-op")
	t.eq(select(2, session:saveAsync()), "inactive")
end)

test("memory servers sharing storage lock each other out until release", function(t)
	local env = FakeEnv.new()
	local shared = newShared()
	local storeA = PlayerData.new(memoryOptions(shared, "a"), env)
	local storeB = PlayerData.new(memoryOptions(shared, "b"), env)
	local a = run(env, function()
		return storeA:load(4)
	end)
	local _, reason = run(env, function()
		return storeB:load(4)
	end)
	t.eq(reason, "locked")
	run(env, function()
		return a:release()
	end)
	local b = run(env, function()
		return storeB:load(4)
	end)
	t.ok(b ~= nil)
	-- a stolen lock is detected at the next save and the session is lost
	local lostWhy = nil
	local storeLost = nil
	b.onSessionLost:Connect(function(why: string)
		lostWhy = why
	end)
	storeB.sessionLost:Connect(function(userId: number, why: string)
		storeLost = { userId, why }
	end)
	b:set("visits", 1)
	storeB._backend:steal("player_4", "c")
	local ok, why = b:saveAsync()
	t.eq({ ok, why }, { false, "lock_lost" })
	t.eq(lostWhy, "lock_lost")
	t.eq(storeLost, { 4, "lock_lost" })
	t.ok(not b:isActive())
	t.eq(storeB:get(4), nil)
	t.eq({ b:release() }, { false, "lost" })
end)

test("open errors and failed closes are reported, not raised", function(t)
	local env = FakeEnv.new()
	local backend = {
		name = "broken",
		managesAutosave = false,
		open = function(): any
			error("backend down")
		end,
	}
	local store = PlayerData.new({ template = {}, version = 1, backend = backend :: any }, env)
	local _, reason = run(env, function()
		return store:load(1)
	end)
	t.eq(reason, "backend_error")
	t.ok(anyReport(env, "backend down"))
	-- a backend that refuses without a reason
	local silent = PlayerData.new({
		template = {},
		version = 1,
		backend = {
			name = "silent",
			managesAutosave = false,
			open = function(): any
				return nil
			end,
		} :: any,
	}, env)
	t.eq(
		select(
			2,
			run(env, function()
				return silent:load(1)
			end)
		),
		"backend_error"
	)
end)

-- ---------------------------------------------------------------- DataStore backend

local function dataStoreSetup(env: any, world: any, serverId: string, clock: () -> number, extra: any?): any
	local ds = FakeDataStore.new({ world = world, env = env, latency = extra and extra.latency })
	local backend = PlayerData.dataStoreBackend(ds, {
		serverId = serverId,
		now = clock,
		lockTimeout = 300,
		lockRetry = 1,
		lockWait = 3,
	}, env)
	local store = PlayerData.new({
		template = TEMPLATE,
		version = 1,
		backend = backend,
		autosave = { interval = 60, jitter = 0, seed = 1 },
	}, env)
	return store, ds
end

test("dataStoreBackend locks in metadata, waits, expires and detects a takeover", function(t)
	local env = FakeEnv.new()
	local world = FakeDataStore.world()
	local utc = 1000
	local function now(): number
		return utc
	end
	local storeA, dsA = dataStoreSetup(env, world, "A", now)
	local storeB = dataStoreSetup(env, world, "B", now)
	local a = run(env, function()
		return storeA:load(21)
	end)
	local _, meta = dsA:peek("player_21")
	t.eq(meta, { lock = { server = "A", at = 1000 } })
	a:set("visits", 5)
	t.ok(a:saveAsync())
	t.eq((dsA:peek("player_21")).visits, 5)
	-- B waits lockWait seconds, then gives up
	local started = env.clock()
	local _, reason = run(env, function()
		return storeB:load(21)
	end)
	t.eq(reason, "locked")
	t.ok(env.clock() - started >= 2, "B waited for the lock")
	-- A's lock expires (A crashed without unlocking): B takes over with A's last save
	utc += 301
	local b = run(env, function()
		return storeB:load(21)
	end)
	t.ok(b ~= nil)
	t.eq(b:get("visits"), 5)
	t.eq((select(2, dsA:peek("player_21"))).lock.server, "B")
	-- A's next save sees the lost lock and never writes over B
	local lostWhy = nil
	a.onSessionLost:Connect(function(why: string)
		lostWhy = why
	end)
	a:set("visits", 666)
	local ok, why = run(env, function()
		return a:saveAsync()
	end)
	t.eq({ ok, why }, { false, "lock_lost" })
	t.eq(lostWhy, "lock_lost")
	t.eq((dsA:peek("player_21")).visits, 5)
	-- B's release writes and clears the lock
	b:set("visits", 6)
	t.ok(run(env, function()
		return b:release()
	end))
	local value, metaAfter = dsA:peek("player_21")
	t.eq(value.visits, 6)
	t.eq(metaAfter.lock, nil)
end)

test("dataStoreBackend retries throttles and server errors but not fatal errors", function(t)
	local env = FakeEnv.new()
	local world = FakeDataStore.world()
	local store, ds = dataStoreSetup(env, world, "A", env.clock)
	ds:fail(2, "301: GetAsync request dropped. Request was throttled")
	local session = run(env, function()
		return store:load(31)
	end)
	t.ok(session ~= nil, "loaded after two throttles")
	t.eq(ds.calls, 3)
	ds:fail(1, "104: Cannot store value in data store")
	local calls = ds.calls
	local ok, why = run(env, function()
		return session:saveAsync()
	end)
	t.eq({ ok, why }, { false, "save_failed" })
	t.eq(ds.calls, calls + 1, "a fatal error is not retried")
	t.ok(anyReport(env, "save failed"))
	-- five server errors exhaust the retries
	ds:fail(5, "502: API Services rejected request")
	calls = ds.calls
	ok, why = run(env, function()
		return session:saveAsync()
	end)
	t.eq({ ok, why }, { false, "save_failed" })
	t.eq(ds.calls, calls + 5)
	-- and the next save works
	t.ok(run(env, function()
		return session:saveAsync()
	end))
	-- a load that cannot reach the store
	ds:fail(5, "502: API Services rejected request")
	local _, reason = run(env, function()
		return store:load(32)
	end)
	t.eq(reason, "backend_error")
	t.ok(anyReport(env, "lock read failed"))
end)

test("dataStoreBackend saves one at a time and the newest snapshot wins", function(t)
	local env = FakeEnv.new()
	local world = FakeDataStore.world()
	local store, ds = dataStoreSetup(env, world, "A", env.clock, { latency = 1 })
	local session = run(env, function()
		return store:load(41)
	end)
	local calls = ds.calls
	session:set("visits", 1)
	session:save()
	session:set("visits", 2)
	session:save()
	session:set("visits", 3)
	session:save()
	settle(env, function(): boolean
		return (ds:peek("player_41")).visits == 3
	end)
	env:advance(5)
	t.eq(ds.calls - calls, 2, "the queued saves collapse into one follow-up write")
	t.eq((ds:peek("player_41")).visits, 3)
	-- saveAsync waits for its own data, even when a save is already in flight
	session:set("visits", 4)
	session:save()
	session:set("visits", 5)
	t.ok(run(env, function()
		return session:saveAsync()
	end))
	t.eq((ds:peek("player_41")).visits, 5)
	-- release waits for an in-flight save and then writes the final state
	session:set("visits", 6)
	session:save()
	session:set("visits", 7)
	t.ok(run(env, function()
		return session:release()
	end))
	local value, meta = ds:peek("player_41")
	t.eq(value.visits, 7)
	t.eq(meta.lock, nil)
end)

test("dataStoreBackend receipts survive a failed save without granting twice", function(t)
	local env = FakeEnv.new()
	local store, ds = dataStoreSetup(env, FakeDataStore.world(), "A", env.clock)
	local session = run(env, function()
		return store:load(51)
	end)
	local grants = 0
	local function grant(data: any): any
		grants += 1
		data.visits += 1
		return nil
	end
	ds:fail(5, "503: service unavailable")
	local status, why = run(env, function()
		return session:grantReceipt("r1", grant)
	end)
	t.eq({ status, why }, { "not_processed", "save_failed" })
	t.eq(
		run(env, function()
			return session:grantReceipt("r1", grant)
		end),
		"granted"
	)
	t.eq(grants, 1)
	t.eq((ds:peek("player_51")).purchaseIds, { "r1" })
end)

test("a load cancelled while waiting or after loading releases the lock without writing", function(t)
	local env = FakeEnv.new()
	local world = FakeDataStore.world()
	local storeA = dataStoreSetup(env, world, "A", env.clock)
	local storeB, dsB = dataStoreSetup(env, world, "B", env.clock, { latency = 1 })
	run(env, function()
		return storeA:load(61)
	end)
	local left = false
	local pending = go(env, function()
		return storeB:load(61, {
			cancel = function(): boolean
				return left
			end,
		})
	end)
	env:advance(1.5)
	left = true
	settle(env, function(): boolean
		return pending() ~= nil
	end)
	t.eq(pending()[2], "cancelled")
	-- cancelled after the data arrived: the lock is released, the stored value not rewritten
	dsB:poke("player_62", { schemaVersion = 1, visits = 2 })
	-- cancel() is asked before the lock read and again once the data arrived: say "left" then
	local asked = 0
	local loading = go(env, function()
		return storeB:load(62, {
			cancel = function(): boolean
				asked += 1
				return asked >= 2
			end,
		})
	end)
	settle(env, function(): boolean
		return loading() ~= nil
	end)
	t.eq(loading()[2], "cancelled")
	local value, meta = dsB:peek("player_62")
	t.eq(value, { schemaVersion = 1, visits = 2 }, "not rewritten with the template")
	t.eq(meta.lock, nil)
	t.eq(storeB:get(62), nil)
end)

-- ---------------------------------------------------------------- ProfileStore backend

local function profileStore(world: any, jobId: string, extra: any?): any
	return PlayerData.new({
		template = TEMPLATE,
		version = 1,
		backend = PlayerData.profileStoreBackend(world:server(jobId), "PlayerData", extra),
	}, world.env)
end

test("profileStoreBackend: a second server takes the session and the first one is told", function(t)
	local env = FakeEnv.new()
	local world = FakeProfileStore.world(env)
	local storeA = profileStore(world, "A")
	local storeB = profileStore(world, "B")
	local a = run(env, function()
		return storeA:load(71)
	end)
	t.ok(a ~= nil)
	a:set("visits", 3)
	local lostWhy = nil
	local storeLost = nil
	a.onSessionLost:Connect(function(why: string)
		lostWhy = why
	end)
	storeA.sessionLost:Connect(function(userId: number, why: string)
		storeLost = { userId, why }
	end)
	local b = run(env, function()
		return storeB:load(71)
	end)
	t.ok(b ~= nil)
	t.eq(b:get("visits"), 3, "B starts from A's final save")
	t.eq(lostWhy, "session_ended")
	t.eq(storeLost, { 71, "session_ended" })
	t.ok(not a:isActive())
	t.eq(storeA:get(71), nil)
	t.eq(
		select(
			2,
			a:update(function(): any
				return nil
			end)
		),
		"inactive"
	)
	t.eq({ a:release() }, { false, "lost" })
	-- B's own release ends the session without reporting a loss
	local bLost = false
	b.onSessionLost:Connect(function()
		bLost = true
	end)
	t.ok(run(env, function()
		return b:release()
	end))
	t.ok(not bLost)
	t.eq(world:peek("PlayerData", "player_71").visits, 3)
end)

test("profileStoreBackend: a holder that never answers is waited on until cancel", function(t)
	local env = FakeEnv.new()
	local world = FakeProfileStore.world(env)
	world.conflict = "block"
	local storeA = profileStore(world, "A")
	local storeB = profileStore(world, "B")
	run(env, function()
		return storeA:load(72)
	end)
	local gone = false
	local pending = go(env, function()
		return storeB:load(72, {
			cancel = function(): boolean
				return gone
			end,
		})
	end)
	env:advance(5)
	t.eq(pending(), nil, "still waiting")
	gone = true
	settle(env, function(): boolean
		return pending() ~= nil
	end)
	t.eq(pending()[2], "cancelled")
end)

test("profileStoreBackend: receipts wait for a save that holds the id", function(t)
	local env = FakeEnv.new()
	local world = FakeProfileStore.world(env)
	world.saveLatency = 1
	local store = profileStore(world, "A")
	local session = run(env, function()
		return store:load(73)
	end)
	local grants = 0
	local function grant(data: any): any
		grants += 1
		data.visits += 1
		return nil
	end
	t.eq(
		run(env, function()
			return session:grantReceipt("q1", grant)
		end),
		"granted"
	)
	t.eq(world:peek("PlayerData", "player_73").purchaseIds, { "q1" })
	-- a failed save: the receipt waits for the next (auto)save
	world:failSaves(1)
	local pending = go(env, function()
		return session:grantReceipt("q2", grant)
	end)
	env:advance(3)
	t.eq(pending(), nil, "waiting for a save that holds q2")
	world:autosave()
	settle(env, function(): boolean
		return pending() ~= nil
	end)
	t.eq(pending()[1], "granted")
	t.eq(grants, 2)
	-- the session ends before any save holds the id: not processed (Roblox retries later)
	world:failSaves(2)
	local ending = go(env, function()
		return session:grantReceipt("q3", grant)
	end)
	env:advance(2)
	local storeB = profileStore(world, "B")
	run(env, function()
		return storeB:load(73)
	end)
	settle(env, function(): boolean
		return ending() ~= nil
	end)
	t.eq({ ending()[1], ending()[2] }, { "not_processed", "inactive" })
	t.eq(world:peek("PlayerData", "player_73").purchaseIds, { "q1", "q2" }, "q3 was never saved")
end)

test("profileStoreBackend: autosave is ProfileStore's, mock is separate, errors are reported", function(t)
	local env = FakeEnv.new()
	local world = FakeProfileStore.world(env)
	local store = profileStore(world, "A", { mock = true })
	local session = run(env, function()
		return store:load(74)
	end)
	session:set("visits", 2)
	env:advance(1000)
	t.eq(store:tick(), {}, "no core autosave for ProfileStore")
	run(env, function()
		return session:release()
	end)
	t.eq(world:peek("PlayerData", "player_74"), nil, "the mock store never touches the real one")
	t.eq(world:peek("mock:PlayerData", "player_74").visits, 2)
	local broken = PlayerData.new({
		template = {},
		version = 1,
		backend = PlayerData.profileStoreBackend({
			New = function(): any
				return {
					StartSessionAsync = function(): any
						error("DataStores unavailable")
					end,
				}
			end,
		}, "PlayerData"),
	}, env)
	t.eq(
		select(
			2,
			run(env, function()
				return broken:load(1)
			end)
		),
		"backend_error"
	)
	t.ok(anyReport(env, "StartSessionAsync failed"))
	t.throws(function()
		PlayerData.profileStoreBackend({}, "PlayerData")
	end)
	t.throws(function()
		PlayerData.profileStoreBackend(world:server("C"), string.rep("x", 51))
	end)
end)

-- ---------------------------------------------------------------- autosave and shutdown

test("tick saves the sessions that are due on the scheduler's cadence", function(t)
	local env = FakeEnv.new()
	local options = memoryOptions(newShared())
	local store = PlayerData.new(options, env)
	run(env, function()
		store:load(1)
		store:load(2)
		return nil
	end)
	t.eq(store:tick(9.9), {})
	t.eq(store:tick(10), { 1, 2 })
	t.eq(options.backend.saves, 2)
	t.eq(store:tick(15), {})
	t.eq(store:tick(20), { 1, 2 })
	run(env, function()
		return store:release(1)
	end)
	t.eq(store:tick(30), { 2 }, "a released session leaves the schedule")
	local manual = PlayerData.new(memoryOptions(newShared(), "m", { autosave = false }), env)
	run(env, function()
		return manual:load(1)
	end)
	t.eq(manual:tick(1000), {})
end)

test("releaseAll flushes in parallel, refuses loads and reports timeouts and failures", function(t)
	local env = FakeEnv.new()
	local world = FakeDataStore.world()
	local store, ds = dataStoreSetup(env, world, "A", env.clock, { latency = 2 })
	for _, userId in { 81, 82, 83 } do
		run(env, function()
			return store:load(userId)
		end)
	end
	local started = env.clock()
	local summary = run(env, function()
		return store:releaseAll()
	end)
	t.eq(summary, { released = { 81, 82, 83 }, failed = {}, timedOut = {} })
	t.ok(env.clock() - started < 5, "saves ran in parallel")
	for _, userId in { 81, 82, 83 } do
		t.eq((select(2, ds:peek("player_" .. userId))).lock, nil)
	end
	-- a deadline shorter than the backend's latency
	local slowStore, slowDs = dataStoreSetup(env, FakeDataStore.world(), "S", env.clock, { latency = 10 })
	run(env, function()
		return slowStore:load(84)
	end)
	local timed = run(env, function()
		return slowStore:releaseAll({ deadline = 3 })
	end)
	t.eq(timed.timedOut, { 84 })
	-- failing saves land in failed
	local failStore, failDs = dataStoreSetup(env, FakeDataStore.world(), "F", env.clock)
	run(env, function()
		return failStore:load(85)
	end)
	failDs:fail(5, "502: down")
	local failed = run(env, function()
		return failStore:releaseAll({ deadline = 120 })
	end)
	t.eq(failed.failed, { 85 })
	t.ok(slowDs ~= nil)
	-- a load still running when the server closes ends as closed and unlocks
	local lateStore, lateDs = dataStoreSetup(env, FakeDataStore.world(), "L", env.clock, { latency = 1 })
	local late = go(env, function()
		return lateStore:load(86)
	end)
	local closing = go(env, function()
		return lateStore:releaseAll({ deadline = 10 })
	end)
	settle(env, function(): boolean
		return closing() ~= nil
	end)
	t.ok(late() ~= nil, "releaseAll waits for loads still running")
	t.eq(late()[2], "closed")
	t.eq((select(2, lateDs:peek("player_86"))).lock, nil)
end)

test("eraseKeys lists keys for the owner and deletes nothing", function(t)
	t.eq(PlayerData.eraseKeys(9, { { name = "PlayerData" }, { name = "Receipts", keyPrefix = "ledger:" } }), {
		{ store = "PlayerData", key = "player_9" },
		{ store = "Receipts", key = "ledger:9" },
	})
	t.throws(function()
		PlayerData.eraseKeys(0, { { name = "PlayerData" } })
	end)
	t.throws(function()
		PlayerData.eraseKeys(9, {})
	end)
	t.throws(function()
		PlayerData.eraseKeys(9, { { name = "" } })
	end)
end)

-- ---------------------------------------------------------------- PlayerDataRoblox

local function bound(env: any, options: any?, bindOptions: any?): (any, any, any, any)
	local players = FakePlatformRoblox.players({ 201 })
	local game = FakePlatformRoblox.game({ jobId = "job" })
	local store = PlayerData.new(options or memoryOptions(newShared()), env)
	local opts = { players = players, game = game, autosaveStep = 1 }
	for key, value in bindOptions or {} do
		opts[key] = value
	end
	local binding = PlayerDataRoblox.bind(store, opts, env)
	return store, binding, players, game
end

test("bind loads present and joining players and releases them on leave", function(t)
	local env = FakeEnv.new()
	local shared = newShared()
	local loadedIds = {}
	local store, binding, players = bound(env, memoryOptions(shared))
	binding.loaded:Connect(function(player: any)
		table.insert(loadedIds, player.UserId)
	end)
	local present = players:GetPlayerByUserId(201)
	t.ok(store:get(201) ~= nil, "a player present at bind time is loaded")
	local joined = players:join(202)
	t.eq(loadedIds, { 202 })
	t.ok(binding:sessionFor(joined) == store:get(202))
	t.ok(run(env, function()
		return binding:waitForSession(present, 1)
	end) == store:get(201))
	store:get(202):set("visits", 9)
	players:leave(joined)
	env:flush()
	t.eq(store:get(202), nil)
	t.eq(shared.values.player_202.visits, 9)
	t.eq(shared.locks.player_202, nil)
	-- waitForSession returns nil for a player who left
	t.eq(
		run(env, function()
			return binding:waitForSession(joined, 1)
		end),
		nil
	)
end)

test("bind kicks players whose data fails or whose session is lost, never on a plain leave", function(t)
	local env = FakeEnv.new()
	local shared = newShared()
	shared.values.player_203 = { schemaVersion = 7 }
	local failures = {}
	local store, binding, players = bound(env, memoryOptions(shared))
	binding.failed:Connect(function(player: any, reason: string)
		table.insert(failures, { player.UserId, reason })
	end)
	local newer = players:join(203)
	t.eq(newer.kicked, PlayerDataRoblox.KICK_MESSAGES.newer_schema)
	t.eq(failures, { { 203, "newer_schema" } })
	local victim = players:join(204)
	store._backend:steal("player_204", "elsewhere")
	store:get(204):save()
	t.eq(victim.kicked, PlayerDataRoblox.KICK_MESSAGES.lock_lost)
	t.eq(PlayerDataRoblox.kickMessage("unknown_reason"), PlayerDataRoblox.KICK_MESSAGES.default)
	t.eq(PlayerDataRoblox.kickMessage(nil), PlayerDataRoblox.KICK_MESSAGES.default)
	-- kickOnFailure = false only reports
	local quietShared = newShared()
	quietShared.values.player_205 = { schemaVersion = 7 }
	local _, quietBinding, quietPlayers = bound(env, memoryOptions(quietShared), { kickOnFailure = false })
	local reasons = {}
	quietBinding.failed:Connect(function(_player: any, reason: string)
		table.insert(reasons, reason)
	end)
	local spared = quietPlayers:join(205)
	t.eq(spared.kicked, nil)
	t.eq(reasons, { "newer_schema" })
	-- a custom message function
	local customShared = newShared()
	customShared.values.player_206 = "corrupt"
	local _, _, customPlayers = bound(env, memoryOptions(customShared), {
		kickMessage = function(reason: string): string
			return "custom:" .. reason
		end,
	})
	t.eq(customPlayers:join(206).kicked, "custom:corrupt")
end)

test("bind: a player who leaves during the load is not kicked and leaves no lock", function(t)
	local env = FakeEnv.new()
	local world = FakeDataStore.world()
	local options = {
		template = TEMPLATE,
		version = 1,
		backend = PlayerData.dataStoreBackend(
			FakeDataStore.new({ world = world, env = env, latency = 1 }),
			{ serverId = "A", now = env.clock },
			env
		),
	}
	local store, binding, players = bound(env, options)
	local failed = 0
	binding.failed:Connect(function()
		failed += 1
	end)
	settle(env, function(): boolean
		return store:get(201) ~= nil
	end)
	local quick = players:join(207)
	env:advance(0.5)
	players:leave(quick)
	env:advance(5)
	t.eq(store:get(207), nil)
	t.eq(quick.kicked, nil)
	t.eq(failed, 0)
	local peekStore = FakeDataStore.new({ world = world })
	t.eq((select(2, peekStore:peek("player_207"))).lock, nil)
end)

test("bind runs the autosave loop and flushes on BindToClose; unbind stops it", function(t)
	local env = FakeEnv.new()
	local options = memoryOptions(newShared())
	local store, binding, players, game = bound(env, options)
	players:join(208)
	env:advance(10.5)
	t.eq(options.backend.saves, 2, "both sessions autosaved once")
	local closed = go(env, function()
		game:close()
		return true
	end)
	settle(env, function(): boolean
		return closed() ~= nil
	end)
	t.eq(store:loaded(), {})
	t.eq(
		select(
			2,
			run(env, function()
				return store:load(209)
			end)
		),
		"closed"
	)
	binding:unbind()
	local saves = options.backend.saves
	env:advance(50)
	t.eq(options.backend.saves, saves)
	-- after unbind, joins are ignored
	local other, otherBinding, otherPlayers = bound(env, memoryOptions(newShared()))
	otherBinding:unbind()
	otherPlayers:join(210)
	t.eq(other:get(210), nil)
end)

test("bind needs Players and a game for BindToClose", function(t)
	local env = FakeEnv.new()
	local store = PlayerData.new(memoryOptions(newShared()), env)
	t.ok(has(
		errorText(function()
			PlayerDataRoblox.bind(store, { players = FakePlatformRoblox.players() }, env)
		end),
		"BindToClose"
	))
	t.ok(has(
		errorText(function()
			PlayerDataRoblox.bind(store, { game = FakePlatformRoblox.game() }, env)
		end),
		"Players service missing"
	))
	t.throws(function()
		PlayerDataRoblox.bind(
			store,
			{ players = FakePlatformRoblox.players(), bindToClose = false, autosaveStep = 0 },
			env
		)
	end)
end)

test("chooseBackend keeps Studio on memory and builds DataStore and ProfileStore backends", function(t)
	local env = FakeEnv.new()
	env.place = { isStudio = true, gameId = 0, placeId = 0 }
	local requested = {}
	local service = {
		GetDataStore = function(_self: any, name: string): any
			table.insert(requested, name)
			return FakeDataStore.new()
		end,
	}
	local backend, kind =
		PlayerDataRoblox.chooseBackend({ storeName = "PlayerData", dataStoreService = service }, env)
	t.eq(kind, "memory")
	t.eq(backend.name, "memory")
	t.eq(requested, {}, "no DataStore is opened in Studio by default")
	local live, liveKind = PlayerDataRoblox.chooseBackend({
		storeName = "PlayerData",
		dataStoreService = service,
		allowStudioDataStores = true,
		serverId = "job",
		now = env.clock,
	}, env)
	t.eq({ liveKind, live.name }, { "datastore", "datastore" })
	t.eq(requested, { "PlayerData" })
	env.place = { isStudio = false, gameId = 5, placeId = 6 }
	local world = FakeProfileStore.world(env)
	local ps, psKind =
		PlayerDataRoblox.chooseBackend({ storeName = "PlayerData", profileStore = world:server("x") }, env)
	t.eq({ psKind, ps.name, ps.managesAutosave }, { "profilestore", "profilestore", true })
	-- an empty JobId gets a random server id; now() defaults to env.roblox.DateTime
	env.roblox = {
		DateTime = {
			now = function(): any
				return { UnixTimestampMillis = 5000 }
			end,
		},
	}
	local _, dsKind = PlayerDataRoblox.chooseBackend(
		{ storeName = "PlayerData", dataStoreService = service, serverId = "" },
		env
	)
	t.eq(dsKind, "datastore")
	t.throws(function()
		PlayerDataRoblox.chooseBackend({ storeName = "PlayerData", kind = "profilestore" }, env)
	end)
	t.throws(function()
		PlayerDataRoblox.chooseBackend({ storeName = "" }, env)
	end)
	t.throws(function()
		PlayerDataRoblox.chooseBackend(
			{ storeName = "PlayerData", kind = "sql" :: any, dataStoreService = service },
			env
		)
	end)
	env.roblox = nil
	t.throws(function()
		PlayerDataRoblox.chooseBackend(
			{ storeName = "PlayerData", dataStoreService = service, serverId = "j" },
			env
		)
	end)
end)

test("chooseBackend fails closed: an unknown place builds no DataStore or ProfileStore", function(t)
	local env = FakeEnv.new()
	local requested = {}
	local service = {
		GetDataStore = function(_self: any, name: string): any
			table.insert(requested, name)
			return FakeDataStore.new()
		end,
	}
	local world = FakeProfileStore.world(env)
	-- no place, a place without isStudio, a place whose isStudio is not a boolean
	local unknown: { any } =
		{ false, { gameId = 5, placeId = 6 }, { isStudio = "no", gameId = 5, placeId = 6 } }
	for _, place in unknown do
		env.place = if place == false then nil else place
		local ds, dsKind = PlayerDataRoblox.chooseBackend({
			storeName = "PlayerData",
			kind = "datastore",
			dataStoreService = service,
			serverId = "job",
			now = env.clock,
		}, env)
		t.eq({ dsKind, ds.name }, { "memory", "memory" }, "a place that is not known to be live is Studio")
		local _, psKind = PlayerDataRoblox.chooseBackend(
			{ storeName = "PlayerData", profileStore = world:server("x") },
			env
		)
		t.eq(psKind, "memory")
	end
	t.eq(requested, {}, "no DataStore is opened when the place is unknown")
	-- the explicit opt-in still reaches DataStores; a known live place needs none
	env.place = nil
	local _, optInKind = PlayerDataRoblox.chooseBackend({
		storeName = "PlayerData",
		dataStoreService = service,
		allowStudioDataStores = true,
		serverId = "job",
		now = env.clock,
	}, env)
	t.eq(optInKind, "datastore")
	env.place = { isStudio = false, gameId = 5, placeId = 6 }
	local _, liveKind = PlayerDataRoblox.chooseBackend(
		{ storeName = "PlayerData", dataStoreService = service, serverId = "job", now = env.clock },
		env
	)
	t.eq(liveKind, "datastore")
	t.eq(requested, { "PlayerData", "PlayerData" })
end)

return cases
