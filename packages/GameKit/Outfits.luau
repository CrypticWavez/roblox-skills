--!strict
-- @tier T0
-- Outfits: avatar outfits as data (outfit/1) for roleplay, fashion and uniform systems, mapped to
-- HumanoidDescription properties. No items ship here; asset ids are whatever the game supplies
-- (0 means "none / default"). An outfit is
--   { schema = "outfit/1",
--     accessories? = { { type, id, layered?, order?, puffiness? } },  -- Enum.AccessoryType names
--     body? = { Head?, Torso?, LeftArm?, RightArm?, LeftLeg?, RightLeg?, Face? },
--     clothing? = { Shirt?, Pants?, GraphicTShirt? },
--     animations? = { Idle?, Walk?, Run?, Jump?, Fall?, Climb?, Swim?, Mood? },
--     colors? = { head?, torso?, leftArm?, rightArm?, leftLeg?, rightLeg? }, -- "#RRGGBB" or {r,g,b}
--     scales? = { height?, width?, depth?, head?, bodyType?, proportion? } }
-- Every section is optional: toDescription() returns a plan that sets only what the outfit
-- names (accessories replace all accessories when the list is present, even empty), so a
-- partial outfit patches the current look. Rules are the game's: scale ranges (defaults below
-- are a convention taken from the avatar editor ranges, UNVERIFIED for every experience
-- setting), an accessory count limit, per-type limits and an allow(kind, id) predicate (for
-- example "owned by the player", checked by the game). OutfitsRoblox (T3) applies plans.
local Check = require("./Check")

local Outfits = {}
Outfits.SCHEMA = "outfit/1"

-- Enum.AccessoryType names accepted in accessories[].type.
Outfits.ACCESSORY_TYPES = table.freeze({
	"Hat",
	"Hair",
	"Face",
	"Neck",
	"Shoulder",
	"Front",
	"Back",
	"Waist",
	"TShirt",
	"Shirt",
	"Pants",
	"Jacket",
	"Sweater",
	"Shorts",
	"LeftShoe",
	"RightShoe",
	"DressSkirt",
	"Eyebrow",
	"Eyelash",
})
-- Types layered by default (layered clothing and head details); others default to rigid.
Outfits.LAYERED_TYPES = table.freeze({
	"TShirt",
	"Shirt",
	"Pants",
	"Jacket",
	"Sweater",
	"Shorts",
	"LeftShoe",
	"RightShoe",
	"DressSkirt",
	"Eyebrow",
	"Eyelash",
})
Outfits.BODY = table.freeze({ "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg", "Face" })
Outfits.CLOTHING = table.freeze({ "Shirt", "Pants", "GraphicTShirt" })
Outfits.ANIMATIONS = table.freeze({ "Idle", "Walk", "Run", "Jump", "Fall", "Climb", "Swim", "Mood" })
Outfits.COLORS = table.freeze({
	head = "HeadColor",
	torso = "TorsoColor",
	leftArm = "LeftArmColor",
	rightArm = "RightArmColor",
	leftLeg = "LeftLegColor",
	rightLeg = "RightLegColor",
})
Outfits.SCALES = table.freeze({
	height = "HeightScale",
	width = "WidthScale",
	depth = "DepthScale",
	head = "HeadScale",
	bodyType = "BodyTypeScale",
	proportion = "ProportionScale",
})
-- Convention, UNVERIFIED: avatar editor ranges; depth follows width. Games override per rules.
Outfits.DEFAULT_SCALE_RANGES = Check.freeze({
	height = { min = 0.9, max = 1.05 },
	width = { min = 0.7, max = 1 },
	depth = { min = 0.7, max = 1 },
	head = { min = 0.95, max = 1 },
	bodyType = { min = 0, max = 1 },
	proportion = { min = 0, max = 1 },
})

export type Accessory = { type: string, id: number, layered: boolean?, order: number?, puffiness: number? }
export type Outfit = { [string]: any }
export type Rules = {
	scales: { [string]: { min: number, max: number } }?,
	maxAccessories: number?,
	perType: { [string]: number }?,
	allow: ((kind: string, id: number) -> boolean)?,
}
export type Plan = {
	properties: { [string]: any },
	accessories: {
		{
			AccessoryType: string,
			AssetId: number,
			IsLayered: boolean,
			Order: number?,
			Puffiness: number?,
		}
	}?,
}

local SECTIONS = { "schema", "accessories", "body", "clothing", "animations", "colors", "scales" }

local function idOk(value: any): boolean
	return Check.integer(value) and value >= 0
end

