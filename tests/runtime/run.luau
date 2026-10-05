local task = require("@lune/task")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Ledger = require("../../packages/Runtime/ReceiptLedger")
local Motion = require("../../packages/Runtime/Motion")
local Lifetime = require("../../packages/Runtime/Lifetime")
local Mixer = require("../../packages/Runtime/AudioMixer")
local Catalog = require("../../packages/Runtime/CommerceCatalog")

local results = {}
local function equal(a, b, message)
	assert(a == b, (message or "mismatch") .. ": " .. tostring(a) .. " ~= " .. tostring(b))
end
local function near(a, b)
	assert(math.abs(a - b) < 0.000001, tostring(a) .. " not near " .. tostring(b))
end
local function test(name, callback)
	local ok, failure = pcall(callback)
	table.insert(results, {
		name = name,
		status = if ok then "passed" else "failed",
		failure = if ok then nil else tostring(failure),
	})
	print((if ok then "PASS " else "FAIL ") .. name .. (if ok then "" else " " .. tostring(failure)))
end
local function clone(value)
	if value == nil then
		return nil
	end
	return serde.decode("json", serde.encode("json", value))
end

-- An optimistic compare-and-swap model with actual coroutine interleaving.
-- It is a test double, not a claim about real datastore latency/durability.
local function store()
	local api = {
		values = {},
		revisions = {},
		calls = 0,
		transforms = 0,
		failures = 0,
		failAfterCommit = 0,
		interleave = false,
	}
	function api:UpdateAsync(key, transform)
		api.calls += 1
		if api.failures > 0 then
			api.failures -= 1
			error("injected write failure")
		end
		for _ = 1, 100 do
			local revision = api.revisions[key] or 0
			local candidate = transform(clone(api.values[key]))
			api.transforms += 1
			if candidate == nil then
				return nil
			end
			if api.interleave then
				task.wait()
			end
			if revision == (api.revisions[key] or 0) then
				api.values[key] = clone(candidate)
				api.revisions[key] = revision + 1
				if api.failAfterCommit > 0 then
					api.failAfterCommit -= 1
					error("injected lost acknowledgement")
				end
				return clone(candidate)
			end
		end
		error("fixture contention exceeded")
	end
	return api
end

local function create(storage, overrides)
	local options = {
		store = storage,
		namespace = "isolated_fixture",
		universeId = 123,
		products = {
			[1001] = { universeId = 123, revision = "test_v1", balances = { units = 10 }, entitlements = {} },
			[1002] = {
				universeId = 123,
				revision = "test_v1",
				balances = {},
				entitlements = { fixture_flag = true },
			},
		},
	}
	for key, value in overrides or {} do
		options[key] = value
	end
	return Ledger.new(options)
end
local function receipt(id, product, user)
	return { PlayerId = user or 42, ProductId = product or 1001, PurchaseId = id or "purchase_A" }
end

