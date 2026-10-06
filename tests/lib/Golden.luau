--!strict
-- Golden: compare a value with tests/golden/<name>.json. The file holds canonical, indented JSON
-- (packages/GameKit/Json), so diffs stay readable and Lune and Studio agree byte for byte.
-- A golden is rewritten only when FACTORY_UPDATE_GOLDEN is "1" (all) or a comma list naming it
-- (python3 tools/check.py --update-golden=<name> sets it); otherwise a missing or different
-- golden fails with the first differing path. Paths resolve from this file, so specs run from
-- any working directory. Shared Stage 0 helper: groups read it, never edit it.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Json = require("../../packages/GameKit/Json")
local Rng = require("../../packages/ProcGen/Rng")

local Golden = {}

local TESTS = string.match(debug.info(1, "s"), "^(.*)[/\\]lib[/\\][^/\\]*$") or "tests"
Golden.DIR = TESTS .. "/golden"
Golden.ENV = "FACTORY_UPDATE_GOLDEN"
-- Goldens tools/check.py writes itself (fixture builds, Studio smoke); specs must not claim them.
Golden.RESERVED = table.freeze({ ["fixture-hashes"] = true, ["studio-smoke"] = true })

local function checkName(name: string)
	if type(name) ~= "string" or not string.match(name, "^[a-z0-9][a-z0-9_.%-]*$") then
		error("Golden: name must be lower-case letters, digits, _ . - (got " .. tostring(name) .. ")", 3)
	end
	if Golden.RESERVED[name] then
		error("Golden: " .. name .. " is written by tools/check.py, not by specs", 3)
	end
end

export type Options = {
	dir: string?, -- golden directory (default tests/golden; specs of Golden itself use build/)
	setting: string?, -- stands in for the FACTORY_UPDATE_GOLDEN value
}

function Golden.path(name: string, dir: string?): string
	checkName(name)
	return (dir or Golden.DIR) .. "/" .. name .. ".json"
end

-- Whether this run may rewrite the named golden.
function Golden.updating(name: string, value: string?): boolean
	local setting = value or process.env[Golden.ENV]
	if setting == nil or setting == "" then
		return false
	end
	if setting == "1" then
		return true
	end
	for _, item in string.split(setting, ",") do
		if string.gsub(item, "^%s*(.-)%s*$", "%1") == name then
			return true
		end
	end
	return false
end

-- Canonical text written to a golden file.
function Golden.encode(value: any): string
	return Json.encode(value, { indent = "  " }) .. "\n"
end

-- An 8-hex FNV-1a digest of the canonical compact JSON (the Manifest.hash family).
function Golden.digest(value: any): string
	return string.format("%08x", Rng.hash(Json.encode(value)))
end

local function firstDifference(expected: any, actual: any, path: string): string?
	if type(expected) ~= type(actual) then
		return string.format("%s: expected %s, got %s", path, Json.encode(expected), Json.encode(actual))
	end
	if type(expected) ~= "table" then
		if expected ~= actual then
			return string.format("%s: expected %s, got %s", path, Json.encode(expected), Json.encode(actual))
		end
		return nil
	end
	local keys: { any } = {}
	local seen: { [any]: boolean } = {}
	for key in expected do
		seen[key] = true
		table.insert(keys, key)
	end
	for key in actual do
		if not seen[key] then
			table.insert(keys, key)
		end
	end
	table.sort(keys, function(a: any, b: any): boolean
		return tostring(a) < tostring(b)
	end)
	for _, key in keys do
		local childPath = if type(key) == "number"
			then path .. "[" .. key .. "]"
			else path .. "." .. tostring(key)
		if expected[key] == nil then
			return childPath .. ": not in the golden"
		elseif actual[key] == nil then
			return childPath .. ": missing"
		end
		local found = firstDifference(expected[key], actual[key], childPath)
		if found then
			return found
		end
	end
	return nil
end

-- (ok, message). Writes the golden when updating (message "updated" or "unchanged").
function Golden.check(name: string, value: any, opts: Options?): (boolean, string)
	local dir = opts and opts.dir or Golden.DIR
	local path = Golden.path(name, dir)
	local text = Golden.encode(value)
	local existing = if fs.isFile(path) then fs.readFile(path) else nil
	if Golden.updating(name, opts and opts.setting) then
		if existing == text then
			return true, "unchanged"
		end
		if not fs.isDir(dir) then
			fs.writeDir(dir)
		end
		fs.writeFile(path, text)
		if dir == Golden.DIR then
			print("GOLDEN updated tests/golden/" .. name .. ".json")
		end
		return true, "updated"
	end
	if existing == nil then
		return false,
			string.format(
				"golden tests/golden/%s.json is missing (intended? rerun with --update-golden=%s or %s=%s)",
				name,
				name,
				Golden.ENV,
				name
			)
	end
	if existing == text then
		return true, "match"
	end
	-- Same data written differently (hand-edited spacing) still matches.
	local expected = serde.decode("json", existing)
	local actual = serde.decode("json", Json.encode(value))
	local difference = firstDifference(expected, actual, "$")
	if difference == nil then
		return true, "match"
	end
	return false,
		string.format(
			"golden tests/golden/%s.json differs at %s (intended? rerun with --update-golden=%s or %s=%s)",
			name,
			difference,
			name,
			Golden.ENV,
			name
		)
end

-- Raises (at the caller's level) unless value matches the named golden.
function Golden.assert(name: string, value: any, opts: Options?)
	local ok, message = Golden.check(name, value, opts)
	if not ok then
		error(message, 2)
	end
end

return Golden
