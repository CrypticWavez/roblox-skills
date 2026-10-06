--!strict
-- GameKit/Wallet: integer-only balances, caps, floors, negatives, atomic multi-currency
-- transactions, transaction-id de-duplication, store durability and kit-event/1 economy events.
local Events = require("../packages/GameKit/Events")
local Wallet = require("../packages/GameKit/Wallet")
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

local function fixture(extra: { [string]: any }?): (any, any, any)
	local env = FakeEnv.new({ start = 5 })
	local sink = Events.recorder({ clock = env.clock })
	local options: any = {
		currencies = {
			currency_a = {},
			currency_b = { cap = 100 },
			currency_c = { cap = 50, overflow = "clamp" },
			currency_d = { allowNegative = true, floor = -20 },
		},
		sink = sink,
		player = "1",
	}
	for key, value in extra or {} do
		options[key] = value
	end
	return Wallet.new(options, env), sink, env
end

test("validateCurrencies lists every problem", function(t)
	t.eq(#Wallet.validateCurrencies({ currency_a = {} }), 0)
	t.ok(contains(Wallet.validateCurrencies(nil), "non-empty map"))
	t.ok(contains(Wallet.validateCurrencies({}), "non-empty map"))
	local problems = Wallet.validateCurrencies({
		Bad = {},
		currency_a = { cap = 1.5 },
		currency_b = { floor = -5 },
		currency_c = { overflow = "wrap" },
		currency_d = { cap = 10, initial = 11 },
		currency_e = { allowNegative = "yes" },
		currency_f = { colour = "x" },
		currency_g = { cap = -1 },
	})
	for _, needle in
		{
			'currency "Bad" is not a label',
			"currency_a: cap must be an integer",
			"currency_b: floor needs allowNegative",
			"currency_c: overflow must be reject or clamp",
			"currency_d: initial must be an integer from 0 to 10",
			"currency_e: allowNegative must be a boolean",
			'currency_f: unknown key "colour"',
			"currency_g: cap must be an integer",
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, "; "))
	end
end)

test("more than five reporting currencies is refused unless the rest opt out", function(t)
	local many = {}
	for index = 1, 6 do
		many["currency_" .. index] = {}
	end
	t.ok(contains(Wallet.validateCurrencies(many), "AnalyticsService tracks at most 5"))
	many.currency_6 = { report = false }
	t.eq(Wallet.validateCurrencies(many), {})
end)

test("Wallet.new raises on invalid options, sink and store", function(t)
	t.throws(function()
		Wallet.new({ currencies = {} } :: any)
	end)
	t.throws(function()
		Wallet.new({ currencies = { currency_a = {} }, sink = {} } :: any)
	end)
	t.throws(function()
		Wallet.new({ currencies = { currency_a = {} }, store = { get = true } } :: any)
	end)
	t.throws(function()
		Wallet.new({ currencies = { currency_a = {} }, player = "has space" } :: any)
	end)
end)

test("credit and debit change balances and emit valid economy events after the change", function(t)
	local wallet, sink = fixture()
	t.eq({ wallet:credit("currency_a", 25, "Gameplay") }, { true, nil, 25 })
	t.eq({ wallet:debit("currency_a", 10, "Shop", { sku = "item_a" }) }, { true, nil, 10 })
	t.eq(wallet:balance("currency_a"), 15)
	t.eq(sink:count("economy"), 2)
	local credit, debit = sink.events[1], sink.events[2]
	t.eq(credit.name, "wallet_credit")
	t.eq(credit.economy, {
		flow = "source",
		currency = "currency_a",
		amount = 25,
		balance = 25,
		transaction_type = "Gameplay",
	})
	t.eq(debit.economy.flow, "sink")
	t.eq(debit.economy.balance, 15, "ending balance")
	t.eq(debit.economy.sku, "item_a")
	t.eq(debit.player, "1")
	t.eq(debit.t, 5, "sink stamps the env clock")
	for _, event in sink.events do
		t.eq(Events.validate(event), {})
	end
	t.eq(wallet:balance("missing"), 0)
	t.ok(wallet:has("currency_a") and not wallet:has("missing"))
end)