test("one commit persists balance and receipt together", function()
	local s = store()
	local result = create(s):process(receipt())
	equal(result.decision, "PurchaseGranted")
	equal(s.values.isolated_fixture_42, nil)
	equal(s.values["isolated_fixture:42"].balances.units, 10)
	equal(s.values["isolated_fixture:42"].receipts.purchase_A.productId, 1001)
end)
test("duplicate receipt across fresh processors has one durable effect", function()
	local s = store()
	create(s):process(receipt())
	for _ = 1, 10 do
		equal(create(s):process(receipt()).decision, "PurchaseGranted")
	end
	equal(s.values["isolated_fixture:42"].balances.units, 10)
end)
test("unknown and malformed receipts make zero storage calls", function()
	local s, ledger = store(), nil
	ledger = create(s)
	equal(ledger:process(receipt("A", 9999)).reason, "unknown_product")
	equal(ledger:process(receipt("A", 1001, -1)).reason, "invalid_receipt")
	equal(ledger:process(receipt(string.rep("x", 129))).reason, "invalid_receipt")
	equal(s.calls, 0)
end)
test("transient errors use bounded exponential backoff", function()
	local s, waits = store(), {}
	s.failures = 2
	local result = create(s, {
		wait = function(seconds)
			table.insert(waits, seconds)
		end,
	}):process(receipt())
	equal(result.decision, "PurchaseGranted")
	equal(result.attempts, 3)
	near(waits[1], 0.25)
	near(waits[2], 0.5)
end)
test("persistent failure never acknowledges or fabricates data", function()
	local s = store()
	s.failures = 8
	local result = create(s):process(receipt())
	equal(result.decision, "NotProcessedYet")
	equal(s.calls, 3)
	equal(next(s.values), nil)
end)
test("lost commit acknowledgement and server restart do not regrant", function()
	local s = store()
	s.failAfterCommit = 1
	equal(create(s, { attempts = 1 }):process(receipt()).decision, "NotProcessedYet")
	equal(s.values["isolated_fixture:42"].balances.units, 10)
	equal(create(s):process(receipt()).decision, "PurchaseGranted")
	equal(s.values["isolated_fixture:42"].balances.units, 10)
end)
test("interrupted retry can resume later", function()
	local s = store()
	s.failures = 1
	equal(
		create(s, {
			wait = function()
				error("server interruption")
			end,
		}):process(receipt()).reason,
		"retry_interrupted"
	)
	equal(create(s):process(receipt()).decision, "PurchaseGranted")
end)
test("two concurrent servers same receipt rebase and grant once", function()
	local s, output = store(), {}
	s.interleave = true
	for _ = 1, 2 do
		task.spawn(function()
			table.insert(output, create(s):process(receipt()))
		end)
	end
	while #output < 2 do
		task.wait()
	end
	equal(output[1].decision, "PurchaseGranted")
	equal(output[2].decision, "PurchaseGranted")
	equal(s.values["isolated_fixture:42"].balances.units, 10)
	assert(s.transforms >= 3, "CAS conflict must replay callback")
end)
test("20 concurrent distinct receipts retain all grants", function()
	local s, output = store(), {}
	s.interleave = true
	for index = 1, 20 do
		task.spawn(function()
			table.insert(output, create(s):process(receipt("batch_" .. index)))
		end)
	end
	while #output < 20 do
		task.wait()
	end
	for _, result in output do
		equal(result.decision, "PurchaseGranted")
	end
	equal(s.values["isolated_fixture:42"].balances.units, 200)
end)
test("delayed out-of-order receipts need no connected player", function()
	local s = store()
	local ledger = create(s)
	ledger:process(receipt("newer"))
	ledger:process(receipt("older"))
	ledger:process(receipt("entitlement", 1002))
	equal(s.values["isolated_fixture:42"].balances.units, 20)
	equal(s.values["isolated_fixture:42"].entitlements.fixture_flag, true)
end)
test("v1 migration preserves facts without regrant", function()
	local s = store()
	s.values["isolated_fixture:42"] =
		{ version = 1, balances = { units = 30 }, entitlements = {}, receipts = { purchase_A = 1001 } }
	equal(create(s):process(receipt()).decision, "PurchaseGranted")
	equal(s.values["isolated_fixture:42"].version, 2)
	equal(s.values["isolated_fixture:42"].balances.units, 30)
end)
test("corrupt and future schemas are preserved for recovery", function()
	for _, bad in
		{ { version = 9 }, { version = 2, balances = { units = -1 }, receipts = {}, entitlements = {} } }
	do
		local s = store()
		s.values["isolated_fixture:42"] = clone(bad)
		local before = serde.encode("json", s.values)
		equal(create(s):process(receipt()).decision, "NotProcessedYet")
		equal(serde.encode("json", s.values), before)
	end
end)
test("receipt capacity fails closed and never evicts dedupe", function()
	local s = store()
	local ledger = create(s, { maxReceipts = 1 })
	ledger:process(receipt("first"))
	equal(ledger:process(receipt("second")).reason, "receipt_capacity_requires_migration")
	equal(ledger:process(receipt("first")).decision, "PurchaseGranted")
	equal(s.values["isolated_fixture:42"].balances.units, 10)
end)
test("balance overflow rolls back grant and receipt together", function()
	local s = store()
	local ledger = create(s, { maxBalance = 10 })
	ledger:process(receipt("first"))
	equal(ledger:process(receipt("second")).reason, "balance_capacity")
	equal(s.values["isolated_fixture:42"].receipts.second, nil)
end)
test("receipt product mismatch fails closed", function()
	local s = store()
	create(s):process(receipt())
	equal(create(s):process(receipt(nil, 1002)).reason, "receipt_product_mismatch")
	equal(next(s.values["isolated_fixture:42"].entitlements), nil)
end)
test("namespace separation prevents cross-game fixture data reuse", function()
	local s = store()
	create(s):process(receipt())
	create(s, { namespace = "other_fixture" }):process(receipt())
	equal(s.values["other_fixture:42"].balances.units, 10)
	equal(s.values["isolated_fixture:42"].balances.units, 10)
	equal(
		pcall(function()
			create(s, { universeId = 999 })
		end),
		false
	)
end)
test("caller mutation cannot change installed grant", function()
	local s = store()
	local products =
		{ [1001] = { universeId = 123, revision = "v1", balances = { units = 10 }, entitlements = {} } }
	local ledger = create(s, { products = products })
	products[1001].balances.units = 1000
	ledger:process(receipt())
	equal(s.values["isolated_fixture:42"].balances.units, 10)
end)
test("unknown account fields are not silently erased", function()
	local s = store()
	s.values["isolated_fixture:42"] =
		{ version = 2, balances = {}, entitlements = {}, receipts = {}, foreignField = "preserve" }
	equal(create(s):process(receipt()).reason, "unrecognized_account_field")
	equal(s.values["isolated_fixture:42"].foreignField, "preserve")
end)
test("constructor snapshots storage namespace and store selection", function()
	local s, alternate = store(), store()
	local options = {
		store = s,
		namespace = "snapshot",
		universeId = 123,
		products = {
			[1001] = { universeId = 123, revision = "v1", balances = { units = 10 }, entitlements = {} },
		},
	}
	local ledger = Ledger.new(options)
	options.namespace, options.store = "mutated", alternate
	ledger:process(receipt())
	equal(s.values["snapshot:42"].balances.units, 10)
	equal(next(alternate.values), nil)
end)
test("catalog fails closed on missing info and rechecks subscription", function()
	local calls = 0
	local catalog = Catalog.new(123, {
		subscription = {
			universeId = 123,
			kind = "subscription",
			id = "EXP-fixture",
			ownershipVerified = true,
			enabled = false,
		},
	}, {
		productInfo = function()
			error("denied")
		end,
		entitlement = function()
			calls += 1
			return calls == 1
		end,
	})
	equal(catalog:display("subscription").state, "unavailable")
	equal(catalog:entitlement("subscription").state, "active")
	equal(catalog:entitlement("subscription").state, "inactive")
	equal(catalog:display("missing").reason, "unconfigured")
end)
test("motion interrupted transition starts at current value", function()
	local t = Motion.transition(0, 1)
	t:set(10, false)
	near(t:step(0.5), 5)
	t:set(0, false)
	near(t:step(0.5), 2.5)
	near(t:step(0.5), 0)
	t:set(20, true)
	near(t.value, 20)
end)
test("motion markers and contact diagnostics catch invalid input", function()
	equal(#Motion.validateMarkers(1, { { name = "impact", time = 0.3 } }, { "impact" }), 0)
	equal(#Motion.validateMarkers(1, { { name = "impact", time = 1.5 } }, { "impact" }), 2)
	local result = Motion.contactDrift({
		{ time = 0, x = 0, y = 0, z = 0, planted = true },
		{ time = 0.1, x = 0.4, y = 0, z = 0, planted = true },
	}, 0.1)
	equal(result.flagged, true)
	near(result.totalDrift, 0.4)
end)
test("effect priority budget cleanup and idempotent destruction", function()
	local lifetime, cleaned = Lifetime.new(2), 0
	local function cleanup()
		cleaned += 1
	end
	lifetime:add(2, 1, cleanup)
	local token = lifetime:add(2, 2, cleanup)
	equal(lifetime:add(1, 0, cleanup), nil)
	lifetime:add(1, 5, cleanup)
	equal(cleaned, 1)
	equal(lifetime:count(), 2)
	lifetime:cancel(token)
	lifetime:step(2)
	lifetime:destroy()
	lifetime:destroy()
	equal(cleaned, 3)
	equal(lifetime:count(), 0)
	equal(lifetime:add(1, 1, cleanup), nil)
end)
test("cleanup errors do not prevent other teardown", function()
	local lifetime = Lifetime.new(2)
	lifetime:add(1, 1, function()
		error("broken destroy")
	end)
	lifetime:add(1, 1, function() end)
	lifetime:destroy()
	equal(lifetime.cleanupErrors, 1)
	equal(lifetime:count(), 0)
end)
test("reentrant cleanup cannot leak or exceed effect budget", function()
	local lifetime = Lifetime.new(2)
	local cleaned = 0
	local second
	lifetime:add(1, 1, function()
		cleaned += 1
		lifetime:cancel(second)
		equal(lifetime:add(1, 1, function() end), nil)
	end)
	second = lifetime:add(1, 1, function()
		cleaned += 1
	end)
	lifetime:step(2)
	equal(cleaned, 2)
	equal(lifetime:count(), 0)
	lifetime:add(1, 1, function()
		lifetime:destroy()
	end)
	lifetime:destroy()
	equal(lifetime:count(), 0)
end)
test("invalid motion samples cannot silently pass drift diagnostics", function()
	equal(
		pcall(function()
			Motion.contactDrift({ { time = 0, x = 0 / 0, y = 0, z = 0, planted = true } }, 0.1)
		end),
		false
	)
end)
test("audio overlapping ducks restore gain and respect user master", function()
	local mixer = Mixer.new({ "music", "effects" })
	mixer:setMaster(0.5)
	mixer:setVolume("music", 0.8)
	mixer:duck("music", 0.5, 1)
	mixer:duck("music", 0.25, 2)
	near(mixer:step(0).music, 0.1)
	near(mixer:step(1.5).music, 0.1)
	near(mixer:step(1).music, 0.4)
end)
test("audio interrupted fades remain continuous and bounded", function()
	local mixer = Mixer.new({ "music" })
	mixer:fade("music", 0, 1)
	near(mixer:step(0.5).music, 0.5)
	mixer:fade("music", 1, 1)
	near(mixer:step(0.5).music, 0.75)
	near(mixer:step(2).music, 1)
	for _ = 1, 32 do
		assert(mixer:duck("music", 0.5, 1))
	end
	equal(mixer:duck("music", 0.5, 1), nil)
	equal(
		pcall(function()
			mixer:setMaster(0 / 0)
		end),
		false
	)
end)

local failed = 0
for _, result in results do
	if result.status ~= "passed" then
		failed += 1
	end
end
local report = {
	schema_version = 1,
	status = if failed == 0 then "partially_verified" else "blocked",
	scope = "SETUP_ONLY offline deterministic and interleaved CAS fixtures",
	passed = #results - failed,
	failed = failed,
	tests = results,
	limitations = {
		"Injected atomic store is an executable model, not Roblox DataStore verification.",
		"No real purchase, live product, DataStore, subscription, or pass invoked.",
		"Exactly-once external side effects are not claimed; only same-account committed ledger facts are deduplicated under the adapter contract.",
		"Native UI rendering, actual input devices, animation assets, audio hearing/permissions, and per-game performance require separate native evidence.",
	},
}
-- Second pass: write to build/ (generated output) instead of the tracked reports/ folder.
if not fs.isDir("build") then
	fs.writeDir("build")
end
fs.writeFile("build/runtime_status.json", serde.encode("json", report, true) .. "\n")
assert(failed == 0, tostring(failed) .. " runtime fixtures failed")
print("RUNTIME_FIXTURES " .. tostring(#results) .. " passed")
