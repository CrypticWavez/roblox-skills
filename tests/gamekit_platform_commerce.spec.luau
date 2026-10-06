--!strict
-- G1 commerce: GameKit/Commerce (prompt gating, price provider, ownership cache, grant writer,
-- receipt processor over PlayerData), GameKit/CommerceRoblox (MarketplaceService wiring) and the
-- inherited Runtime commerce modules (CommerceCatalog catalog/1 support, ReceiptLedger
-- retention, RobloxReceiptAdapter.bind) against tests/fakes/FakeMarketplace. Every id here is a
-- test fixture: no real product, prompt or purchase is involved.
local roblox = require("@lune/roblox")
local Catalog = require("../packages/GameKit/Catalog")
local Commerce = require("../packages/GameKit/Commerce")
local CommerceRoblox = require("../packages/GameKit/CommerceRoblox")
local FakeEnv = require("./fakes/FakeEnv")
local FakeMarketplace = require("./fakes/FakeMarketplace")
local FakePolicy = require("./fakes/FakePolicy")
local LegacyCatalog = require("../packages/Runtime/CommerceCatalog")
local PlayerData = require("../packages/GameKit/PlayerData")
local PolicyGate = require("../packages/GameKit/PolicyGate")
local ReceiptAdapter = require("../packages/Runtime/RobloxReceiptAdapter")
local ReceiptLedger = require("../packages/Runtime/ReceiptLedger")

local Enum = roblox.Enum

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

local function run(env: any, fn: () -> ...any): ...any
	local out = nil
	env.spawn(function()
		out = table.pack(fn())
	end)
	for _ = 1, 3000 do
		if out ~= nil then
			break
		end
		env:advance(0.1)
		env:flush()
	end
	assert(out ~= nil, "did not finish: " .. table.concat(env.errors, "\n"))
	return table.unpack(out, 1, out.n)
end

local function newEnv(): any
	return FakeEnv.new({ roblox = roblox })
end

local function player(userId: number): any
	return { UserId = userId, Name = "fixture_" .. tostring(userId) }
end

local function product(key: string, kind: string, id: any, extra: { [string]: any }?): any
	local out: { [string]: any } = {
		key = key,
		kind = kind,
		id = id,
		enabled = true,
		ownershipVerified = true,
		grants = { { type = "currency", currency = "currency_a", amount = 100 } },
		display = { nameKey = "shop." .. key .. ".name" },
	}
	if kind ~= "devproduct" then
		out.grants = { { type = "entitlement", entitlement = key } }
	end
	for k, v in extra or {} do
		out[k] = v
	end
	return out
end

-- A game-mode catalog with fixture ids.
local function gameCatalog(): any
	return Catalog.define({
		schema = "catalog/1",
		mode = "game",
		products = {
			product("currency_pack_a", "devproduct", 1001),
			product("bundle_b", "devproduct", 1002, {
				grants = {
					{ type = "currency", currency = "currency_a", amount = 5 },
					{ type = "item", item = "item_a", count = 2 },
					{ type = "entitlement", entitlement = "badge_a" },
					{ type = "custom", handler = "unlock_slot", data = { slot = 3 } },
				},
			}),
			product("random_box_a", "devproduct", 1003, { tags = { Commerce.RANDOM_TAG } }),
			product("retired_pack", "devproduct", 1004, { enabled = false }),
			product("pass_a", "gamepass", 2001),
			product("pass_off", "gamepass", 2002, { enabled = false }),
			product("sub_a", "subscription", "EXP-1001"),
		},
	})
end

local function setupCatalog(): any
	return Catalog.define({
		schema = "catalog/1",
		mode = "setup",
		products = {
			product("currency_pack_a", "devproduct", 0, { enabled = false, ownershipVerified = false }),
			product("pass_a", "gamepass", 0, { enabled = false, ownershipVerified = false }),
			product("sub_a", "subscription", "EXP-0", { enabled = false, ownershipVerified = false }),
		},
	})
end

local function allow(feature: string): boolean
	return true
end

-- ---------------------------------------------------------------- prompt gating

