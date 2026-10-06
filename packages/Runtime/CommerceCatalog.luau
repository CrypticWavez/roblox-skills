--!strict
-- Read-only display/entitlement boundary; no purchase prompting in this package.
-- Two constructors share one display/entitlement API:
--   new(universeId, entries, platform)        the inherited setup form: entries keyed by stable
--                                             key, each verified, disabled and with a real id;
--                                             displays are preview_only, never purchasable
--   fromCatalog(universeId, catalog, platform) a catalog/1 table (GameKit/Catalog, the schema
--                                             every kit uses). Setup mode never offers a product
--                                             (preview_only at most); placeholder ids (0, EXP-0)
--                                             show "unavailable" without a platform call; game
--                                             mode offers enabled, owner-verified products
-- validateEntry(entry, mode) lists the problems with one legacy entry. Legacy entries may spell
-- the id `productId` (Creator/UI.shopDisplay's spelling); id and productId must agree when both
-- are set. platform is { productInfo(kind, id, player), entitlement(kind, id, player) }, bound
-- to MarketplaceService by GameKit/CommerceRoblox.platform. Kinds passed to the platform keep
-- the legacy names (pass, developer_product, subscription).
local CatalogSchema = require("../GameKit/Catalog")

local Catalog = {}
export type Display = { state: string, reason: string?, name: string?, price: string?, purchasable: boolean? }
export type Entitlement = { state: string, reason: string? }

local LEGACY_NAME =
	table.freeze({ devproduct = "developer_product", gamepass = "pass", subscription = "subscription" })

-- The entry's id, from id or its alias productId. Raises "id_conflict" when both disagree.
local function entryId(entry: any): any
	if entry.id ~= nil and entry.productId ~= nil and entry.id ~= entry.productId then
		error("id_conflict: id and productId disagree", 3)
	end
	if entry.id ~= nil then
		return entry.id
	end
	return entry.productId
end

local function priceLike(key: any): boolean
	if type(key) ~= "string" then
		return false
	end
	local lower = string.lower(key)
	return string.find(lower, "price", 1, true) ~= nil
		or string.find(lower, "robux", 1, true) ~= nil
		or string.find(lower, "cost", 1, true) ~= nil
end

-- Problems with one legacy entry under a catalog mode ("setup" by default). Empty when valid.
-- Setup mode: enabled must be false; ids may be real or the placeholder. Game mode: real ids
-- only, and an enabled entry needs ownershipVerified = true. Subscription ids keep EXP-.
function Catalog.validateEntry(entry: any, mode: string?): { string }
	if type(entry) ~= "table" then
		return { "entry must be a table" }
	end
	local problems = {}
	local catalogMode = mode or "setup"
	if catalogMode ~= "setup" and catalogMode ~= "game" then
		table.insert(problems, "mode must be setup or game")
	end
	local kind = if type(entry.kind) == "string" then CatalogSchema.normalizeKind(entry.kind) else nil
	if kind == nil or table.find(CatalogSchema.KINDS, kind) == nil then
		table.insert(problems, "kind must be pass, developer_product or subscription")
	end
	local idOk, id = pcall(entryId, entry)
	if not idOk then
		table.insert(problems, "id_conflict: id and productId disagree")
	else
		local placeholder = if kind == "subscription"
			then id == CatalogSchema.PLACEHOLDER_SUBSCRIPTION_ID
			else id == CatalogSchema.PLACEHOLDER_ID
		local real = if kind == "subscription"
			then type(id) == "string" and #id <= 64 and string.match(id, "^EXP%-%w+$") ~= nil and not placeholder
			else type(id) == "number" and id > 0 and id % 1 == 0 and id <= 9007199254740991
		if not placeholder and not real then
			table.insert(
				problems,
				if kind == "subscription"
					then "id must be an EXP- subscription id (placeholder EXP-0)"
					else "id must be an integer > 0 (placeholder 0)"
			)
		end
		if catalogMode == "game" and placeholder then
			table.insert(problems, "game mode needs the real id, not the placeholder")
		end
	end
	if type(entry.enabled) ~= "boolean" then
		table.insert(problems, "enabled must be a boolean")
	end
	if type(entry.ownershipVerified) ~= "boolean" then
		table.insert(problems, "ownershipVerified must be a boolean")
	end
	if catalogMode == "setup" and entry.enabled == true then
		table.insert(problems, "setup mode keeps every product disabled (enabled = false)")
	end
	if catalogMode == "game" and entry.enabled == true and entry.ownershipVerified ~= true then
		table.insert(problems, "an enabled entry needs ownershipVerified = true (owner check)")
	end
	if
		entry.universeId ~= nil
		and not (type(entry.universeId) == "number" and entry.universeId > 0 and entry.universeId % 1 == 0)
	then
		table.insert(problems, "universeId must be an integer > 0")
	end
	for key in entry do
		if priceLike(key) then
			table.insert(problems, tostring(key) .. ": prices are runtime reads, never catalog data")
		end
	end
	return problems
end

local function api(approved: { [string]: any }, platform: any, describe: (entry: any) -> (boolean, string?))
	local self = {}
	function self:display(key: string, player: any): Display
		local entry = approved[key]
		if not entry then
			return { state = "unavailable", reason = "unconfigured" }
		end
		if entry.placeholder then
			return { state = "unavailable", reason = "placeholder" }
		end
		local ok, info = pcall(platform.productInfo, entry.kind, entry.id, player)
		if
			not ok
			or type(info) ~= "table"
			or type(info.name) ~= "string"
			or type(info.formattedPrice) ~= "string"
			or info.available ~= true
		then
			return { state = "unavailable", reason = "platform_info_unavailable" }
		end
		local purchasable, why = describe(entry)
		return {
			state = if purchasable then "available" else "preview_only",
			reason = why,
			name = info.name,
			price = info.formattedPrice,
			purchasable = purchasable,
		}
	end
	function self:entitlement(key: string, player: any): Entitlement
		local entry = approved[key]
		if not entry or entry.kind == "developer_product" then
			return { state = "unknown", reason = "receipt_ledger_required" }
		end
		if entry.placeholder then
			return { state = "unknown", reason = "placeholder" }
		end
		local ok, owned = pcall(platform.entitlement, entry.kind, entry.id, player)
		if not ok or type(owned) ~= "boolean" then
			return { state = "unknown", reason = "platform_unavailable" }
		end
		-- Subscriptions are rechecked, never stored as permanent entitlements.
		return { state = if owned then "active" else "inactive" }
	end
	return self
end

function Catalog.new(universeId: number, entries: { [string]: any }, platform: any)
	assert(type(universeId) == "number" and universeId > 0, "explicit universe required")
	local approved = {}
	for key, entry in entries do
		assert(type(key) == "string" and #key > 0, "stable key required")
		assert(entry.universeId == universeId, "cross-universe entry")
		assert(
			entry.kind == "pass" or entry.kind == "developer_product" or entry.kind == "subscription",
			"unsupported kind"
		)
		assert(
			entry.ownershipVerified == true and entry.enabled == false,
			"setup entries must be verified and disabled"
		)
		local id = entryId(entry)
		assert(
			(type(id) == "number" and id > 0 and id % 1 == 0)
				or (entry.kind == "subscription" and type(id) == "string" and id:match("^EXP%-")),
			"missing id"
		)
		local copy = table.clone(entry)
		copy.id, copy.productId = id, nil
		approved[key] = copy
	end
	return api(approved, platform, function(): (boolean, string?)
		return false, nil
	end)
end

-- A display/entitlement API over a catalog/1 table. Raises with every Catalog.validate problem.
-- Display states: available (game mode, enabled, owner-verified; purchasable = true),
-- preview_only (reason setup_mode, disabled or ownership_unverified), unavailable (reason
-- unconfigured, placeholder or platform_info_unavailable).
function Catalog.fromCatalog(universeId: number, catalog: any, platform: any)
	assert(
		type(universeId) == "number" and universeId > 0 and universeId % 1 == 0,
		"explicit universe required"
	)
	local problems = CatalogSchema.validate(catalog)
	if #problems > 0 then
		error("CommerceCatalog.fromCatalog: " .. table.concat(problems, "; "), 2)
	end
	local mode = catalog.mode
	local approved = {}
	for _, product in catalog.products do
		approved[product.key] = {
			key = product.key,
			kind = LEGACY_NAME[product.kind],
			id = product.id,
			enabled = product.enabled,
			ownershipVerified = product.ownershipVerified,
			placeholder = if product.kind == "subscription"
				then product.id == CatalogSchema.PLACEHOLDER_SUBSCRIPTION_ID
				else product.id == CatalogSchema.PLACEHOLDER_ID,
		}
	end
	return api(approved, platform, function(entry: any): (boolean, string?)
		if mode ~= "game" then
			return false, "setup_mode"
		elseif entry.enabled ~= true then
			return false, "disabled"
		elseif entry.ownershipVerified ~= true then
			return false, "ownership_unverified"
		end
		return true, nil
	end)
end

return Catalog
