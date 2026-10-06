--!strict
-- G1 settings persistence: GameKit/SettingsStore over a PlayerData session (memory backend) and
-- over plain key stores. Covers load-time migration and write-back, untrusted patches (clamped,
-- unknown keys dropped, NaN and junk refused), the RemoteGuard patch schema, rate limits, store
-- failures, reset, effective values and option validation.
local FakeEnv = require("./fakes/FakeEnv")
local PlayerData = require("../packages/GameKit/PlayerData")
local RemoteGuard = require("../packages/GameKit/RemoteGuard")
local Schema = require("../packages/GameKit/Schema")
local Settings = require("../packages/GameKit/Settings")
local SettingsStore = require("../packages/GameKit/SettingsStore")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

local function anyNote(notes: { string }, needle: string): boolean
	for _, note in notes do
		if has(note, needle) then
			return true
		end
	end
	return false
end

-- A key store over a table, counting writes; fail = true makes set refuse.
local function tableStore(initial: { [string]: any }?): any
	local data = initial or {}
	local store = { data = data, writes = 0, fail = false }
	function store.get(_self: any, key: string): any
		return data[key]
	end
	function store.set(self: any, key: string, value: any): (boolean, string?)
		if self.fail then
			return false, "offline"
		end
		self.writes += 1
		data[key] = value
		return true, nil
	end
	return store
end

local function session(env: any, shared: any): any
	local store = PlayerData.new({
		template = { visits = 0 },
		version = 1,
		backend = PlayerData.memoryBackend({ shared = shared }),
		autosave = false,
	}, env)
	local result = nil
	env.spawn(function()
		result = store:load(1)
	end)
	assert(result ~= nil, "memory load does not yield")
	return result, store
end

test("load writes defaults once and persists through a PlayerData session", function(t)
	local env = FakeEnv.new()
	local shared = { values = {}, locks = {} }
	local playerSession = session(env, shared)
	local settings = SettingsStore.new({ store = playerSession:keyStore() }, env)
	local values, notes = settings:load()
	t.eq(values, Settings.defaults())
	t.ok(anyNote(notes, "no saved settings"))
	t.eq(playerSession:get("settings"), Settings.defaults(), "defaults written back")
	local ok, applied = settings:apply({ volume = { music = 0.25 }, invertY = true })
	t.ok(ok)
	t.eq(applied.volume.music, 0.25)
	-- release and load again on a fresh session: the change persisted
	env.spawn(function()
		playerSession:release()
	end)
	local again = session(env, shared)
	local reloaded = SettingsStore.new({ store = again:keyStore() }, env)
	local values2, notes2 = reloaded:load()
	t.eq(values2.volume.music, 0.25)
	t.eq(values2.invertY, true)
	t.eq(notes2, {}, "clean saved settings need no write-back")
end)

test("load migrates and sanitizes any saved shape and writes the clean result back", function(t)
	local env = FakeEnv.new()
	local store = tableStore({
		settings = { version = 1, volume = { music = 7, sfx = "loud" }, uiScale = 0.1, mystery = true },
	})
	local schema = Settings.schema({
		{ path = "game.hints", kind = "boolean", default = true, group = "game" },
	})
	local settings = SettingsStore.new({
		store = store,
		schema = schema,
		version = 2,
		migrations = {
			[1] = function(data: any): any
				data.game = { hints = data.mystery == true }
				data.mystery = nil
				return data
			end,
		},
	}, env)
	local values, notes = settings:load()
	t.eq(values.version, 2)
	t.eq(values.volume.music, 1, "clamped")
	t.eq(values.volume.sfx, 1, "invalid -> default")
	t.eq(values.uiScale, 0.75, "clamped up")
	t.eq(values.game.hints, true, "migrated")
	t.ok(anyNote(notes, "volume.music: clamped"))
	t.ok(anyNote(notes, "volume.sfx"))
	t.eq(store.writes, 1)
	t.eq(store.data.settings, values)
	-- load is cached: no second read or write
	settings:load()
	t.eq(store.writes, 1)
	-- a value that is not a table at all
	local junk = SettingsStore.new({ store = tableStore({ settings = "corrupt" }) }, env)
	local junkValues, junkNotes = junk:load()
	t.eq(junkValues, Settings.defaults())
	t.ok(anyNote(junkNotes, "not a table"))
end)