test("a debit past the balance fails, leaves the balance and emits nothing", function(t)
	local wallet, sink = fixture()
	wallet:credit("currency_a", 5, "Gameplay")
	sink:clear()
	t.eq({ wallet:debit("currency_a", 6, "Shop") }, { false, "insufficient_funds", nil })
	t.eq(wallet:balance("currency_a"), 5)
	t.eq(sink:count(), 0)
	t.eq({ wallet:debit("currency_a", 5, "Shop") }, { true, nil, 5 })
	t.eq(wallet:balance("currency_a"), 0)
end)

test("allowNegative honours the floor and reports a non-negative balance with a sign field", function(t)
	local wallet, sink = fixture()
	t.ok((wallet:debit("currency_d", 20, "custom_sink")))
	t.eq(wallet:balance("currency_d"), -20)
	t.eq({ wallet:debit("currency_d", 1, "custom_sink") }, { false, "insufficient_funds", nil })
	local event = sink.events[1]
	t.eq(event.economy.balance, 0, "AnalyticsService needs endingBalance >= 0")
	t.eq(event.fields, { balance_sign = "negative" })
	t.eq(Events.validate(event), {})
end)

test("caps reject by default and clamp when configured", function(t)
	local wallet, sink = fixture()
	t.ok((wallet:credit("currency_b", 100, "Gameplay")))
	t.eq({ wallet:credit("currency_b", 1, "Gameplay") }, { false, "at_cap", nil })
	t.ok((wallet:debit("currency_b", 10, "Shop")))
	t.eq(
		{ wallet:credit("currency_b", 11, "Gameplay") },
		{ false, "at_cap", nil },
		"reject keeps all-or-nothing"
	)
	t.eq(wallet:balance("currency_b"), 90)
	sink:clear()
	t.eq({ wallet:credit("currency_c", 70, "Gameplay") }, { true, nil, 50 }, "clamp credits what fits")
	t.eq(sink.events[1].economy.amount, 50, "event reports the applied amount")
	t.eq({ wallet:credit("currency_c", 1, "Gameplay") }, { false, "at_cap", nil })
end)

test("amounts must be whole, positive and within 2^53", function(t)
	local wallet, sink = fixture()
	for _, bad in { 0, -1, 1.5, 0 / 0, math.huge, -math.huge, 2 ^ 53 + 2, "5" :: any, nil :: any } do
		t.eq(select(2, wallet:credit("currency_a", bad, "Gameplay")), "invalid_amount", tostring(bad))
		t.eq(select(2, wallet:debit("currency_a", bad, "Shop")), "invalid_amount", tostring(bad))
	end
	t.eq(select(2, wallet:credit("nope", 1, "Gameplay")), "unknown_currency")
	t.eq(select(2, wallet:credit("currency_a", 1, "not a label")), "invalid_reason")
	t.eq(select(2, wallet:credit("currency_a", 1, "Gameplay", { txId = "bad id!" })), "invalid_tx")
	t.ok((wallet:credit("currency_a", 2 ^ 53 - 1, "Gameplay")))
	t.eq(select(2, wallet:credit("currency_a", 2, "Gameplay")), "overflow", "beyond exact integers")
	t.eq(wallet:balance("currency_a"), 2 ^ 53 - 1)
	t.eq(sink:count(), 1)
end)

