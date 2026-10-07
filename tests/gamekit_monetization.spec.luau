--!strict
-- GameKit monetization data kits: Offers (popup rules, triggers, audiences, personal timers,
-- state repair), Boosts (stacking, playtime clocks, combine rules, saves), Perks (pass and
-- entitlement effects) and ShopLayout (sections, ribbons, owned sorting, lint). None of them
-- prompts: the specs scan the files for MarketplaceService.
local fs = require("@lune/fs")

local Boosts = require("../packages/GameKit/Boosts")
local Catalog = require("../packages/GameKit/Catalog")
local Offers = require("../packages/GameKit/Offers")
local Perks = require("../packages/GameKit/Perks")
local ShopLayout = require("../packages/GameKit/ShopLayout")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local T0 = 1791244800 -- 2026-10-06T00:00:00Z

local function product(key: string, kind: string, tags: { string }?): any
	return {
		key = key,
		kind = kind,
		id = if kind == "subscription" then "EXP-0" else 0,
		grants = { { type = "entitlement", entitlement = key } },
		display = { nameKey = "shop." .. key },
		enabled = false,
		ownershipVerified = false,
		tags = tags,
	}
end

local CATALOG = Catalog.define({
	schema = "catalog/1",
	mode = "setup",
	products = {
		product("starter_pack", "devproduct", { "bundles" }),
		product("coins_small", "devproduct", { "currency" }),
		product("coins_large", "devproduct", { "currency" }),
		product("revive", "devproduct", { "boosts" }),
		product("double_cash", "gamepass", { "passes" }),
		product("vip", "gamepass", { "passes" }),
	},
})

local OFFERS = Offers.define({
	schema = "offers/1",
	rules = { maxPerSession = 2, minSpacing = 60, grace = 30, quietAfterPurchase = 120 },
	offers = {
		{
			key = "starter",
			productKey = "starter_pack",
			trigger = "join",
			priority = 10,
			duration = 86400,
			audience = { payer = "non_payer" },
			ribbon = "starter",
		},
		{ key = "join_vip", productKey = "vip", trigger = "join", priority = 1 },
		{
			key = "revive_offer",
			productKey = "revive",
			trigger = "death",
			cooldown = 300,
			untilBought = false,
		},
		{ key = "featured", productKey = "double_cash", trigger = "shop_open" },
	},
}, CATALOG)

