--!strict
-- @tier T0
-- SettingsStore: persists one player's settings/1 values (GameKit/Settings) on the server
-- through a key store, usually a PlayerData session: SettingsStore.new({ store =
-- session:keyStore() }, env). load() migrates whatever was saved (any age, any shape) and writes
-- the clean result back once; apply(patch) takes a client's partial change, merges and
-- sanitizes it with Settings.merge (clamped numbers, defaults for invalid values, unknown keys
-- dropped), rate-limits it and saves only when something changed. patchSchema() is the
-- RemoteGuard schema for the settings remote, built from the field list, so a malformed patch
-- is refused before it reaches apply. The client keeps its own copy for instant feedback; the
-- server's copy is the one that persists. UI is UIKit's; effects read Settings.effective.
local Check = require("./Check")
local RateLimit = require("./RateLimit")
local Schema = require("./Schema")
local Settings = require("./Settings")
local Signal = require("./Signal")

local SettingsStore = {}

SettingsStore.DEFAULT_KEY = "settings"
SettingsStore.DEFAULT_RATE = table.freeze({ capacity = 10, refillPerSec = 1 }) -- convention
SettingsStore.LOCALE_MAX_LEN = 16 -- convention: longest locale id accepted in a patch

export type KeyStore = {
	get: (self: any, key: string) -> any,
	set: (self: any, key: string, value: any) -> (boolean, string?),
}

export type Options = {
	store: KeyStore,
	key: string?, -- default "settings"
	schema: Settings.Schema?, -- Settings.schema(extra) for game.* fields
	version: number?, -- the game's settings version (default Settings.VERSION)
	migrations: { [number]: (data: { [string]: any }) -> { [string]: any } }?,
	rate: { capacity: number, refillPerSec: number }?,
}

