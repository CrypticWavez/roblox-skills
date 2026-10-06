--!strict
-- GameKit/Trade: escrow state machine, revision-checked accepts, countdown, any change resetting
-- both confirmations, two-phase commit across inventories and wallets with rollback on injected
-- failures, idempotent commit (same object and journal), policy gating of paid items, the
-- one-trade-per-player book, and a seeded multi-trade fuzz proving conservation (no dupes).
local Events = require("../packages/GameKit/Events")
local Inventory = require("../packages/GameKit/Inventory")
local ItemDefs = require("../packages/GameKit/ItemDefs")
local Rng = require("../packages/ProcGen/Rng")
local Trade = require("../packages/GameKit/Trade")
local Wallet = require("../packages/GameKit/Wallet")
local FakeEconomyStore = require("./fakes/FakeEconomyStore")
local FakeEnv = require("./fakes/FakeEnv")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local ITEMS = ItemDefs.registry({
	{ id = "material_a", kind = "material", stackable = true, maxStack = 50 },
	{ id = "follower_a", kind = "follower", stackable = false, maxStack = 1, slot = "slot_a" },
	{ id = "bound_a", kind = "material", stackable = true, maxStack = 10, tradable = false },
	{ id = "premium_a", kind = "material", stackable = true, maxStack = 10, paid = true },
})

type Player = { key: string, inventory: any, wallet: any, store: any, policyAllows: any }

local function player(key: string, sink: any?, env: any?, capacity: number?): Player
	local store = FakeEconomyStore.new()
	local inventory = Inventory.new({
		items = ITEMS,
		owner = key,
		capacity = capacity or 10,
		equipSlots = { "slot_a" },
		store = store,
	}, env)
	local wallet = Wallet.new({
		currencies = { currency_a = {}, currency_b = {} },
		sink = sink,
		player = key,
		store = store,
	}, env)
	return {
		key = key,
		inventory = inventory,
		wallet = wallet,
		store = store,
		policyAllows = FakeEconomyStore.policy({ "trading" }),
	}
end

local function setup(options: { [string]: any }?): (any, Player, Player, any, any)
	local env = FakeEnv.new({ start = 100 })
	local sink = Events.recorder({ clock = env.clock })
	local a = player("pa", sink, env)
	local b = player("pb", sink, env)
	a.inventory:add("material_a", 20)
	a.inventory:add("follower_a", 1, { level = 4 })
	a.wallet:credit("currency_a", 100, "Gameplay")
	b.inventory:add("material_a", 5)
	b.wallet:credit("currency_a", 50, "Gameplay")
	sink:clear()
	local tradeOptions: any = {
		id = "trade_1",
		a = a,
		b = b,
		countdown = 3,
		currencies = { "currency_a" },
		sink = sink,
	}
	for key, value in options or {} do
		tradeOptions[key] = value
	end
	return Trade.new(tradeOptions, env), a, b, env, sink
end

local function snapshot(p: Player): any
	return { inventory = p.inventory:serialize(), wallet = p.wallet:serialize() }
end

test("Trade.new refuses bad parties, self trades and bad timings", function(t)
	local a = player("pa")
	local b = player("pb")
	t.throws(function()
		Trade.new({ id = "x", a = a, b = a } :: any)
	end)
	t.throws(function()
		Trade.new({ id = "bad id", a = a, b = b } :: any)
	end)
	t.throws(function()
		Trade.new({ id = "x", a = a, b = { key = "pc", inventory = a.inventory } } :: any)
	end)
	t.throws(function()
		Trade.new({ id = "x", a = a, b = b, countdown = -1 } :: any)
	end)
	t.throws(function()
		Trade.new({ id = "x", a = a, b = { key = "pc" } } :: any)
	end)
	t.eq(Trade.new({ id = "x", a = a, b = b }):serialize(), "fsm/1:trade:proposed")
end)

