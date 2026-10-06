--!strict
-- @tier T0
-- Commerce: the rules between a catalog/1 table (GameKit/Catalog) and MarketplaceService, kept
-- pure so every branch runs in Lune. GameKit/CommerceRoblox wires them to the engine.
--   canPrompt(catalog, key, ctx)     may a purchase prompt open? (ok, reason, detail), closed reasons
--   features(product)                the PolicyGate features a product needs before a prompt
--   priceProvider(fetch, opts, env)  provider:price(product) -> PriceInfo for UIs; never yields
--   ownership(check, opts, env)      cached, shared pass and subscription ownership checks
--   grantWriter(writers)             catalog grants -> one PlayerData update function
--   receiptProcessor(opts, env)      developer-product receipts -> PlayerData Session.grantReceipt
-- Rules this module keeps:
--   * Prompts open only in catalog mode "game", for enabled, owner-verified products with real
--     ids, and only when PolicyGate allows what the product needs (subscriptions; products tagged
--     "paid_random_item" need paidRandomItems). Unknown policy is a refusal (fail closed).
--   * Prices are runtime reads (regional pricing and Managed Pricing change them), never data.
--   * Ownership that cannot be checked is "unknown", which callers treat as not owned.
--   * Receipts are granted whether or not the product is still enabled (the player paid), but
--     never in setup mode, never for a product the catalog does not list, and only through the
--     session's grant-once receipt ring, so a re-delivered receipt grants once.
-- Nothing here prompts, grants on its own or spends: those calls live in CommerceRoblox and only
-- run in a live game.
local Catalog = require("./Catalog")
local Check = require("./Check")
local Signal = require("./Signal")

local Commerce = {}

-- The tag a product carries when it sells a random outcome (needs PolicyGate paidRandomItems).
Commerce.RANDOM_TAG = "paid_random_item"
Commerce.PRICE_TTL = 60 -- convention: seconds a fetched price is shown before a re-read
Commerce.PRICE_RETRY = 30 -- convention: seconds before a failed price read is tried again
Commerce.SUBSCRIPTION_TTL = 60 -- convention: seconds a subscription status is trusted
Commerce.NEGATIVE_TTL = 60 -- convention: seconds a "not owned" pass result is trusted
Commerce.UNKNOWN_TTL = 30 -- convention: seconds before a failed ownership check runs again

Commerce.PROMPT_REASONS = table.freeze({
	"invalid_catalog", -- the catalog fails Catalog.validate
	"unknown_product", -- no product with that key
	"setup_mode", -- the catalog is in setup mode: nothing is for sale
	"disabled", -- enabled = false
	"policy_unknown", -- a policy feature is needed and no policy predicate was given
	"policy_denied", -- PolicyGate says no (detail: the feature)
	"already_owned", -- a pass or subscription the player already has
	"studio_subscription", -- subscription prompts are refused in Studio
})

Commerce.RECEIPT_REASONS = table.freeze({
	"invalid_receipt",
	"setup_mode",
	"unknown_product",
	"not_devproduct",
	"player_not_loaded",
	-- plus PlayerData Session.grantReceipt's reasons: invalid_purchase_id, inactive, busy,
	-- update_failed, not_storable, schema, too_large, not_saved, ...
})

export type PromptContext = {
	policy: ((feature: string) -> boolean)?, -- PolicyGate gate:predicate(player)
	owned: boolean?, -- passes and subscriptions: true when the player already has it
	isStudio: boolean?,
}
-- Catalog.PriceInfo plus an optional reason, written out flat so literals check against it.
export type PriceInfo = {
	state: "ok" | "pending" | "unavailable",
	text: string?,
	robux: number?,
	reason: string?,
}
export type PriceRead = { robux: number?, text: string?, forSale: boolean? }
export type PriceOptions = {
	ttl: number?,
	retryAfter: number?,
	format: ((robux: number) -> string)?,
}
export type OwnershipState = "owned" | "not_owned" | "unknown"
export type OwnershipOptions = {
	subscriptionTtl: number?,
	negativeTtl: number?,
	unknownTtl: number?,
	keyOf: ((player: any) -> any)?,
}
export type Writers = {
	currency: ((data: any, currency: string, amount: number, product: Catalog.Product) -> ())?,
	item: ((data: any, item: string, count: number, product: Catalog.Product) -> ())?,
	entitlement: ((data: any, entitlement: string, product: Catalog.Product) -> ())?,
	custom: { [string]: (data: any, grantData: { [string]: any }, product: Catalog.Product) -> () }?,
}
export type ReceiptResult = {
	status: "granted" | "not_processed",
	reason: string?,
	productKey: string?,
	purchaseId: string?,
	playerId: number?,
}

