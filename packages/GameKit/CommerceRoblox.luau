--!strict
-- @tier T4
-- CommerceRoblox: MarketplaceService wiring for GameKit/Commerce. T4 because only a live game
-- with real, owner-created products shows real prices, ownership and purchases; agents never
-- prompt or buy (the tools/hooks guards ask or deny on Prompt*Purchase). Lune specs cover the
-- wiring against tests/fakes/FakeMarketplace.
--   fetchInfo(marketplace, enums)          price reads: GetProductInfoAsync(id, InfoType.Product |
--                                          GamePass) and GetSubscriptionProductInfoAsync(id)
--                                          (GetProductInfo is deprecated)
--   priceProvider(marketplace, opts, env)  Commerce.priceProvider over fetchInfo
--   ownershipCheck(marketplace, opts, env) UserOwnsGamePassAsync / GetUserSubscriptionStatusAsync
--                                          with GameKit/Retry
--   ownership(marketplace, opts, env)      Commerce.ownership over ownershipCheck
--   priceLevels(marketplace, userIds)      GetUsersPriceLevelsAsync: call at join, never cache
--   prompt(marketplace, catalog, key, player, ctx)  Commerce.canPrompt, then the Prompt* call
--   bindReceipts(marketplace, process, enums)  BindReceiptHandler(ReceiptType.DeveloperProduct)
--                                          over Commerce.receiptProcessor -> ReceiptDecision
--   platform(marketplace, enums)           the productInfo/entitlement seam the inherited
--                                          Runtime/CommerceCatalog takes
-- enums defaults to env.roblox.Enum (the Enum global in Roblox, @lune/roblox in Lune).
local Catalog = require("./Catalog")
local Commerce = require("./Commerce")
local Retry = require("./Retry")

local CommerceRoblox = {}

-- Ownership retries: 3 tries, 0.5 s base, full jitter (DataStore-like web calls; convention).
CommerceRoblox.RETRY = table.freeze({ attempts = 3, base = 0.5, factor = 2, maxDelay = 4, jitter = "full" })

local function enumsFrom(enums: any, env: any?): any
	local found = enums or (env ~= nil and env.roblox ~= nil and env.roblox.Enum) or nil
	assert(found ~= nil, "CommerceRoblox: pass enums or an env with roblox.Enum")
	return found
end

-- fetch(product) for Commerce.priceProvider: { robux?, text?, forSale } from the marketplace.
-- Raises on engine errors (the provider turns that into "unavailable").
function CommerceRoblox.fetchInfo(
	marketplace: any,
	enums: any
): (product: Catalog.Product) -> Commerce.PriceRead
	assert(marketplace ~= nil, "CommerceRoblox.fetchInfo: MarketplaceService required")
	local Enum = enumsFrom(enums)
	return function(product: Catalog.Product): Commerce.PriceRead
		if product.kind == "subscription" then
			local info = marketplace:GetSubscriptionProductInfoAsync(product.id)
			return {
				text = if type(info.DisplayPrice) == "string" then info.DisplayPrice else nil,
				forSale = info.IsForSale ~= false,
			}
		end
		local infoType = if product.kind == "gamepass" then Enum.InfoType.GamePass else Enum.InfoType.Product
		local info = marketplace:GetProductInfoAsync(product.id, infoType)
		local robux = info.PriceInRobux
		return {
			robux = if type(robux) == "number" then robux else nil,
			-- passes not for sale report IsForSale = false and no price; developer products may
			-- omit IsForSale (UNVERIFIED), so only an explicit false counts
			forSale = info.IsForSale ~= false and robux ~= nil,
		}
	end
end

function CommerceRoblox.priceProvider(marketplace: any, opts: Commerce.PriceOptions?, env: any): any
	return Commerce.priceProvider(CommerceRoblox.fetchInfo(marketplace, enumsFrom(nil, env)), opts, env)
end

-- check(player, product) for Commerce.ownership: raises after the retries run out.
function CommerceRoblox.ownershipCheck(
	marketplace: any,
	opts: { retry: Retry.Options? }?,
	env: any
): (player: any, product: Catalog.Product) -> boolean
	assert(marketplace ~= nil, "CommerceRoblox.ownershipCheck: MarketplaceService required")
	local retry = (opts and opts.retry) or CommerceRoblox.RETRY
	return function(player: any, product: Catalog.Product): boolean
		local ok, result = Retry.run(function(): any
			if product.kind == "gamepass" then
				local owned = marketplace:UserOwnsGamePassAsync(player.UserId, product.id)
				if type(owned) ~= "boolean" then
					error("UserOwnsGamePassAsync returned " .. typeof(owned))
				end
				return owned
			elseif product.kind == "subscription" then
				local status = marketplace:GetUserSubscriptionStatusAsync(player, product.id)
				if type(status) ~= "table" or type(status.IsSubscribed) ~= "boolean" then
					error("GetUserSubscriptionStatusAsync returned no IsSubscribed")
				end
				return status.IsSubscribed
			end
			error("CommerceRoblox: " .. tostring(product.kind) .. " has no ownership")
		end, retry :: any, env)
		if not ok then
			error(result, 0)
		end
		return result
	end
