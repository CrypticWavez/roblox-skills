-- Second-pass verification of first-pass (Codex) pure modules that previously had no
-- tests in this repository. Roblox-bound modules (NativeUI, Observation, ...) need Studio.
local Lifetime = require("../packages/Runtime/Lifetime")
local Motion = require("../packages/Runtime/Motion")
local ReceiptLedger = require("../packages/Runtime/ReceiptLedger")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

-- In-memory DataStore double: UpdateAsync runs the transform twice (Roblox may retry it)
-- and can be told to fail the next N calls.
local function fakeStore()
	local store = { data = {}, failNext = 0, calls = 0 }
	function store:UpdateAsync(key, transform)
		self.calls += 1
		if self.failNext > 0 then
			self.failNext -= 1
			error("throttled")
		end
		transform(self.data[key])
		local result = transform(self.data[key])
		if result ~= nil then
			self.data[key] = result
		end
		return self.data[key]
	end
	return store
end

local PRODUCTS = {
	[101] = { universeId = 9, revision = "r1", balances = { coins = 100 }, entitlements = {} },
	[202] = { universeId = 9, revision = "r1", balances = {}, entitlements = { vip = true } },
}

local function ledger(store)
	return ReceiptLedger.new({ store = store, namespace = "fixture", universeId = 9, products = PRODUCTS })
end

test("receipt ledger grants once and is idempotent under retried transforms", function(t)
	local store = fakeStore()
	local l = ledger(store)
	local receipt = { PlayerId = 1, ProductId = 101, PurchaseId = "p-1" }
	local first = l:process(receipt)
	t.eq(first.decision, "PurchaseGranted")
	t.eq(first.account.balances.coins, 100)
	local again = l:process(receipt)
	t.eq(again.decision, "PurchaseGranted")
	t.eq(again.account.balances.coins, 100, "duplicate receipt must not double-grant")
	t.eq(l:process({ PlayerId = 1, ProductId = 101, PurchaseId = "p-2" }).account.balances.coins, 200)
end)

test("receipt ledger rejects unknown products and malformed receipts", function(t)
	local l = ledger(fakeStore())
	t.eq(l:process({ PlayerId = 1, ProductId = 999, PurchaseId = "x" }).reason, "unknown_product")
	t.eq(l:process({ PlayerId = 0, ProductId = 101, PurchaseId = "x" }).reason, "invalid_receipt")
	t.eq(l:process(nil).decision, "NotProcessedYet")
end)

test("receipt ledger retries store failures then defers", function(t)
	local store = fakeStore()
	local l = ledger(store)
	store.failNext = 2
	local ok = l:process({ PlayerId = 2, ProductId = 202, PurchaseId = "p-3" })
	t.eq(ok.decision, "PurchaseGranted")
	t.eq(ok.attempts, 3)
	store.failNext = 10
	local deferred = l:process({ PlayerId = 2, ProductId = 101, PurchaseId = "p-4" })
	t.eq(deferred.decision, "NotProcessedYet")
	t.eq(deferred.reason, "store_unavailable")
end)

test("receipt ledger migrates v1 accounts and refuses corrupt ones", function(t)
	local store = fakeStore()
	local l = ledger(store)
	store.data[l:key(3)] =
		{ version = 1, balances = { coins = 5 }, entitlements = {}, receipts = { old = 101 } }
	local migrated = l:process({ PlayerId = 3, ProductId = 101, PurchaseId = "new" })
	t.eq(migrated.decision, "PurchaseGranted")
	t.eq(migrated.account.receipts.old.revision, "migrated_v1")
	t.eq(migrated.account.balances.coins, 105)
	store.data[l:key(4)] = { version = 7 }
	t.eq(
		l:process({ PlayerId = 4, ProductId = 101, PurchaseId = "z" }).reason,
		"unsupported_or_corrupt_schema"
	)
end)

test("receipt ledger refuses cross-universe products at construction", function(t)
	t.throws(function()
		ReceiptLedger.new({
			store = fakeStore(),
			namespace = "fixture",
			universeId = 9,
			products = { [1] = { universeId = 8, revision = "r", balances = { a = 1 }, entitlements = {} } },
		})
	end)
end)

test("lifetime evicts lowest priority at capacity and cleans up on expiry", function(t)
	local cleaned = {}
	local life = Lifetime.new(2)
	life:add(1, 1, function()
		table.insert(cleaned, "low")
	end)
	life:add(5, 5, function()
		table.insert(cleaned, "high")
	end)
	local id = life:add(5, 3, function()
		table.insert(cleaned, "mid")
	end)
	t.ok(id ~= nil, "higher priority admitted")
	t.eq(cleaned, { "low" }, "lowest evicted")
	local rejected, reason = life:add(5, 0, function() end)
	t.eq(rejected, nil)
	t.eq(reason, "capacity")
	life:step(6)
	t.eq(life:count(), 0)
	life:destroy()
	t.eq(select(2, life:add(1, 1, function() end)), "closed")
end)

test("motion curve is bounded, monotonic and honours reduced motion", function(t)
	local previous = -1
	for i = 0, 20 do
		local v = Motion.curve(i / 20, false)
		t.ok(v >= previous and v >= 0 and v <= 1)
		previous = v
	end
	t.eq(Motion.curve(0.3, true), 1)
	local tr = Motion.transition(0, 1)
	tr:set(10, false)
	tr:step(0.5)
	t.ok(tr.value > 0 and tr.value < 10)
	tr:step(1)
	t.near(tr.value, 10, 1e-9)
end)

return cases