test("transact applies every change or none", function(t)
	local wallet, sink = fixture()
	wallet:credit("currency_a", 10, "Gameplay")
	wallet:credit("currency_b", 10, "Gameplay")
	sink:clear()
	local ok, err = wallet:transact({
		{ currency = "currency_a", delta = -5, reason = "Shop" },
		{ currency = "currency_b", delta = -11, reason = "Shop" },
	})
	t.eq({ ok, err }, { false, "insufficient_funds" })
	t.eq(wallet:balances(), { currency_a = 10, currency_b = 10, currency_c = 0, currency_d = 0 })
	t.eq(sink:count(), 0)
	local ok2, err2, applied = wallet:transact({
		{ currency = "currency_a", delta = -5, reason = "Shop" },
		{ currency = "currency_a", delta = 3, reason = "Gameplay" },
		{ currency = "currency_b", delta = -10, reason = "Shop" },
	})
	t.ok(ok2 and err2 == nil)
	t.eq(applied, { -5, 3, -10 })
	t.eq(wallet:balance("currency_a"), 8)
	t.eq(
		{ sink.events[1].economy.balance, sink.events[2].economy.balance, sink.events[3].economy.balance },
		{ 5, 8, 0 },
		"each event carries the running ending balance"
	)
	t.eq({ wallet:transact({}) }, { false, "invalid_amount", nil })
	t.ok(wallet:canAfford({ currency_a = 8 }) and not wallet:canAfford({ currency_a = 9 }))
	t.ok(wallet:canAfford({}))
end)

test("a repeated transaction id is a no-op that reports duplicate", function(t)
	local wallet, sink = fixture()
	t.eq({ wallet:credit("currency_a", 10, "IAP", { txId = "receipt:1" }) }, { true, nil, 10 })
	t.eq({ wallet:credit("currency_a", 10, "IAP", { txId = "receipt:1" }) }, { true, "duplicate", nil })
	t.eq(wallet:balance("currency_a"), 10)
	t.eq(sink:count(), 1)
	t.ok(wallet:seen("receipt:1"))
	local failed = wallet:debit("currency_a", 99, "Shop", { txId = "spend:1" })
	t.ok(not failed and not wallet:seen("spend:1"), "a failed tx does not burn its id")
end)

test("the id ledger is bounded and survives a store round trip", function(t)
	local store = FakeEconomyStore.new()
	local wallet = Wallet.new({ currencies = { currency_a = {} }, store = store, ledgerSize = 2 })
	for index = 1, 3 do
		wallet:credit("currency_a", 1, "Gameplay", { txId = "tx:" .. index })
	end
	t.ok(not wallet:seen("tx:1") and wallet:seen("tx:2") and wallet:seen("tx:3"))
	local again = Wallet.new({ currencies = { currency_a = {} }, store = store, ledgerSize = 2 })
	t.eq(again:balance("currency_a"), 3)
	t.eq({ again:credit("currency_a", 1, "Gameplay", { txId = "tx:3" }) }, { true, "duplicate", nil })
	t.eq(store.data.wallet.schema, "wallet/1")
end)

test("a failing store write restores the balance and emits nothing", function(t)
	local store = FakeEconomyStore.new()
	local env = FakeEnv.new()
	local sink = Events.recorder()
	local wallet = Wallet.new({ currencies = { currency_a = {} }, store = store, sink = sink }, env)
	wallet:credit("currency_a", 4, "Gameplay")
	store:failSet(1)
	t.eq({ wallet:credit("currency_a", 6, "Gameplay", { txId = "t1" }) }, { false, "store_failed", nil })
	t.eq(wallet:balance("currency_a"), 4)
	t.ok(not wallet:seen("t1"), "the id is not burnt")
	t.eq(sink:count(), 1)
	t.eq(store.data.wallet.balances.currency_a, 4)
	t.ok(contains(env.reports, "store:set failed"))
	t.ok((wallet:credit("currency_a", 6, "Gameplay", { txId = "t1" })), "the retry goes through")
	t.eq(wallet:balance("currency_a"), 10)
end)