test("the happy path moves instances, stacks and currency and reports only after commit", function(t)
	local trade, a, b, env, sink = setup()
	local uid = a.inventory:entries()[2].uid
	t.ok((trade:addInstance("a", uid)))
	t.ok((trade:addStack("a", "material_a", 12)))
	t.ok((trade:setCurrency("b", "currency_a", 30)))
	t.eq(trade:revision(), 3)
	t.ok((trade:accept("a", 3)))
	t.eq(trade:state(), "proposed")
	t.ok((trade:accept("b", 3)))
	t.eq(trade:state(), "locked")
	t.eq(trade:countdownLeft(), 3)
	t.eq({ trade:confirm("a") }, { false, "countdown" })
	env:advance(3)
	t.ok((trade:confirm("a")))
	t.eq(sink:count("economy"), 0, "nothing reported before commit")
	t.ok((trade:confirm("b")))
	t.eq(trade:state(), "committed")
	t.eq(trade:serialize(), "fsm/1:trade:committed")
	t.eq(a.inventory:count("material_a"), 8)
	t.eq(b.inventory:count("material_a"), 17)
	t.eq(a.inventory:get(uid), nil)
	local moved = assert(b.inventory:get(uid))
	t.eq(moved.data, { level = 4 }, "instance data travels with the uid")
	t.eq({ a.wallet:balance("currency_a"), b.wallet:balance("currency_a") }, { 130, 20 })
	t.eq(sink:count("economy"), 2)
	t.eq(sink:named("trade_committed")[1].event_id, "trade_1")
	for _, event in sink.events do
		t.eq(Events.validate(event), {})
		if event.economy then
			t.eq(event.economy.transaction_type, "trade")
		end
	end
	t.ok(a.store.data.inventory ~= nil and b.store.data.wallet.balances.currency_a == 20, "persisted")
end)

test("any change clears both accepts and confirmations and unlocks a locked trade", function(t)
	local trade, _a, _b, env = setup({ autoCommit = false })
	trade:addStack("a", "material_a", 2)
	trade:accept("a", 1)
	trade:accept("b", 1)
	t.eq(trade:state(), "locked")
	env:advance(5)
	t.ok((trade:confirm("a")))
	t.ok((trade:setCurrency("b", "currency_a", 1)))
	t.eq(trade:state(), "proposed")
	local view = trade:view()
	t.eq(view.accepted, { a = false, b = false })
	t.eq(view.confirmed, { a = false, b = false })
	t.eq(view.revision, 2)
	t.eq({ trade:accept("a", 1) }, { false, "stale_offer" }, "accept names the revision the player saw")
	t.ok((trade:accept("a", 2)))
	t.ok((trade:accept("b", 2)))
	t.eq(trade:countdownLeft(), 3, "the countdown restarts")
	t.ok((trade:unaccept("b")))
	t.eq(trade:state(), "proposed")
	t.eq(trade:view().accepted, { a = true, b = false })
	t.eq({ trade:confirm("a") }, { false, "proposed" })
	t.eq({ trade:accept("c", 2) }, { false, "bad_side" })
end)

test("a double commit is a no-op, also through a journal on a new trade object", function(t)
	local journal = FakeEconomyStore.new()
	local trade, a, b, env = setup({ autoCommit = false, journal = journal })
	trade:addStack("a", "material_a", 5)
	trade:accept("a", 1)
	trade:accept("b", 1)
	env:advance(3)
	trade:confirm("a")
	t.ok((trade:confirm("b")))
	t.eq(trade:state(), "confirmed")
	t.eq({ trade:commit() }, { true, nil })
	local after = { snapshot(a), snapshot(b) }
	t.eq({ trade:commit() }, { true, "already_committed" })
	t.eq({ snapshot(a), snapshot(b) }, after)
	t.eq(journal.data["trade:trade_1"].state, "committed")
	local replay =
		Trade.new({ id = "trade_1", a = a, b = b, journal = journal, currencies = { "currency_a" } }, env)
	t.eq(replay:state(), "committed", "the journal marks a replayed id committed")
	t.eq({ replay:commit() }, { true, "already_committed" })
	t.eq({ replay:addStack("a", "material_a", 1) }, { false, "committed" })
	t.eq({ snapshot(a), snapshot(b) }, after, "nothing applied twice")
end)

