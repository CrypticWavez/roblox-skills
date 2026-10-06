--!strict
-- @tier T0
-- Settings: the settings/1 player-settings contract (docs/runtime-kits.md "settings/1"): field
-- schema, defaults, validate, sanitize/merge for untrusted input, migrate with a hook, and the
-- effective values kits read (reduced motion folded with the system setting, shake scale, bus
-- gains). Pure data: persistence is GameKit/SettingsStore (G1), the panel is UIKit (G4), and
-- Feel/AVKit/Cinematics read Settings.effective. Ranges marked "convention" are factory choices,
-- not Roblox limits. A game adds its own fields under game.* with Settings.schema(extra).
local Check = require("./Check")

local Settings = {}
Settings.SCHEMA = "settings/1"
Settings.VERSION = 1

export type Kind = "number" | "boolean" | "enum" | "locale"
export type Field = {
	path: string,
	kind: Kind,
	default: any,
	min: number?,
	max: number?,
	step: number?,
	choices: { string }?,
	group: string,
	labelKey: string,
}
export type Schema = { Field }
export type Values = { [string]: any }
export type Effective = {
	reducedMotion: boolean,
	shakeScale: number,
	allowFlashes: boolean,
	haptics: boolean,
	volume: { [string]: number },
	uiScale: number,
	colorblindMode: string,
	cameraSensitivity: number,
	invertY: boolean,
	subtitles: boolean,
	language: string,
}
export type SystemInfo = { reducedMotion: boolean?, hapticsSupported: boolean?, locale: string? }

Settings.BUSES = table.freeze({ "master", "music", "sfx", "ui", "ambience", "dialogue", "world" })
Settings.COLORBLIND_MODES = table.freeze({ "none", "protanopia", "deuteranopia", "tritanopia" })
Settings.GROUPS = table.freeze({ "audio", "display", "accessibility", "controls", "language", "game" })

local function field(path: string, kind: Kind, default: any, group: string, extra: { [string]: any }?): Field
	local out: any =
		{ path = path, kind = kind, default = default, group = group, labelKey = "settings." .. path }
	if extra then
		for key, value in extra do
			out[key] = value
		end
	end
	return table.freeze(out)
end

local base: { Field } = {}
for _, bus in Settings.BUSES do
	table.insert(base, field("volume." .. bus, "number", 1, "audio", { min = 0, max = 1, step = 0.05 }))
end
table.insert(base, field("reducedMotion", "boolean", false, "accessibility"))
table.insert(base, field("screenShake", "number", 1, "accessibility", { min = 0, max = 1, step = 0.1 }))
table.insert(base, field("reduceFlashing", "boolean", false, "accessibility"))
table.insert(base, field("subtitles", "boolean", true, "accessibility"))
table.insert(
	base,
	field("colorblindMode", "enum", "none", "accessibility", { choices = Settings.COLORBLIND_MODES })
)
-- uiScale 0.75-1.5 and cameraSensitivity 0.1-4 are conventions.
table.insert(base, field("uiScale", "number", 1, "display", { min = 0.75, max = 1.5, step = 0.05 }))
table.insert(base, field("haptics", "boolean", true, "controls"))
table.insert(base, field("cameraSensitivity", "number", 1, "controls", { min = 0.1, max = 4, step = 0.05 }))
table.insert(base, field("invertY", "boolean", false, "controls"))
table.insert(base, field("language", "locale", "auto", "language"))
Settings.FIELDS = table.freeze(base) :: Schema

local function segments(path: string): { string }
	return string.split(path, ".")
end

-- "auto", or a lowercase Roblox locale id such as en-us, pt-br or zh-cn.
local function validLocale(value: any): boolean
	return type(value) == "string"
		and (
			value == "auto"
			or string.match(value, "^[a-z][a-z][a-z]?$") ~= nil
			or string.match(value, "^[a-z][a-z][a-z]?%-[a-z0-9]+$") ~= nil
		)
end