local function isPlaceholder(product: any): boolean
	if product.kind == "subscription" then
		return product.id == Catalog.PLACEHOLDER_SUBSCRIPTION_ID
	end
	return product.id == Catalog.PLACEHOLDER_ID
end
Commerce.isPlaceholder = isPlaceholder

-- Validity of a catalog, cached for frozen tables (Catalog.define returns frozen copies).
local checked: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local function validCatalog(catalog: any): boolean
	if type(catalog) ~= "table" then
		return false
	end
	local known = checked[catalog]
	if known ~= nil then
		return known
	end
	local ok = #Catalog.validate(catalog) == 0
	if table.isfrozen(catalog) then
		checked[catalog] = ok
	end
	return ok
end

-- The PolicyGate features a product needs before it may be prompted, sorted.
function Commerce.features(product: Catalog.Product): { string }
	local out = {}
	if product.tags ~= nil and table.find(product.tags, Commerce.RANDOM_TAG) ~= nil then
		table.insert(out, "paidRandomItems")
	end
	if product.kind == "subscription" then
		table.insert(out, "subscriptions")
	end
	table.sort(out)
	return out
end

-- (true, nil, product) when a purchase prompt for key may open, else (false, reason, detail).
-- Reasons are Commerce.PROMPT_REASONS; detail is the feature for policy_denied. Never yields.
function Commerce.canPrompt(catalog: any, key: string, ctx: PromptContext?): (boolean, string?, any)
	if not validCatalog(catalog) then
		return false, "invalid_catalog", nil
	end
	local product = Catalog.find(catalog, key)
	if product == nil then
		return false, "unknown_product", nil
	end
	if catalog.mode ~= "game" then
		return false, "setup_mode", nil
	end
	if product.enabled ~= true then
		return false, "disabled", nil
	end
	-- Catalog.validate already holds game mode to real ids and owner-verified enabled products.
	local context: PromptContext = ctx or {}
	for _, feature in Commerce.features(product) do
		if context.policy == nil then
			return false, "policy_unknown", feature
		end
		local ok, allowed = pcall(context.policy, feature)
		if not ok or allowed ~= true then
			return false, "policy_denied", feature
		end
	end
	if product.kind ~= "devproduct" and context.owned == true then
		return false, "already_owned", nil
	end
	if product.kind == "subscription" and context.isStudio == true then
		return false, "studio_subscription", nil
	end
	return true, nil, product
end

local function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function positiveOption(value: any, default: number, name: string): number
	if value == nil then
		return default
	end
	assert(Check.finite(value) and value >= 0, name .. " must be a finite number >= 0")
	return value
end

local function unavailable(reason: string): PriceInfo
	return { state = "unavailable", reason = reason }
end

