--!strict
-- @tier T0
-- Json: canonical JSON encoding that is byte-identical in Lune and Roblox (sorted object keys,
-- shortest round-trip numbers), so probe lines, kit-event/1 JSONL and goldens hash the same
-- everywhere. Encode only: decode with HttpService:JSONDecode in Roblox or @lune/serde in Lune.
local Json = {}

-- A table that always encodes as {} (an empty Luau table otherwise encodes as []).
Json.EMPTY_OBJECT = table.freeze({})

export type Options = { indent: string? }

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(text: string): string
	return '"'
		.. string.gsub(text, '[%c"\\]', function(char: string): string
			return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
		end)
		.. '"'
end

local function encodeNumber(value: number): string
	if value ~= value or value == math.huge or value == -math.huge then
		return "null" -- JSON has no NaN or infinity
	end
	if value % 1 == 0 and math.abs(value) < 2 ^ 53 then
		return string.format("%d", value)
	end
	for _, format in { "%.14g", "%.15g", "%.16g" } do
		local text = string.format(format, value)
		if tonumber(text) == value then
			return text
		end
	end
	return string.format("%.17g", value)
end

-- An array is a table whose keys are exactly 1..n (n >= 1).
local function isArray(value: { [any]: any }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end
	return count > 0 and count == #value
end

function Json.encode(value: any, options: Options?): string
	local indent = options and options.indent
	local out: { string } = {}
	local stack: { [any]: boolean } = {}

	local function newline(depth: number)
		if indent then
			table.insert(out, "\n" .. string.rep(indent, depth))
		end
	end

	local function walk(item: any, path: string, depth: number)
		local kind = type(item)
		if kind == "nil" then
			table.insert(out, "null")
		elseif kind == "boolean" then
			table.insert(out, if item then "true" else "false")
		elseif kind == "number" then
			table.insert(out, encodeNumber(item))
		elseif kind == "string" then
			table.insert(out, encodeString(item))
		elseif kind == "table" then
			if stack[item] then
				error("Json.encode: cycle at " .. path, 0)
			end
			if item == Json.EMPTY_OBJECT then
				table.insert(out, "{}")
				return
			end
			stack[item] = true
			if next(item) == nil then
				table.insert(out, "[]")
			elseif isArray(item) then
				table.insert(out, "[")
				for index, child in ipairs(item) do
					if index > 1 then
						table.insert(out, ",")
					end
					newline(depth + 1)
					walk(child, path .. "[" .. index .. "]", depth + 1)
				end
				newline(depth)
				table.insert(out, "]")
			else
				local keys: { string } = {}
				local byText: { [string]: any } = {}
				for key in item do
					local keyKind = type(key)
					if keyKind ~= "string" and keyKind ~= "number" then
						error("Json.encode: " .. keyKind .. " key at " .. path, 0)
					end
					local text = if keyKind == "number" then encodeNumber(key) else key
					if byText[text] ~= nil then
						error("Json.encode: duplicate key " .. text .. " at " .. path, 0)
					end
					byText[text] = key
					table.insert(keys, text)
				end
				table.sort(keys)
				table.insert(out, "{")
				for index, text in keys do
					if index > 1 then
						table.insert(out, ",")
					end
					newline(depth + 1)
					table.insert(out, encodeString(text))
					table.insert(out, if indent then ": " else ":")
					walk(item[byText[text]], path .. "." .. text, depth + 1)
				end
				newline(depth)
				table.insert(out, "}")
			end
			stack[item] = nil
		else
			error("Json.encode: cannot encode " .. kind .. " at " .. path, 0)
		end
	end

	walk(value, "$", 0)
	return table.concat(out)
end

return Json