test("a failing participant mid-commit rolls everything back with no events", function(t)
	local trade, a, b, env, sink = setup()
	local before = { snapshot(a), snapshot(b) }
	local uid = a.inventory:entries()[2].uid
	trade:addInstance("a", uid)
	trade:setCurrency("a", "currency_a", 40)
	trade:setCurrency("b", "currency_a", 10)
	trade:accept("a", 3)
	trade:accept("b", 3)
	env:advance(3)
	trade:confirm("a")
	-- The last participant (wallet b) fails its durable write.
	b.store:failSetWhen(function(key: string): boolean
		return key == "wallet"
	end)
	t.eq({ trade:confirm("b") }, { false, "commit_failed" })
	b.store:failSetWhen(nil)
	t.eq(trade:state(), "cancelled")
	t.eq(trade:reason(), "commit_failed")
	t.eq({ snapshot(a), snapshot(b) }, before, "both sides exactly as before")
	t.eq(a.store.data.inventory, before[1].inventory, "the store holds the pre-trade state")
	t.eq(sink:count("economy"), 0)
	t.eq(#sink:named("trade_cancelled"), 1)
	t.ok(string.find(table.concat(env.reports, "\n"), "rolling back", 1, true) ~= nil)
end)

test("a failing journal write rolls the trade back", function(t)
	local journal = FakeEconomyStore.new()
	local trade, a, b, env = setup({ journal = journal })
	local before = { snapshot(a), snapshot(b) }
	trade:addStack("a", "material_a", 3)
	trade:setCurrency("b", "currency_a", 5)
	trade:accept("a", 2)
	trade:accept("b", 2)
	env:advance(3)
	trade:confirm("a")
	journal:failSet(1)
	t.eq({ trade:confirm("b") }, { false, "journal_failed" })
	t.eq({ snapshot(a), snapshot(b) }, before)
	t.eq(journal.data["trade:trade_1"], nil)
end)

test("concurrent trades over the same item cannot duplicate it", function(t)
	local env = FakeEnv.new()
	local a, b, c = player("pa", nil, env), player("pb", nil, env), player("pc", nil, env)
	a.inventory:add("follower_a", 1)
	local uid = a.inventory:entries()[1].uid
	local first = Trade.new({ id = "t1", a = a, b = b, countdown = 0 }, env)
	local second = Trade.new({ id = "t2", a = a, b = c, countdown = 0 }, env)
	t.ok((first:addInstance("a", uid)))
	t.ok((second:addInstance("a", uid)))
	for _, trade in { first, second } do
		trade:accept("a", 1)
		trade:accept("b", 1)
		trade:confirm("a")
	end
	t.ok((first:confirm("b")))
	t.eq({ second:confirm("b") }, { false, "offer_unavailable" })
	t.eq(second:state(), "cancelled")
	local holders = 0
	for _, p in { a, b, c } do
		if p.inventory:get(uid) then
			holders += 1
		end
	end
	t.eq(holders, 1)
	t.ok(b.inventory:get(uid) ~= nil)
end)

test("the book allows one open trade per player and frees it when the trade ends", function(t)
	local env = FakeEnv.new()
	local a, b, c = player("pa", nil, env), player("pb", nil, env), player("pc", nil, env)
	local book = Trade.book()
	local first = assert(book:open({ id = "t1", a = a, b = b }, env))
	t.eq({ book:open({ id = "t2", a = c, b = a }, env) }, { nil, "party_busy" })
	t.ok(book:active("pb") == first)
	first:cancel("player_left")
	t.eq(first:reason(), "player_left")
	t.eq(book:active("pa"), nil)
	t.ok(book:open({ id = "t2", a = c, b = a }, env) ~= nil)
end)

test("paid items need both players' trading policy, checked again at commit", function(t)
	local trade, a, b, env = setup()
	a.inventory:add("premium_a", 2)
	b.policyAllows = FakeEconomyStore.policy({})
	t.eq({ trade:addStack("a", "premium_a", 1) }, { false, "policy_denied" })
	t.eq(trade:revision(), 0, "a refused change changes nothing")
	b.policyAllows = function(): boolean
		error("policy service down")
	end
	t.eq({ trade:addStack("a", "premium_a", 1) }, { false, "policy_denied" }, "errors fail closed")
	b.policyAllows = true
	t.ok((trade:addStack("a", "premium_a", 1)))
	trade:accept("a", 1)
	trade:accept("b", 1)
	env:advance(3)
	trade:confirm("a")
	a.policyAllows = false
	t.eq({ trade:confirm("b") }, { false, "policy_denied" })
	t.eq(a.inventory:count("premium_a"), 2)
	t.eq(b.inventory:count("premium_a"), 0)
	local paidInstance, a2, b2 = setup()
	a2.inventory:apply({ { op = "add", item = "follower_a", paid = true } })
	b2.policyAllows = nil
	local uid = a2.inventory:entries()[#a2.inventory:entries()].uid
	t.eq({ paidInstance:addInstance("a", uid) }, { false, "policy_denied" }, "instance paid origin counts")
end)

test("offers are checked against holdings, tradability, equip state, currencies and limits", function(t)
	local trade, a = setup({ maxEntries = 2 })
	a.inventory:add("bound_a", 2)
	local uid = a.inventory:entries()[2].uid
	a.inventory:apply({ { op = "equip", uid = uid, slot = "slot_a" } })
	t.eq({ trade:addStack("a", "material_a", 21) }, { false, "missing_item" })
	t.eq({ trade:addStack("a", "bound_a", 1) }, { false, "untradable" })
	t.eq({ trade:addInstance("a", uid) }, { false, "item_equipped" })
	t.eq({ trade:addInstance("a", "pa-99") }, { false, "missing_item" })
	t.eq({ trade:addStack("a", "follower_a", 1) }, { false, "bad_offer" })
	t.eq({ trade:setCurrency("a", "currency_b", 1) }, { false, "currency_not_tradable" })
	t.eq({ trade:setCurrency("a", "currency_a", 101) }, { false, "insufficient_funds" })
	t.eq({ trade:setCurrency("a", "currency_a", 1.5) }, { false, "bad_offer" })
	t.eq({ trade:setOffer("a", { instances = { "pa-1", "pa-1" } }) }, { false, "duplicate_entry" })
	t.ok((trade:addStack("a", "material_a", 1)))
	t.ok((trade:setCurrency("a", "currency_a", 1)))
	t.eq({ trade:addStack("a", "material_a", 1, true) }, { false, "too_many_entries" })
	t.ok((trade:setCurrency("a", "currency_a", 0)), "0 removes the currency entry")
	t.eq(trade:offer("a").currency, {})
	t.eq({ trade:removeInstance("a", "pa-77") }, { false, "not_offered" })
	t.eq({ trade:setOffer("x", {}) }, { false, "bad_side" })
end)

test("accept refuses to lock a trade the receiver cannot hold", function(t)
	local env = FakeEnv.new()
	local a = player("pa", nil, env)
	local b = player("pb", nil, env, 1)
	a.inventory:add("follower_a", 2)
	b.inventory:add("material_a", 1)
	local trade = Trade.new({ id = "t1", a = a, b = b }, env)
	for _, entry in a.inventory:entries() do
		trade:addInstance("a", entry.uid :: string)
	end
	trade:accept("a", 2)
	t.eq({ trade:accept("b", 2) }, { false, "no_space_b" })
	t.eq(trade:state(), "proposed")
	t.eq(trade:view().accepted, { a = false, b = false })
end)

test("tick expires idle trades and auto-confirms after the countdown", function(t)
	local trade, _a, b, env = setup({ expireSeconds = 30 })
	trade:addStack("a", "material_a", 1)
	env:advance(29)
	t.eq(trade:tick(), "proposed")
	env:advance(1)
	t.eq(trade:tick(), "cancelled")
	t.eq(trade:reason(), "expired")
	t.eq({ trade:cancel() }, { false, "cancelled" })
	local auto, _a2, b2, env2 = setup({ autoConfirm = true, id = "trade_2" })
	auto:addStack("a", "material_a", 1)
	auto:accept("a", 1)
	auto:accept("b", 1)
	env2:advance(2)
	t.eq(auto:tick(), "locked")
	env2:advance(1)
	t.eq(auto:tick(), "committed")
	t.eq(b2.inventory:count("material_a"), 6)
	t.eq(b.inventory:count("material_a"), 5, "the expired trade moved nothing")
end)

test("seeded multi-trade fuzz conserves every item, uid and coin under injected failures", function(t)
	local env = FakeEnv.new()
	local rng = Rng.new("trade-fuzz")
	local players: { Player } = {}
	for index = 1, 4 do
		local p = player("p" .. index, nil, env, 12)
		p.inventory:add("material_a", 30)
		p.inventory:add("follower_a", 3)
		p.wallet:credit("currency_a", 500, "Gameplay")
		table.insert(players, p)
	end
	local function totals(): (number, number, number)
		local material, coins, followers = 0, 0, 0
		local uids = {}
		for _, p in players do
			material += p.inventory:count("material_a")
			coins += p.wallet:balance("currency_a")
			for _, entry in p.inventory:entries() do
				if entry.uid then
					assert(not uids[entry.uid], "duplicate uid " .. entry.uid)
					uids[entry.uid] = true
					followers += 1
				end
			end
		end
		return material, coins, followers
	end
	local m0, c0, f0 = totals()
	local committed, cancelled, injected = 0, 0, 0
	local open = {}
	for round = 1, 400 do
		if #open < 5 and rng:chance(0.6) then
			local i = rng:int(1, 4)
			local j = rng:int(1, 3)
			if j >= i then
				j += 1
			end
			local trade = Trade.new({
				id = "fuzz_" .. round,
				a = players[i],
				b = players[j],
				countdown = 0,
				currencies = { "currency_a" },
			}, env)
			for _, side in { "a", "b" } do
				local p = if side == "a" then players[i] else players[j]
				local entries = p.inventory:entries()
				local pick = entries[rng:int(1, #entries)]
				if pick and pick.uid and rng:chance(0.6) then
					trade:addInstance(side, pick.uid)
				end
				if rng:chance(0.7) then
					trade:addStack(side, "material_a", rng:int(1, 30))
				end
				if rng:chance(0.6) then
					trade:setCurrency(side, "currency_a", rng:int(1, 400))
				end
			end
			table.insert(open, trade)
		end
		if #open > 0 then
			local index = rng:int(1, #open)
			local trade = open[index]
			local revision = trade:revision()
			trade:accept("a", revision)
			trade:accept("b", revision)
			trade:confirm("a")
			local victim = nil
			if trade:state() == "locked" and rng:chance(0.25) then
				-- A durable write fails somewhere in the commit: rollback must restore everything.
				victim = players[rng:int(1, 4)]
				victim.store:failSet(1)
				injected += 1
			end
			trade:confirm("b")
			if victim then
				victim.store:failSet(0)
			end
			if trade:state() == "committed" then
				committed += 1
			else
				trade:cancel("fuzz")
				cancelled += 1
			end
			table.remove(open, index)
		end
		local m, c, f = totals()
		t.eq({ m, c, f }, { m0, c0, f0 }, "round " .. round)
	end
	t.ok(
		committed > 30 and cancelled > 10 and injected > 10,
		string.format("committed %d cancelled %d injected %d", committed, cancelled, injected)
	)
	for _, p in players do
		local again = Inventory.new({
			items = ITEMS,
			owner = p.key,
			capacity = 12,
			equipSlots = { "slot_a" },
			store = p.store,
		})
		t.eq(again:serialize(), p.inventory:serialize(), p.key .. " store matches memory")
		local wallet = Wallet.new({ currencies = { currency_a = {}, currency_b = {} }, store = p.store })
		t.eq(wallet:balances(), p.wallet:balances(), p.key .. " wallet store matches memory")
	end
end)

return cases
