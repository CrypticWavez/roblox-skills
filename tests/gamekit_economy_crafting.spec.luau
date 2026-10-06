--!strict
-- GameKit/Crafting: recipe validation (including duplication loops in recipe data), atomic
-- instant crafts across inventory and wallet with rollback, timed jobs that survive a reload,
-- and refunds on cancel.
local Crafting = require("../packages/GameKit/Crafting")
local Inventory = require("../packages/GameKit/Inventory")
local ItemDefs = require("../packages/GameKit/ItemDefs")
local Wallet = require("../packages/GameKit/Wallet")
local FakeEconomyStore = require("./fakes/FakeEconomyStore")

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

local ITEMS = ItemDefs.registry({
	{ id = "material_a", kind = "material", stackable = true, maxStack = 99 },
	{ id = "material_b", kind = "material", stackable = true, maxStack = 99 },
	{ id = "material_c", kind = "material", stackable = true, maxStack = 99 },
	{ id = "gear_a", kind = "gear", stackable = false, maxStack = 1 },
})

local RECIPES = {
	{
		id = "refine_a",
		inputs = { { item = "material_a", count = 3 } },
		outputs = { { item = "material_b", count = 1 } },
	},
	{
		id = "make_gear",
		inputs = { { item = "material_b", count = 2 }, { item = "material_a", count = 1 } },
		outputs = { { item = "gear_a", count = 1, data = { tier = 1 } } },
		costs = { currency_a = 10 },
	},
	{
		id = "slow_c",
		inputs = { { item = "material_a", count = 1 } },
		outputs = { { item = "material_c", count = 1 } },
		seconds = 60,
	},
	{
		id = "buy_a",
		inputs = {},
		outputs = { { item = "material_a", count = 5 } },
		costs = { currency_a = 4 },
	},
}

local function kit(capacity: number?, store: any?): (any, any, any)
	local inventory = Inventory.new({ items = ITEMS, owner = "p1", capacity = capacity or 10, store = store })
	local wallet = Wallet.new({ currencies = { currency_a = {} }, store = store })
	return Crafting.new(RECIPES, { items = ITEMS, maxJobs = 2 }), inventory, wallet
end