local function fieldValid(f: Field, value: any): boolean
	if f.kind == "number" then
		return Check.finite(value) and value >= (f.min :: number) and value <= (f.max :: number)
	elseif f.kind == "boolean" then
		return type(value) == "boolean"
	elseif f.kind == "enum" then
		return type(value) == "string" and table.find(f.choices :: { string }, value) ~= nil
	end
	return validLocale(value)
end

-- Problems with a field list (empty when valid): paths, kinds, ranges, defaults, duplicates.
local function schemaProblems(schema: { any }): { string }
	local problems = {}
	local seen: { [string]: boolean } = {}
	local leaves: { [string]: boolean } = {}
	for index, f in schema do
		local where = "field " .. tostring(index)
		if type(f) ~= "table" or type(f.path) ~= "string" then
			table.insert(problems, where .. ": needs a path")
			continue
		end
		where = "field " .. f.path
		for _, part in segments(f.path) do
			if not string.match(part, "^[a-z][A-Za-z0-9]*$") then
				table.insert(problems, where .. ": path segments are camelCase identifiers")
				break
			end
		end
		if seen[f.path] then
			table.insert(problems, where .. ": duplicate path")
		end
		seen[f.path] = true
		leaves[f.path] = true
		if f.kind ~= "number" and f.kind ~= "boolean" and f.kind ~= "enum" and f.kind ~= "locale" then
			table.insert(problems, where .. ": kind must be number, boolean, enum or locale")
			continue
		end
		if f.kind == "number" then
			if not (Check.finite(f.min) and Check.finite(f.max) and f.min <= f.max) then
				table.insert(problems, where .. ": number fields need finite min <= max")
				continue
			end
		elseif f.kind == "enum" then
			if type(f.choices) ~= "table" or #f.choices == 0 then
				table.insert(problems, where .. ": enum fields need choices")
				continue
			end
		end
		if not fieldValid(f, f.default) then
			table.insert(problems, where .. ": default is out of range")
		end
		if not table.find(Settings.GROUPS, f.group) then
			table.insert(problems, where .. ": group must be one of " .. table.concat(Settings.GROUPS, ", "))
		end
	end
	-- A path cannot be both a value and a table of values (volume vs volume.music).
	for path in leaves do
		local parts = segments(path)
		for depth = 1, #parts - 1 do
			local prefix = table.concat(parts, ".", 1, depth)
			if leaves[prefix] then
				table.insert(problems, "field " .. prefix .. ": also used as a group of " .. path)
			end
		end
	end
	return problems
end

-- settings/1 plus a game's own fields; every extra path must start with "game.".
function Settings.schema(extra: { any }?): Schema
	local out: { any } = table.clone(Settings.FIELDS :: any)
	for _, f in extra or {} do
		if type(f) ~= "table" or type(f.path) ~= "string" or string.sub(f.path, 1, 5) ~= "game." then
			error("Settings.schema: extra fields need a path starting with game.", 2)
		end
		local copy: any = table.clone(f)
		copy.group = copy.group or "game"
		copy.labelKey = copy.labelKey or ("settings." .. copy.path)
		table.insert(out, table.freeze(copy))
	end
	local problems = schemaProblems(out)
	if #problems > 0 then
		error("Settings.schema: " .. table.concat(problems, "; "), 2)
	end
	return table.freeze(out) :: any
end

local function getPath(values: any, path: string): (any, boolean)
	local node = values
	for _, part in segments(path) do
		if type(node) ~= "table" then
			return nil, false
		end
		node = node[part]
	end
	return node, true
end

