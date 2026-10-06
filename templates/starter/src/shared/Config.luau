--!strict
-- @tier T0
-- Config: the game's static boot settings. Every field starts as "TBD": a TBD field is not decided,
-- so code reads it through Config.get(path, default) and gets the safe default. Fill a field only
-- from a decision logged in docs/decisions.md (and the matching production/brief.json entry).
-- Live values that change after publishing belong in GameKit/Config (ConfigService) once wired.
local TBD = "TBD"

local Config = {}

Config.TBD = TBD

Config.values = {
	name = "{{NAME}}",
	kits = {
		required = TBD, -- list of "Kit/Module" paths the boot must find, e.g. { "GameKit/Signal" }
	},
	data = {
		enabled = TBD, -- true once a data layer (GameKit/PlayerData) is wired in src/server/Phases.luau
	},
	telemetry = {
		enabled = TBD, -- true once an events sink (GameKit/Telemetry) is wired
	},
	ui = {
		root = TBD, -- name of the first screen the ui phase mounts
	},
	input = {
		contexts = TBD, -- Input Action System contexts the input phase creates (GameKit/InputMap)
	},
	boot = {
		timeouts = TBD, -- seconds per phase, e.g. { data = 15 }; Boot.DEFAULT_TIMEOUT until decided
	},
	loading = {
		timeoutSeconds = TBD, -- when the loading screen says loading is slow
	},
	debugCommands = TBD, -- Studio-only debug tools (GameKit/DebugCommands); never true in a release (A12)
	settings = {
		extra = TBD, -- game.* fields added to settings/1 through GameKit/Settings.schema
	},
}

-- Expected type per path once decided (TBD is always allowed).
local KINDS: { [string]: string } = {
	name = "string",
	["kits.required"] = "list",
	["data.enabled"] = "boolean",
	["telemetry.enabled"] = "boolean",
	["ui.root"] = "string",
	["input.contexts"] = "list",
	["boot.timeouts"] = "table",
	["loading.timeoutSeconds"] = "number",
	debugCommands = "boolean",
	["settings.extra"] = "table",
}

local function lookup(values: any, path: string): any
	local node = values
	for part in string.gmatch(path, "[^.]+") do
		if type(node) ~= "table" then
			return nil
		end
		node = node[part]
	end
	return node
end

function Config.isTbd(value: any): boolean
	return value == TBD
end

-- The decided value at a dotted path, or default when it is TBD or absent.
function Config.get(path: string, default: any?, values: any?): any
	local value = lookup(values or Config.values, path)
	if value == nil or value == TBD then
		return default
	end
	return value
end

-- Problems (empty when valid): a decided field with the wrong type. TBD is allowed everywhere.
function Config.validate(values: any?): { string }
	local problems = {}
	local source = values or Config.values
	if type(source) ~= "table" then
		return { "config values must be a table" }
	end
	local paths = {}
	for path in KINDS do
		table.insert(paths, path)
	end
	table.sort(paths)
	for _, path in paths do
		local value = lookup(source, path)
		local kind = KINDS[path]
		if value == nil then
			table.insert(problems, `{path} is missing (use "TBD" when undecided)`)
		elseif value ~= TBD then
			local ok
			if kind == "list" then
				ok = type(value) == "table"
				local count = 0
				for key, item in (if ok then value else {}) do
					count += 1
					ok = ok and type(key) == "number" and type(item) == "string"
				end
				ok = ok and count == #value
			elseif kind == "number" then
				ok = type(value) == "number" and value == value and value > 0 and value < math.huge
			else
				ok = type(value) == kind
			end
			if not ok then
				table.insert(problems, `{path} must be a {kind} or "TBD"`)
			end
		end
	end
	return problems
end

-- Count of TBD fields, for the boot report note.
function Config.undecided(values: any?): number
	local count = 0
	for path in KINDS do
		if lookup(values or Config.values, path) == TBD then
			count += 1
		end
	end
	return count
end

return Config