-- A price provider for UIs (docs/runtime-kits.md catalog/1): provider:price(product) returns the
-- cached PriceInfo { state = "ok" | "pending" | "unavailable", text?, robux?, reason? } at once
-- and, when nothing is cached or the cache is stale, starts one fetch(product) on env.spawn.
-- fetch yields and returns { robux?, text?, forSale? } (CommerceRoblox.fetchInfo) or raises.
-- provider.changed fires (productKey, PriceInfo) when a read changes what to show. A failed
-- re-read keeps showing the last good price and retries after retryAfter. Placeholder ids are
-- "unavailable" without a fetch. Under regional pricing prices differ per user, so run the
-- provider where the price is shown (the client) and never send a price to the server to trust.
function Commerce.priceProvider(
	fetch: (product: Catalog.Product) -> PriceRead,
	opts: PriceOptions?,
	env: any
): any
	assert(type(fetch) == "function", "Commerce.priceProvider: fetch must be a function")
	assert(env ~= nil and type(env.spawn) == "function", "Commerce.priceProvider: env with spawn required")
	local options: PriceOptions = opts or {}
	local ttl = positiveOption(options.ttl, Commerce.PRICE_TTL, "ttl")
	local retryAfter = positiveOption(options.retryAfter, Commerce.PRICE_RETRY, "retryAfter")
	local format = options.format or function(robux: number): string
		return tostring(robux)
	end
	local entries: { [string]: any } = {}
	local provider = { changed = Signal.new(env), fetches = 0 }

	local function read(product: Catalog.Product): PriceInfo
		local ok, result = pcall(fetch, product)
		if not ok then
			env.report(string.format("Commerce price read for %s failed: %s", product.key, tostring(result)))
			return unavailable("fetch_failed")
		end
		if type(result) ~= "table" then
			return unavailable("fetch_failed")
		end
		if result.forSale == false then
			return unavailable("not_for_sale")
		end
		local robux = result.robux
		local validRobux = Check.integer(robux) and (robux :: number) >= 0
		local text = result.text
		if type(text) ~= "string" or #text < 1 or #text > 64 then
			text = nil
		end
		if not validRobux and text == nil then
			return unavailable("no_price")
		end
		local textOk, shown = true, text
		if shown == nil then
			textOk, shown = pcall(format, robux :: number)
		end
		if not textOk or type(shown) ~= "string" then
			return unavailable("format_failed")
		end
		return { state = "ok", text = shown, robux = if validRobux then robux else nil }
	end

	local function start(product: Catalog.Product, entry: any)
		entry.loading = true
		provider.fetches += 1
		env.spawn(function()
			local info = read(product)
			if entries[product.key] ~= entry then
				return -- refreshed or replaced while reading
			end
			entry.loading = false
			entry.at = env.clock()
			if info.state ~= "ok" and entry.info.state == "ok" then
				entry.retryOnly = true -- keep the last good price; try again sooner
				return
			end
			entry.retryOnly = info.state ~= "ok"
			if not same(entry.info, info) then
				entry.info = info
				provider.changed:Fire(product.key, table.clone(info))
			end
		end)
	end

	function provider.price(_self: any, product: Catalog.Product): PriceInfo
		if type(product) ~= "table" or not Check.label(product.key) then
			return unavailable("invalid_product")
		end
		if isPlaceholder(product) then
			return unavailable("placeholder")
		end
		local entry = entries[product.key]
		if entry ~= nil and entry.id ~= product.id then
			entry = nil
		end
		if entry == nil then
			entry = { id = product.id, info = { state = "pending" }, at = -math.huge, loading = false }
			entries[product.key] = entry
		end
		local age = env.clock() - entry.at
		if not entry.loading and age >= (if entry.retryOnly then retryAfter else ttl) then
			start(product, entry)
		end
		return table.clone(entry.info)
	end

	-- Forgets cached prices (one product, or all) so the next price() reads again.
	function provider.refresh(_self: any, product: Catalog.Product?)
		if product == nil then
			table.clear(entries)
		else
			entries[product.key] = nil
		end
	end

	return provider
end

local function ownable(product: any): (boolean, string?)
	if type(product) ~= "table" or not Check.label(product.key) then
		return false, "invalid_product"
	end
	if product.kind == "devproduct" then
		return false, "not_ownable" -- consumables live in the receipt ledger or player data
	end
	if product.kind ~= "gamepass" and product.kind ~= "subscription" then
		return false, "invalid_product"
	end
	if isPlaceholder(product) then
		return false, "placeholder"
	end
	return true, nil
end

