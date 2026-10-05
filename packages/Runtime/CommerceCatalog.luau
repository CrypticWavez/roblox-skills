--!strict
-- Read-only display/entitlement boundary; no purchase prompting in this package.
local Catalog = {}
export type Display = { state: string, reason: string?, name: string?, price: string?, purchasable: boolean? }
export type Entitlement = { state: string, reason: string? }

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
		assert(
			(type(entry.id) == "number" and entry.id > 0 and entry.id % 1 == 0)
				or (entry.kind == "subscription" and type(entry.id) == "string" and entry.id:match("^EXP%-")),
			"missing id"
		)
		approved[key] = table.clone(entry)
	end
	local api = {}
	function api:display(key: string, player: any): Display
		local entry = approved[key]
		if not entry then
			return { state = "unavailable", reason = "unconfigured" }
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
		return { state = "preview_only", name = info.name, price = info.formattedPrice, purchasable = false }
	end
	function api:entitlement(key: string, player: any): Entitlement
		local entry = approved[key]
		if not entry or entry.kind == "developer_product" then
			return { state = "unknown", reason = "receipt_ledger_required" }
		end
		local ok, owned = pcall(platform.entitlement, entry.kind, entry.id, player)
		if not ok or type(owned) ~= "boolean" then
			return { state = "unknown", reason = "platform_unavailable" }
		end
		-- Subscriptions are rechecked, never stored as permanent entitlements.
		return { state = if owned then "active" else "inactive" }
	end
	return api
end

return Catalog
