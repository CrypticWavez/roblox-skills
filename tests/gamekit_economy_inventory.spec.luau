--!strict
-- GameKit/ItemDefs and GameKit/Inventory: definition validation, stacks, instances with uids,
-- equip slots, capacity, weight, unique items, paid origin, atomic apply (a failing op leaves
-- the inventory untouched), two-phase commit and rollback, store durability and loading repairs.
local Check = require("../packages/GameKit/Check")
local Inventory = require("../packages/GameKit/Inventory")
local ItemDefs = require("../packages/GameKit/ItemDefs")
local Rng = require("../packages/ProcGen/Rng")
local FakeEconomyStore = require("./fakes/FakeEconomyStore")
local FakeEnv = require("./fakes/FakeEnv")

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

local DEFS = {
	{
		id = "material_a",
		kind = "material",
		stackable = true,
		maxStack = 10,
		tags = { "craft" },
		weight = 0.5,
	},
	{ id = "material_b", kind = "material", stackable = true, maxStack = 3, weight = 1 },
	{ id = "follower_a", kind = "follower", stackable = false, maxStack = 1, slot = "slot_a", weight = 2 },
	{ id = "gear_a", kind = "gear", stackable = false, maxStack = 1, slot = "slot_b" },
	{ id = "token_a", kind = "token", stackable = false, maxStack = 1, unique = true },
	{ id = "bound_a", kind = "token", stackable = true, maxStack = 5, tradable = false },
	{ id = "premium_a", kind = "material", stackable = true, maxStack = 5, paid = true },
}

local function registry()
	return ItemDefs.registry(DEFS)
end

local function make(extra: { [string]: any }?): any
	local options: any = {
		items = registry(),
		owner = "p1",
		capacity = 6,
		equipSlots = { "slot_a", "slot_b" },
	}
	for key, value in extra or {} do
		options[key] = value
	end
	return Inventory.new(options, FakeEnv.new())
end

-- ---------------------------------------------------------------- ItemDefs

