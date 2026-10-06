--!strict
-- @tier T0
-- Config: live-tunable values with in-code defaults (the kill switches and tunables a game
-- hides content behind). get(key) always returns a valid value: the default until a source
-- (ConfigRoblox reading ConfigService, or a spec) applies values, and the default again for any
-- key the source leaves out or sets to an invalid value. Keys are declared up front: asking for
-- an undeclared key raises (a typo should fail in tests, not read nil in production). Each value
-- is checked by its GameKit/Schema schema, or by the default's type when no schema is given.
-- changed fires (key, value, previous) after an apply that changed a key.
local Check = require("./Check")
local Schema = require("./Schema")
local Signal = require("./Signal")

local Config = {}

export type Options = {
	defaults: { [string]: any },
	schema: { [string]: Schema.Schema }?,
}

local Store = {}
Store.__index = Store

type StoreFields = {
	changed: Signal.Signal,
	_defaults: { [string]: any },
	_schema: { [string]: Schema.Schema },
	_values: { [string]: any },
	_source: string,
	_notes: { string },
}
export type Config = typeof(setmetatable({} :: StoreFields, Store))

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

local function typeSchema(default: any): Schema.Schema
	local kind = type(default)
	if kind == "number" then
		return Schema.number()
	elseif kind == "boolean" then
		return Schema.boolean()
	elseif kind == "string" then
		return Schema.string({ maxLen = 100000 }) -- ConfigService strings hold up to 100,000 characters
	end
	return Schema.custom("storable", function(value: any): (boolean, string?)
		return type(value) == kind and (Schema.storable(value)), nil
	end)
end

-- Problems with options (empty when valid).
function Config.validate(options: any): { string }
	if type(options) ~= "table" or type(options.defaults) ~= "table" then
		return { "defaults must be a table of key -> value" }
	end
	local problems = {}
	local schema = options.schema or {}
	if type(schema) ~= "table" then
		return { "schema must map keys to GameKit/Schema schemas" }
	end
	for key, default in options.defaults do
		if not Check.label(key) then
			table.insert(problems, string.format("key %s is not a lower_snake label", Check.describe(key)))
			continue
		end
		local kind = type(default)
		if kind ~= "number" and kind ~= "boolean" and kind ~= "string" and kind ~= "table" then
			table.insert(problems, key .. ": defaults must be numbers, booleans, strings or tables")
			continue
		end
		if kind == "table" and not Schema.storable(default) then
			table.insert(problems, key .. ": a table default must be plain JSON-like data")
		end
		local keySchema = schema[key]
		if keySchema ~= nil then
			if not Schema.isSchema(keySchema) then
				table.insert(problems, key .. ": schema is not a GameKit/Schema schema")
			elseif not Schema.check(keySchema, default) then
				table.insert(problems, key .. ": the default fails its own schema")
			end
		end
	end
	for key in schema do
		if options.defaults[key] == nil then
			table.insert(problems, string.format("schema names %s, which has no default", tostring(key)))
		end
	end
	return problems
end

function Config.new(options: Options, env: any?): Config
	local problems = Config.validate(options)
	if #problems > 0 then
		error("Config.new: " .. table.concat(problems, "; "), 2)
	end
	local schema: { [string]: Schema.Schema } = {}
	for key, default in options.defaults do
		schema[key] = (options.schema and options.schema[key]) or typeSchema(default)
	end
	return setmetatable({
		changed = Signal.new(env),
		_defaults = Check.freeze(Check.copy(options.defaults)),
		_schema = schema,
		_values = Check.copy(options.defaults),
		_source = "defaults",
		_notes = {},
	}, Store)
end

-- The current value of a declared key (a copy for tables). Raises on an undeclared key.
function Store.get(self: Config, key: string): any
	if self._defaults[key] == nil then
		error("Config: unknown key " .. tostring(key), 2)
	end
	return Check.copy(self._values[key])
end

-- The default of a declared key.
function Store.default(self: Config, key: string): any
	if self._defaults[key] == nil then
		error("Config: unknown key " .. tostring(key), 2)
	end
	return Check.copy(self._defaults[key])
end

-- Applies a full set of values from a source (what a ConfigService snapshot holds). Keys the
-- source does not hold, or holds with an invalid value, use the default; undeclared keys are
-- ignored. Returns notes (one per ignored or invalid entry). Fires changed per changed key.
function Store.apply(self: Config, values: { [string]: any }?, source: string): { string }
	local notes = {}
	local incoming: { [string]: any } = if type(values) == "table" then values else {}
	if type(values) ~= "table" and values ~= nil then
		table.insert(notes, "values are not a table: defaults used")
	end
	for key in incoming do
		if self._defaults[key] == nil then
			table.insert(notes, string.format("%s: not declared, ignored", tostring(key)))
		end
	end
	local changes = {}
	for key, default in self._defaults do
		local value = incoming[key]
		if value == nil then
			value = default
		else
			local ok, path, reason = Schema.check(self._schema[key], value)
			if not ok then
				table.insert(
					notes,
					string.format("%s: %s at %s, default used", key, tostring(reason), tostring(path))
				)
				value = default
			end
		end
		local previous = self._values[key]
		if not same(previous, value) then
			self._values[key] = Check.copy(value)
			table.insert(changes, { key = key, value = value, previous = previous })
		end
	end
	table.sort(notes)
	table.sort(changes, function(a: any, b: any): boolean
		return a.key < b.key
	end)
	self._source = source
	self._notes = notes
	for _, change in changes do
		self.changed:Fire(change.key, Check.copy(change.value), change.previous)
	end
	return notes
end

-- Back to the defaults (a source that failed or was withdrawn).
function Store.reset(self: Config, source: string?): { string }
	return self:apply({}, source or "defaults")
end

-- All current values (a copy), where they came from and the last apply's notes.
function Store.snapshot(self: Config): { values: { [string]: any }, source: string, notes: { string } }
	return { values = Check.copy(self._values), source = self._source, notes = table.clone(self._notes) }
end

-- Declared keys, sorted.
function Store.keys(self: Config): { string }
	local out = {}
	for key in self._defaults do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

return Config