-- A cache of pass and subscription ownership. check(player, product) yields and returns a
-- boolean or raises (CommerceRoblox.ownershipCheck: UserOwnsGamePassAsync,
-- GetUserSubscriptionStatusAsync, with retries). Methods:
--   owns(player, product) -> (state, reason?)  yields; concurrent calls share one check
--   peek(player, product) -> (state, reason?)  the cached answer; never yields
--   markOwned(player, product)                 after a confirmed pass purchase on the server
--   invalidate(player, product?)               re-check next time (subscription status change)
--   forget(player)                             on leave
--   changed                                    Signal(player, productKey, state)
-- States: owned, not_owned, unknown (reasons not_checked, check_failed, not_ownable,
-- placeholder, invalid_product). Unknown is not owned: benefits stay off until a check works.
-- Owned passes stay cached for the session; subscriptions are re-checked after subscriptionTtl
-- and never stored as permanent; "not owned" is re-checked after negativeTtl.
function Commerce.ownership(
	check: (player: any, product: Catalog.Product) -> boolean,
	opts: OwnershipOptions?,
	env: any
): any
	assert(type(check) == "function", "Commerce.ownership: check must be a function")
	assert(env ~= nil and type(env.clock) == "function", "Commerce.ownership: env required")
	local options: OwnershipOptions = opts or {}
	local subscriptionTtl =
		positiveOption(options.subscriptionTtl, Commerce.SUBSCRIPTION_TTL, "subscriptionTtl")
	local negativeTtl = positiveOption(options.negativeTtl, Commerce.NEGATIVE_TTL, "negativeTtl")
	local unknownTtl = positiveOption(options.unknownTtl, Commerce.UNKNOWN_TTL, "unknownTtl")
	local keyOf = options.keyOf or function(player: any): any
		return player.UserId
	end
	local players: { [any]: { [string]: any } } = {}
	local cache = { changed = Signal.new(env), checks = 0 }

	local function slot(player: any, create: boolean): { [string]: any }?
		local key = keyOf(player)
		local entries = players[key]
		if entries == nil and create then
			entries = {}
			players[key] = entries
		end
		return entries
	end

	local function fresh(entry: any, product: Catalog.Product): boolean
		if entry == nil or entry.state == nil then
			return false
		end
		local age = env.clock() - entry.at
		if entry.state == "owned" then
			return product.kind == "gamepass" or age < subscriptionTtl
		elseif entry.state == "not_owned" then
			return age < negativeTtl
		end
		return age < unknownTtl
	end

	local function settle(
		player: any,
		product: Catalog.Product,
		entry: any,
		state: OwnershipState,
		reason: string?
	)
		local previous = entry.state
		entry.state, entry.reason, entry.at, entry.loading = state, reason, env.clock(), false
		local waiters = entry.waiters
		entry.waiters = {}
		if previous ~= state then
			cache.changed:Fire(player, product.key, state)
		end
		for _, thread in waiters do
			env.spawn(thread)
		end
	end

	function cache.peek(_self: any, player: any, product: Catalog.Product): (OwnershipState, string?)
		local ok, why = ownable(product)
		if not ok then
			return "unknown", why
		end
		local entries = slot(player, false)
		local entry = entries and entries[product.key]
		if entry == nil or entry.state == nil then
			return "unknown", "not_checked"
		end
		if entry.state == "owned" and product.kind == "subscription" and not fresh(entry, product) then
			return "unknown", "not_checked" -- a lapsed subscription answer is not trusted
		end
		return entry.state, entry.reason
	end

	function cache.owns(_self: any, player: any, product: Catalog.Product): (OwnershipState, string?)
		local ok, why = ownable(product)
		if not ok then
			return "unknown", why
		end
		local entries = slot(player, true) :: { [string]: any }
		local entry = entries[product.key]
		if entry ~= nil and entry.id ~= product.id then
			entry = nil
		end
		if entry == nil then
			entry = { id = product.id, waiters = {}, loading = false, at = -math.huge }
			entries[product.key] = entry
		end
		if fresh(entry, product) and not entry.loading then
			return entry.state, entry.reason
		end
		if entry.loading then
			table.insert(entry.waiters, coroutine.running())
			coroutine.yield()
			if entry.state == nil then
				return "unknown", "check_failed"
			end
			return entry.state, entry.reason
		end
		entry.loading = true
		cache.checks += 1
		local callOk, owned = pcall(check, player, product)
		local state: OwnershipState, reason: string? = "unknown", "check_failed"
		if callOk and type(owned) == "boolean" then
			state, reason = if owned then "owned" else "not_owned", nil
		elseif env.report then
			env.report(
				string.format("Commerce ownership check for %s failed: %s", product.key, tostring(owned))
			)
		end
		if entries ~= slot(player, false) or entries[product.key] ~= entry then
			-- forgotten, invalidated or marked owned while checking: answer, cache nothing
			entry.state, entry.reason, entry.loading = state, reason, false
			local waiters = entry.waiters
			entry.waiters = {}
			for _, thread in waiters do
				env.spawn(thread)
			end
			return state, reason
		end
		settle(player, product, entry, state, reason)
		return state, reason
	end

	-- Records ownership the server has confirmed (PromptGamePassPurchaseFinished with
	-- wasPurchased on the server, or a subscription purchase); replaces any check in flight.
	function cache.markOwned(_self: any, player: any, product: Catalog.Product)
		if not ownable(product) then
			return
		end
		local entries = slot(player, true) :: { [string]: any }
		local previous = entries[product.key]
		local entry = {
			id = product.id,
			waiters = {},
			loading = false,
			at = -math.huge,
			-- the last answer, so changed fires only when the state really changes
			state = if previous ~= nil and previous.id == product.id then previous.state else nil,
		}
		entries[product.key] = entry
		settle(player, product, entry, "owned", nil)
	end

	-- Drops cached answers (one product, or all for the player); checks in flight are not cached.
	function cache.invalidate(_self: any, player: any, product: Catalog.Product?)
		local entries = slot(player, false)
		if entries == nil then
			return
		end
		if product == nil then
			table.clear(entries)
		else
			entries[product.key] = nil
		end
	end

	function cache.forget(_self: any, player: any)
		players[keyOf(player)] = nil
	end

	return cache
