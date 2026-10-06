--!strict
-- @tier T0
-- Catalog: the catalog/1 product list (docs/runtime-kits.md "catalog/1"): developer products,
-- passes and subscriptions with a stable key, the Roblox id, grants as data and display keys
-- (localisation and icon keys, never text). No prices: Roblox prices change per region and
-- under Managed Pricing, so they are read at runtime (GetProductInfoAsync, in G1's
-- CommerceRoblox) and shown through a price provider. Any price-like field is rejected.
-- mode "setup" (the factory and new game repos) keeps every product disabled; mode "game"
-- needs real ids and owner-verified ownership for enabled products. Display and data only:
-- nothing here prompts or grants.
local Check = require("./Check")

local Catalog = {}
Catalog.SCHEMA = "catalog/1"
Catalog.KINDS = table.freeze({ "devproduct", "gamepass", "subscription" })
Catalog.MODES = table.freeze({ "setup", "game" })
Catalog.GRANT_TYPES = table.freeze({ "currency", "item", "entitlement", "custom" })
-- Kind names used by the inherited Runtime/CommerceCatalog and Creator/UI.
Catalog.LEGACY_KINDS =
	table.freeze({ developer_product = "devproduct", pass = "gamepass", subscription = "subscription" })
-- Placeholder ids: 0 for products and passes, "EXP-0" for subscriptions.
Catalog.PLACEHOLDER_ID = 0
Catalog.PLACEHOLDER_SUBSCRIPTION_ID = "EXP-0"

export type Kind = "devproduct" | "gamepass" | "subscription"
export type Grant = {
	type: "currency" | "item" | "entitlement" | "custom",
	currency: string?,
	amount: number?,
	item: string?,
	count: number?,
	entitlement: string?,
	handler: string?,
	data: { [string]: string | number | boolean }?,
}
export type Display = { nameKey: string, descriptionKey: string?, iconKey: string? }
export type Product = {
	key: string,
	kind: Kind,
	id: number | string,
	grants: { Grant },
	display: Display,
	enabled: boolean,
	ownershipVerified: boolean,
	adReward: boolean?,
	tags: { string }?,
	order: number?,
}
export type Catalog = { schema: string, mode: "setup" | "game", products: { Product } }
-- What a UI shows for a price; produced at runtime by the game's price provider.
export type PriceInfo = { state: "ok" | "pending" | "unavailable", text: string?, robux: number? }

local PRODUCT_KEYS = table.freeze({
	"key",
	"kind",
	"id",
	"grants",
	"display",
	"enabled",
	"ownershipVerified",
	"adReward",
	"tags",
	"order",
})
local GRANT_KEYS: { [string]: { string } } = {
	currency = { "type", "currency", "amount" },
	item = { "type", "item", "count" },
	entitlement = { "type", "entitlement" },
	custom = { "type", "handler", "data" },
}

local function priceLike(key: any): boolean
	if type(key) ~= "string" then
		return false
	end
	local lower = string.lower(key)
	return string.find(lower, "price", 1, true) ~= nil
		or string.find(lower, "robux", 1, true) ~= nil
		or string.find(lower, "cost", 1, true) ~= nil
end

-- A localisation or asset key: 1..100 of letters, digits and _ . -
local function displayKey(value: any): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 100
		and string.match(value, "^[%w_%.%-]+$") ~= nil
end

local function isPlaceholder(kind: any, id: any): boolean
	if kind == "subscription" then
		return id == Catalog.PLACEHOLDER_SUBSCRIPTION_ID
	end
	return id == Catalog.PLACEHOLDER_ID
end

local function realId(kind: any, id: any): boolean
	if kind == "subscription" then
		return type(id) == "string"
			and #id <= 64
			and string.match(id, "^EXP%-%w+$") ~= nil
			and id ~= Catalog.PLACEHOLDER_SUBSCRIPTION_ID
	end
	return Check.integer(id) and id > 0
end

-- The catalog/1 kind for a legacy kind name (pass, developer_product), or the name unchanged.
function Catalog.normalizeKind(kind: string): string
	return (Catalog.LEGACY_KINDS :: any)[kind] or kind
end