test("loading repairs corrupt data, preserves unknown currencies and notes every repair", function(t)
	local wallet = Wallet.new({
		currencies = { currency_a = {}, currency_b = {}, currency_c = { cap = 5 } },
		data = {
			schema = "wallet/1",
			balances = { currency_a = 0 / 0, currency_b = 7.9, currency_c = 9, retired = 40, [1] = 3 },
			recent = { "ok:1", "bad id", "ok:1" },
		},
	})
	t.eq(wallet:balance("currency_a"), 0)
	t.eq(wallet:balance("currency_b"), 7)
	t.eq(wallet:balance("currency_c"), 9, "over-cap value is kept, not destroyed")
	t.eq(select(2, wallet:credit("currency_c", 1, "Gameplay")), "at_cap")
	t.ok((wallet:debit("currency_c", 4, "Shop")))
	t.eq(wallet:serialize().balances.retired, 40)
	t.ok(not wallet:has("retired"))
	t.eq(wallet:serialize().recent, { "ok:1" })
	t.ok(contains(wallet.notes, "currency_a: non-finite balance reset to 0"))
	t.ok(contains(wallet.notes, "currency_b: balance 7.9 repaired to 7"))
	t.ok(contains(wallet.notes, "unknown currency retired preserved"))
	t.ok(contains(wallet.notes, "above cap kept"))
	local fresh = Wallet.new({ currencies = { currency_a = { initial = 3 } }, data = { schema = "other" } })
	t.eq(fresh:balance("currency_a"), 3)
	t.ok(contains(fresh.notes, "not wallet/1"))
end)

test("prepare, commit and rollback detect stale state and compensate emitted events", function(t)
	local wallet, sink = fixture()
	wallet:credit("currency_a", 10, "Gameplay")
	local tx = assert(wallet:prepare({ { currency = "currency_a", delta = -4, reason = "trade" } }))
	local other = assert(wallet:prepare({ { currency = "currency_a", delta = 1, reason = "Gameplay" } }))
	t.ok((wallet:commit(other)))
	t.eq({ wallet:commit(tx) }, { false, "stale" }, "the wallet changed after prepare")
	t.eq({ wallet:commit(other) }, { false, "invalid_tx" }, "a tx commits once")
	sink:clear()
	local deferred = assert(wallet:prepare({ { currency = "currency_a", delta = -4, reason = "trade" } }))
	t.ok((wallet:commit(deferred, { emit = false })))
	t.eq(sink:count(), 0, "events deferred")
	t.ok((wallet:rollback(deferred)))
	t.eq(wallet:balance("currency_a"), 11)
	t.eq(sink:count(), 0, "a rollback of an unreported tx reports nothing")
	local emitted = assert(wallet:prepare({ { currency = "currency_a", delta = -1, reason = "Shop" } }))
	t.ok((wallet:commit(emitted)))
	t.ok((wallet:rollback(emitted)))
	t.eq(sink:count(), 2)
	t.eq(sink.events[2].economy.flow, "source")
	t.eq(sink.events[2].economy.transaction_type, "rollback")
	t.eq(sink.events[2].economy.balance, 11)
	t.eq({ wallet:rollback(emitted) }, { false, "not_committed" })
	local later = assert(wallet:prepare({ { currency = "currency_a", delta = -1, reason = "Shop" } }))
	t.ok((wallet:commit(later)))
	wallet:credit("currency_a", 1, "Gameplay")
	t.eq({ wallet:rollback(later) }, { false, "stale" }, "rollback refuses after another change")
end)

test("changed fires after commits and a throwing sink never breaks the wallet", function(t)
	local env = FakeEnv.new()
	local wallet = Wallet.new({
		currencies = { currency_a = {} },
		sink = {
			emit = function()
				error("sink down")
			end,
		},
	}, env)
	local seen = {}
	wallet.changed:Connect(function(currency, balance, delta)
		table.insert(seen, { currency, balance, delta })
	end)
	t.ok((wallet:credit("currency_a", 3, "Gameplay")))
	t.eq(seen, { { "currency_a", 3, 3 } })
	t.eq(wallet:balance("currency_a"), 3)
	t.ok(contains(env.reports, "sink error"))
	local rejecting = Wallet.new({
		currencies = { currency_a = {} },
		sink = Events.recorder({ strict = false }),
		player = "p:1",
	}, env)
	t.ok((rejecting:credit("currency_a", 1, "Gameplay")))
end)

test("events can be silenced per currency", function(t)
	local sink = Events.recorder()
	local wallet =
		Wallet.new({ currencies = { currency_a = { report = false }, currency_b = {} }, sink = sink })
	wallet:credit("currency_a", 1, "Gameplay")
	wallet:credit("currency_b", 1, "Gameplay")
	t.eq(sink:count(), 1)
	t.eq(sink.events[1].economy.currency, "currency_b")
end)

return cases
