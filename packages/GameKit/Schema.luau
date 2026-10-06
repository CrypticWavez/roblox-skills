--!strict
-- @tier T0
-- Schema: validators for untrusted values (remote arguments, saved data, config values). Build
-- a schema from combinators and check a value with Schema.check(schema, value) ->
-- (ok, path, reason): path names the first failing place ("$.items[3].count", "args[2]") and
-- reason is one word from Schema.REASONS. NaN and +-inf are always rejected, strings must be
-- valid UTF-8 (a client can send any bytes), and every check is bounded by a depth and a node
-- budget, so a hostile payload costs bounded work. Combinator names follow the t library;
-- Roblox datatypes (Vector3, CFrame, Instance) are recognised with typeof, which Lune's roblox
-- library mirrors. Schema.storable/size check DataStore-safe plain data (JSON-encodable,
-- under the 4,194,304-character value limit). Pure; option mistakes raise when building.
local Check = require("./Check")
local Json = require("./Json")

local Schema = {}

Schema.DEFAULT_MAX_DEPTH = 32
Schema.DEFAULT_MAX_NODES = 10000
Schema.DEFAULT_MAX_LEN = 256 -- convention: string bytes and array items when no bound is given
-- Roblox DataStore value limit in characters (data-stores error-codes-and-limits page).
Schema.DATASTORE_VALUE_LIMIT = 4194304
Schema.REASONS = table.freeze({
	"type", -- wrong Luau or Roblox type
	"nan",
	"infinite",
	"not_integer",
	"below_min",
	"above_max",
	"too_short",
	"too_long",
	"pattern",
	"invalid_utf8",
	"not_in_enum",
	"missing", -- a required struct field or argument is nil
	"unexpected_key", -- strict struct with an unknown key
	"key", -- a key of the wrong type
	"not_array",
	"sparse_array",
	"mixed_keys",
	"too_many",
	"too_deep",
	"too_many_nodes",
	"magnitude",
	"class",
	"ancestor",
	"cycle",
	"union",
	"custom",
	"arity",
})

export type Context = { nodes: number, maxNodes: number, maxDepth: number }
type CheckFn = (value: any, ctx: Context, path: string, depth: number) -> (boolean, string?, string?)

local Node = {}
Node.__index = Node

export type Schema = {
	kind: string,
	optional: boolean,
	options: { [string]: any },
	_check: CheckFn,
}

export type CheckOptions = { maxDepth: number?, maxNodes: number? }

local function node(kind: string, check: CheckFn, options: { [string]: any }?): Schema
	return setmetatable(
			{ kind = kind, optional = false, options = options or {}, _check = check },
			Node
		) :: any
end