test("offers: validate catches unknown products, prices and bad fields", function(t)
	local problems = Offers.validate({
		schema = "offers/1",
		offers = {
			{ key = "a", productKey = "missing", trigger = "join", priceRobux = 99 },
			{ key = "a", productKey = "vip", trigger = "Join", ribbon = "huge" },
			{ key = "b", productKey = "vip", trigger = "join", window = { start = 10, ["end"] = 5 } },
			{ key = "c", productKey = "vip", trigger = "join", audience = { payer = "whale" } },
		},
	}, CATALOG)
	t.ok(contains(problems, "missing is not in the catalog"))
	t.ok(contains(problems, "prices are runtime reads"))
	t.ok(contains(problems, "a: duplicate key"))
	t.ok(contains(problems, "trigger must be a label"))
	t.ok(contains(problems, "ribbon must be one of"))
	t.ok(contains(problems, "window must be"))
	t.ok(contains(problems, "audience.payer"))
	t.eq(#Offers.validate(OFFERS, CATALOG), 0)
	t.eq(OFFERS.rules.maxPerSession, 2)
	t.throws(function()
		Offers.define({ schema = "offers/2", offers = {} })
	end)
end)

test("offers: grace, priority, spacing and the session cap", function(t)
	local state = Offers.newState()
	local session = Offers.session(OFFERS, state, T0)
	local offer, why = session:evaluate("join", { now = T0 + 5 })
	t.eq({ offer, why }, { nil, "grace" })
	offer = session:evaluate("join", { now = T0 + 31 })
	t.eq(offer and offer.key, "starter", "the higher priority wins")
	session:shown("starter", T0 + 31)
	t.eq(session:expiresAt("starter"), T0 + 31 + 86400)
	offer, why = session:evaluate("join", { now = T0 + 40 })
	t.eq(why, "spacing")
	offer = session:evaluate("death", { now = T0 + 100 })
	t.eq(offer and offer.key, "revive_offer")
	session:shown("revive_offer", T0 + 100)
	offer, why = session:evaluate("join", { now = T0 + 500 })
	t.eq(why, "session_cap")
	-- the shop is opened by the player: popup rules do not apply
	offer = session:evaluate("shop_open", { now = T0 + 501 })
	t.eq(offer and offer.key, "featured")
	t.eq({ session:evaluate("nothing", { now = T0 }) }, { nil, "unknown_trigger" })
	t.eq({ session:evaluate("death", { now = T0 + 999, promptOpen = true }) }, { nil, "prompt_open" })
end)

test("offers: owned, bought, quiet period, audience and expiry", function(t)
	local state = Offers.newState()
	state.sessions = 3 -- not the first session: no grace
	local session = Offers.session(OFFERS, state, T0)
	local owned = function(key: string): boolean
		return key == "vip"
	end
	local offer = session:evaluate("join", { now = T0, owned = owned })
	t.eq(offer and offer.key, "starter")
	session:shown("starter", T0)
	session:purchased("starter_pack", T0 + 10)
	t.ok(state.payer)
	local _, why = session:evaluate("death", { now = T0 + 70 })
	t.eq(why, "quiet_after_purchase")
	-- a new session: the starter pack was bought, vip is owned, so nothing listens to join
	local again = Offers.session(OFFERS, state, T0 + 1000)
	_, why = again:evaluate("join", { now = T0 + 1000, owned = owned })
	t.eq(why, "none_eligible")
	-- revive is repeatable (untilBought = false) and cools down
	again:purchased("revive", T0 + 1000)
	local revive = again:evaluate("death", { now = T0 + 1200 })
	t.eq(revive and revive.key, "revive_offer")
	again:shown("revive_offer", T0 + 1200)
	local third = Offers.session(OFFERS, state, T0 + 1300)
	_, why = third:evaluate("death", { now = T0 + 1300 })
	t.eq(why, "none_eligible", "cooldown 300 s")
	-- a personal timer ends
	local fresh = Offers.newState()
	fresh.sessions = 5
	local s = Offers.session(OFFERS, fresh, T0)
	s:shown("starter", T0)
	local later = Offers.session(OFFERS, fresh, T0 + 86401)
	local next_ = later:evaluate("join", { now = T0 + 86401 })
	t.eq(next_ and next_.key, "join_vip", "the starter pack expired")
end)

test("offers: loadState repairs a corrupt save", function(t)
	local state = Offers.loadState({
		schema = "offer-state/1",
		sessions = -4,
		payer = "yes",
		shows = { starter = 2, ["Bad Key"] = 1, other = "x" },
		bought = { vip = true, coins = 1 },
	})
	t.eq(state.sessions, 0)
	t.eq(state.payer, false)
	t.eq(state.shows, { starter = 2 })
	t.eq(state.bought, { vip = true })
	t.eq(Offers.loadState(nil).schema, "offer-state/1")
end)

local BOOSTS = Boosts.define({
	schema = "boosts/1",
	stats = {
		luck = { combine = "multiply", cap = 10 },
		speed = { combine = "max" },
		cash = { combine = "add" },
	},
	boosts = {
		{ key = "luck_x2", stat = "luck", multiplier = 2, duration = 900, maxDuration = 3600 },
		{ key = "luck_refresh", stat = "luck", multiplier = 3, duration = 600, stack = "refresh" },
		{ key = "speed_potion", stat = "speed", multiplier = 1.5, duration = 300, stack = "stack" },
		{ key = "cash_x2", stat = "cash", multiplier = 2, duration = 600, clock = "playtime" },
		{ key = "cash_flat", stat = "cash", add = 5, duration = 600 },
	},
})

test("boosts: validation", function(t)
	local problems = Boosts.validate({
		schema = "boosts/1",
		stats = { luck = { combine = "power" } },
		boosts = {
			{ key = "a", stat = "luck", multiplier = 2, add = 1, duration = 10 },
			{ key = "b", stat = "luck", multiplier = 0, duration = 0, stack = "pile", clock = "moon" },
			{ key = "c", stat = "luck", multiplier = 2, duration = 100, maxDuration = 50 },
		},
	})
	t.ok(contains(problems, "combine must be"))
	t.ok(contains(problems, "exactly one of multiplier or add"))
	t.ok(contains(problems, "multiplier must be a number > 0"))
	t.ok(contains(problems, "duration must be seconds > 0"))
	t.ok(contains(problems, "stack must be"))
	t.ok(contains(problems, "clock must be"))
	t.ok(contains(problems, "maxDuration must be >= duration"))
end)

test("boosts: extend up to the cap, refresh, stack and combine", function(t)
	local tracker = Boosts.new(BOOSTS, nil, T0)
	t.eq(tracker:add("luck_x2", T0), 900)
	t.eq(tracker:add("luck_x2", T0 + 100, 2), 800 + 1800)
	t.eq(tracker:add("luck_x2", T0 + 100, 5), 3600, "maxDuration caps an extension")
	t.eq(tracker:value("luck", T0 + 100), 2)
	tracker:add("luck_refresh", T0 + 100)
	t.eq(tracker:value("luck", T0 + 100), 6, "multiply combine")
	t.eq(tracker:value("luck", T0 + 100, 2), 12, "base applies")
	tracker:add("speed_potion", T0, 3)
	t.eq(#tracker:active(T0 + 1), 5)
	t.eq(tracker:value("speed", T0 + 1), 1.5, "max combine: the strongest wins")
	t.eq(tracker:value("speed", T0 + 301), 1, "expired")
	tracker:add("cash_flat", T0)
	tracker:resume(T0)
	tracker:add("cash_x2", T0)
	t.eq(tracker:value("cash", T0 + 1, 10), 25, "add combine: 10 * (1 + 1) + 5")
	t.eq(tracker:value("missing", T0), 1)
	t.throws(function()
		tracker:add("nope", T0)
	end)
end)

test("offers: a level audience needs a known level, both bounds", function(t)
	local data = Offers.define({
		schema = "offers/1",
		offers = {
			{ key = "low", productKey = "starter_pack", trigger = "level_up", audience = { maxLevel = 5 } },
			{
				key = "high",
				productKey = "starter_pack",
				trigger = "round_end",
				audience = { minLevel = 10 },
			},
		},
	}, CATALOG)
	local state = Offers.newState()
	state.sessions = 3
	local session = Offers.session(data, state, T0)
	local _, why = session:evaluate("level_up", { now = T0 })
	t.eq(why, "none_eligible", "maxLevel with no level is not eligible")
	local offer = session:evaluate("level_up", { now = T0, level = 3 })
	t.eq(offer and offer.key, "low")
	_, why = session:evaluate("round_end", { now = T0 })
	t.eq(why, "none_eligible", "minLevel with no level is not eligible")
end)

test("boosts: a stack boost at the instance cap keeps every paid activation", function(t)
	local tracker = Boosts.new(BOOSTS, nil, T0)
	tracker:add("speed_potion", T0, Boosts.MAX_INSTANCES)
	t.eq(#tracker:active(T0), Boosts.MAX_INSTANCES)
	local longest = tracker:add("speed_potion", T0)
	t.eq(#tracker:active(T0), Boosts.MAX_INSTANCES, "the count is capped")
	t.eq(longest, 600, "the extra activation extended an instance instead of being dropped")
	t.eq(#tracker:active(T0 + 301), 1, "the extended instance outlives the rest")
end)

test("boosts: playtime pauses offline and saves round-trip", function(t)
	local tracker = Boosts.new(BOOSTS, nil, T0)
	tracker:resume(T0)
	tracker:add("cash_x2", T0)
	tracker:add("luck_x2", T0)
	tracker:pause(T0 + 100) -- the player leaves
	local saved = tracker:save(T0 + 100)
	t.eq(saved.schema, "boost-state/1")
	-- rejoin a day later: the realtime luck boost ended, the playtime cash boost kept 500 s
	local back = Boosts.new(BOOSTS, saved, T0 + 86400)
	back:resume(T0 + 86400)
	local active = back:active(T0 + 86400)
	t.eq(#active, 1)
	t.eq(active[1].key, "cash_x2")
	t.eq(active[1].remaining, 500)
	t.eq(back:active(T0 + 86400 + 501), {})
	local junk = Boosts.new(
		BOOSTS,
		{ schema = "boost-state/1", instances = { gone = { { endsAt = 1 } }, luck_x2 = "x" } },
		T0
	)
	t.eq(junk:active(T0), {})
end)

local PERKS = Perks.define({
	schema = "perks/1",
	stats = { slots = { combine = "add" }, cash = { combine = "multiply", cap = 8 } },
	perks = {
		{
			key = "double_cash",
			source = { productKey = "double_cash" },
			effects = { { stat = "cash", multiplier = 2 } },
		},
		{
			key = "vip",
			source = { productKey = "vip" },
			effects = {
				{ stat = "cash", multiplier = 1.5 },
				{ stat = "slots", add = 2 },
				{ flag = "vip_tag" },
			},
		},
		{
			key = "gifted",
			source = { entitlement = "gift_slots" },
			effects = { { stat = "slots", add = 1 } },
		},
	},
}, CATALOG)

test("perks: validation against the catalog", function(t)
	local problems = Perks.validate({
		schema = "perks/1",
		perks = {
			{ key = "a", source = { productKey = "revive" }, effects = { { stat = "x", multiplier = 2 } } },
			{ key = "b", source = { productKey = "vip", entitlement = "x" }, effects = {} },
			{ key = "c", source = { productKey = "ghost" }, effects = { { flag = "f", stat = "x" } } },
		},
	}, CATALOG)
	t.ok(contains(problems, "a developer product is not owned"))
	t.ok(contains(problems, "exactly one of productKey or entitlement"))
	t.ok(contains(problems, "effects must be a non-empty list"))
	t.ok(contains(problems, "ghost is not in the catalog"))
	t.ok(contains(problems, "a flag effect has no stat"))
end)

test("perks: resolve and value", function(t)
	local owned = { double_cash = true, vip = true }
	local resolved = Perks.resolve(PERKS, function(source: any): boolean
		if source.productKey == "vip" then
			error("ownership check failed")
		end
		return owned[source.productKey] == true or source.entitlement == "gift_slots"
	end)
	t.eq(resolved.perks, { "double_cash", "gifted" }, "an erroring check is not owned")
	t.eq(Perks.value(resolved, "cash", 10), 20)
	t.eq(Perks.value(resolved, "slots", 3), 4)
	t.ok(not Perks.has(resolved, "vip_tag"))
	local all = Perks.resolve(PERKS, function(): boolean
		return true
	end)
	t.eq(Perks.value(all, "cash", 10), 30)
	t.eq(Perks.value(all, "slots", 3), 6)
	t.ok(Perks.has(all, "vip_tag"))
	t.eq(Perks.value(all, "speed", 16), 16)
end)

local SHOP = ShopLayout.define({
	schema = "shop/1",
	entry = { hud = "left", label = true, notify = true },
	sections = {
		{
			id = "featured",
			titleKey = "shop.featured",
			products = { "starter_pack", "vip" },
			featured = "vip",
		},
		{ id = "passes", titleKey = "shop.passes", tag = "passes" },
		{ id = "currency", titleKey = "shop.currency", tag = "currency" },
		{ id = "empty", titleKey = "shop.empty", tag = "nothing" },
	},
	ribbons = { coins_large = "best_value", vip = "most_popular" },
}, CATALOG)

test("shop layout: validation", function(t)
	local problems = ShopLayout.validate({
		schema = "shop/1",
		entry = { hud = "middle" },
		sections = {
			{ id = "a", titleKey = "x y", featured = "vip" },
			{ id = "a", titleKey = "k", products = { "ghost" } },
		},
		ribbons = { vip = "shiny" },
	}, CATALOG)
	t.ok(contains(problems, "entry.hud must be"))
	t.ok(contains(problems, "titleKey must be"))
	t.ok(contains(problems, "give a tag, products or both"))
	t.ok(contains(problems, "featured vip is not one of the section's products"))
	t.ok(contains(problems, "a: duplicate id"))
	t.ok(contains(problems, "ghost is not in the catalog"))
	t.ok(contains(problems, "ribbons.vip must be one of"))
end)

test("shop layout: build sorts featured first and owned last, skips empty sections", function(t)
	local owned = function(key: string): boolean
		return key == "vip" or key == "starter_pack"
	end
	local built = ShopLayout.build(SHOP, CATALOG, { owned = owned })
	t.eq(#built, 3, "the empty section is skipped")
	t.eq(built[1].items[1].productKey, "vip")
	t.ok(built[1].items[1].featured and built[1].items[1].owned)
	t.eq(built[1].items[2].owned, false, "developer products are never owned")
	t.eq(built[2].items[1].productKey, "double_cash", "owned passes sort last")
	t.eq(built[2].items[2].productKey, "vip")
	t.eq(built[3].items[1].productKey, "coins_large")
	t.eq(built[3].items[1].ribbon, "best_value")
	local hidden = ShopLayout.build(SHOP, CATALOG, { owned = owned, hideOwned = true })
	t.eq(#hidden[2].items, 1)
	local warnings = ShopLayout.lint(SHOP, CATALOG)
	t.ok(contains(warnings, "revive: no shop section shows it"))
end)

test("monetization data kits never prompt or touch MarketplaceService", function(t)
	for _, name in { "Offers", "Boosts", "Perks", "ShopLayout" } do
		local source = fs.readFile(ROOT .. "/packages/GameKit/" .. name .. ".luau")
		t.ok(not string.find(source, "MarketplaceService", 1, true), name)
		t.ok(not string.find(source, "Prompt%a*Purchase"), name)
	end
end)

return cases