-- {r, g, b} 0..255 from "#RRGGBB" or a table; nil when invalid.
function Outfits.color(value: any): { r: number, g: number, b: number }?
	if type(value) == "string" then
		local hex = string.match(value, "^#(%x%x%x%x%x%x)$")
		if hex == nil then
			return nil
		end
		return {
			r = tonumber(string.sub(hex, 1, 2), 16) :: number,
			g = tonumber(string.sub(hex, 3, 4), 16) :: number,
			b = tonumber(string.sub(hex, 5, 6), 16) :: number,
		}
	end
	if type(value) == "table" then
		for _, key in { "r", "g", "b" } do
			local channel = value[key]
			if not (Check.integer(channel) and channel >= 0 and channel <= 255) then
				return nil
			end
		end
		return { r = value.r, g = value.g, b = value.b }
	end
	return nil
end

local function checkIdMap(problems: { string }, section: string, map: any, names: { string }, rules: Rules)
	if map == nil then
		return
	end
	if type(map) ~= "table" then
		table.insert(problems, section .. " must be a map")
		return
	end
	for key, id in map do
		if not table.find(names, key) then
			table.insert(problems, section .. ": unknown key " .. Check.describe(key))
		elseif not idOk(id) then
			table.insert(problems, section .. "." .. key .. ": id must be an integer >= 0 (0 = default)")
		elseif id > 0 and rules.allow and not rules.allow(section .. "." .. key, id) then
			table.insert(problems, section .. "." .. key .. ": id " .. id .. " is not allowed")
		end
	end
end