local function grantProblems(grant: any, where: string, adReward: boolean, problems: { string })
	if type(grant) ~= "table" then
		table.insert(problems, where .. " must be a table")
		return
	end
	local keys = GRANT_KEYS[grant.type]
	if keys == nil then
		table.insert(problems, where .. ".type must be one of " .. table.concat(Catalog.GRANT_TYPES, ", "))
		return
	end
	for key in grant do
		if priceLike(key) then
			table.insert(
				problems,
				string.format("%s.%s: prices are runtime reads, not catalog data", where, key)
			)
		elseif not table.find(keys, key) then
			table.insert(problems, string.format("%s: unexpected key %s", where, Check.describe(key)))
		end
	end
	if grant.type == "currency" then
		if not Check.label(grant.currency) then
			table.insert(problems, where .. ".currency must be a label")
		end
		if not (Check.integer(grant.amount) and grant.amount > 0) then
			table.insert(problems, where .. ".amount must be an integer > 0")
		end
	elseif grant.type == "item" then
		if not Check.label(grant.item) then
			table.insert(problems, where .. ".item must be a label")
		end
		if not (Check.integer(grant.count) and grant.count > 0) then
			table.insert(problems, where .. ".count must be an integer > 0")
		end
	elseif grant.type == "entitlement" then
		if not Check.label(grant.entitlement) then
			table.insert(problems, where .. ".entitlement must be a label")
		end
	else
		if adReward then
			table.insert(
				problems,
				where .. ": ad-reward products grant fixed currency, items or entitlements only"
			)
		end
		if not Check.label(grant.handler) then
			table.insert(problems, where .. ".handler must be a label")
		end
		if grant.data ~= nil then
			if type(grant.data) ~= "table" then
				table.insert(problems, where .. ".data must be a map")
			else
				for key, value in grant.data do
					local kind = type(value)
					if
						not Check.label(key)
						or (kind ~= "string" and kind ~= "boolean" and not Check.finite(value))
					then
						table.insert(
							problems,
							string.format(
								"%s.data.%s must map a label to a string, number or boolean",
								where,
								tostring(key)
							)
						)
					end
				end
			end
		end
	end
end

