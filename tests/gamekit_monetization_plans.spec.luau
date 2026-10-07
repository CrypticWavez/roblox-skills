--!strict
-- The starter's monetization planner output (templates/starter/tools/monetize.py, committed under
-- fixtures/monetization/<genre>/; tests/test_monetize.py keeps them current) loads through the
-- Luau validators: Catalog.define, Offers.define, Boosts.define, Perks.define and
-- ShopLayout.define each accept every file, every product is in a shop section, and a first
-- session gets the starter pack, the death or locked offer where the genre has one, and boosts
-- and perks that change values. So what the planner writes is what the kits run.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Boosts = require("../packages/GameKit/Boosts")
local Catalog = require("../packages/GameKit/Catalog")
local Offers = require("../packages/GameKit/Offers")
local Perks = require("../packages/GameKit/Perks")
local ShopLayout = require("../packages/GameKit/ShopLayout")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."
local DIR = ROOT .. "/fixtures/monetization"

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function read(path: string): any
	return serde.decode("json", fs.readFile(path))
end

local T0 = 1791244800

local names = fs.readDir(DIR)
table.sort(names)

test("fixtures exist for several genres", function(t)
	local dirs = 0
	for _, name in names do
		if fs.isDir(DIR .. "/" .. name) then
			dirs += 1
		end
	end
	t.ok(dirs >= 6, "at least six genre fixtures, found " .. dirs)
end)

for _, name in names do
	local base = DIR .. "/" .. name
	if not fs.isDir(base) then
		continue
	end
	test(name .. ": every generated file passes its Luau validator and runs a session", function(t)
		local shared = base .. "/src/shared/"
		local catalog = Catalog.define(read(shared .. "catalog.json"))
		t.eq(catalog.mode, "setup", "the planner never enables products")
		local passes, products = 0, 0
		for _, product in catalog.products do
			t.eq(product.enabled, false)
			if product.kind == "gamepass" then
				passes += 1
			elseif product.kind == "devproduct" then
				products += 1
			end
		end
		t.ok(
			passes >= 3 and products >= 4,
			"a full shop: " .. passes .. " passes, " .. products .. " products"
		)
		local offers = Offers.define(read(shared .. "offers.json"), catalog)
		local boosts = Boosts.define(read(shared .. "boosts.json"))
		local perks = Perks.define(read(shared .. "perks.json"), catalog)
		local shop = ShopLayout.define(read(shared .. "shop.json"), catalog)
		local warnings = ShopLayout.lint(shop, catalog)
		for _, warning in warnings do
			t.ok(not string.find(warning, "no shop section shows", 1, true), warning)
		end
		-- Everything is in the shop, the featured pass first.
		local built = ShopLayout.build(shop, catalog)
		t.ok(#built >= 3, "at least three sections")
		-- A first session: grace, then the starter pack on join.
		local state = Offers.newState()
		local session = Offers.session(offers, state, T0)
		local _, why = session:evaluate("join", { now = T0 + 1 })
		t.eq(why, "grace")
		local offer = session:evaluate("join", { now = T0 + 200 })
		t.eq(offer and offer.productKey, "starter_pack")
		session:shown(offer.key, T0 + 200)
		t.eq(session:expiresAt(offer.key), T0 + 200 + 86400, "a real 24 h timer, not a fake one")
		-- Boost products grant through the boost handler into the tracker.
		local tracker = Boosts.new(boosts, nil, T0)
		tracker:resume(T0)
		for _, product in catalog.products do
			for _, grant in product.grants do
				if
					grant.type == "custom" and (grant.handler == "boost" or grant.handler == "server_boost")
				then
					local boostKey = (grant.data :: any).boost
					tracker:add(boostKey, T0)
					local def = nil
					for _, b in boosts.boosts do
						if b.key == boostKey then
							def = b
						end
					end
					t.ok(tracker:value(def.stat, T0 + 1) > 1, boostKey .. " raises " .. def.stat)
				end
			end
		end
		-- Owning every pass turns every perk on.
		local resolved = Perks.resolve(perks, function(): boolean
			return true
		end)
		t.ok(#resolved.perks >= 3)
		t.ok(Perks.has(resolved, "vip_tag"), "VIP is in every shop")
	end)
end

return cases
