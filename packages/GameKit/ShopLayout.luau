--!strict
-- @tier T0
-- ShopLayout: how the in-game shop is arranged (shop/1 data, docs/monetization.md): which
-- sections it has, which products each shows, which product is featured and which carry a
-- ribbon ("Best value", "Most popular", "Limited"). It is data for UIKit (Tabs, Grid,
-- ShopCard, OfferPopup); it never prompts. Data:
--   { schema = "shop/1",
--     entry = { hud = "left" | "right" | "top", label = bool?, notify = bool? },
--     sections = { { id, titleKey, tag? | products?, featured? } },
--     ribbons? = { [productKey] = ribbon } }
-- A section lists products by catalog tag or by explicit keys (in that order); featured names
-- one of its products for the big banner. build(shop, catalog, ctx) resolves sections into
-- items for the current player, sorts owned passes to the end (or hides them), and skips empty
-- sections. lint(shop, catalog) reports merchandising problems the validator does not: a
-- product that no section shows, a section with one product, more than one "best value" ribbon
-- per section, no visible HUD entry.
local Catalog = require("./Catalog")
local Check = require("./Check")
local Offers = require("./Offers")

local ShopLayout = {}
ShopLayout.SCHEMA = "shop/1"
ShopLayout.HUD = table.freeze({ "left", "right", "top" })
ShopLayout.MAX_SECTIONS = 8 -- UIKit Tabs takes 2-8 items

export type Section = {
	id: string,
	titleKey: string,
	tag: string?,
	products: { string }?,
	featured: string?,
}
export type Data = {
	schema: string,
	entry: { hud: "left" | "right" | "top", label: boolean?, notify: boolean? },
	sections: { Section },
	ribbons: { [string]: string }?,
}
export type Item = { productKey: string, kind: string, ribbon: string?, owned: boolean, featured: boolean }
export type BuiltSection = { id: string, titleKey: string, items: { Item } }

local function displayKey(value: any): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 100
		and string.match(value, "^[%w_%.%-]+$") ~= nil
end

local function sectionKeys(section: Section, catalog: any): { string }
	local keys = {}
	if section.tag ~= nil then
		for _, product in Catalog.list(catalog, section.tag) do
			table.insert(keys, product.key)
		end
	end
	local listed: { string } = section.products or {}
	for _, key in listed do
		if not table.find(keys, key) then
			table.insert(keys, key)
		end
	end
	return keys
end

-- Problems with shop/1 data (empty when valid). With a catalog, product keys and featured
-- products must exist and ribbons must name catalog products.
function ShopLayout.validate(data: any, catalog: any?): { string }
	if type(data) ~= "table" then
		return { "shop must be a table" }
	end
	local problems = {}
	if data.schema ~= ShopLayout.SCHEMA then
		table.insert(problems, "schema must be " .. ShopLayout.SCHEMA)
	end
	for key in data do
		if key ~= "schema" and key ~= "entry" and key ~= "sections" and key ~= "ribbons" then
			table.insert(problems, "unexpected key " .. Check.describe(key))
		end
	end
	local entry = data.entry
	if type(entry) ~= "table" or not table.find(ShopLayout.HUD, entry.hud) then
		table.insert(problems, "entry.hud must be left, right or top (the shop button on the HUD)")
	elseif type(entry) == "table" then
		for key, value in entry do
			if key == "label" or key == "notify" then
				if type(value) ~= "boolean" then
					table.insert(problems, "entry." .. key .. " must be a boolean")
				end
			elseif key ~= "hud" then
				table.insert(problems, "entry: unexpected key " .. Check.describe(key))
			end
		end
	end
	local validCatalog = catalog ~= nil and #Catalog.validate(catalog) == 0
	if catalog ~= nil and not validCatalog then
		table.insert(problems, "catalog is not a valid catalog/1 table")
	end
	local sections = data.sections
	if type(sections) ~= "table" or #sections == 0 then
		table.insert(problems, "sections must be a non-empty list")
	else
		if #sections > ShopLayout.MAX_SECTIONS then
			table.insert(problems, "at most " .. ShopLayout.MAX_SECTIONS .. " sections (UIKit Tabs)")
		end
		local seen: { [string]: boolean } = {}
		for index, section in sections do
			local where = "sections[" .. index .. "]"
			if type(section) ~= "table" then
				table.insert(problems, where .. " must be a table")
				continue
			end
			if Check.label(section.id) then
				where = section.id
				if seen[section.id] then
					table.insert(problems, where .. ": duplicate id")
				end
				seen[section.id] = true
			else
				table.insert(problems, where .. ".id must be a label")
			end
			for key in section do
				if
					key ~= "id"
					and key ~= "titleKey"
					and key ~= "tag"
					and key ~= "products"
					and key ~= "featured"
				then
					table.insert(problems, where .. ": unexpected key " .. Check.describe(key))
				end
			end
			if not displayKey(section.titleKey) then
				table.insert(problems, where .. ".titleKey must be a localisation key")
			end
			if section.tag == nil and section.products == nil then
				table.insert(problems, where .. ": give a tag, products or both")
			end
			if section.tag ~= nil and not Check.label(section.tag) then
				table.insert(problems, where .. ".tag must be a label")
			end
			if section.products ~= nil then
				if type(section.products) ~= "table" then
					table.insert(problems, where .. ".products must be a list of product keys")
				else
					for _, key in section.products do
						if not Check.label(key) then
							table.insert(
								problems,
								where .. ".products: " .. Check.describe(key) .. " is not a label"
							)
						elseif validCatalog and Catalog.find(catalog :: any, key) == nil then
							table.insert(problems, where .. ".products: " .. key .. " is not in the catalog")
						end
					end
				end
			end
			if section.featured ~= nil then
				if not Check.label(section.featured) then
					table.insert(problems, where .. ".featured must be a product key")
				elseif validCatalog and not table.find(sectionKeys(section, catalog), section.featured) then
					table.insert(
						problems,
						where .. ".featured " .. section.featured .. " is not one of the section's products"
					)
				end
			end
		end
	end
	if data.ribbons ~= nil then
		if type(data.ribbons) ~= "table" then
			table.insert(problems, "ribbons must map product keys to ribbons")
		else
			for key, ribbon in data.ribbons do
				if not Check.label(key) or not table.find(Offers.RIBBONS, ribbon) then
					table.insert(
						problems,
						"ribbons."
							.. tostring(key)
							.. " must be one of "
							.. table.concat(Offers.RIBBONS, ", ")
					)
				elseif validCatalog and Catalog.find(catalog :: any, key) == nil then
					table.insert(problems, "ribbons." .. key .. " is not in the catalog")
				end
			end
		end
	end
	return problems