end

function CommerceRoblox.ownership(marketplace: any, opts: { [string]: any }?, env: any): any
	return Commerce.ownership(CommerceRoblox.ownershipCheck(marketplace, opts :: any, env), opts :: any, env)
end

-- The users' price levels for regional-pricing transfer caps (trading, gifting). Yields. Returns
-- (true, levels) or (false, error). Never cached: Roblox asks for a fresh read at join.
function CommerceRoblox.priceLevels(marketplace: any, userIds: { number }): (boolean, any)
	if type(userIds) ~= "table" or #userIds == 0 then
		return false, "userIds must be a non-empty list"
	end
	local ok, result = pcall(function(): any
		return marketplace:GetUsersPriceLevelsAsync(table.clone(userIds))
	end)
	if not ok then
		return false, tostring(result)
	end
	return true, result
end

-- Opens the purchase prompt for key when Commerce.canPrompt allows it. ctx is a
-- Commerce.PromptContext; ctx.isStudio defaults from ctx.place.isStudio. Returns (true) or
-- (false, reason, detail) with Commerce.PROMPT_REASONS or "prompt_failed". The prompt only
-- asks: grants come from the receipt handler (developer products) or ownership re-checks.
function CommerceRoblox.prompt(
	marketplace: any,
	catalog: any,
	key: string,
	player: any,
	ctx: { [string]: any }?
): (boolean, string?, any)
	local context: { [string]: any } = table.clone(ctx or {})
	if context.isStudio == nil and type(context.place) == "table" then
		context.isStudio = context.place.isStudio
	end
	local ok, reason, detail = Commerce.canPrompt(catalog, key, context :: any)
	if not ok then
		return false, reason, detail
	end
	local product = detail :: Catalog.Product
	local method = if product.kind == "gamepass"
		then "PromptGamePassPurchase"
		elseif product.kind == "subscription" then "PromptSubscriptionPurchase"
		else "PromptProductPurchase"
	local called, err = pcall(function()
		marketplace[method](marketplace, player, product.id)
	end)
	if not called then
		return false, "prompt_failed", tostring(err)
	end
	return true, nil, nil
end

-- Binds process (Commerce.receiptProcessor's result) as the developer-product receipt handler.
-- Returns the connection. Bind once per server, on the server; a handler that errors or returns
-- anything but "granted" answers NotProcessedYet, so Roblox retries later.
function CommerceRoblox.bindReceipts(
	marketplace: any,
	process: (receipt: any) -> (string, string?),
	enums: any
): any
	assert(type(process) == "function", "CommerceRoblox.bindReceipts: process must be a function")
	assert(
		marketplace ~= nil and marketplace.BindReceiptHandler ~= nil,
		"CommerceRoblox.bindReceipts: MarketplaceService with BindReceiptHandler required"
	)
	local Enum = enumsFrom(enums)
	return marketplace:BindReceiptHandler(Enum.ReceiptType.DeveloperProduct, function(receipt: any): any
		local ok, status = pcall(process, receipt)
		if ok and status == "granted" then
			return Enum.ReceiptDecision.Processed
		end
		return Enum.ReceiptDecision.NotProcessedYet
	end)
end

-- The seam Runtime/CommerceCatalog.new/fromCatalog take: productInfo(kind, id, player) ->
-- { name, formattedPrice, available } and entitlement(kind, id, player) -> boolean. Kinds may
-- be legacy (pass, developer_product) or catalog/1 names. Both raise on engine errors.
function CommerceRoblox.platform(marketplace: any, enums: any): { [string]: any }
	local Enum = enumsFrom(enums)
	return {
		productInfo = function(kind: string, id: any, _player: any): { [string]: any }
			local normalized = Catalog.normalizeKind(kind)
			if normalized == "subscription" then
				local info = marketplace:GetSubscriptionProductInfoAsync(id)
				return {
					name = info.Name,
					formattedPrice = info.DisplayPrice,
					available = info.IsForSale ~= false and type(info.DisplayPrice) == "string",
				}
			end
			local infoType = if normalized == "gamepass"
				then Enum.InfoType.GamePass
				else Enum.InfoType.Product
			local info = marketplace:GetProductInfoAsync(id, infoType)
			local robux = info.PriceInRobux
			return {
				name = info.Name,
				formattedPrice = if type(robux) == "number" then tostring(robux) else nil,
				available = info.IsForSale ~= false and type(robux) == "number",
			}
		end,
		entitlement = function(kind: string, id: any, player: any): boolean
			local normalized = Catalog.normalizeKind(kind)
			if normalized == "gamepass" then
				return marketplace:UserOwnsGamePassAsync(player.UserId, id) == true
			elseif normalized == "subscription" then
				local status = marketplace:GetUserSubscriptionStatusAsync(player, id)
				return type(status) == "table" and status.IsSubscribed == true
			end
			error("developer products have no entitlement: use the receipt ledger")
		end,
	}
end

return CommerceRoblox
