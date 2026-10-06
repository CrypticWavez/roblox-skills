--!strict
-- @tier T0
-- Check: validation helpers every kit shares. Numbers from remotes, stores and data files are
-- checked with finite/integer before use (NaN and inf pass naive range checks), ids and names
-- with label, and data tables are deep-copied and deep-frozen with copy/freeze.
local Check = {}

-- Largest integer a double holds exactly (2^53); integer() refuses anything beyond it.
Check.MAX_SAFE_INTEGER = 9007199254740992
Check.LABEL_MAX = 64

-- True for a number that is neither NaN nor +-inf.
function Check.finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- True for a finite whole number within +-2^53.
function Check.integer(value: any): boolean
	return Check.finite(value) and value % 1 == 0 and math.abs(value) <= Check.MAX_SAFE_INTEGER
end

-- True for a lower_snake_case label: a letter first, then letters, digits or underscores,
-- 1 to maxLength (default 64) characters. Ids, keys, event names and states use it.
function Check.label(value: any, maxLength: number?): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= (maxLength or Check.LABEL_MAX)
		and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function describe(value: any): string
	if type(value) == "number" then
		if value ~= value then
			return "nan"
		end
		return tostring(value)
	elseif type(value) == "string" then
		return string.format("%q", if #value > 40 then string.sub(value, 1, 40) .. "..." else value)
	end
	return type(value)
end
Check.describe = describe

-- Returns value when it is finite; otherwise raises "<what> must be a finite number (got ...)".
function Check.assertFinite(value: any, what: string?): number
	if not Check.finite(value) then
		error(string.format("%s must be a finite number (got %s)", what or "value", describe(value)), 2)
	end
	return value
end

-- Deep copy of plain data. Shared sub-tables stay shared and cycles are preserved; metatables
-- are not copied (data tables carry none). Non-table values are returned as they are.
function Check.copy<T>(value: T): T
	local seen: { [any]: any } = {}
	local function walk(item: any): any
		if type(item) ~= "table" then
			return item
		end
		if seen[item] then
			return seen[item]
		end
		local out = {}
		seen[item] = out
		for key, child in item do
			out[walk(key)] = walk(child)
		end
		return out
	end
	return walk(value)
end

-- Deep-freezes a table in place (table.freeze on it and every nested table) and returns it.
-- Already frozen tables are walked but not re-frozen; cycles are handled.
function Check.freeze<T>(value: T): T
	local seen: { [any]: boolean } = {}
	local function walk(item: any)
		if type(item) ~= "table" or seen[item] then
			return
		end
		seen[item] = true
		for key, child in item do
			walk(key)
			walk(child)
		end
		if not table.isfrozen(item) then
			table.freeze(item)
		end
	end
	walk(value)
	return value
end

return Check