test("recipe validation names every problem", function(t)
	t.eq(Crafting.validate(RECIPES, ITEMS), {})
	t.ok(contains(Crafting.validate({}), "non-empty"))
	local problems = Crafting.validate({
		{ id = "a", inputs = { { item = "material_a", count = 0 } }, outputs = {} },
		{
			id = "a",
			inputs = { { item = "ghost", count = 1 } },
			outputs = { { item = "material_a", count = 1 } },
		},
		{ id = "free", inputs = {}, outputs = { { item = "material_a", count = 1 } } },
		{
			id = "b",
			inputs = {},
			outputs = { { item = "material_a", count = 1 } },
			costs = { currency_a = 0 },
			seconds = -1,
			price = 3,
		},
	}, ITEMS)
	for _, needle in
		{
			"recipe a: inputs[1] needs an item label and an integer count >= 1",
			"recipe a: outputs must be a non-empty list",
			"recipe a: duplicate id",
			"recipe a: inputs[1] item ghost is not defined",
			"recipe free: needs inputs or costs",
			'recipe b: costs "currency_a" needs an integer amount >= 1',
			"recipe b: seconds must be a finite number >= 0",
			'recipe b: unknown key "price"',
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
end)

test("validation refuses recipe loops that multiply items, and accepts lossless or lossy ones", function(t)
	local dupe = Crafting.validate({
		{
			id = "split",
			inputs = { { item = "material_a", count = 1 } },
			outputs = { { item = "material_b", count = 2 } },
		},
		{
			id = "join",
			inputs = { { item = "material_b", count = 1 } },
			outputs = { { item = "material_c", count = 1 } },
		},
		{
			id = "back",
			inputs = { { item = "material_c", count = 1 } },
			outputs = { { item = "material_a", count = 1 } },
		},
	})
	t.ok(contains(dupe, "form a loop that multiplies"), table.concat(dupe, " | "))
	t.ok(contains(dupe, "by 2 (duplication)"), table.concat(dupe, " | "))
	local selfLoop = Crafting.validate({
		{
			id = "grow",
			inputs = { { item = "material_a", count = 2 } },
			outputs = { { item = "material_a", count = 3 } },
		},
	})
	t.ok(contains(selfLoop, "recipes grow form a loop"), table.concat(selfLoop, " | "))
	t.eq(
		Crafting.validate({
			{
				id = "split",
				inputs = { { item = "material_a", count = 1 } },
				outputs = { { item = "material_b", count = 2 } },
			},
			{
				id = "join",
				inputs = { { item = "material_b", count = 2 } },
				outputs = { { item = "material_a", count = 1 } },
			},
		}),
		{},
		"a lossless round trip is fine"
	)
	t.eq(
		Crafting.validate({
			{
				id = "split",
				inputs = { { item = "material_a", count = 1 } },
				outputs = { { item = "material_b", count = 2 } },
			},
			{
				id = "join",
				inputs = { { item = "material_b", count = 3 } },
				outputs = { { item = "material_a", count = 1 } },
			},
		}),
		{},
		"a lossy loop is a sink, not a dupe"
	)
	t.throws(function()
		Crafting.new({
			{
				id = "grow",
				inputs = { { item = "material_a", count = 1 } },
				outputs = { { item = "material_a", count = 2 } },
			},
		})
	end)
end)

test("instant crafts are atomic across inventory and wallet", function(t)
	local crafting, inventory, wallet = kit()
	inventory:add("material_a", 10)
	t.ok((crafting:craft("refine_a", inventory, wallet, 3)))
	t.eq({ inventory:count("material_a"), inventory:count("material_b") }, { 1, 3 })
	t.eq({ crafting:can("make_gear", inventory, wallet) }, { false, "insufficient_funds" })
	local before = inventory:serialize()
	t.eq({ crafting:craft("make_gear", inventory, wallet) }, { false, "insufficient_funds", nil })
	t.eq(inventory:serialize(), before, "no inputs taken when the wallet refuses")
	wallet:credit("currency_a", 15, "Gameplay")
	local ok, err, info = crafting:craft("make_gear", inventory, wallet)
	t.ok(ok, err)
	t.eq(assert(inventory:get(info.created[1])).data, { tier = 1 })
	t.eq(wallet:balance("currency_a"), 5)
	t.eq({ crafting:craft("make_gear", inventory, nil) }, { false, "insufficient_items", nil })
	t.eq({ crafting:craft("nope", inventory, wallet) }, { false, "unknown_recipe", nil })
	t.eq({ crafting:craft("refine_a", inventory, wallet, 0) }, { false, "invalid_times", nil })
	t.eq({ crafting:craft("refine_a", inventory, wallet, 101) }, { false, "invalid_times", nil })
	t.eq({ crafting:craft("slow_c", inventory, wallet) }, { false, "timed_recipe", nil })
	t.ok((crafting:craft("buy_a", inventory, wallet)), "currency-only recipes work")
	t.eq(inventory:count("material_a"), 5)
	t.eq({ crafting:can("buy_a", inventory, nil) }, { false, "no_wallet" })
end)

test("a wallet commit failure rolls the inventory back", function(t)
	local store = FakeEconomyStore.new()
	local crafting, inventory, wallet = kit(10, store)
	inventory:add("material_a", 5)
	inventory:add("material_b", 4)
	wallet:credit("currency_a", 20, "Gameplay")
	local before = { inventory:serialize(), wallet:serialize() }
	store:failSetWhen(function(key: string): boolean
		return key == "wallet"
	end)
	t.eq({ crafting:craft("make_gear", inventory, wallet) }, { false, "store_failed", nil })
	store:failSetWhen(nil)
	t.eq({ inventory:serialize(), wallet:serialize() }, before)
	t.eq(store.data.inventory, before[1], "the stored inventory was rolled back too")
end)

test("a full inventory refuses the craft without taking inputs", function(t)
	local crafting, inventory, wallet = kit(2)
	inventory:add("material_a", 3)
	inventory:add("material_c", 1)
	t.eq(
		{ crafting:craft("refine_a", inventory, wallet) },
		{ true, nil, { created = {} } },
		"the slot frees first"
	)
	local full, inv2 = kit(1)
	inv2:add("material_a", 6)
	t.eq({ full:craft("refine_a", inv2, nil, 1) }, { false, "no_space", nil })
	t.eq(inv2:count("material_a"), 6)
end)

test("timed jobs pay now, complete when ready, survive a reload and refund on cancel", function(t)
	local crafting, inventory, wallet = kit()
	inventory:add("material_a", 3)
	local ok, err, job = crafting:start("slow_c", inventory, wallet, 1000, 2)
	t.ok(ok, err)
	t.eq(assert(job).readyAt, 1120)
	t.eq(inventory:count("material_a"), 1)
	t.eq({ crafting:complete(assert(job).id, inventory, 1100) }, { false, "not_ready", 20 })
	local reloaded = Crafting.new(RECIPES, { items = ITEMS, data = crafting:serialize() })
	t.eq(reloaded:jobs(), crafting:jobs())
	t.ok((reloaded:complete(assert(job).id, inventory, 1120)))
	t.eq(inventory:count("material_c"), 2)
	t.eq({ reloaded:complete(assert(job).id, inventory, 1120) }, { false, "unknown_job", nil })
	local _, _, second = reloaded:start("slow_c", inventory, wallet, 2000)
	t.eq(assert(second).id, 2, "job ids keep counting after a reload")
	t.ok((reloaded:cancel(assert(second).id, inventory, wallet)))
	t.eq(inventory:count("material_a"), 1, "inputs refunded")
	t.eq(#reloaded:jobs(), 0)
	inventory:add("material_a", 5)
	reloaded:start("slow_c", inventory, wallet, 0)
	t.eq(
		{ reloaded:start("slow_c", inventory, wallet, 0) },
		{ false, "jobs_full", nil },
		"maxJobs defaults to 1"
	)
	local dropped = Crafting.new(RECIPES, {
		data = { schema = "crafting/1", jobs = { { id = 1, recipe = "retired", times = 1, readyAt = 0 } } },
	})
	t.ok(contains(dropped.notes, "dropped invalid or retired job"))
end)

test("completing into a full inventory keeps the job", function(t)
	local crafting = Crafting.new(RECIPES, { items = ITEMS })
	local inventory = Inventory.new({ items = ITEMS, owner = "p1", capacity = 1 })
	inventory:add("material_a", 1)
	local _, _, job = crafting:start("slow_c", inventory, nil, 0)
	inventory:add("material_b", 1)
	t.eq({ crafting:complete(assert(job).id, inventory, 60) }, { false, "no_space", nil })
	t.eq(#crafting:jobs(), 1)
	inventory:remove("material_b", 1)
	t.ok((crafting:complete(assert(job).id, inventory, 60)))
end)

return cases
