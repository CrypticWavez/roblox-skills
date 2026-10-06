--!strict
-- GameKit/UnlockGraph: validation (unknown requirements, cycles, unreachable nodes), stable
-- topological order, atomic paid unlocks through Wallet, retry safety and load repair.
local Events = require("../packages/GameKit/Events")
local UnlockGraph = require("../packages/GameKit/UnlockGraph")
local Wallet = require("../packages/GameKit/Wallet")

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

local function nodes(): { any }
	return {
		{ id = "node_a" },
		{ id = "node_b", requires = { "node_a" }, cost = { currency_a = 10 } },
		{ id = "node_c", requires = { "node_a" }, cost = { currency_a = 5, currency_b = 2 } },
		{ id = "node_d", requires = { "node_b", "node_c" }, cost = { currency_a = 20 }, data = { slot = 1 } },
		{ id = "node_e", requires = { "node_b", "node_c" }, mode = "any" },
	}
end

local function wallet(balances: { [string]: number }): any
	return Wallet.new({
		currencies = { currency_a = {}, currency_b = {} },
		data = { schema = "wallet/1", balances = balances, recent = {} },
	})
end

test("a valid graph defines with roots and a stable topological order", function(t)
	t.eq(UnlockGraph.validate(nodes()), {})
	local spec = UnlockGraph.define(nodes())
	t.eq(spec.roots, { "node_a" })
	t.eq(spec.order, { "node_a", "node_b", "node_c", "node_d", "node_e" })
	t.ok(table.isfrozen(spec))
	-- Declaration order does not leak requirements: a dependent declared first still sorts after.
	local shuffled = nodes()
	shuffled[1], shuffled[4] = shuffled[4], shuffled[1]
	t.eq(UnlockGraph.define(shuffled).order, { "node_a", "node_b", "node_c", "node_d", "node_e" })
end)

test("unknown requirements, self requirements, cycles and unreachable nodes are rejected", function(t)
	local unknown = nodes()
	unknown[2].requires = { "node_z" }
	t.ok(contains(UnlockGraph.validate(unknown), "node node_b: requires unknown node"))
	local selfReq = nodes()
	selfReq[3].requires = { "node_c" }
	t.ok(contains(UnlockGraph.validate(selfReq), "node node_c: requires itself"))
	local cycle = {
		{ id = "node_a" },
		{ id = "node_b", requires = { "node_a", "node_d" } },
		{ id = "node_c", requires = { "node_b" } },
		{ id = "node_d", requires = { "node_c" } },
	}
	local problems = UnlockGraph.validate(cycle)
	t.ok(
		contains(problems, "requires cycle: node_b -> node_d -> node_c -> node_b"),
		table.concat(problems, " | ")
	)
	t.ok(contains(problems, "node node_b can never unlock from the start nodes"))
	local noRoot = { { id = "node_a", requires = { "node_b" } }, { id = "node_b", requires = { "node_a" } } }
	t.ok(contains(UnlockGraph.validate(noRoot), "no start node"))
	t.throws(function()
		UnlockGraph.define(cycle)
	end)
end)