local function setPath(values: { [string]: any }, path: string, value: any)
	local parts = segments(path)
	local node = values
	for index = 1, #parts - 1 do
		local part = parts[index]
		if type(node[part]) ~= "table" then
			node[part] = {}
		end
		node = node[part]
	end
	node[parts[#parts]] = value
end

-- A complete settings/1 table holding every default.
function Settings.defaults(schema: Schema?): Values
	local out: Values = { schema = Settings.SCHEMA, version = Settings.VERSION }
	for _, f in schema or Settings.FIELDS do
		setPath(out, f.path, f.default)
	end
	return out
end

local function knownPaths(schema: Schema): ({ [string]: boolean }, { [string]: boolean })
	local leaves, groups = {}, {}
	for _, f in schema do
		leaves[f.path] = true
		local parts = segments(f.path)
		for depth = 1, #parts - 1 do
			groups[table.concat(parts, ".", 1, depth)] = true
		end
	end
	return leaves, groups
end

-- Unknown keys in values (paths), given the schema's leaves and groups.
local function unknownKeys(values: any, schema: Schema): { string }
	local leaves, groups = knownPaths(schema)
	local found = {}
	local function walk(node: any, prefix: string)
		for key, child in node do
			local path = if prefix == "" then tostring(key) else prefix .. "." .. tostring(key)
			if prefix == "" and (key == "schema" or key == "version") then
				continue
			end
			if leaves[path] then
				continue
			elseif groups[path] and type(child) == "table" then
				walk(child, path)
			else
				table.insert(found, path)
			end
		end
	end
	walk(values, "")
	table.sort(found)
	return found
end

-- Problems with a settings table (empty when it is a valid, complete settings/1 table).
function Settings.validate(values: any, schema: Schema?): { string }
	local fields = schema or Settings.FIELDS
	if type(values) ~= "table" then
		return { "settings must be a table" }
	end
	local problems = {}
	if values.schema ~= Settings.SCHEMA then
		table.insert(problems, "schema must be " .. Settings.SCHEMA)
	end
	if not (Check.integer(values.version) and values.version >= 1) then
		table.insert(problems, "version must be an integer >= 1")
	end
	for _, f in fields do
		local value, reachable = getPath(values, f.path)
		if not reachable or value == nil then
			table.insert(problems, f.path .. ": missing")
		elseif not fieldValid(f, value) then
			table.insert(
				problems,
				string.format("%s: %s is not a valid %s", f.path, Check.describe(value), f.kind)
			)
		end
	end
	for _, path in unknownKeys(values, fields) do
		table.insert(problems, path .. ": unknown setting")
	end
	return problems
end

-- A complete, valid settings table from untrusted input: numbers are clamped into range,
-- invalid or missing values take the default, unknown keys are dropped. Returns the table and
-- notes saying what changed. The version is kept when it is a valid integer.
function Settings.sanitize(raw: any, schema: Schema?): (Values, { string })
	local fields = schema or Settings.FIELDS
	local notes = {}
	local out = Settings.defaults(fields)
	if type(raw) ~= "table" then
		table.insert(notes, "not a table: defaults used")
		return out, notes
	end
	if Check.integer(raw.version) and raw.version >= 1 then
		out.version = raw.version
	end
	for _, f in fields do
		local value = getPath(raw, f.path)
		if value == nil then
			continue
		end
		if fieldValid(f, value) then
			setPath(out, f.path, value)
		elseif f.kind == "number" and Check.finite(value) then
			local clamped = math.clamp(value, f.min :: number, f.max :: number)
			setPath(out, f.path, clamped)
			table.insert(
				notes,
				string.format("%s: clamped %s to %s", f.path, tostring(value), tostring(clamped))
			)
		else
			table.insert(
				notes,
				string.format("%s: %s is invalid, default used", f.path, Check.describe(value))
			)
		end
	end
	for _, path in unknownKeys(raw, fields) do
		table.insert(notes, path .. ": unknown setting dropped")
	end
	return out, notes
end

-- base overlaid with a partial patch, sanitized (a client's settings change goes through here
-- on the server). schema and version in the patch are ignored.
function Settings.merge(base: Values, patch: any, schema: Schema?): (Values, { string })
	local fields = schema or Settings.FIELDS
	local combined: any = if type(base) == "table" then Check.copy(base) else Settings.defaults(fields)
	local notes = {}
	if type(patch) ~= "table" then
		table.insert(notes, "patch is not a table: ignored")
	else
		local leaves = knownPaths(fields)
		for path in leaves do
			local value = getPath(patch, path)
			if value ~= nil then
				setPath(combined, path, value)
			end
		end
		for _, path in unknownKeys(patch, fields) do
			table.insert(notes, path .. ": unknown setting dropped")
		end
	end
	local merged, sanitizeNotes = Settings.sanitize(combined, fields)
	for _, note in sanitizeNotes do
		table.insert(notes, note)
	end
	return merged, notes
end

-- One field changed: Settings.set(s, "volume.music", 0.5).
function Settings.set(values: Values, path: string, value: any, schema: Schema?): (Values, { string })
	local patch = {}
	setPath(patch, path, value)
	return Settings.merge(values, patch, schema)
end

function Settings.get(values: Values, path: string): any
	return (getPath(values, path))
end

export type MigrateOptions = {
	schema: Schema?,
	version: number?, -- the game's current settings version (default Settings.VERSION)
	migrations: { [number]: (data: { [string]: any }) -> { [string]: any } }?, -- from version n to n + 1
}

-- Loads saved settings of any age: nil gives defaults; older versions run migrations[n] for
-- each step up to the current version (a missing step is noted and skipped); the result is
-- sanitized and stamped with the current version. Returns the table and notes.
function Settings.migrate(raw: any, opts: MigrateOptions?): (Values, { string })
	local fields = opts and opts.schema or Settings.FIELDS
	local current = opts and opts.version or Settings.VERSION
	assert(Check.integer(current) and current >= 1, "Settings.migrate: version must be an integer >= 1")
	local notes = {}
	if raw == nil then
		local out = Settings.defaults(fields)
		out.version = current
		return out, { "no saved settings: defaults used" }
	end
	if type(raw) ~= "table" then
		local out = Settings.defaults(fields)
		out.version = current
		return out, { "saved settings are not a table: defaults used" }
	end
	local data: any = Check.copy(raw)
	local from = if Check.integer(data.version) and data.version >= 1 then data.version else 1
	if from > current then
		table.insert(
			notes,
			string.format("saved version %d is newer than %d: unknown fields dropped", from, current)
		)
	end
	for version = from, current - 1 do
		local step = opts and opts.migrations and opts.migrations[version]
		if step then
			local ok, result = pcall(step, data)
			if ok and type(result) == "table" then
				data = result
			else
				table.insert(notes, string.format("migration %d failed: %s", version, tostring(result)))
			end
		else
			table.insert(notes, string.format("no migration from version %d", version))
		end
	end
	local out, sanitizeNotes = Settings.sanitize(data, fields)
	out.version = current
	for _, note in sanitizeNotes do
		table.insert(notes, note)
	end
	return out, notes
end

-- What kits read: reduced motion is the setting OR the system setting (GuiService
-- ReducedMotionEnabled); shake is 0 under reduced motion; bus gains are master x bus.
function Settings.effective(values: Values, system: SystemInfo?): Effective
	local s = values
	local reducedMotion = s.reducedMotion == true or (system ~= nil and system.reducedMotion == true)
	local volume = {}
	local master = s.volume.master
	for _, bus in Settings.BUSES do
		volume[bus] = if bus == "master" then master else master * s.volume[bus]
	end
	local language = s.language
	if language == "auto" then
		language = if system
				and validLocale(system.locale)
				and system.locale ~= "auto"
			then system.locale :: string
			else "en-us"
	end
	return {
		reducedMotion = reducedMotion,
		shakeScale = if reducedMotion then 0 else s.screenShake,
		allowFlashes = not s.reduceFlashing,
		haptics = s.haptics == true and not (system ~= nil and system.hapticsSupported == false),
		volume = volume,
		uiScale = s.uiScale,
		colorblindMode = s.colorblindMode,
		cameraSensitivity = s.cameraSensitivity,
		invertY = s.invertY,
		subtitles = s.subtitles,
		language = language,
	}
end

return Settings