end

-- A PlayerData update function that applies a product's catalog grants through writers, one
-- per grant type (and custom handlers by name). The data layout stays the game's choice: the
-- writers decide where currency, items and entitlements live. A grant with no writer raises,
-- which fails the update, so the receipt is not processed and Roblox retries it later.
function Commerce.grantWriter(writers: Writers): (data: any, product: Catalog.Product) -> ()
	assert(type(writers) == "table", "Commerce.grantWriter: writers must be a table")
	for _, name in { "currency", "item", "entitlement" } do
		local writer = (writers :: any)[name]
		assert(
			writer == nil or type(writer) == "function",
			"Commerce.grantWriter: " .. name .. " must be a function"
		)
	end
	assert(
		writers.custom == nil or type(writers.custom) == "table",
		"Commerce.grantWriter: custom must map handler names to functions"
	)
	local custom: { [string]: (data: any, grantData: { [string]: any }, product: Catalog.Product) -> () } = writers.custom
		or {}
	for name, handler in custom do
		assert(
			Check.label(name) and type(handler) == "function",
			"Commerce.grantWriter: custom must map handler names to functions"
		)
	end
	return function(data: any, product: Catalog.Product)
		for index, grant in product.grants do
			if grant.type == "currency" then
				local writer = writers.currency
				if writer == nil then
					error(string.format("%s grant %d: no currency writer", product.key, index), 0)
				end
				writer(data, grant.currency :: string, grant.amount :: number, product)
			elseif grant.type == "item" then
				local writer = writers.item
				if writer == nil then
					error(string.format("%s grant %d: no item writer", product.key, index), 0)
				end
				writer(data, grant.item :: string, grant.count :: number, product)
			elseif grant.type == "entitlement" then
				local writer = writers.entitlement
				if writer == nil then
					error(string.format("%s grant %d: no entitlement writer", product.key, index), 0)
				end
				writer(data, grant.entitlement :: string, product)
			else
				local handler = writers.custom and writers.custom[grant.handler :: string]
				if handler == nil then
					error(
						string.format(
							"%s grant %d: no custom handler %s",
							product.key,
							index,
							tostring(grant.handler)
						),
						0
					)
				end
				handler(data, Check.copy(grant.data or {}), product)
			end
		end
	end