test("shape problems are listed together", function(t)
	t.ok(contains(UnlockGraph.validate({}), "non-empty list"))
	local bad = nodes()
	bad[2].id = "Bad Id"
	bad[3].mode = "some"
	bad[4].cost = { currency_a = 0 }
	bad[5].price = 3
	table.insert(bad, { id = "node_a" })
	local problems = UnlockGraph.validate(bad)
	for _, needle in
		{
			"id is not a label",
			"mode must be all or any",
			'cost "currency_a" needs an integer amount >= 1',
			'unknown key "price"',
			"node node_a: duplicate id",
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
end)

test("unlocks follow requirements and charge atomically", function(t)
	local spec = UnlockGraph.define(nodes())
	local sink = Events.recorder()
	local tracker = UnlockGraph.new(spec, { sink = sink, player = "1" })
	local purse = wallet({ currency_a = 30, currency_b = 1 })
	t.eq(tracker:available(), { "node_a" })
	t.eq({ tracker:canUnlock("node_b", purse) }, { false, "locked" })
	t.eq({ tracker:unlock("node_a") }, { true, nil, nil })
	t.eq(tracker:available(), { "node_b", "node_c" })
	t.eq({ tracker:canUnlock("node_b") }, { false, "no_wallet" })
	-- node_c needs currency_b 2 (has 1): nothing is charged, including currency_a.
	t.eq({ tracker:unlock("node_c", purse) }, { false, "insufficient_funds", nil })
	t.eq(purse:balance("currency_a"), 30)
	t.eq({ tracker:unlock("node_b", purse) }, { true, nil, nil })
	t.eq(purse:balance("currency_a"), 20)
	t.eq(tracker:available(), { "node_c", "node_e" }, "mode any opens with one requirement")
	t.eq({ tracker:unlock("node_b", purse) }, { false, "already_unlocked", nil })
	t.eq({ tracker:unlock("node_z", purse) }, { false, "unknown", nil })
	t.eq({ tracker:unlock("node_d", purse) }, { false, "locked", nil })
	t.eq(tracker:progress(), { unlocked = 2, total = 5 })
	local unlocks = sink:named("unlock")
	t.eq(#unlocks, 2)
	t.eq(unlocks[2].progression.level, 2)
	t.eq(unlocks[2].fields, { node = "node_b" })
	t.eq(unlocks[2].player, "1")
	t.eq(#sink:named("wallet_debit"), 0, "the tracker's sink is not the wallet's sink")
end)

test("a retried unlock after a lost tracker save never charges twice", function(t)
	local spec = UnlockGraph.define(nodes())
	local purse = wallet({ currency_a = 100, currency_b = 10 })
	local tracker = UnlockGraph.new(spec)
	tracker:unlock("node_a")
	t.ok((tracker:unlock("node_b", purse)))
	t.eq(purse:balance("currency_a"), 90)
	-- The tracker's save was lost: reload from the state before node_b, the wallet remembers.
	local reloaded = UnlockGraph.new(spec, { data = { schema = "unlocks/1", unlocked = { "node_a" } } })
	t.eq({ reloaded:canUnlock("node_b", purse) }, { true, nil })
	t.eq({ reloaded:unlock("node_b", purse) }, { true, nil, nil })
	t.eq(purse:balance("currency_a"), 90, "paid once")
	t.ok(reloaded:isUnlocked("node_b"))
end)

test("grant skips payment but not requirements unless forced", function(t)
	local tracker = UnlockGraph.new(UnlockGraph.define(nodes()))
	t.eq({ tracker:grant("node_d") }, { false, "locked" })
	t.eq({ tracker:grant("node_d", true) }, { true, nil })
	t.eq({ tracker:grant("node_d", true) }, { false, "already_unlocked" })
	t.eq({ tracker:grant("node_q") }, { false, "unknown" })
	t.eq(tracker:unlocked(), { "node_d" })
end)

test("loading keeps purchases, drops removed ids and notes changes", function(t)
	local spec = UnlockGraph.define(nodes())
	local tracker = UnlockGraph.new(spec, {
		data = { schema = "unlocks/1", unlocked = { "node_d", "node_gone", "node_a" } },
	})
	t.eq(tracker:unlocked(), { "node_a", "node_d" })
	t.ok(contains(tracker.notes, 'unlocked id "node_gone" is no longer in the graph'))
	t.ok(contains(tracker.notes, "kept node_d although its requirements changed"))
	t.eq(tracker:serialize(), { schema = "unlocks/1", unlocked = { "node_a", "node_d" } })
	local fresh = UnlockGraph.new(spec, { data = { schema = "unlocks/0" } })
	t.eq(fresh:unlocked(), {})
	t.ok(contains(fresh.notes, "not unlocks/1"))
	t.throws(function()
		UnlockGraph.new(nodes() :: any)
	end)
end)

return cases