test("apply merges untrusted patches, writes only on change and refuses junk", function(t)
	local env = FakeEnv.new()
	local store = tableStore()
	local settings = SettingsStore.new({ store = store }, env)
	settings:load()
	local events = {}
	settings.changed:Connect(function(values: any, notes: any)
		table.insert(events, { values = values, notes = notes })
	end)
	local writes = store.writes
	local ok, values, notes = settings:apply({ volume = { music = 3 }, colorblindMode = "nope", extra = 1 })
	t.ok(ok)
	t.eq(values.volume.music, 1)
	t.eq(values.colorblindMode, "none")
	t.ok(anyNote(notes, "extra: unknown setting dropped"))
	t.eq(store.writes, writes, "clamped back to the current values: nothing to write")
	t.eq(#events, 0)
	ok, values = settings:apply({ volume = { music = 0.5 }, colorblindMode = "tritanopia" })
	t.ok(ok)
	t.eq(store.writes, writes + 1)
	t.eq(#events, 1)
	t.eq(events[1].values.colorblindMode, "tritanopia")
	-- the same patch again changes nothing
	settings:apply({ volume = { music = 0.5 } })
	t.eq(store.writes, writes + 1)
	-- junk never reaches the merge
	for _, patch in
		{
			"text" :: any,
			{ volume = { music = 0 / 0 } },
			{ volume = { music = math.huge } },
			{ a = { b = { c = { d = { e = 1 } } } } },
			{ f = function() end },
		}
	do
		local refused, reason = settings:apply(patch)
		t.eq(refused, false)
		t.eq(reason, "invalid_patch", tostring(patch))
	end
	t.eq(settings:get().volume.music, 0.5)
	-- returned values are copies
	local copy = settings:get()
	copy.volume.music = 0
	t.eq(settings:get().volume.music, 0.5)
end)

test("set, reset, rate limits and store failures", function(t)
	local env = FakeEnv.new()
	local store = tableStore()
	local settings = SettingsStore.new({ store = store, rate = { capacity = 3, refillPerSec = 1 } }, env)
	t.ok(settings:set("volume.ui", 0.3))
	t.eq(settings:get().volume.ui, 0.3)
	t.ok(settings:set("haptics", false))
	t.ok(settings:reset())
	t.eq(settings:get(), Settings.defaults())
	local ok, reason = settings:set("haptics", false)
	t.eq({ ok, reason }, { false, "rate" })
	env:advance(1)
	t.ok(settings:set("haptics", false))
	-- a failing store leaves the values as they were
	env:advance(10)
	store.fail = true
	local failed, why = settings:set("volume.ui", 0.1)
	t.eq(failed, false)
	t.ok(has(why, "store_failed:offline"), why)
	t.eq(settings:get().volume.ui, 1)
	t.throws(function()
		settings:set("", 1)
	end)
	-- a failed write-back on load is reported in the notes, values still usable
	local broken = tableStore()
	broken.fail = true
	local values, notes = SettingsStore.new({ store = broken }, env):load()
	t.eq(values, Settings.defaults())
	t.ok(anyNote(notes, "write-back failed: offline"))
end)

test("patchSchema guards the settings remote", function(t)
	local env = FakeEnv.new()
	local patchSchema = SettingsStore.patchSchema()
	t.ok(Schema.check(patchSchema, { volume = { music = 0.5 }, reducedMotion = true }))
	t.ok(Schema.check(patchSchema, {}))
	t.ok(Schema.check(patchSchema, { language = "pt-br", colorblindMode = "protanopia" }))
	local function refused(value: any, expected: string)
		local ok, _, reason = Schema.check(patchSchema, value)
		t.eq(ok, false, expected)
		t.eq(reason, expected)
	end
	refused({ volume = { music = 0 / 0 } }, "nan")
	refused({ volume = { music = "x" } }, "type")
	refused({ volume = { bass = 1 } }, "unexpected_key")
	refused({ hacked = true }, "unexpected_key")
	refused({ colorblindMode = "rainbow" }, "not_in_enum")
	refused({ language = string.rep("x", 17) }, "too_long")
	refused({ volume = 1 }, "type")
	-- with game fields
	local withGame = SettingsStore.patchSchema(Settings.schema({
		{ path = "game.hints", kind = "boolean", default = true, group = "game" },
	}))
	t.ok(Schema.check(withGame, { game = { hints = false } }))
	-- as a RemoteGuard argument
	local guard = RemoteGuard.new({
		schemas = { settings_patch = { kind = "event", args = { patchSchema } } },
	}, env)
	local player = { UserId = 1 }
	t.ok(guard:check("settings_patch", player, { volume = { sfx = 0.2 } }))
	local ok, reason = guard:check("settings_patch", player, { volume = { sfx = 0 / 0 } })
	t.eq({ ok, reason }, { false, "schema" })
end)

test("effective folds the system reduced-motion setting", function(t)
	local env = FakeEnv.new()
	local settings = SettingsStore.new({ store = tableStore() }, env)
	settings:set("volume.master", 0.5)
	settings:set("volume.music", 0.5)
	local effective = settings:effective({ reducedMotion = true })
	t.eq(effective.reducedMotion, true)
	t.near(effective.volume.music, 0.25)
	t.eq(settings:effective().reducedMotion, false)
end)

test("validate and new refuse bad options", function(t)
	local problems = table.concat(
		SettingsStore.validate({
			store = {},
			key = "a.b",
			version = 0,
			migrations = 5,
			rate = { capacity = 0, refillPerSec = -1 },
			schema = { { path = "x" } },
		}),
		"\n"
	)
	for _, needle in
		{ "store must have get and set", "key must be", "version must be", "migrations", "rate:", "schema" }
	do
		t.ok(has(problems, needle), needle .. "\n" .. problems)
	end
	t.eq(SettingsStore.validate(nil), { "options must be a table" })
	local ok, err = pcall(SettingsStore.new, { store = tableStore() } :: any, nil)
	t.ok(not ok and has(tostring(err), "env with clock"))
	t.eq(#SettingsStore.validate({ store = tableStore() }), 0)
	local withGame = Settings.schema({ { path = "game.hints", kind = "boolean", default = true } })
	t.eq(SettingsStore.validate({ store = tableStore(), schema = withGame }), {})
	local trimmed = { Settings.FIELDS[1] }
	t.ok(
		has(
			table.concat(SettingsStore.validate({ store = tableStore(), schema = trimmed }), "\n"),
			"keep every"
		)
	)
end)

return cases
