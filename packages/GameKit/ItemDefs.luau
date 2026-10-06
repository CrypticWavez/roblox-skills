--!strict
-- @tier T0
-- ItemDefs: validated, frozen item definitions for Inventory, Crafting, Trade and OddsTable
-- results. A definition is data the game supplies; none ship here:
--   { id, kind, stackable, maxStack, tags?, slot?, weight?, unique?, tradable?, paid?, data? }
-- id and kind are labels; a stackable item has maxStack >= 1 (a non-stackable one exactly 1,
-- each copy then being an instance with its own uid in Inventory); slot names the equip slot;
-- weight is a finite number >= 0; unique allows one copy per inventory; tradable (default
-- true) gates Trade; paid marks every copy as the outcome of a paid item or paid random item
-- (Trade then needs the trading policy); data maps labels to strings, numbers or booleans.
local Check = require("./Check")

local ItemDefs = {}
ItemDefs.__index = ItemDefs
ItemDefs.KEYS = table.freeze({
	"id",
	"kind",
	"stackable",
	"maxStack",
	"tags",
	"slot",
	"weight",
	"unique",
	"tradable",
	"paid",
	"data",
})

export type Def = {
	id: string,
	kind: string,
	stackable: boolean,
	maxStack: number,
	tags: { string },
	slot: string?,
	weight: number,
	unique: boolean,
	tradable: boolean,
	paid: boolean,
	data: { [string]: string | number | boolean },
}
type RegistryFields = { _defs: { [string]: Def }, _order: { string } }
export type Registry = typeof(setmetatable({} :: RegistryFields, ItemDefs))

-- Problems with one definition (where names it in messages).
local function inspect(def: any, where: string, problems: { string })
	local function problem(text: string, ...: any)
		table.insert(problems, where .. ": " .. string.format(text, ...))
	end
	if type(def) ~= "table" then
		problem("must be a table")
		return
	end
	for key in def do
		if not table.find(ItemDefs.KEYS, key) then
			problem("unknown key %s", Check.describe(key))
		end
	end
	if not Check.label(def.id) then
		problem("id %s is not a label", Check.describe(def.id))
	end
	if not Check.label(def.kind) then
		problem("kind %s is not a label", Check.describe(def.kind))
	end
	if type(def.stackable) ~= "boolean" then
		problem("stackable must be a boolean")
	end
	if not (Check.integer(def.maxStack) and def.maxStack >= 1) then
		problem("maxStack must be an integer >= 1")
	elseif def.stackable == false and def.maxStack ~= 1 then
		problem("a non-stackable item has maxStack 1")
	end
	if def.tags ~= nil then
		if type(def.tags) ~= "table" then
			problem("tags must be a list of labels")
		else
			local seen = {}
			for index, tag in def.tags do
				if type(index) ~= "number" or not Check.label(tag) then
					problem("tag %s is not a label", Check.describe(tag))
				elseif seen[tag] then
					problem("duplicate tag %s", tag)
				end
				seen[tag] = true
			end
		end
	end
	if def.slot ~= nil then
		if not Check.label(def.slot) then
			problem("slot %s is not a label", Check.describe(def.slot))
		elseif def.stackable == true then
			problem("an equippable item (slot) must be non-stackable")
		end
	end
	if def.weight ~= nil and not (Check.finite(def.weight) and def.weight >= 0) then
		problem("weight must be a finite number >= 0")
	end
	for _, flag in { "unique", "tradable", "paid" } do
		if def[flag] ~= nil and type(def[flag]) ~= "boolean" then
			problem("%s must be a boolean", flag)
		end
	end
	if def.unique == true and def.maxStack ~= 1 then
		problem("a unique item has maxStack 1")
	end
	if def.data ~= nil then
		if type(def.data) ~= "table" then
			problem("data must be a map of label -> string, number or boolean")
		else
			for key, value in def.data do
				local kind = type(value)
				if not Check.label(key) then
					problem("data key %s is not a label", Check.describe(key))
				elseif
					not (kind == "string" or kind == "boolean" or (kind == "number" and Check.finite(value)))
				then
					problem("data.%s must be a string, finite number or boolean", key)
				end
			end
		end
	end
end

-- Problems with a list of definitions (empty when valid): shapes and duplicate ids.
function ItemDefs.validate(defs: any): { string }
	if type(defs) ~= "table" then
		return { "defs must be a list of item definitions" }
	end
	local problems = {}
	local seen: { [string]: number } = {}
	for index, def in defs do
		if type(index) ~= "number" then
			table.insert(problems, "defs must be a list (found key " .. Check.describe(index) .. ")")
			continue
		end
		local where = "item "
			.. (if type(def) == "table" and type(def.id) == "string" then def.id else "#" .. index)
		inspect(def, where, problems)
		if type(def) == "table" and type(def.id) == "string" then
			if seen[def.id] then
				table.insert(problems, string.format("%s: duplicate id (also item #%d)", where, seen[def.id]))
			else
				seen[def.id] = index
			end
		end
	end
	return problems
end

-- A frozen registry of definitions with defaults filled. Raises with every problem listed.
function ItemDefs.registry(defs: { any }): Registry
	local problems = ItemDefs.validate(defs)
	if #problems > 0 then
		error("ItemDefs.registry: " .. table.concat(problems, "; "), 2)
	end
	local byId: { [string]: Def } = {}
	local order = {}
	for _, raw in defs do
		local def: Def = {
			id = raw.id,
			kind = raw.kind,
			stackable = raw.stackable,
			maxStack = raw.maxStack,
			tags = if raw.tags then table.clone(raw.tags) else {},
			slot = raw.slot,
			weight = raw.weight or 0,
			unique = raw.unique == true,
			tradable = raw.tradable ~= false,
			paid = raw.paid == true,
			data = if raw.data then table.clone(raw.data) else {},
		}
		byId[def.id] = Check.freeze(def)
		table.insert(order, def.id)
	end
	return setmetatable({ _defs = byId, _order = order }, ItemDefs)
end

-- Whether value is a registry from ItemDefs.registry.
function ItemDefs.isRegistry(value: any): boolean
	return type(value) == "table" and getmetatable(value) == ItemDefs
end

function ItemDefs.get(self: Registry, id: string): Def?
	return self._defs[id]
end

function ItemDefs.has(self: Registry, id: string): boolean
	return self._defs[id] ~= nil
end

-- Definitions in declaration order, optionally only those carrying tag.
function ItemDefs.list(self: Registry, tag: string?): { Def }
	local out = {}
	for _, id in self._order do
		local def = self._defs[id]
		if tag == nil or table.find(def.tags, tag) then
			table.insert(out, def)
		end
	end
	return out
end

function ItemDefs.count(self: Registry): number
	return #self._order
end

return ItemDefs