-- Problems with an outfit under rules (empty when valid).
function Outfits.validate(outfit: any, rules: Rules?): { string }
	if type(outfit) ~= "table" then
		return { "outfit must be a table" }
	end
	local r: Rules = rules or {}
	local problems = {}
	if outfit.schema ~= nil and outfit.schema ~= Outfits.SCHEMA then
		table.insert(problems, "schema must be outfit/1")
	end
	for key in outfit do
		if not table.find(SECTIONS, key) then
			table.insert(problems, "unknown section " .. Check.describe(key))
		end
	end
	local accessories = outfit.accessories
	if accessories ~= nil then
		if type(accessories) ~= "table" then
			table.insert(problems, "accessories must be a list")
		else
			local seen, perType = {}, {}
			for index, accessory in accessories do
				local where = "accessories[" .. index .. "]"
				if type(accessory) ~= "table" then
					table.insert(problems, where .. " must be a table")
					continue
				end
				for key in accessory do
					if not table.find({ "type", "id", "layered", "order", "puffiness" }, key) then
						table.insert(problems, where .. ": unknown key " .. Check.describe(key))
					end
				end
				if not table.find(Outfits.ACCESSORY_TYPES, accessory.type) then
					table.insert(
						problems,
						where .. ": type " .. Check.describe(accessory.type) .. " is not an AccessoryType"
					)
				else
					perType[accessory.type] = (perType[accessory.type] or 0) + 1
				end
				if not (Check.integer(accessory.id) and accessory.id >= 1) then
					table.insert(problems, where .. ": id must be an integer >= 1")
				elseif seen[accessory.id] then
					table.insert(problems, where .. ": id " .. accessory.id .. " appears twice")
				else
					seen[accessory.id] = true
					if r.allow and not r.allow("accessory." .. tostring(accessory.type), accessory.id) then
						table.insert(problems, where .. ": id " .. accessory.id .. " is not allowed")
					end
				end
				if accessory.layered ~= nil and type(accessory.layered) ~= "boolean" then
					table.insert(problems, where .. ": layered must be a boolean")
				end
				if
					accessory.order ~= nil and not (Check.integer(accessory.order) and accessory.order >= 0)
				then
					table.insert(problems, where .. ": order must be an integer >= 0")
				end
				if
					accessory.puffiness ~= nil
					and not (
						Check.finite(accessory.puffiness)
						and accessory.puffiness >= 0
						and accessory.puffiness <= 1
					)
				then
					table.insert(problems, where .. ": puffiness must be in [0, 1]")
				end
			end
			if r.maxAccessories ~= nil and #accessories > r.maxAccessories then
				table.insert(
					problems,
					string.format("%d accessories pass the limit of %d", #accessories, r.maxAccessories)
				)
			end
			for kind, limit in r.perType or {} do
				if (perType[kind] or 0) > limit then
					table.insert(
						problems,
						string.format("%d %s accessories pass the limit of %d", perType[kind], kind, limit)
					)
				end
			end
		end
	end
	checkIdMap(problems, "body", outfit.body, Outfits.BODY :: any, r)
	checkIdMap(problems, "clothing", outfit.clothing, Outfits.CLOTHING :: any, r)
	checkIdMap(problems, "animations", outfit.animations, Outfits.ANIMATIONS :: any, r)
	if outfit.colors ~= nil then
		if type(outfit.colors) ~= "table" then
			table.insert(problems, "colors must be a map")
		else
			for key, value in outfit.colors do
				if Outfits.COLORS[key] == nil then
					table.insert(problems, "colors: unknown key " .. Check.describe(key))
				elseif Outfits.color(value) == nil then
					table.insert(problems, "colors." .. key .. ' must be "#RRGGBB" or { r, g, b } in 0..255')
				end
			end
		end
	end
	if outfit.scales ~= nil then
		if type(outfit.scales) ~= "table" then
			table.insert(problems, "scales must be a map")
		else
			local ranges = r.scales or Outfits.DEFAULT_SCALE_RANGES
			for key, value in outfit.scales do
				local range = ranges[key]
				if Outfits.SCALES[key] == nil then
					table.insert(problems, "scales: unknown key " .. Check.describe(key))
				elseif not Check.finite(value) then
					table.insert(problems, "scales." .. key .. " must be a finite number")
				elseif range and (value < range.min or value > range.max) then
					table.insert(
						problems,
						string.format(
							"scales.%s %s is outside %s..%s",
							key,
							tostring(value),
							tostring(range.min),
							tostring(range.max)
						)
					)
				end
			end
		end
	end
	return problems
end

-- The HumanoidDescription plan for a valid outfit (raises otherwise). Colors stay { r, g, b }.
function Outfits.toDescription(outfit: Outfit, rules: Rules?): Plan
	local problems = Outfits.validate(outfit, rules)
	if #problems > 0 then
		error("Outfits.toDescription: " .. table.concat(problems, "; "), 2)
	end
	local properties = table.clone(outfit.body or {})
	for key, id in outfit.clothing or {} do
		properties[key] = id
	end
	for key, id in outfit.animations or {} do
		properties[key .. "Animation"] = id
	end
	for key, value in outfit.colors or {} do
		properties[Outfits.COLORS[key]] = Outfits.color(value)
	end
	for key, value in outfit.scales or {} do
		properties[Outfits.SCALES[key]] = value
	end
	local plan: Plan = { properties = properties, accessories = nil }
	if outfit.accessories ~= nil then
		local list = {}
		for _, accessory in outfit.accessories do
			local layered = if accessory.layered ~= nil
				then accessory.layered
				else table.find(Outfits.LAYERED_TYPES, accessory.type) ~= nil
			table.insert(list, {
				AccessoryType = accessory.type,
				AssetId = accessory.id,
				IsLayered = layered,
				Order = if layered then accessory.order or #list else nil,
				Puffiness = if layered then accessory.puffiness else nil,
			})
		end
		plan.accessories = list
	end
	return plan
end

-- An outfit from a description snapshot { properties, accessories } (the adapter reads one from
-- a HumanoidDescription, colors as { r, g, b }). Unknown properties are ignored.
function Outfits.fromDescription(snapshot: any): Outfit
	assert(type(snapshot) == "table", "Outfits.fromDescription: snapshot must be a table")
	local props = snapshot.properties or {}
	local outfit: Outfit = { schema = Outfits.SCHEMA }
	local function section(name: string, keys: { string }, suffix: string)
		local map = {}
		local any = false
		for _, key in keys do
			local id = props[key .. suffix]
			if idOk(id) then
				map[key] = id
				any = true
			end
		end
		if any then
			outfit[name] = map
		end
	end
	section("body", Outfits.BODY :: any, "")
	section("clothing", Outfits.CLOTHING :: any, "")
	section("animations", Outfits.ANIMATIONS :: any, "Animation")
	local colors, scales = {}, {}
	for key, property in Outfits.COLORS do
		local color = Outfits.color(props[property])
		if color then
			colors[key] = color
		end
	end
	for key, property in Outfits.SCALES do
		if Check.finite(props[property]) then
			scales[key] = props[property]
		end
	end
	if next(colors) then
		outfit.colors = colors
	end
	if next(scales) then
		outfit.scales = scales
	end
	if type(snapshot.accessories) == "table" then
		local list = {}
		for _, accessory in snapshot.accessories do
			local entry: Accessory = {
				type = accessory.AccessoryType,
				id = accessory.AssetId,
				layered = accessory.IsLayered == true,
			}
			if accessory.IsLayered then
				entry.order = accessory.Order
				entry.puffiness = accessory.Puffiness
			end
			table.insert(list, entry)
		end
		outfit.accessories = list
	end
	return outfit
end

-- overlay on top of base: maps merge key by key; overlay accessories replace base accessories
-- of the same type and keep the rest (a uniform over a player's own look).
function Outfits.merge(base: Outfit, overlay: Outfit): Outfit
	local out: Outfit = Check.copy(base)
	out.schema = Outfits.SCHEMA
	for _, name in { "body", "clothing", "animations", "colors", "scales" } do
		if overlay[name] ~= nil then
			out[name] = out[name] or {}
			for key, value in overlay[name] do
				out[name][key] = Check.copy(value)
			end
		end
	end
	if overlay.accessories ~= nil then
		local replaced = {}
		for _, accessory in overlay.accessories do
			replaced[accessory.type] = true
		end
		local list = {}
		for _, accessory in base.accessories or {} do
			if not replaced[accessory.type] then
				table.insert(list, Check.copy(accessory))
			end
		end
		for _, accessory in overlay.accessories do
			table.insert(list, Check.copy(accessory))
		end
		out.accessories = list
	end
	return out
end

return Outfits
