--!strict
-- Saved generation manifests: canonical (sorted-key) JSON plus a content hash, so a seed
-- can be regenerated and compared byte-for-byte in any runtime.
local Rng = require("./Rng")

local Manifest = {}
Manifest.VERSION = 1

local function encode(value: any, out: { string })
	local kind = type(value)
	if kind == "nil" then
		table.insert(out, "null")
	elseif kind == "boolean" then
		table.insert(out, tostring(value))
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			table.insert(out, "null")
		elseif value % 1 == 0 and math.abs(value) < 2 ^ 53 then
			table.insert(out, string.format("%d", value))
		else
			table.insert(out, string.format("%.6g", value))
		end
	elseif kind == "string" then
		table.insert(out, '"' .. string.gsub(value, '[%c"\\]', function(c)
			return string.format("\\u%04x", string.byte(c))
		end) .. '"')
	elseif kind == "table" then
		if #value > 0 or next(value) == nil then
			table.insert(out, "[")
			for index, item in ipairs(value) do
				if index > 1 then
					table.insert(out, ",")
				end
				encode(item, out)
			end
			table.insert(out, "]")
		else
			local keys = {}
			for key in value do
				table.insert(keys, tostring(key))
			end
			table.sort(keys)
			table.insert(out, "{")
			for index, key in keys do
				if index > 1 then
					table.insert(out, ",")
				end
				encode(key, out)
				table.insert(out, ":")
				local item = value[key]
				if item == nil then
					item = value[tonumber(key)]
				end
				encode(item, out)
			end
			table.insert(out, "}")
		end
	else
		error("Manifest cannot encode " .. kind)
	end
end

function Manifest.encode(value: any): string
	local out = {}
	encode(value, out)
	return table.concat(out)
end

function Manifest.hash(value: any): string
	return string.format("%08x", Rng.hash(Manifest.encode(value)))
end

-- Plain-data layout fields copied into a manifest when present (forest: bands to exit).
local LAYOUT_KEYS = {
	"rooms",
	"spawns",
	"objectives",
	"roads",
	"lots",
	"landmark",
	"corridors",
	"bands",
	"clearings",
	"paths",
	"vegetation",
	"entry",
	"exit",
}

-- Strip runtime objects (Grid/Graph metatables) into plain data.
function Manifest.fromLayout(layout, extra: { [string]: any }?)
	local body: { [string]: any } = { version = Manifest.VERSION, kind = layout.kind, params = layout.params }
	if layout.grid then
		body.grid = {
			width = layout.grid.width,
			height = layout.grid.height,
			cellSize = layout.grid.cellSize,
			ascii = layout.grid:toAscii(),
		}
	end
	if layout.graph then
		body.graph = layout.graph:toTable()
	end
	for _, key in LAYOUT_KEYS do
		if layout[key] ~= nil then
			body[key] = layout[key]
		end
	end
	for key, value in extra or {} do
		body[key] = value
	end
	body.hash = Manifest.hash(body)
	return body
end

return Manifest