end

function ShopLayout.define(data: any, catalog: any?): Data
	local problems = ShopLayout.validate(data, catalog)
	if #problems > 0 then
		error("ShopLayout.define: " .. table.concat(problems, "; "), 2)
	end
	return Check.freeze(Check.copy(data))
end

-- Sections for one player. ctx.owned(productKey) -> boolean marks owned passes; with
-- ctx.hideOwned they are left out, else they sort after what can still be bought. Developer
-- products are never "owned". Empty sections are skipped. Never yields.
function ShopLayout.build(
	data: Data,
	catalog: any,
	ctx: { owned: ((productKey: string) -> boolean)?, hideOwned: boolean? }?
): { BuiltSection }
	local context: { owned: ((productKey: string) -> boolean)?, hideOwned: boolean? } = ctx or {}
	local out = {}
	for _, section in data.sections do
		local items: { Item } = {}
		for index, key in sectionKeys(section, catalog) do
			local product = Catalog.find(catalog, key)
			if product == nil then
				continue
			end
			local owned = false
			if product.kind ~= "devproduct" and context.owned ~= nil then
				local ok, result = pcall(context.owned, key)
				owned = ok and result == true
			end
			if owned and context.hideOwned then
				continue
			end
			table.insert(
				items,
				{
					productKey = key,
					kind = product.kind,
					ribbon = data.ribbons and data.ribbons[key] or nil,
					owned = owned,
					featured = section.featured == key,
					order = index,
				} :: any
			)
		end
		table.sort(items, function(a: any, b: any): boolean
			if a.featured ~= b.featured then
				return a.featured
			end
			if a.owned ~= b.owned then
				return not a.owned
			end
			return a.order < b.order
		end)
		for _, item in items do
			(item :: any).order = nil
		end
		if #items > 0 then
			table.insert(out, { id = section.id, titleKey = section.titleKey, items = items })
		end
	end
	return out
end

-- Merchandising warnings (strings), separate from validate's hard problems.
function ShopLayout.lint(data: Data, catalog: any): { string }
	local warnings = {}
	local shown: { [string]: boolean } = {}
	for _, section in data.sections do
		local keys = sectionKeys(section, catalog)
		for _, key in keys do
			shown[key] = true
		end
		if #keys == 1 then
			table.insert(warnings, section.id .. ": one product; merge it into another section")
		end
		local best = 0
		for _, key in keys do
			if data.ribbons and data.ribbons[key] == "best_value" then
				best += 1
			end
		end
		if best > 1 then
			table.insert(
				warnings,
				section.id .. ": " .. best .. " best_value ribbons; one per section reads as a real pick"
			)
		end
	end
	for _, product in catalog.products do
		if not shown[product.key] and not product.adReward then
			table.insert(warnings, product.key .. ": no shop section shows it")
		end
	end
	if data.entry.label == false then
		table.insert(warnings, "entry.label is false: an icon-only shop button is easy to miss on phones")
	end
	return warnings
end

return ShopLayout