test("setup mode refuses every prompt and keeps products disabled", function(t)
	local catalog = setupCatalog()
	for _, key in { "currency_pack_a", "pass_a", "sub_a" } do
		t.eq({ Commerce.canPrompt(catalog, key, { policy = allow }) }, { false, "setup_mode" })
	end
	-- an enabled product cannot be declared in setup mode at all
	local enabled = product("currency_pack_a", "devproduct", 0, { ownershipVerified = false })
	local problems =
		table.concat(Catalog.validate({ schema = "catalog/1", mode = "setup", products = { enabled } }), "\n")
	t.ok(has(problems, "setup mode keeps every product disabled"), problems)
	t.eq(
		LegacyCatalog.validateEntry(
			{ kind = "pass", id = 0, enabled = true, ownershipVerified = false },
			"setup"
		),
		{
			"setup mode keeps every product disabled (enabled = false)",
		}
	)
	-- the adapter never reaches the marketplace in setup mode
	local market = FakeMarketplace.new()
	t.eq(
		{ CommerceRoblox.prompt(market, catalog, "pass_a", player(1), { policy = allow }) },
		{ false, "setup_mode" }
	)
	t.eq(#market.prompts, 0)
end)

test("canPrompt refuses unknown, disabled, owned and invalid-catalog cases", function(t)
	local catalog = gameCatalog()
	t.eq(
		{ Commerce.canPrompt(catalog, "currency_pack_a", {}) },
		{ true, nil, Catalog.find(catalog, "currency_pack_a") }
	)
	t.eq({ Commerce.canPrompt(catalog, "missing_key") }, { false, "unknown_product" })
	t.eq({ Commerce.canPrompt(catalog, "retired_pack") }, { false, "disabled" })
	t.eq({ Commerce.canPrompt(catalog, "pass_off") }, { false, "disabled" })
	t.eq({ Commerce.canPrompt(catalog, "pass_a", { owned = true }) }, { false, "already_owned" })
	t.eq(select(1, Commerce.canPrompt(catalog, "pass_a", { owned = false })), true)
	t.eq(
		select(1, Commerce.canPrompt(catalog, "currency_pack_a", { owned = true })),
		true,
		"consumables repeat"
	)
	-- a table that is not a valid catalog/1 is refused, and an unfrozen one is re-checked each call
	t.eq({ Commerce.canPrompt({ schema = "catalog/1" }, "pass_a") }, { false, "invalid_catalog" })
	t.eq({ Commerce.canPrompt(nil, "pass_a") }, { false, "invalid_catalog" })
	local loose: any = {
		schema = "catalog/1",
		mode = "game",
		products = { product("pass_a", "gamepass", 2001) },
	}
	t.eq(select(1, Commerce.canPrompt(loose, "pass_a")), true)
	loose.products[1].enabled = "yes"
	t.eq({ Commerce.canPrompt(loose, "pass_a") }, { false, "invalid_catalog" })
end)

test("policy gating fails closed for subscriptions and paid random items", function(t)
	local catalog = gameCatalog()
	t.eq(Commerce.features(Catalog.find(catalog, "random_box_a") :: any), { "paidRandomItems" })
	t.eq(Commerce.features(Catalog.find(catalog, "sub_a") :: any), { "subscriptions" })
	t.eq(Commerce.features(Catalog.find(catalog, "pass_a") :: any), {})
	t.eq({ Commerce.canPrompt(catalog, "sub_a") }, { false, "policy_unknown", "subscriptions" })
	t.eq({ Commerce.canPrompt(catalog, "random_box_a", {}) }, { false, "policy_unknown", "paidRandomItems" })
	local function deny(feature: string): boolean
		return feature ~= "paidRandomItems"
	end
	t.eq({ Commerce.canPrompt(catalog, "random_box_a", { policy = deny }) }, {
		false,
		"policy_denied",
		"paidRandomItems",
	})
	local function broken(_feature: string): boolean
		error("policy exploded")
	end
	t.eq(
		{ Commerce.canPrompt(catalog, "sub_a", { policy = broken }) },
		{ false, "policy_denied", "subscriptions" }
	)
	local function maybe(_feature: string): any
		return "yes"
	end
	t.eq(
		{ Commerce.canPrompt(catalog, "sub_a", { policy = maybe }) },
		{ false, "policy_denied", "subscriptions" }
	)
	-- wired through PolicyGate and the restricted region preset: both refused; permissive: both ok
	local env = newEnv()
	for preset, expected in { restricted = false, permissive = true } do
		local service = FakePolicy.new({ preset = preset })
		local gate = PolicyGate.new({
			fetch = function(p: any): any
				return service:GetPolicyInfoForPlayerAsync(p)
			end,
		}, env)
		local who = player(5)
		run(env, function()
			return gate:load(who)
		end)
		-- isStudio = false: a known live place (an unknown place refuses subscriptions, below)
		local live = { policy = gate:predicate(who), isStudio = false }
		for _, key in { "sub_a", "random_box_a" } do
			t.eq(select(1, Commerce.canPrompt(catalog, key, live)), expected, preset .. key)
		end
	end
	-- subscriptions are never prompted in Studio
	t.eq({ Commerce.canPrompt(catalog, "sub_a", { policy = allow, isStudio = true }) }, {
		false,
		"studio_subscription",
	})
end)

test("a subscription prompt fails closed when the place is unknown", function(t)
	local catalog = gameCatalog()
	-- neither isStudio nor a place: treated as Studio, so the subscription is refused
	t.eq({ Commerce.canPrompt(catalog, "sub_a", { policy = allow }) }, { false, "studio_subscription" })
	t.eq(
		{ Commerce.canPrompt(catalog, "sub_a", { policy = allow, isStudio = "no" :: any }) },
		{ false, "studio_subscription" },
		"only a boolean false counts as live"
	)
	t.eq(select(1, Commerce.canPrompt(catalog, "sub_a", { policy = allow, isStudio = false })), true)
	-- other kinds do not depend on the place
	t.eq(select(1, Commerce.canPrompt(catalog, "pass_a", { policy = allow })), true)
	t.eq(select(1, Commerce.canPrompt(catalog, "currency_pack_a", { policy = allow })), true)

	-- the adapter: no ctx.place and no env never reaches PromptSubscriptionPurchase
	local market = FakeMarketplace.new()
	local who = player(9)
	t.eq({ CommerceRoblox.prompt(market, catalog, "sub_a", who, { policy = allow }) }, {
		false,
		"studio_subscription",
	})
	t.eq({ CommerceRoblox.prompt(market, catalog, "sub_a", who, { policy = allow }, {}) }, {
		false,
		"studio_subscription",
	})
	-- env.place supplies the default (FakeEnv defaults to a Studio diagnostic place)
	t.eq({ CommerceRoblox.prompt(market, catalog, "sub_a", who, { policy = allow }, newEnv()) }, {
		false,
		"studio_subscription",
	})
	t.eq(#market.prompts, 0)
	local liveEnv = FakeEnv.new({ roblox = roblox, place = { isStudio = false, gameId = 1, placeId = 1 } })
	t.eq({ CommerceRoblox.prompt(market, catalog, "sub_a", who, { policy = allow }, liveEnv) }, { true })
	t.eq(market.prompts, { { method = "PromptSubscriptionPurchase", userId = 9, id = "EXP-1001" } })
	-- an explicit ctx.isStudio or ctx.place wins over env.place
	local studioFlag = { policy = allow, isStudio = true }
	local studioPlace = { policy = allow, place = { isStudio = true, gameId = 0, placeId = 0 } }
	for _, ctx in { studioFlag, studioPlace } do
		t.eq({ CommerceRoblox.prompt(market, catalog, "sub_a", who, ctx, liveEnv) }, {
			false,
			"studio_subscription",
		})
	end
	t.eq(#market.prompts, 1)
end)

test("CommerceRoblox.prompt opens the matching prompt only when allowed", function(t)
	local catalog = gameCatalog()
	local market = FakeMarketplace.new()
	local who = player(7)
	local live = { place = { isStudio = false, gameId = 1, placeId = 1 }, policy = allow }
	t.eq({ CommerceRoblox.prompt(market, catalog, "currency_pack_a", who, live) }, { true })
	t.eq({ CommerceRoblox.prompt(market, catalog, "pass_a", who, live) }, { true })
	t.eq({ CommerceRoblox.prompt(market, catalog, "sub_a", who, live) }, { true })
	t.eq(market.prompts, {
		{ method = "PromptProductPurchase", userId = 7, id = 1001 },
		{ method = "PromptGamePassPurchase", userId = 7, id = 2001 },
		{ method = "PromptSubscriptionPurchase", userId = 7, id = "EXP-1001" },
	})
	local studio = { place = { isStudio = true, gameId = 0, placeId = 0 }, policy = allow }
	t.eq({ CommerceRoblox.prompt(market, catalog, "sub_a", who, studio) }, { false, "studio_subscription" })
	t.eq({ CommerceRoblox.prompt(market, catalog, "pass_a", who, { policy = allow, owned = true }) }, {
		false,
		"already_owned",
	})
	market:fail("PromptProductPurchase", 1, "prompt refused")
	local ok, reason, detail = CommerceRoblox.prompt(market, catalog, "currency_pack_a", who, live)
	t.eq({ ok, reason }, { false, "prompt_failed" })
	t.ok(has(detail, "prompt refused"))
	t.eq(#market.prompts, 3)
end)

-- ---------------------------------------------------------------- prices

test("the price provider reads once, caches, shares a fetch and never yields", function(t)
	local env = newEnv()
	local catalog = gameCatalog()
	local market = FakeMarketplace.new({
		products = { [1001] = { Name = "n", PriceInRobux = 25 } },
		passes = { [2001] = { Name = "n", PriceInRobux = 150, IsForSale = true } },
		subscriptions = { ["EXP-1001"] = { Name = "n", DisplayPrice = "$4.99", IsForSale = true } },
		env = env,
		latency = 0.5,
	})
	local provider = CommerceRoblox.priceProvider(market, {
		format = function(robux: number): string
			return "R" .. tostring(robux)
		end,
	}, env)
	local changes = {}
	provider.changed:Connect(function(key: string, info: any)
		table.insert(changes, { key, info.state, info.text })
	end)
	local pack = Catalog.find(catalog, "currency_pack_a") :: any
	t.eq(provider:price(pack), { state = "pending" })
	t.eq(provider:price(pack), { state = "pending" }, "a second call shares the fetch")
	t.eq(market.calls.GetProductInfoAsync, 1)
	env:advance(0.5)
	env:flush()
	t.eq(provider:price(pack), { state = "ok", text = "R25", robux = 25 })
	t.eq(changes, { { "currency_pack_a", "ok", "R25" } })
	-- within the TTL the cache answers
	env:advance(Commerce.PRICE_TTL - 1)
	t.eq(provider:price(pack).text, "R25")
	t.eq(market.calls.GetProductInfoAsync, 1)
	-- after the TTL the stale price is shown while one re-read runs
	env:advance(1)
	market.products[1001].PriceInRobux = 30
	t.eq(provider:price(pack).text, "R25")
	env:advance(0.5)
	env:flush()
	t.eq(provider:price(pack).text, "R30")
	t.eq(market.calls.GetProductInfoAsync, 2)
	-- passes and subscriptions
	local pass = Catalog.find(catalog, "pass_a") :: any
	local sub = Catalog.find(catalog, "sub_a") :: any
	provider:price(pass)
	provider:price(sub)
	env:advance(0.5)
	env:flush()
	t.eq(provider:price(pass), { state = "ok", text = "R150", robux = 150 })
	t.eq(provider:price(sub), { state = "ok", text = "$4.99" })
	-- refresh forgets: the next call is pending again
	provider:refresh(pass)
	t.eq(provider:price(pass).state, "pending")
	provider:refresh()
	t.eq(provider:price(sub).state, "pending")
	-- placeholders and junk never fetch
	local before = market.calls.GetProductInfoAsync
	t.eq(provider:price(Catalog.find(setupCatalog(), "currency_pack_a") :: any), {
		state = "unavailable",
		reason = "placeholder",
	})
	t.eq(provider:price(nil :: any).reason, "invalid_product")
	t.eq(market.calls.GetProductInfoAsync, before)
end)

test("the price provider fails closed and retries after a failed read", function(t)
	local env = newEnv()
	local catalog = gameCatalog()
	local market = FakeMarketplace.new({
		products = { [1001] = { Name = "n", PriceInRobux = 25 } },
		passes = { [2001] = { Name = "n", IsForSale = false } },
		subscriptions = { ["EXP-1001"] = { Name = "n", DisplayPrice = "$4.99", IsForSale = false } },
	})
	local provider = CommerceRoblox.priceProvider(market, nil, env)
	t.eq(
		provider:price(Catalog.find(catalog, "sub_a") :: any),
		{ state = "unavailable", reason = "not_for_sale" }
	)
	local pack = Catalog.find(catalog, "currency_pack_a") :: any
	market:fail("GetProductInfoAsync", 1)
	provider:price(pack)
	t.eq(provider:price(pack), { state = "unavailable", reason = "fetch_failed" })
	t.ok(has(table.concat(env.reports, "\n"), "currency_pack_a failed"))
	env:advance(Commerce.PRICE_RETRY - 1)
	provider:price(pack)
	t.eq(market.calls.GetProductInfoAsync, 1, "no retry before retryAfter")
	env:advance(1)
	t.eq(provider:price(pack), { state = "ok", text = "25", robux = 25 })
	-- a failed re-read keeps the last good price
	env:advance(Commerce.PRICE_TTL)
	market:fail("GetProductInfoAsync", 1)
	t.eq(provider:price(pack).text, "25")
	t.eq(provider:price(pack).text, "25")
	env:advance(Commerce.PRICE_RETRY)
	market.products[1001].PriceInRobux = 40
	t.eq(provider:price(pack).text, "40")
	-- not for sale, junk prices and a broken formatter are unavailable
	t.eq(
		provider:price(Catalog.find(catalog, "pass_a") :: any),
		{ state = "unavailable", reason = "not_for_sale" }
	)
	local junk = Commerce.priceProvider(function(): any
		return { robux = 0 / 0 }
	end, nil, env)
	t.eq(junk:price(pack), { state = "unavailable", reason = "no_price" })
	local negative = Commerce.priceProvider(function(): any
		return { robux = -5 }
	end, nil, env)
	t.eq(negative:price(pack).reason, "no_price")
	local badFormat = Commerce.priceProvider(function(): any
		return { robux = 5 }
	end, {
		format = function(): string
			error("no locale")
		end,
	}, env)
	t.eq(badFormat:price(pack).reason, "format_failed")
	local notTable = Commerce.priceProvider(function(): any
		return "5"
	end, nil, env)
	t.eq(notTable:price(pack).reason, "fetch_failed")
	t.ok(not pcall(Commerce.priceProvider, nil :: any, nil, env))
	t.ok(not pcall(Commerce.priceProvider, notTable :: any, { ttl = -1 }, env))
	-- an id change refetches instead of showing another product's price
	local renamed = table.clone(pack)
	renamed.id = 1099
	market.products[1099] = { Name = "n", PriceInRobux = 7 }
	t.eq(provider:price(renamed).text, "7")
	-- a read that lands after its entry was replaced is dropped (no stale price, no event)
	local slowEnv = newEnv()
	local slowMarket = FakeMarketplace.new({
		products = { [1001] = { Name = "n", PriceInRobux = 25 }, [1099] = { Name = "n", PriceInRobux = 7 } },
		env = slowEnv,
		latency = 1,
	})
	local slow = CommerceRoblox.priceProvider(slowMarket, nil, slowEnv)
	local events = {}
	slow.changed:Connect(function(key: string, info: any)
		table.insert(events, { key, info.text })
	end)
	slow:price(pack)
	slowEnv:advance(0.5)
	slow:price(renamed)
	slowEnv:advance(0.5)
	slowEnv:flush()
	t.eq(slow:price(renamed).state, "pending", "the old id's read is not shown for the new id")
	slowEnv:advance(0.5)
	slowEnv:flush()
	t.eq(slow:price(renamed).text, "7")
	t.eq(events, { { "currency_pack_a", "7" } })
end)

-- ---------------------------------------------------------------- ownership

test("ownership caches passes, re-checks subscriptions and shares checks", function(t)
	local env = newEnv()
	local catalog = gameCatalog()
	local market = FakeMarketplace.new({
		owned = { [1] = { [2001] = true } },
		subscribed = { [1] = { ["EXP-1001"] = true } },
		env = env,
		latency = 0.2,
	})
	local cache = CommerceRoblox.ownership(market, nil, env)
	local changes = {}
	cache.changed:Connect(function(p: any, key: string, state: string)
		table.insert(changes, { p.UserId, key, state })
	end)
	local pass = Catalog.find(catalog, "pass_a") :: any
	local sub = Catalog.find(catalog, "sub_a") :: any
	local one, two = player(1), player(2)
	t.eq({ cache:peek(one, pass) }, { "unknown", "not_checked" })
	-- two concurrent checks for one player share one call
	local results = {}
	for _ = 1, 2 do
		env.spawn(function()
			table.insert(results, { cache:owns(one, pass) })
		end)
	end
	for _ = 1, 10 do
		env:advance(0.1)
		env:flush()
	end
	t.eq(results, { { "owned" }, { "owned" } })
	t.eq(market.calls.UserOwnsGamePassAsync, 1)
	t.eq({ cache:peek(one, pass) }, { "owned" })
	-- an owned pass stays cached for the session
	env:advance(3600)
	t.eq({ run(env, function()
		return cache:owns(one, pass)
	end) }, { "owned" })
	t.eq(market.calls.UserOwnsGamePassAsync, 1)
	-- not owned is re-checked after negativeTtl
	t.eq({ run(env, function()
		return cache:owns(two, pass)
	end) }, { "not_owned" })
	market.owned[2] = { [2001] = true }
	env:advance(Commerce.NEGATIVE_TTL - 1)
	t.eq({ run(env, function()
		return cache:owns(two, pass)
	end) }, { "not_owned" })
	env:advance(1)
	t.eq({ run(env, function()
		return cache:owns(two, pass)
	end) }, { "owned" })
	-- subscriptions are re-checked after their TTL and a lapsed answer is not trusted by peek
	t.eq({ run(env, function()
		return cache:owns(one, sub)
	end) }, { "owned" })
	env:advance(Commerce.SUBSCRIPTION_TTL)
	t.eq(
		{ run(env, function()
			return cache:owns(one, sub)
		end) },
		{ "owned" },
		"a re-check with the same answer fires no change"
	)
	market.subscribed[1]["EXP-1001"] = false
	env:advance(Commerce.SUBSCRIPTION_TTL)
	t.eq({ cache:peek(one, sub) }, { "unknown", "not_checked" })
	t.eq({ run(env, function()
		return cache:owns(one, sub)
	end) }, { "not_owned" })
	t.eq(market.calls.GetUserSubscriptionStatusAsync, 3)
	t.eq(changes, {
		{ 1, "pass_a", "owned" },
		{ 2, "pass_a", "not_owned" },
		{ 2, "pass_a", "owned" },
		{ 1, "sub_a", "owned" },
		{ 1, "sub_a", "not_owned" },
	})
	-- developer products and placeholders have no ownership
	t.eq({ cache:owns(one, Catalog.find(catalog, "currency_pack_a") :: any) }, { "unknown", "not_ownable" })
	t.eq({ cache:peek(one, Catalog.find(setupCatalog(), "pass_a") :: any) }, { "unknown", "placeholder" })
	t.eq({ cache:owns(one, { key = "x", kind = "bundle", id = 3 } :: any) }, { "unknown", "invalid_product" })
end)

test("ownership check failures stay unknown, retry, and markOwned wins a race", function(t)
	local env = newEnv()
	local catalog = gameCatalog()
	local market = FakeMarketplace.new({ owned = { [1] = { [2001] = true } } })
	local cache = CommerceRoblox.ownership(market, nil, env)
	local pass = Catalog.find(catalog, "pass_a") :: any
	local one = player(1)
	-- two transient failures are retried inside one check
	market:fail("UserOwnsGamePassAsync", 2)
	t.eq({ run(env, function()
		return cache:owns(one, pass)
	end) }, { "owned" })
	t.eq(market.calls.UserOwnsGamePassAsync, 3)
	-- retries exhausted: unknown (benefits off), then re-checked after unknownTtl
	cache:forget(one)
	market:fail("UserOwnsGamePassAsync", 3)
	t.eq({ run(env, function()
		return cache:owns(one, pass)
	end) }, { "unknown", "check_failed" })
	t.ok(has(table.concat(env.reports, "\n"), "pass_a failed"))
	local calls = market.calls.UserOwnsGamePassAsync
	t.eq({ run(env, function()
		return cache:owns(one, pass)
	end) }, { "unknown", "check_failed" })
	t.eq(market.calls.UserOwnsGamePassAsync, calls, "no hammering inside unknownTtl")
	env:advance(Commerce.UNKNOWN_TTL)
	t.eq({ run(env, function()
		return cache:owns(one, pass)
	end) }, { "owned" })
	-- a confirmed purchase during a stale "not owned" check: markOwned wins
	local two = player(2)
	local slow = Commerce.ownership(function(_p: any, _product: any): boolean
		env.wait(1)
		return false
	end, nil, env)
	local events = {}
	slow.changed:Connect(function(p: any, key: string, state: string)
		table.insert(events, { p.UserId, key, state })
	end)
	local answer = nil
	env.spawn(function()
		answer = { slow:owns(two, pass) }
	end)
	slow:markOwned(two, pass)
	for _ = 1, 20 do
		env:advance(0.1)
		env:flush()
	end
	t.eq(answer, { "not_owned" }, "the stale caller gets its own answer")
	t.eq({ slow:peek(two, pass) }, { "owned" }, "but the cache keeps the confirmed purchase")
	slow:markOwned(two, pass) -- already owned: no second event
	slow:markOwned(two, Catalog.find(catalog, "currency_pack_a") :: any) -- not ownable: ignored
	-- invalidate during a check: the answer is not cached
	local three = player(3)
	local later = nil
	env.spawn(function()
		later = { slow:owns(three, pass) }
	end)
	slow:invalidate(three)
	for _ = 1, 20 do
		env:advance(0.1)
		env:flush()
	end
	t.eq(later, { "not_owned" })
	t.eq({ slow:peek(three, pass) }, { "unknown", "not_checked" })
	t.eq(events, { { 2, "pass_a", "owned" } }, "stale checks fire nothing")
	slow:invalidate(player(99)) -- unknown players are fine
	t.ok(not pcall(Commerce.ownership, nil :: any, nil, env))
end)

-- ---------------------------------------------------------------- receipts over PlayerData

local function profileSession(env: any, shared: any): any
	local store = PlayerData.new({
		template = { currencies = {}, items = {}, entitlements = {}, slots = {} },
		version = 1,
		backend = PlayerData.memoryBackend({ serverId = "a", shared = shared }),
	}, env)
	return store, run(env, function()
		return store:load(42)
	end)
end

local WRITERS = {
	currency = function(data: any, currency: string, amount: number)
		data.currencies[currency] = (data.currencies[currency] or 0) + amount
	end,
	item = function(data: any, item: string, count: number)
		data.items[item] = (data.items[item] or 0) + count
	end,
	entitlement = function(data: any, entitlement: string)
		data.entitlements[entitlement] = true
	end,
	custom = {
		unlock_slot = function(data: any, grantData: any)
			data.slots[tostring(grantData.slot)] = true
		end,
	},
}

test("a duplicate purchaseId grants once through BindReceiptHandler", function(t)
	local env = newEnv()
	local shared = { values = {}, locks = {} }
	local store, session = profileSession(env, shared)
	local write = Commerce.grantWriter(WRITERS)
	local results = {}
	local process = Commerce.receiptProcessor({
		catalog = gameCatalog(),
		sessionFor = function(playerId: number): any
			return store:get(playerId)
		end,
		grant = function(data: any, p: any)
			write(data, p)
		end,
		onResult = function(result: any)
			table.insert(results, result)
		end,
	}, env)
	local market = FakeMarketplace.new()
	local connection = CommerceRoblox.bindReceipts(market, process, Enum)
	local receipt = { PlayerId = 42, ProductId = 1002, PurchaseId = "purchase_1", CurrencySpent = 1 }
	for _ = 1, 3 do
		t.eq(
			run(env, function()
				return market:deliver(receipt)
			end),
			"Processed"
		)
	end
	local saved = shared.values.player_42
	t.eq(saved.currencies, { currency_a = 5 })
	t.eq(saved.items, { item_a = 2 })
	t.eq(saved.entitlements, { badge_a = true })
	t.eq(saved.slots, { ["3"] = true })
	t.eq(saved.purchaseIds, { "purchase_1" })
	t.eq(session:get("currencies"), { currency_a = 5 })
	t.eq(results[1], {
		status = "granted",
		productKey = "bundle_b",
		purchaseId = "purchase_1",
		playerId = 42,
	})
	-- a product disabled after the purchase still grants (the player paid)
	t.eq(
		run(env, function()
			return market:deliver({ PlayerId = 42, ProductId = 1004, PurchaseId = "purchase_2" })
		end),
		"Processed"
	)
	t.eq(shared.values.player_42.currencies.currency_a, 105)
	connection:Disconnect()
	t.eq(market:deliver(receipt), "Unhandled")
end)

test("receipts that cannot be granted are left for Roblox to retry", function(t)
	local env = newEnv()
	local shared = { values = {}, locks = {} }
	local store = profileSession(env, shared)
	local results = {}
	local function processor(catalog: any, writers: any): any
		local write = Commerce.grantWriter(writers)
		return Commerce.receiptProcessor({
			catalog = catalog,
			sessionFor = function(playerId: number): any
				return store:get(playerId)
			end,
			grant = function(data: any, p: any)
				write(data, p)
			end,
			onResult = function(result: any)
				table.insert(results, result.reason)
				error("telemetry sink down") -- ignored
			end,
		}, env)
	end
	local process = processor(gameCatalog(), WRITERS)
	local function status(receipt: any): (string, string?)
		return run(env, function()
			return process(receipt)
		end)
	end
	t.eq(
		{ status({ PlayerId = 42, ProductId = 9999, PurchaseId = "p" }) },
		{ "not_processed", "unknown_product" }
	)
	t.eq(
		{ status({ PlayerId = 42, ProductId = 2001, PurchaseId = "p" }) },
		{ "not_processed", "not_devproduct" }
	)
	t.eq(
		{ status({ PlayerId = 77, ProductId = 1001, PurchaseId = "p" }) },
		{ "not_processed", "player_not_loaded" }
	)
	for _, bad in
		{
			{ PlayerId = 0, ProductId = 1001, PurchaseId = "p" },
			{ PlayerId = 42, ProductId = 1001.5, PurchaseId = "p" },
			{ PlayerId = 42, ProductId = 1001, PurchaseId = "" },
			{ PlayerId = 42, ProductId = 1001, PurchaseId = string.rep("x", 129) },
			"receipt",
		} :: { any }
	do
		t.eq({ status(bad) }, { "not_processed", "invalid_receipt" })
	end
	t.ok(has(table.concat(env.reports, "\n"), "telemetry sink down"))
	-- a grant with no writer fails the update: nothing recorded, the receipt is retried later
	local partial = processor(gameCatalog(), { currency = WRITERS.currency })
	local s1, r1 = run(env, function()
		return partial({ PlayerId = 42, ProductId = 1002, PurchaseId = "p_bundle" })
	end)
	t.eq({ s1, r1 }, { "not_processed", "update_failed" })
	t.eq(shared.values.player_42 and shared.values.player_42.currencies.currency_a, nil)
	t.ok(not store:get(42):hasReceipt("p_bundle"))
	-- the fixed processor grants it once
	t.eq(status({ PlayerId = 42, ProductId = 1002, PurchaseId = "p_bundle" }), "granted")
	-- setup mode never grants, even with a matching id
	local setupWithIds = Catalog.define({
		schema = "catalog/1",
		mode = "setup",
		products = { product("currency_pack_a", "devproduct", 1001, { enabled = false }) },
	})
	local setupProcess = processor(setupWithIds, WRITERS)
	t.eq({
		run(env, function()
			return setupProcess({ PlayerId = 42, ProductId = 1001, PurchaseId = "p_setup" })
		end),
	}, { "not_processed", "setup_mode" })
	-- a processor that raises answers NotProcessedYet through the binding
	local market = FakeMarketplace.new()
	CommerceRoblox.bindReceipts(market, function(): (string, string?)
		error("boom")
	end, Enum)
	t.eq(market:deliver({ PlayerId = 42, ProductId = 1001, PurchaseId = "p" }), "NotProcessedYet")
	-- and so does a processor that answers not_processed
	local bound = FakeMarketplace.new()
	CommerceRoblox.bindReceipts(bound, process, Enum)
	t.eq(bound:deliver({ PlayerId = 42, ProductId = 9999, PurchaseId = "p" }), "NotProcessedYet")
	-- options are checked up front
	t.ok(not pcall(Commerce.receiptProcessor, { catalog = { schema = "x" } } :: any))
	t.ok(not pcall(Commerce.grantWriter, { currency = 5 } :: any))
	t.ok(not pcall(Commerce.grantWriter, { custom = { ["Bad Name"] = function() end } } :: any))
	t.ok(not pcall(CommerceRoblox.bindReceipts, {}, process, Enum))
end)

-- ---------------------------------------------------------------- Runtime ledger and adapter

local function casStore(): any
	local s = { values = {}, calls = 0 }
	function s.UpdateAsync(_self: any, key: string, transform: (any) -> any): any
		s.calls += 1
		-- Roblox may run a transform more than once: run it twice, keep the second answer
		transform(s.values[key] and table.clone(s.values[key]))
		local candidate = transform(s.values[key] and table.clone(s.values[key]))
		if candidate ~= nil then
			s.values[key] = candidate
		end
		return s.values[key]
	end
	return s
end

local LEDGER_PRODUCTS = {
	[1001] = { universeId = 9, revision = "r1", balances = { currency_a = 100 }, entitlements = {} },
}

test("RobloxReceiptAdapter.bind grants a duplicate receipt once and maps decisions", function(t)
	local storage = casStore()
	local ledger = ReceiptLedger.new({
		store = storage,
		namespace = "fixture",
		universeId = 9,
		products = LEDGER_PRODUCTS,
	})
	local market = FakeMarketplace.new()
	local seen = {}
	local connection = ReceiptAdapter.bind(market, ledger, function(result: any)
		table.insert(seen, result)
	end, Enum)
	local receipt = { PlayerId = 5, ProductId = 1001, PurchaseId = "dup_1" }
	t.eq(market:deliver(receipt), "Processed")
	t.eq(market:deliver(receipt), "Processed")
	t.eq(storage.values["fixture:5"].balances.currency_a, 100)
	t.eq(seen[1].decision, "PurchaseGranted")
	t.eq({ seen[1].purchaseId, seen[1].productId, seen[1].playerId }, { "dup_1", 1001, 5 })
	t.eq(market:deliver({ PlayerId = 5, ProductId = 4040, PurchaseId = "x" }), "NotProcessedYet")
	t.eq(seen[3].reason, "unknown_product")
	-- a ledger that raises is NotProcessedYet with no raw error text
	local broken = {
		process = function()
			error("secret internal detail")
		end,
	}
	local handler = ReceiptAdapter.handler(broken, function(result: any)
		table.insert(seen, result)
	end, Enum)
	t.eq(handler(receipt), Enum.ReceiptDecision.NotProcessedYet)
	t.eq(seen[4].reason, "ledger_error")
	-- the legacy callback keeps ProductPurchaseDecision
	local legacy = ReceiptAdapter.callback(ledger, nil, Enum)
	t.eq(legacy(receipt), Enum.ProductPurchaseDecision.PurchaseGranted)
	t.eq(legacy({ PlayerId = 5 }), Enum.ProductPurchaseDecision.NotProcessedYet)
	connection:Disconnect()
	t.ok(not pcall(ReceiptAdapter.bind, {}, ledger, nil, Enum), "needs BindReceiptHandler")
	t.ok(not pcall(ReceiptAdapter.bind, market, {}, nil, Enum), "needs a ledger")
	t.ok(not pcall(ReceiptAdapter.handler(ledger, nil, nil), receipt), "no Enum outside Roblox")
end)

test("ReceiptLedger retention prunes old receipts and keeps in-window dedupe", function(t)
	local storage = casStore()
	local clock = 1800000000
	local ledger = ReceiptLedger.new({
		store = storage,
		namespace = "fixture",
		universeId = 9,
		products = LEDGER_PRODUCTS,
		maxReceipts = 2,
		minRetentionDays = 7,
		now = function(): number
			return clock
		end,
	})
	local function grant(id: string): any
		return ledger:process({ PlayerId = 5, ProductId = 1001, PurchaseId = id })
	end
	t.eq(grant("a").decision, "PurchaseGranted")
	clock += 86400
	t.eq(grant("b").decision, "PurchaseGranted")
	t.eq(grant("c").reason, "receipt_capacity_requires_migration", "both receipts are inside 7 days")
	clock += 6 * 86400 + 1 -- "a" is now 7 days and 1 second old; "b" is 6 days old
	local result = grant("c")
	t.eq({ result.decision, result.pruned }, { "PurchaseGranted", 1 })
	local receipts = storage.values["fixture:5"].receipts
	t.eq({ receipts.a, receipts.b ~= nil, receipts.c ~= nil }, { nil, true, true })
	t.eq(storage.values["fixture:5"].balances.currency_a, 300)
	t.eq(grant("b").decision, "PurchaseGranted")
	t.eq(storage.values["fixture:5"].balances.currency_a, 300, "b is still deduped")
end)

test("CommerceCatalog reads catalog/1, accepts productId and validates entries", function(t)
	local market = FakeMarketplace.new({
		products = { [1001] = { Name = "pack", PriceInRobux = 25 } },
		passes = {
			[2001] = { Name = "pass", PriceInRobux = 150, IsForSale = true },
			[2002] = { Name = "off", IsForSale = false },
		},
		subscriptions = { ["EXP-1001"] = { Name = "sub", DisplayPrice = "$4.99" } },
		owned = { [3] = { [2001] = true } },
	})
	local platform = CommerceRoblox.platform(market, Enum)
	t.eq(platform.productInfo("pass", 2002, player(3)), { name = "off", available = false })
	t.eq(platform.productInfo("gamepass", 2001, player(3)).formattedPrice, "150")
	t.ok(not pcall(platform.entitlement, "developer_product", 1001, player(3)))
	local live = LegacyCatalog.fromCatalog(9, gameCatalog(), platform)
	t.eq(live:display("currency_pack_a"), {
		state = "available",
		name = "pack",
		price = "25",
		purchasable = true,
	})
	t.eq(live:display("retired_pack").reason, "platform_info_unavailable")
	t.eq(
		live:display("pass_off"),
		{ state = "unavailable", reason = "platform_info_unavailable" },
		"not for sale"
	)
	t.eq(live:display("sub_a").price, "$4.99")
	t.eq(live:entitlement("pass_a", player(3)), { state = "active" })
	t.eq(live:entitlement("pass_a", player(4)), { state = "inactive" })
	t.eq(live:entitlement("currency_pack_a", player(3)).reason, "receipt_ledger_required")
	t.eq(live:display("missing").reason, "unconfigured")
	-- setup mode: placeholders never reach the platform; nothing is purchasable
	local before = market.calls.GetProductInfoAsync
	local setup = LegacyCatalog.fromCatalog(9, setupCatalog(), platform)
	t.eq(setup:display("currency_pack_a"), { state = "unavailable", reason = "placeholder" })
	t.eq(setup:entitlement("pass_a", player(3)), { state = "unknown", reason = "placeholder" })
	t.eq(market.calls.GetProductInfoAsync, before)
	local previewCatalog = Catalog.define({
		schema = "catalog/1",
		mode = "setup",
		products = { product("currency_pack_a", "devproduct", 1001, { enabled = false }) },
	})
	t.eq(LegacyCatalog.fromCatalog(9, previewCatalog, platform):display("currency_pack_a"), {
		state = "preview_only",
		reason = "setup_mode",
		name = "pack",
		price = "25",
		purchasable = false,
	})
	t.ok(
		not pcall(
			LegacyCatalog.fromCatalog,
			9,
			{ schema = "catalog/1", mode = "live", products = {} },
			platform
		)
	)
	t.ok(not pcall(LegacyCatalog.fromCatalog, 0, gameCatalog(), platform))
	-- legacy entries may say productId (the Creator shop spelling) but must not contradict id
	local legacy = LegacyCatalog.new(9, {
		pass_a = {
			universeId = 9,
			kind = "pass",
			productId = 2001,
			ownershipVerified = true,
			enabled = false,
		},
	}, platform)
	t.eq(
		legacy:display("pass_a"),
		{ state = "preview_only", name = "pass", price = "150", purchasable = false }
	)
	t.ok(not pcall(LegacyCatalog.new, 9, {
		pass_a = {
			universeId = 9,
			kind = "pass",
			id = 1,
			productId = 2,
			ownershipVerified = true,
			enabled = false,
		},
	}, platform))
	t.eq(
		LegacyCatalog.validateEntry({
			kind = "pass",
			id = 1,
			productId = 2,
			enabled = false,
			ownershipVerified = true,
		}),
		{ "id_conflict: id and productId disagree" }
	)
	t.eq(
		LegacyCatalog.validateEntry({
			kind = "subscription",
			id = "EXP-0",
			enabled = false,
			ownershipVerified = false,
		}),
		{}
	)
	local gameProblems = table.concat(
		LegacyCatalog.validateEntry({
			kind = "subscription",
			id = "EXP-0",
			enabled = true,
			ownershipVerified = false,
			priceInRobux = 5,
			universeId = -1,
		}, "game"),
		"\n"
	)
	for _, needle in
		{
			"game mode needs the real id",
			"an enabled entry needs ownershipVerified",
			"priceInRobux: prices are runtime reads",
			"universeId must be an integer > 0",
		}
	do
		t.ok(has(gameProblems, needle), needle .. "\n" .. gameProblems)
	end
	t.eq(LegacyCatalog.validateEntry({ kind = "bundle", id = "1", enabled = 1 }, "live"), {
		"mode must be setup or game",
		"kind must be pass, developer_product or subscription",
		"id must be an integer > 0 (placeholder 0)",
		"enabled must be a boolean",
		"ownershipVerified must be a boolean",
	})
	t.eq(LegacyCatalog.validateEntry(nil), { "entry must be a table" })
	t.eq(
		LegacyCatalog.validateEntry({
			kind = "subscription",
			id = "SUB-1",
			enabled = false,
			ownershipVerified = true,
		}),
		{
			"id must be an EXP- subscription id (placeholder EXP-0)",
		}
	)
end)

test("price levels are read fresh every call and failures are returned", function(t)
	local market = FakeMarketplace.new({ priceLevels = { [1] = 3 } })
	t.eq({ CommerceRoblox.priceLevels(market, { 1, 2 }) }, {
		true,
		{ { UserId = 1, PriceLevel = 3 }, { UserId = 2, PriceLevel = 0 } },
	})
	CommerceRoblox.priceLevels(market, { 1 })
	t.eq(market.calls.GetUsersPriceLevelsAsync, 2)
	market:fail("GetUsersPriceLevelsAsync", 1, "throttled")
	local ok, err = CommerceRoblox.priceLevels(market, { 1 })
	t.eq(ok, false)
	t.ok(has(err, "throttled"))
	t.eq({ CommerceRoblox.priceLevels(market, {}) }, { false, "userIds must be a non-empty list" })
end)

return cases