function Schema.isSchema(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Node
end

local function assertSchema(value: any, what: string)
	if not Schema.isSchema(value) then
		error(string.format("Schema: %s must be a schema (got %s)", what, typeof(value)), 3)
	end
end

local function fail(path: string, reason: string): (boolean, string?, string?)
	return false, path, reason
end

local function count(ctx: Context, path: string): (boolean, string?, string?)
	ctx.nodes += 1
	if ctx.nodes > ctx.maxNodes then
		return fail(path, "too_many_nodes")
	end
	return true, nil, nil
end

local function numberProblem(value: number): string?
	if value ~= value then
		return "nan"
	elseif value == math.huge or value == -math.huge then
		return "infinite"
	end
	return nil
end

local function optionNumber(options: any, name: string, minimum: number?): number?
	local value = options and options[name]
	if value == nil then
		return nil
	end
	if not Check.finite(value) or (minimum ~= nil and value < minimum) then
		error(
			string.format(
				"Schema: option %s must be a finite number%s",
				name,
				if minimum ~= nil then " >= " .. minimum else ""
			),
			3
		)
	end
	return value
end

local function childPath(path: string, key: any): string
	if type(key) ~= "string" then
		return path .. "[" .. tostring(key) .. "]"
	end
	local text = key
	if string.match(text, "^[%a_][%w_]*$") then
		return path .. "." .. text
	end
	return path
		.. "["
		.. string.format("%q", if #text > 32 then string.sub(text, 1, 32) .. "..." else text)
		.. "]"
end

-- ---------------------------------------------------------------- scalars

-- A finite number; options min, max, integer (whole and within 2^53).
function Schema.number(options: { min: number?, max: number?, integer: boolean? }?): Schema
	local min = optionNumber(options, "min")
	local max = optionNumber(options, "max")
	if min and max and min > max then
		error("Schema.number: min must be <= max", 2)
	end
	local integer = options ~= nil and options.integer == true
	return node("number", function(value: any, ctx: Context, path: string): (boolean, string?, string?)
		local ok, p, r = count(ctx, path)
		if not ok then
			return ok, p, r
		end
		if type(value) ~= "number" then
			return fail(path, "type")
		end
		local problem = numberProblem(value)
		if problem then
			return fail(path, problem)
		end
		if integer and not Check.integer(value) then
			return fail(path, "not_integer")
		end
		if min and value < min then
			return fail(path, "below_min")
		end
		if max and value > max then
			return fail(path, "above_max")
		end
		return true, nil, nil
	end, { min = min, max = max, integer = integer })
end

-- Schema.number with integer = true.
function Schema.integer(options: { min: number?, max: number? }?): Schema
	return Schema.number({ min = options and options.min, max = options and options.max, integer = true })
end

-- A UTF-8 string; options minLen (bytes, default 0), maxLen (bytes, default 256, a convention),
-- pattern (a Lua pattern the string must match; anchor it yourself) and utf8 (default true).
function Schema.string(
	options: { minLen: number?, maxLen: number?, pattern: string?, utf8: boolean? }?
): Schema
	local minLen = optionNumber(options, "minLen", 0) or 0
	local maxLen = optionNumber(options, "maxLen", 0) or Schema.DEFAULT_MAX_LEN
	if minLen > maxLen then
		error("Schema.string: minLen must be <= maxLen", 2)
	end
	local pattern = options and options.pattern
	if pattern ~= nil and type(pattern) ~= "string" then
		error("Schema.string: pattern must be a string", 2)
	end
	local checkUtf8 = not (options ~= nil and options.utf8 == false)
	return node("string", function(value: any, ctx: Context, path: string): (boolean, string?, string?)
		local ok, p, r = count(ctx, path)
		if not ok then
			return ok, p, r
		end
		if type(value) ~= "string" then
			return fail(path, "type")
		end
		if #value > maxLen then
			return fail(path, "too_long")
		end
		if #value < minLen then
			return fail(path, "too_short")
		end
		if checkUtf8 and utf8.len(value) == nil then
			return fail(path, "invalid_utf8")
		end
		if pattern and string.find(value, pattern) == nil then
			return fail(path, "pattern")
		end
		return true, nil, nil
	end, { minLen = minLen, maxLen = maxLen, pattern = pattern })
end

function Schema.boolean(): Schema
	return node("boolean", function(value: any, ctx: Context, path: string): (boolean, string?, string?)
		local ok, p, r = count(ctx, path)
		if not ok then
			return ok, p, r
		end
		if type(value) ~= "boolean" then
			return fail(path, "type")
		end
		return true, nil, nil
	end)
end

-- Exactly this value (a string, number or boolean).
function Schema.literal(expected: string | number | boolean): Schema
	local kind = type(expected)
	if kind ~= "string" and kind ~= "boolean" and not Check.finite(expected) then
		error("Schema.literal: expected a string, finite number or boolean", 2)
	end
	return node("literal", function(value: any, ctx: Context, path: string): (boolean, string?, string?)
		local ok, p, r = count(ctx, path)
		if not ok then
			return ok, p, r
		end
		if value ~= expected then
			return fail(path, if type(value) == kind then "not_in_enum" else "type")
		end
		return true, nil, nil
	end, { value = expected })
end

-- One of the listed strings or numbers.
function Schema.enum(choices: { string | number }): Schema
	if type(choices) ~= "table" or #choices == 0 then
		error("Schema.enum: choices must be a non-empty list", 2)
	end
	local set: { [any]: boolean } = {}
	for _, choice in choices do
		if type(choice) ~= "string" and not Check.finite(choice) then
			error("Schema.enum: choices must be strings or finite numbers", 2)
		end
		set[choice] = true
	end
	return node("enum", function(value: any, ctx: Context, path: string): (boolean, string?, string?)
		local ok, p, r = count(ctx, path)
		if not ok then
			return ok, p, r
		end
		if type(value) ~= "string" and type(value) ~= "number" then
			return fail(path, "type")
		end
		if not set[value] then
			return fail(path, "not_in_enum")
		end
		return true, nil, nil
	end, { choices = table.clone(choices) })
end

-- ---------------------------------------------------------------- Roblox datatypes

local function components(value: any): (number, number, number)
	local x = (value :: any).X
	if x == nil then
		return (value :: any).x, (value :: any).y, (value :: any).z
	end
	return x, (value :: any).Y, (value :: any).Z
end

-- A Vector3 (Roblox) or native vector with finite components; option maxMagnitude.
function Schema.vector3(options: { maxMagnitude: number? }?): Schema
	local maxMagnitude = optionNumber(options, "maxMagnitude", 0)
	return node("vector3", function(value: any, ctx: Context, path: string): (boolean, string?, string?)
		local ok, p, r = count(ctx, path)
		if not ok then
			return ok, p, r
		end
		local kind = typeof(value)
		if kind ~= "Vector3" and kind ~= "vector" then
			return fail(path, "type")
		end
		local x, y, z = components(value)
		for _, component in { x, y, z } do
			local problem = if type(component) == "number" then numberProblem(component) else "type"
			if problem then
				return fail(path, problem)
			end
		end
		if maxMagnitude and math.sqrt(x * x + y * y + z * z) > maxMagnitude then
			return fail(path, "magnitude")
		end
		return true, nil, nil
	end, { maxMagnitude = maxMagnitude })
end

-- A CFrame whose 12 components are finite; option maxMagnitude bounds its position.
function Schema.cframe(options: { maxMagnitude: number? }?): Schema
	local maxMagnitude = optionNumber(options, "maxMagnitude", 0)
	return node("cframe", function(value: any, ctx: Context, path: string): (boolean, string?, string?)
		local ok, p, r = count(ctx, path)
		if not ok then
			return ok, p, r
		end
		if typeof(value) ~= "CFrame" then
			return fail(path, "type")
		end
		local parts = { (value :: any):GetComponents() }
		for _, component in parts do
			local problem = numberProblem(component)
			if problem then
				return fail(path, problem)
			end
		end
		if maxMagnitude then
			local x, y, z = parts[1], parts[2], parts[3]
			if math.sqrt(x * x + y * y + z * z) > maxMagnitude then
				return fail(path, "magnitude")
			end
		end
		return true, nil, nil
	end, { maxMagnitude = maxMagnitude })
end

-- An Instance that IsA(className); option ancestor (the value must be its descendant). Option
-- typeof replaces the builtin for Lune specs with fake instances; never set it in a game.
function Schema.instanceOf(
	className: string,
	options: { ancestor: any?, typeof: ((value: any) -> string)? }?
): Schema
	if type(className) ~= "string" or className == "" then
		error("Schema.instanceOf: className must be a non-empty string", 2)
	end
	local ancestor = options and options.ancestor
	local typeOf = options and options.typeof or typeof
	return node("instance", function(value: any, ctx: Context, path: string): (boolean, string?, string?)
		local ok, p, r = count(ctx, path)
		if not ok then
			return ok, p, r
		end
		if typeOf(value) ~= "Instance" then
			return fail(path, "type")
		end
		if not (value :: any):IsA(className) then
			return fail(path, "class")
		end
		if ancestor ~= nil and not (value :: any):IsDescendantOf(ancestor) then
			return fail(path, "ancestor")
		end
		return true, nil, nil
	end, { className = className })
end

-- ---------------------------------------------------------------- composites

-- The same schema, also accepting nil.
function Schema.optional(schema: Schema): Schema
	assertSchema(schema, "Schema.optional's argument")
	local out = node(schema.kind, function(value: any, ctx: Context, path: string, depth: number)
		if value == nil then
			return true, nil, nil
		end
		return schema._check(value, ctx, path, depth)
	end, schema.options)
	out.optional = true
	return out
end

local function tableEntry(ctx: Context, value: any, path: string, depth: number): (boolean, string?, string?)
	local ok, p, r = count(ctx, path)
	if not ok then
		return ok, p, r
	end
	if type(value) ~= "table" then
		return fail(path, "type")
	end
	if depth >= ctx.maxDepth then
		return fail(path, "too_deep")
	end
	return true, nil, nil
end

-- A table with these string fields. strict (default true) rejects keys the shape does not name.
function Schema.struct(shape: { [string]: Schema }, options: { strict: boolean? }?): Schema
	if type(shape) ~= "table" then
		error("Schema.struct: shape must be a table of field -> schema", 2)
	end
	local fields: { string } = {}
	for key, child in shape do
		if type(key) ~= "string" then
			error("Schema.struct: field names must be strings", 2)
		end
		assertSchema(child, "field " .. key)
		table.insert(fields, key)
	end
	table.sort(fields)
	local strict = not (options ~= nil and options.strict == false)
	return node("struct", function(value: any, ctx: Context, path: string, depth: number)
		local ok, p, r = tableEntry(ctx, value, path, depth)
		if not ok then
			return ok, p, r
		end
		for key in value do
			if type(key) ~= "string" then
				return fail(childPath(path, key), "key")
			end
			if strict and shape[key] == nil then
				return fail(childPath(path, key), "unexpected_key")
			end
		end
		for _, field in fields do
			local child = shape[field]
			local item = value[field]
			if item == nil and not child.optional then
				return fail(childPath(path, field), "missing")
			end
			local okChild, pChild, rChild = child._check(item, ctx, childPath(path, field), depth + 1)
			if not okChild then
				return okChild, pChild, rChild
			end
		end
		return true, nil, nil
	end, { fields = fields, strict = strict })
end

-- A list (keys exactly 1..n) of items; minLen (default 0), maxLen (default 256, a convention).
function Schema.array(item: Schema, options: { minLen: number?, maxLen: number? }?): Schema
	assertSchema(item, "Schema.array's item")
	local minLen = optionNumber(options, "minLen", 0) or 0
	local maxLen = optionNumber(options, "maxLen", 0) or Schema.DEFAULT_MAX_LEN
	return node("array", function(value: any, ctx: Context, path: string, depth: number)
		local ok, p, r = tableEntry(ctx, value, path, depth)
		if not ok then
			return ok, p, r
		end
		local n = 0
		for key in value do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
				return fail(childPath(path, key), "not_array")
			end
			n += 1
			if n > maxLen then
				return fail(path, "too_long")
			end
		end
		-- n positive integer keys are exactly 1..n only when none of 1..n is missing (the length
		-- operator alone can report any border of a table with holes).
		for index = 1, n do
			if value[index] == nil then
				return fail(path, "sparse_array")
			end
		end
		if n < minLen then
			return fail(path, "too_short")
		end
		for index = 1, n do
			local okItem, pItem, rItem = item._check(value[index], ctx, childPath(path, index), depth + 1)
			if not okItem then
				return okItem, pItem, rItem
			end
		end
		return true, nil, nil
	end, { minLen = minLen, maxLen = maxLen })
end

-- A table of key -> value, each checked; maxEntries (default 256, a convention).
function Schema.map(key: Schema, value: Schema, options: { maxEntries: number? }?): Schema
	assertSchema(key, "Schema.map's key")
	assertSchema(value, "Schema.map's value")
	local maxEntries = optionNumber(options, "maxEntries", 0) or Schema.DEFAULT_MAX_LEN
	return node("map", function(item: any, ctx: Context, path: string, depth: number)
		local ok, p, r = tableEntry(ctx, item, path, depth)
		if not ok then
			return ok, p, r
		end
		local n = 0
		for k in item do
			n += 1
			if n > maxEntries then
				return fail(path, "too_many")
			end
			local okKey, _, rKey = key._check(k, ctx, childPath(path, k), depth + 1)
			if not okKey then
				return fail(childPath(path, k), if rKey == "type" then "key" else rKey :: string)
			end
		end
		for k, v in item do
			local okValue, pValue, rValue = value._check(v, ctx, childPath(path, k), depth + 1)
			if not okValue then
				return okValue, pValue, rValue
			end
		end
		return true, nil, nil
	end, { maxEntries = maxEntries })
end

-- The first of these schemas that accepts the value; reason "union" when none does.
function Schema.union(options: { Schema }): Schema
	if type(options) ~= "table" or #options == 0 then
		error("Schema.union: needs a non-empty list of schemas", 2)
	end
	for index, option in options do
		assertSchema(option, "option " .. index)
	end
	return node("union", function(value: any, ctx: Context, path: string, depth: number)
		for _, option in options do
			if option._check(value, ctx, path, depth) then
				return true, nil, nil
			end
			if ctx.nodes > ctx.maxNodes then
				return fail(path, "too_many_nodes")
			end
		end
		return fail(path, "union")
	end)
end

-- A predicate: fn(value) -> (ok, reason?). An error or a false result fails with "custom".
function Schema.custom(name: string, fn: (value: any) -> (boolean, string?)): Schema
	if type(name) ~= "string" or type(fn) ~= "function" then
		error("Schema.custom needs a name and a function", 2)
	end
	return node("custom", function(value: any, ctx: Context, path: string)
		local ok, p, r = count(ctx, path)
		if not ok then
			return ok, p, r
		end
		local called, accepted = pcall(fn, value)
		if not called or accepted ~= true then
			return fail(path, "custom")
		end
		return true, nil, nil
	end, { name = name })
end

-- ---------------------------------------------------------------- plain data

local function storableWalk(
	value: any,
	ctx: Context,
	path: string,
	depth: number,
	stack: { [any]: boolean }
): (boolean, string?, string?)
	local ok, p, r = count(ctx, path)
	if not ok then
		return ok, p, r
	end
	local kind = type(value)
	if kind == "boolean" then
		return true, nil, nil
	elseif kind == "number" then
		local problem = numberProblem(value)
		if problem then
			return fail(path, problem)
		end
		return true, nil, nil
	elseif kind == "string" then
		if utf8.len(value) == nil then
			return fail(path, "invalid_utf8")
		end
		return true, nil, nil
	elseif kind ~= "table" then
		return fail(path, "type")
	end
	if stack[value] then
		return fail(path, "cycle")
	end
	if depth >= ctx.maxDepth then
		return fail(path, "too_deep")
	end
	local strings, numbers = 0, 0
	for key in value do
		if type(key) == "string" then
			if utf8.len(key) == nil then
				return fail(childPath(path, "?"), "invalid_utf8")
			end
			strings += 1
		elseif type(key) == "number" and key % 1 == 0 and key >= 1 then
			numbers += 1
		else
			return fail(childPath(path, key), "key")
		end
	end
	if strings > 0 and numbers > 0 then
		return fail(path, "mixed_keys")
	end
	for index = 1, numbers do
		if value[index] == nil then
			return fail(path, "sparse_array")
		end
	end
	stack[value] = true
	local keys: { any } = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys, function(a: any, b: any): boolean
		return tostring(a) < tostring(b)
	end)
	for _, key in keys do
		local okChild, pChild, rChild = storableWalk(value[key], ctx, childPath(path, key), depth + 1, stack)
		if not okChild then
			stack[value] = nil
			return okChild, pChild, rChild
		end
	end
	stack[value] = nil
	return true, nil, nil
end

local function context(opts: CheckOptions?): Context
	local maxDepth = opts and opts.maxDepth or Schema.DEFAULT_MAX_DEPTH
	local maxNodes = opts and opts.maxNodes or Schema.DEFAULT_MAX_NODES
	assert(Check.integer(maxDepth) and maxDepth >= 1, "Schema: maxDepth must be an integer >= 1")
	assert(Check.integer(maxNodes) and maxNodes >= 1, "Schema: maxNodes must be an integer >= 1")
	return { nodes = 0, maxDepth = maxDepth, maxNodes = maxNodes }
end

-- Plain data a DataStore or JSON can hold: booleans, finite numbers, UTF-8 strings and tables
-- that are either arrays (keys 1..n) or string-keyed maps; no cycles, Instances, functions,
-- vectors or buffers. Returns (ok, path, reason).
function Schema.storable(value: any, opts: CheckOptions?): (boolean, string?, string?)
	return storableWalk(value, context(opts), "$", 0, {})
end

-- Any plain data (Schema.storable) as a schema.
function Schema.any(): Schema
	return node("any", function(value: any, ctx: Context, path: string, depth: number)
		if value == nil then
			return fail(path, "missing")
		end
		local inner: Context = { nodes = ctx.nodes, maxDepth = ctx.maxDepth - depth, maxNodes = ctx.maxNodes }
		local ok, p, r = storableWalk(value, inner, path, 0, {})
		ctx.nodes = inner.nodes
		return ok, p, r
	end)
end

-- Characters in the canonical JSON encoding: an estimate of the DataStore size of a storable
-- value (Roblox's own encoder may order keys and format numbers differently).
function Schema.size(value: any): number
	return #Json.encode(value)
end

-- ---------------------------------------------------------------- checking

-- (true) or (false, path, reason) for value against schema. Options: maxDepth (32), maxNodes (10000).
function Schema.check(schema: Schema, value: any, opts: CheckOptions?): (boolean, string?, string?)
	assertSchema(schema, "the first argument")
	if value == nil and not schema.optional then
		return false, "$", "missing"
	end
	local ok, path, reason = schema._check(value, context(opts), "$", 0)
	if ok then
		return true, nil, nil
	end
	return false, path, reason
end

-- Raises "<what>: <reason> at <path>" unless the value passes.
function Schema.assert(schema: Schema, value: any, what: string?)
	local ok, path, reason = Schema.check(schema, value)
	if not ok then
		error(string.format("%s: %s at %s", what or "value", tostring(reason), tostring(path)), 2)
	end
end

-- Minimum number of arguments: the position of the last required schema.
function Schema.requiredCount(list: { Schema }): number
	local required = 0
	for index, schema in list do
		if not schema.optional then
			required = index
		end
	end
	return required
end

-- Checks a positional argument list (args packed with table.pack). More arguments than schemas,
-- or fewer than the required ones, fail with reason "arity" at path "args".
function Schema.checkArgs(
	list: { Schema },
	args: { n: number, [number]: any },
	opts: CheckOptions?
): (boolean, string?, string?)
	if args.n > #list or args.n < Schema.requiredCount(list) then
		return false, "args", "arity"
	end
	local ctx = context(opts)
	for index, schema in list do
		local path = "args[" .. index .. "]"
		local value = args[index]
		if value == nil then
			if not schema.optional then
				return false, path, "missing"
			end
		else
			local ok, p, r = schema._check(value, ctx, path, 0)
			if not ok then
				return false, p, r
			end
		end
	end
	return true, nil, nil
end

return Schema