local function patchNode(schema: Settings.Schema): Schema.Schema
	-- nested optional structs mirroring the field paths (volume.music -> { volume = { music } })
	local tree: { [string]: any } = {}
	for _, f in schema do
		local parts = string.split(f.path, ".")
		local node = tree
		for index = 1, #parts - 1 do
			node[parts[index]] = node[parts[index]] or {}
			node = node[parts[index]]
		end
		local leaf: Schema.Schema
		if f.kind == "number" then
			leaf = Schema.number()
		elseif f.kind == "boolean" then
			leaf = Schema.boolean()
		elseif f.kind == "enum" then
			leaf = Schema.enum(f.choices :: { string })
		else
			leaf = Schema.string({ minLen = 1, maxLen = SettingsStore.LOCALE_MAX_LEN })
		end
		node[parts[#parts]] = leaf
	end
	local function build(node: { [string]: any }): Schema.Schema
		local shape: { [string]: Schema.Schema } = {}
		for key, child in node do
			if Schema.isSchema(child) then
				shape[key] = Schema.optional(child)
			else
				shape[key] = Schema.optional(build(child))
			end
		end
		return Schema.struct(shape, { strict = true })
	end
	return build(tree)
end

-- The RemoteGuard argument schema for a settings patch: a table holding only known settings
-- paths with values of the right kind (numbers are range-clamped later by apply; NaN and inf are
-- refused here). Unknown keys, wrong types and deep junk fail the guard's check.
function SettingsStore.patchSchema(schema: Settings.Schema?): Schema.Schema
	return patchNode(schema or Settings.FIELDS)
end

local Store = {}
Store.__index = Store

type StoreFields = {
	changed: Signal.Signal,
	_store: KeyStore,
	_key: string,
	_schema: Settings.Schema,
	_version: number,
	_migrations: { [number]: (any) -> any }?,
	_limiter: any,
	_values: Settings.Values?,
	_env: any,
}
export type SettingsStore = typeof(setmetatable({} :: StoreFields, Store))

-- Problems with options (empty when valid).
function SettingsStore.validate(options: any): { string }
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	local problems = {}
	local store = options.store
	if type(store) ~= "table" or type(store.get) ~= "function" or type(store.set) ~= "function" then
		table.insert(problems, "store must have get and set (a PlayerData session:keyStore())")
	end
	local key = options.key
	if key ~= nil and not (type(key) == "string" and key ~= "" and not string.find(key, ".", 1, true)) then
		table.insert(problems, "key must be a non-empty string without dots")
	end
	if options.schema ~= nil then
		-- must be Settings.schema(extra): every settings/1 field plus valid game.* fields
		local schema = options.schema
		if type(schema) ~= "table" then
			table.insert(problems, "schema must come from Settings.schema(extra)")
		else
			local extra = {}
			for _, f in schema do
				if not table.find(Settings.FIELDS, f) then
					table.insert(extra, f)
				end
			end
			local ok, err = pcall(Settings.schema, extra)
			if not ok then
				table.insert(problems, "schema must come from Settings.schema(extra): " .. tostring(err))
			elseif #schema - #extra ~= #Settings.FIELDS then
				table.insert(problems, "schema must keep every settings/1 field (use Settings.schema(extra))")
			end
		end
	end
	local version = options.version
	if version ~= nil and not (Check.integer(version) and version >= 1) then
		table.insert(problems, "version must be an integer >= 1")
	end
	if options.migrations ~= nil and type(options.migrations) ~= "table" then
		table.insert(problems, "migrations must map versions to functions")
	end
	if options.rate ~= nil then
		for _, problem in
			RateLimit.validate({
				capacity = options.rate.capacity,
				refillPerSec = options.rate.refillPerSec,
				clock = function(): number
					return 0
				end,
			})
		do
			table.insert(problems, "rate: " .. problem)
		end
	end
	return problems
end

function SettingsStore.new(options: Options, env: any): SettingsStore
	local problems = SettingsStore.validate(options)
	if env == nil or type(env.clock) ~= "function" then
		table.insert(problems, "env with clock is required")
	end
	if #problems > 0 then
		error("SettingsStore.new: " .. table.concat(problems, "; "), 2)
	end
	local rate = options.rate or SettingsStore.DEFAULT_RATE
	return setmetatable({
		changed = Signal.new(env),
		_store = options.store,
		_key = options.key or SettingsStore.DEFAULT_KEY,
		_schema = options.schema or Settings.FIELDS,
		_version = options.version or Settings.VERSION,
		_migrations = options.migrations,
		_limiter = RateLimit.new(
			{ capacity = rate.capacity, refillPerSec = rate.refillPerSec, maxKeys = 1 },
			env
		),
		_values = nil,
		_env = env,
	}, Store)
end

-- Loads (once) and returns (values, notes). Saved data of any age or shape is migrated and
-- sanitized; when that changed anything, the clean values are written back.
function Store.load(self: SettingsStore): (Settings.Values, { string })
	if self._values ~= nil then
		return Check.copy(self._values :: Settings.Values), {}
	end
	local raw = self._store:get(self._key)
	local values, notes = Settings.migrate(raw, {
		schema = self._schema,
		version = self._version,
		migrations = self._migrations,
	})
	self._values = values
	if raw == nil or #notes > 0 then
		local ok, reason = self._store:set(self._key, values)
		if not ok then
			table.insert(notes, "write-back failed: " .. tostring(reason))
		end
	end
	return Check.copy(values), notes
end

-- The current values (a copy); loads first if needed.
function Store.get(self: SettingsStore): Settings.Values
	local values = self:load()
	return values
end

-- What kits read (Settings.effective) for the current values and the system info.
function Store.effective(self: SettingsStore, system: Settings.SystemInfo?): Settings.Effective
	return Settings.effective(self:get(), system)
end

local function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not same(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function commit(
	self: SettingsStore,
	nextValues: Settings.Values,
	notes: { string }
): (boolean, any, { string })
	local current = self._values :: Settings.Values
	if same(current, nextValues) then
		return true, Check.copy(current), notes
	end
	local ok, reason = self._store:set(self._key, nextValues)
	if not ok then
		return false, "store_failed:" .. tostring(reason), notes
	end
	self._values = nextValues
	self.changed:Fire(Check.copy(nextValues), notes)
	return true, Check.copy(nextValues), notes
end

-- Applies an untrusted partial patch (nested like the values: { volume = { music = 0.4 } }).
-- Returns (true, values, notes) or (false, reason, notes) with reasons rate, invalid_patch and
-- store_failed:<why>. A patch that changes nothing writes nothing.
function Store.apply(self: SettingsStore, patch: any): (boolean, any, { string })
	local current = self:load()
	local allowed = self._limiter:take("patch")
	if not allowed then
		return false, "rate", {}
	end
	if type(patch) ~= "table" then
		return false, "invalid_patch", { "patch is not a table" }
	end
	local storable, path, why = Schema.storable(patch, { maxDepth = 4, maxNodes = 64 })
	if not storable then
		return false, "invalid_patch", { string.format("%s at %s", tostring(why), tostring(path)) }
	end
	local merged, notes = Settings.merge(current, patch, self._schema)
	merged.version = self._version
	return commit(self, merged, notes)
end

-- Sets one field ("volume.music"); same results as apply.
function Store.set(self: SettingsStore, path: string, value: any): (boolean, any, { string })
	assert(type(path) == "string" and path ~= "", "SettingsStore:set needs a path")
	local patch = {}
	local node = patch
	local parts = string.split(path, ".")
	for index = 1, #parts - 1 do
		node[parts[index]] = {}
		node = node[parts[index]]
	end
	node[parts[#parts]] = value
	return self:apply(patch)
end

-- Back to defaults (rate-limited like apply).
function Store.reset(self: SettingsStore): (boolean, any, { string })
	self:load()
	local allowed = self._limiter:take("patch")
	if not allowed then
		return false, "rate", {}
	end
	local defaults = Settings.defaults(self._schema)
	defaults.version = self._version
	return commit(self, defaults, { "reset to defaults" })
end

return SettingsStore