test("ItemDefs.validate names every broken field", function(t)
	t.eq(ItemDefs.validate(DEFS), {})
	t.ok(contains(ItemDefs.validate("x"), "must be a list"))
	local problems = ItemDefs.validate({
		{ id = "Bad", kind = "k", stackable = true, maxStack = 1 },
		{ id = "a", kind = "k", stackable = "yes", maxStack = 0 },
		{ id = "b", kind = "k", stackable = false, maxStack = 2 },
		{ id = "c", kind = "k", stackable = true, maxStack = 5, slot = "slot_a" },
		{ id = "d", kind = "k", stackable = true, maxStack = 1, weight = -1 },
		{ id = "e", kind = "k", stackable = true, maxStack = 4, unique = true },
		{ id = "f", kind = "k", stackable = true, maxStack = 1, data = { colour = {} } },
		{ id = "g", kind = "k", stackable = true, maxStack = 1, tags = { "x", "x" } },
		{ id = "g", kind = "k", stackable = true, maxStack = 1, price = 5 },
		{ id = "h", kind = "Kind", stackable = true, maxStack = 1, tradable = 1 },
	})
	for _, needle in
		{
			'item Bad: id "Bad" is not a label',
			"item a: stackable must be a boolean",
			"item a: maxStack must be an integer >= 1",
			"item b: a non-stackable item has maxStack 1",
			"item c: an equippable item (slot) must be non-stackable",
			"item d: weight must be a finite number >= 0",
			"item e: a unique item has maxStack 1",
			"item f: data.colour must be a string",
			"item g: duplicate tag x",
			"item g: duplicate id (also item #8)",
			'item g: unknown key "price"',
			'item h: kind "Kind" is not a label',
			"item h: tradable must be a boolean",
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
end)

test("ItemDefs.registry fills defaults, freezes and lists by tag", function(t)
	local items = registry()
	local def = assert(items:get("material_a"))
	t.eq(def.unique, false)
	t.eq(def.tradable, true)
	t.eq(assert(items:get("bound_a")).tradable, false)
	t.eq(assert(items:get("gear_a")).weight, 0)
	t.ok(table.isfrozen(def) and table.isfrozen(def.tags))
	t.eq(#items:list(), 7)
	t.eq(items:list("craft")[1].id, "material_a")
	t.ok(items:has("gear_a") and not items:has("nope"))
	t.eq(items:count(), 7)
	t.throws(function()
		ItemDefs.registry({ { id = "x" } })
	end)
	t.ok(ItemDefs.isRegistry(items) and not ItemDefs.isRegistry({}))
end)

-- ---------------------------------------------------------------- Inventory basics

test("Inventory.new refuses bad options", function(t)
	t.throws(function()
		Inventory.new({ items = {}, owner = "p", capacity = 1 } :: any)
	end)
	t.throws(function()
		Inventory.new({ items = registry(), owner = "has space", capacity = 1 } :: any)
	end)
	t.throws(function()
		Inventory.new({ items = registry(), owner = "p", capacity = 0 } :: any)
	end)
	t.throws(function()
		Inventory.new({ items = registry(), owner = "p", capacity = 1, equipSlots = { "a", "a" } } :: any)
	end)
	t.throws(function()
		Inventory.new({ items = registry(), owner = string.rep("p", 49), capacity = 1 } :: any)
	end)
end)

test("stackable adds fill existing stacks before opening new ones", function(t)
	local inv = make()
	t.ok((inv:add("material_a", 7)))
	t.ok((inv:add("material_a", 7)))
	local entries = inv:entries()
	t.eq(#entries, 2)
	t.eq({ entries[1].count, entries[2].count }, { 10, 4 })
	t.eq(inv:count("material_a"), 14)
	t.ok((inv:remove("material_a", 5)))
	t.eq(inv:count("material_a"), 9, "removes newest first")
	t.eq(#inv:entries(), 1)
	t.eq(inv:weight(), 4.5)
end)

test("instances get owner-prefixed uids and keep their data", function(t)
	local inv = make()
	local ok, err, info = inv:add("follower_a", 2, { level = 1 })
	t.ok(ok, err)
	t.eq(info.created, { "p1-1", "p1-2" })
	t.eq(assert(inv:get("p1-2")).data, { level = 1 })
	t.ok((inv:apply({ { op = "set_data", uid = "p1-2", data = { level = 2, tags = { "a" } } } })))
	t.eq(assert(inv:get("p1-2")).data.level, 2)
	t.eq(assert(inv:get("p1-1")).data.level, 1, "data is copied per instance")
	t.eq(
		select(2, inv:apply({ { op = "add", instance = { uid = "p1-1", item = "follower_a" } } })),
		"duplicate_uid"
	)
	t.ok((inv:apply({ { op = "remove", uid = "p1-1" } })))
	t.ok((inv:add("follower_a")))
	t.ok(inv:get("p1-3") ~= nil and inv:get("p1-1") == nil, "uids are never reused")
	t.eq(select(2, inv:apply({ { op = "add", item = "material_a", data = { x = 1 } } })), "invalid_data")
	t.eq(
		select(2, inv:apply({ { op = "set_data", uid = "p1-2", data = { bad = function() end } } })),
		"invalid_data"
	)
end)

test("a failing op leaves the inventory, store and version untouched", function(t)
	local store = FakeEconomyStore.new()
	local inv = make({ store = store })
	inv:add("material_a", 10)
	inv:add("follower_a", 1)
	local before = inv:serialize()
	local writes, version = store.writes, inv:version()
	local ok, err, info = inv:apply({
		{ op = "remove", item = "material_a", count = 4 },
		{ op = "add", item = "follower_a", count = 1 },
		{ op = "remove", item = "material_b", count = 1 },
	})
	t.eq({ ok, err, info.index }, { false, "insufficient_items", 3 })
	t.eq(inv:serialize(), before)
	t.eq(store.writes, writes)
	t.eq(inv:version(), version)
	local cases_ = {
		{ { op = "teleport" }, "bad_op" },
		{ { op = "add", item = "nope" }, "unknown_item" },
		{ { op = "add", item = "material_a", count = 0 }, "invalid_count" },
		{ { op = "add", item = "material_a", count = 2.5 }, "invalid_count" },
		{ { op = "remove", uid = "p1-99" }, "missing_uid" },
		{ { op = "move", from = 1, to = 9 }, "bad_op" },
		{ "not a table", "bad_op" },
	}
	for _, case in cases_ do
		t.eq(select(2, inv:apply({ case[1] :: any })), case[2], case[2])
		t.eq(inv:serialize(), before)
	end
	t.eq({ inv:apply({}) }, { false, "bad_op", { index = 0 } })
end)

test("capacity counts entries and refuses growth past it, even for huge counts", function(t)
	local inv = make({ capacity = 2 })
	t.ok((inv:add("material_b", 6)))
	t.eq(select(2, inv:add("material_b", 1)), "no_space")
	t.eq(select(2, inv:add("material_b", 1e15)), "no_space", "bounded, no hang")
	t.eq(select(2, inv:add("follower_a", 1e15)), "no_space")
	t.ok((inv:apply({ { op = "remove", item = "material_b", count = 3 }, { op = "add", item = "gear_a" } })))
	t.eq(inv:free(), 0)
	inv:setCapacity(1)
	t.ok((inv:remove("material_b", 3)), "removals work while over capacity")
	t.eq(select(2, inv:add("material_b", 1)), "no_space")
end)

test("equip slots check the item's slot and protect equipped items", function(t)
	local inv = make()
	inv:add("follower_a", 2)
	inv:add("gear_a")
	inv:add("material_a", 1)
	t.eq(select(2, inv:apply({ { op = "equip", uid = "p1-1", slot = "slot_x" } })), "unknown_slot")
	t.eq(select(2, inv:apply({ { op = "equip", uid = "p1-1", slot = "slot_b" } })), "wrong_slot")
	t.eq(select(2, inv:apply({ { op = "equip", uid = "p1-9", slot = "slot_a" } })), "missing_uid")
	t.ok((inv:apply({ { op = "equip", uid = "p1-1", slot = "slot_a" } })))
	t.eq(inv:equipped("slot_a"), "p1-1")
	t.ok(inv:isEquipped("p1-1"))
	t.eq(select(2, inv:apply({ { op = "remove", uid = "p1-1" } })), "item_equipped")
	t.ok((inv:remove("follower_a", 1)), "removing by item skips equipped copies")
	t.ok(inv:get("p1-1") ~= nil and inv:get("p1-2") == nil)
	t.eq(select(2, inv:remove("follower_a", 1)), "insufficient_items")
	t.ok((inv:apply({ { op = "unequip", slot = "slot_a" } })))
	t.eq(inv:equipped(), {})
	t.ok((inv:apply({ { op = "remove", uid = "p1-1" } })))
end)

test("slot kinds let several slots hold items of one kind", function(t)
	local inv = make({ equipSlots = { pet_1 = "slot_a", pet_2 = "slot_a", hand = "slot_b" }, capacity = 8 })
	inv:add("follower_a", 3)
	inv:add("gear_a")
	t.ok((inv:apply({
		{ op = "equip", uid = "p1-1", slot = "pet_1" },
		{ op = "equip", uid = "p1-2", slot = "pet_2" },
		{ op = "equip", uid = "p1-4", slot = "hand" },
	})))
	t.eq(inv:equipped(), { pet_1 = "p1-1", pet_2 = "p1-2", hand = "p1-4" })
	t.eq(select(2, inv:apply({ { op = "equip", uid = "p1-3", slot = "hand" } })), "wrong_slot")
	t.eq(select(2, inv:apply({ { op = "equip", uid = "p1-3", slot = "slot_a" } })), "unknown_slot")
	t.ok((inv:apply({ { op = "equip", uid = "p1-1", slot = "pet_2" } })), "moving a uid frees its old slot")
	t.eq(inv:equipped(), { pet_2 = "p1-1", hand = "p1-4" })
	local reloaded = make({
		equipSlots = { pet_1 = "slot_a", pet_2 = "slot_a", hand = "slot_b" },
		capacity = 8,
		data = inv:serialize(),
	})
	t.eq(reloaded:equipped(), { pet_2 = "p1-1", hand = "p1-4" })
	t.eq(reloaded.notes, {})
	t.throws(function()
		make({ equipSlots = { pet_1 = 3 } })
	end)
	t.throws(function()
		make({ equipSlots = "slot_a" })
	end)
end)

test("weight and unique limits", function(t)
	local inv = make({ maxWeight = 5 })
	t.ok((inv:add("follower_a", 2)))
	t.eq(select(2, inv:add("material_b", 2)), "over_weight")
	t.ok((inv:add("material_b", 1)))
	t.ok((inv:add("token_a")))
	t.eq(select(2, inv:add("token_a")), "unique_item")
	t.eq(inv:count("token_a"), 1)
end)

test("paid copies never merge with earned ones and can be counted apart", function(t)
	local inv = make()
	inv:add("material_a", 3)
	t.ok((inv:apply({ { op = "add", item = "material_a", count = 2, paid = true } })))
	t.ok((inv:add("premium_a", 1)), "def.paid marks every copy")
	t.eq(#inv:entries(), 3)
	t.eq(inv:count("material_a", true), 2)
	t.eq(inv:count("material_a", false), 3)
	t.eq(inv:count("premium_a", true), 1)
	t.ok((inv:apply({ { op = "remove", item = "material_a", count = 3, paid = false } })))
	t.eq(inv:count("material_a"), 2)
	t.eq(
		select(2, inv:apply({ { op = "remove", item = "material_a", count = 1, paid = false } })),
		"insufficient_items"
	)
end)

test("move reorders entries", function(t)
	local inv = make()
	inv:add("material_a", 1)
	inv:add("gear_a")
	inv:add("material_b", 1)
	t.ok((inv:apply({ { op = "move", from = 3, to = 1 } })))
	local order = {}
	for _, entry in inv:entries() do
		table.insert(order, entry.item)
	end
	t.eq(order, { "material_b", "material_a", "gear_a" })
end)

test("prepare, commit and rollback are version checked", function(t)
	local inv = make()
	inv:add("material_a", 2)
	local tx = assert(inv:prepare({ { op = "remove", item = "material_a", count = 2 } }))
	local other = assert(inv:prepare({ { op = "add", item = "gear_a" } }))
	t.ok((inv:commit(other)))
	t.eq({ inv:commit(tx) }, { false, "stale" })
	t.eq({ inv:commit(other) }, { false, "invalid_tx" })
	local undo = assert(inv:prepare({ { op = "remove", item = "material_a", count = 1 } }))
	t.ok((inv:commit(undo)))
	t.ok((inv:rollback(undo)))
	t.eq(inv:count("material_a"), 2)
	t.eq({ inv:rollback(undo) }, { false, "not_committed" })
	local late = assert(inv:prepare({ { op = "remove", item = "material_a", count = 1 } }))
	t.ok((inv:commit(late)))
	inv:add("material_b", 1)
	t.eq({ inv:rollback(late) }, { false, "stale" })
	t.ok(inv:canApply({ { op = "add", item = "material_b" } }))
end)

test("store failure restores state; a reload round-trips everything", function(t)
	local store = FakeEconomyStore.new()
	local inv = make({ store = store })
	inv:add("follower_a", 1, { level = 3 })
	inv:apply({ { op = "equip", uid = "p1-1", slot = "slot_a" } })
	inv:add("material_a", 4)
	store:failSet(1)
	t.eq(select(2, inv:add("gear_a")), "store_failed")
	t.eq(inv:count("gear_a"), 0)
	local again = make({ store = store })
	t.eq(again:serialize(), inv:serialize())
	t.eq(again:equipped("slot_a"), "p1-1")
	t.eq(again.notes, {})
	again:add("follower_a")
	t.ok(again:get("p1-2") ~= nil)
end)

test("loading quarantines retired items, broken entries and duplicate uids", function(t)
	local inv = make({
		data = {
			schema = "inventory/1",
			nextUid = 2,
			entries = {
				{ item = "follower_a", count = 1, uid = "p1-5" },
				{ item = "follower_a", count = 1, uid = "p1-5" },
				{ item = "retired_item", count = 4 },
				{ item = "material_a", count = 0 },
				{ item = "material_b", count = 9 },
				{ item = "material_a", count = 2, uid = "p1-7" },
				{ item = "gear_a", count = 1 },
				"junk",
				{ item = "material_a", count = 3 },
			},
			equipped = { slot_a = "p1-5", slot_b = "p1-404", slot_z = "p1-5" },
		},
	})
	t.eq(#inv:entries(), 2)
	t.eq(#inv:quarantine(), 7)
	t.ok(contains(inv.notes, "duplicates uid p1-5"))
	t.ok(contains(inv.notes, 'names retired item "retired_item"'))
	t.ok(contains(inv.notes, "invalid count"))
	t.ok(contains(inv.notes, "exceeds maxStack"))
	t.ok(contains(inv.notes, "stack with a uid"))
	t.ok(contains(inv.notes, "instance without a valid uid"))
	t.ok(contains(inv.notes, "nextUid repaired past p1-5"))
	t.ok(contains(inv.notes, 'equipped "slot_b" dropped'))
	t.eq(inv:equipped("slot_a"), "p1-5")
	inv:add("follower_a")
	t.ok(inv:get("p1-6") ~= nil, "no uid reuse after repair")
	t.eq(#inv:serialize().quarantine, 7, "quarantine persists")
	local wrong = make({ data = { schema = "other" } })
	t.ok(contains(wrong.notes, "not inventory/1"))
	t.eq(#wrong:quarantine(), 1)
end)

test("seeded random op batches keep invariants and failed batches change nothing", function(t)
	local rng = Rng.new("inventory-fuzz")
	local inv = make({ capacity = 8, maxWeight = 30 })
	local items = { "material_a", "material_b", "follower_a", "gear_a", "token_a" }
	local applied, refused = 0, 0
	for _ = 1, 400 do
		local ops = {}
		for _ = 1, rng:int(1, 4) do
			local item = rng:pick(items)
			local roll = rng:int(1, 6)
			if roll <= 3 then
				table.insert(ops, { op = "add", item = item, count = rng:int(1, 4) })
			elseif roll <= 5 then
				table.insert(ops, { op = "remove", item = item, count = rng:int(1, 3) })
			else
				local entries = inv:entries()
				local entry = entries[rng:int(1, math.max(#entries, 1))]
				if entry and entry.uid then
					table.insert(ops, { op = "equip", uid = entry.uid, slot = "slot_a" })
				else
					table.insert(ops, { op = "move", from = 1, to = 1 })
				end
			end
		end
		local before = inv:serialize()
		local ok = inv:apply(ops)
		if ok then
			applied += 1
		else
			refused += 1
			t.eq(inv:serialize(), before, "refused batch changed state")
		end
		local entries = inv:entries()
		t.ok(#entries <= 8, "capacity")
		t.ok(inv:weight() <= 30 + 1e-9, "weight")
		local uids = {}
		for _, entry in entries do
			local def = assert(registry():get(entry.item))
			t.ok(entry.count >= 1 and entry.count <= def.maxStack and Check.integer(entry.count))
			if entry.uid then
				t.ok(not uids[entry.uid], "unique uid")
				uids[entry.uid] = true
			end
		end
		t.ok(inv:count("token_a") <= 1)
	end
	t.ok(applied > 50 and refused > 50, string.format("applied %d refused %d", applied, refused))
end)

return cases