end

local MAX_INTEGER = 9007199254740991

local function validReceipt(receipt: any): boolean
	return type(receipt) == "table"
		and Check.integer(receipt.PlayerId)
		and receipt.PlayerId > 0
		and receipt.PlayerId <= MAX_INTEGER
		and Check.integer(receipt.ProductId)
		and receipt.ProductId > 0
		and type(receipt.PurchaseId) == "string"
		and #receipt.PurchaseId > 0
		and #receipt.PurchaseId <= 128
end

-- A developer-product receipt processor over PlayerData sessions (the profile-backed path; the
-- separate-key path is Runtime/ReceiptLedger). process(receipt) yields until the grant is
-- durable and returns (status, reason): "granted" means return ReceiptDecision.Processed;
-- "not_processed" means NotProcessedYet, and Roblox delivers the receipt again later (for
-- example when the player rejoins). Options:
--   catalog     a catalog/1 table (receipts in setup mode are refused)
--   sessionFor  (playerId) -> PlayerData session or nil (PlayerDataRoblox binding:sessionFor)
--   grant       (data, product, receipt) -> () mutates the draft (Commerce.grantWriter's result
--               fits: grant = function(data, product) write(data, product) end)
--   onResult    optional (ReceiptResult) -> () after each receipt, for telemetry; errors ignored
function Commerce.receiptProcessor(
	options: {
		catalog: any,
		sessionFor: (playerId: number) -> any,
		grant: (data: any, product: Catalog.Product, receipt: any) -> (),
		onResult: ((result: ReceiptResult) -> ())?,
	},
	env: any?
): (receipt: any) -> (string, string?)
	assert(type(options) == "table", "Commerce.receiptProcessor: options required")
	local problems = Catalog.validate(options.catalog)
	assert(#problems == 0, "Commerce.receiptProcessor: invalid catalog: " .. table.concat(problems, "; "))
	assert(type(options.sessionFor) == "function", "Commerce.receiptProcessor: sessionFor must be a function")
	assert(type(options.grant) == "function", "Commerce.receiptProcessor: grant must be a function")
	local catalog = Check.freeze(Check.copy(options.catalog))

	local function finish(receipt: any, status: string, reason: string?, product: any): (string, string?)
		if options.onResult ~= nil then
			local ok: boolean, err: any = pcall(
				options.onResult,
				{
					status = status,
					reason = reason,
					productKey = product and product.key,
					purchaseId = if type(receipt) == "table" then receipt.PurchaseId else nil,
					playerId = if type(receipt) == "table" then receipt.PlayerId else nil,
				} :: any
			)
			if not ok and env ~= nil and env.report then
				env.report("Commerce receipt onResult failed: " .. tostring(err))
			end
		end
		return status, reason
	end

	return function(receipt: any): (string, string?)
		if not validReceipt(receipt) then
			return finish(receipt, "not_processed", "invalid_receipt", nil)
		end
		if catalog.mode ~= "game" then
			return finish(receipt, "not_processed", "setup_mode", nil)
		end
		local product = Catalog.byId(catalog, receipt.ProductId)
		if product == nil then
			return finish(receipt, "not_processed", "unknown_product", nil)
		end
		if product.kind ~= "devproduct" then
			return finish(receipt, "not_processed", "not_devproduct", product)
		end
		local ok, session = pcall(options.sessionFor, receipt.PlayerId)
		if not ok or session == nil then
			return finish(receipt, "not_processed", "player_not_loaded", product)
		end
		local status, reason = session:grantReceipt(receipt.PurchaseId, function(data: any): any
			options.grant(data, product, receipt)
			return nil
		end)
		return finish(receipt, status, reason, product)
	end
end

return Commerce