-- Problems with a catalog (empty when it is a valid catalog/1 table).
function Catalog.validate(catalog: any): { string }
	if type(catalog) ~= "table" then
		return { "catalog must be a table" }
	end
	local problems = {}
	if catalog.schema ~= Catalog.SCHEMA then
		table.insert(problems, "schema must be " .. Catalog.SCHEMA)
	end
	local mode = catalog.mode
	if mode ~= "setup" and mode ~= "game" then
		table.insert(problems, "mode must be setup or game")
	end
	for key in catalog do
		if key ~= "schema" and key ~= "mode" and key ~= "products" then
			table.insert(problems, "unexpected key " .. Check.describe(key))
		end
	end
	local products = catalog.products
	if type(products) ~= "table" then
		table.insert(problems, "products must be a list")
		return problems
	end
	local keys: { [string]: number } = {}
	local ids: { [any]: string } = {}
	for index, product in products do
		local where = "products[" .. tostring(index) .. "]"
		if type(product) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		if Check.label(product.key) then
			where = product.key
			if keys[product.key] then
				table.insert(
					problems,
					string.format("%s: duplicate key (also products[%d])", where, keys[product.key])
				)
			end
			keys[product.key] = index
		else
			table.insert(problems, where .. ".key must be a label")
		end
		for key in product do
			if priceLike(key) then
				table.insert(
					problems,
					string.format(
						"%s.%s: prices are runtime reads (GetProductInfoAsync), never catalog data",
						where,
						tostring(key)
					)
				)
			elseif not table.find(PRODUCT_KEYS, key) then
				table.insert(problems, string.format("%s: unexpected key %s", where, Check.describe(key)))
			end
		end
		local kind = product.kind
		if not table.find(Catalog.KINDS, kind) then
			local legacy = (Catalog.LEGACY_KINDS :: any)[kind]
			table.insert(
				problems,
				string.format(
					"%s.kind must be devproduct, gamepass or subscription%s",
					where,
					if legacy then " (legacy " .. tostring(kind) .. " is " .. legacy .. ")" else ""
				)
			)
		end
		local placeholder = isPlaceholder(kind, product.id)
		if not placeholder and not realId(kind, product.id) then
			table.insert(
				problems,
				string.format(
					"%s.id must be %s",
					where,
					if kind == "subscription"
						then "an EXP- subscription id (placeholder EXP-0)"
						else "an integer > 0 (placeholder 0)"
				)
			)
		elseif not placeholder then
			if ids[product.id] then
				table.insert(problems, string.format("%s: id also used by %s", where, ids[product.id]))
			end
			ids[product.id] = where
		end
		if type(product.enabled) ~= "boolean" then
			table.insert(problems, where .. ".enabled must be a boolean")
		end
		if type(product.ownershipVerified) ~= "boolean" then
			table.insert(problems, where .. ".ownershipVerified must be a boolean")
		end
		if mode == "setup" and product.enabled == true then
			table.insert(problems, where .. ": setup mode keeps every product disabled")
		end
		if mode == "game" then
			if placeholder then
				table.insert(problems, where .. ": game mode needs the real id, not the placeholder")
			end
			if product.enabled == true and product.ownershipVerified ~= true then
				table.insert(
					problems,
					where .. ": an enabled product needs ownershipVerified = true (owner check)"
				)
			end
		end
		if product.adReward ~= nil then
			if type(product.adReward) ~= "boolean" then
				table.insert(problems, where .. ".adReward must be a boolean")
			elseif product.adReward and kind ~= "devproduct" then
				table.insert(problems, where .. ": only developer products can be ad rewards")
			end
		end
		local display = product.display
		if type(display) ~= "table" then
			table.insert(problems, where .. ".display must be a table with nameKey")
		else
			for key, value in display do
				if key ~= "nameKey" and key ~= "descriptionKey" and key ~= "iconKey" then
					table.insert(
						problems,
						string.format("%s.display: unexpected key %s", where, Check.describe(key))
					)
				elseif not displayKey(value) then
					table.insert(
						problems,
						string.format("%s.display.%s must be a key (letters, digits, _ . -)", where, key)
					)
				end
			end
			if display.nameKey == nil then
				table.insert(problems, where .. ".display.nameKey is required")
			end
		end
		local grants = product.grants
		if type(grants) ~= "table" or #grants == 0 then
			table.insert(problems, where .. ".grants must be a non-empty list")
		else
			for gindex, grant in grants do
				grantProblems(
					grant,
					string.format("%s.grants[%d]", where, gindex),
					product.adReward == true,
					problems
				)
			end
		end
		if product.tags ~= nil then
			if type(product.tags) ~= "table" then
				table.insert(problems, where .. ".tags must be a list of labels")
			else
				for _, tag in product.tags do
					if not Check.label(tag) then
						table.insert(
							problems,
							string.format("%s.tags: %s is not a label", where, Check.describe(tag))
						)
					end
				end
			end
		end
		if product.order ~= nil and not Check.integer(product.order) then
			table.insert(problems, where .. ".order must be an integer")
		end
	end
	return problems
end

-- Validates, deep-copies and deep-freezes a catalog. Raises with every problem listed.
function Catalog.define(data: any): Catalog
	local problems = Catalog.validate(data)
	if #problems > 0 then
		error("Catalog.define: " .. table.concat(problems, "; "), 2)
	end
	return Check.freeze(Check.copy(data))
end

function Catalog.find(catalog: Catalog, key: string): Product?
	for _, product in catalog.products do
		if product.key == key then
			return product
		end
	end
	return nil
end

-- The product with this Roblox id (receipts carry ids); placeholders never match.
function Catalog.byId(catalog: Catalog, id: number | string): Product?
	for _, product in catalog.products do
		if product.id == id and not isPlaceholder(product.kind, product.id) then
			return product
		end
	end
	return nil
end

-- Products to show, optionally with a tag, sorted by order then key.
function Catalog.list(catalog: Catalog, tag: string?): { Product }
	local out = {}
	for _, product in catalog.products do
		if tag == nil or (product.tags ~= nil and table.find(product.tags, tag) ~= nil) then
			table.insert(out, product)
		end
	end
	table.sort(out, function(a: Product, b: Product): boolean
		local oa, ob = a.order or 0, b.order or 0
		if oa ~= ob then
			return oa < ob
		end
		return a.key < b.key
	end)
	return out
end

return Catalog
