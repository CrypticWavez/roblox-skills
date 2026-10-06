--!strict
-- GameKit/OddsTable: exact disclosure (sums to exactly 100.0000 % over 500 random tables),
-- paid rolls refused without the policy's yes, a chi-square sanity check over 100k seeded rolls,
-- once-only outcomes, boosts and pity, all shown identically by disclose().
local OddsTable = require("../packages/GameKit/OddsTable")
local Rng = require("../packages/ProcGen/Rng")
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

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

-- Units parsed back from the disclosed text ("12.3456%" -> 123456), so the check covers what a
-- player reads, not just the integers behind it.
local function parse(text: string): number
	local whole, frac = string.match(text, "^(%d+)%.(%d%d%d%d)%%$")
	assert(whole and frac, "bad disclosure text " .. text)
	return tonumber(whole) :: number * 10000 + tonumber(frac) :: number
end

local ENTRIES = {
	{ id = "outcome_a", weight = 500 },
	{ id = "outcome_b", weight = 300 },
	{ id = "outcome_c", weight = 150 },
	{ id = "outcome_d", weight = 45 },
	{ id = "outcome_e", weight = 5, once = true },
}

test("format prints exactly four decimals", function(t)
	t.eq(OddsTable.format(0), "0.0000%")
	t.eq(OddsTable.format(1), "0.0001%")
	t.eq(OddsTable.format(123456), "12.3456%")
	t.eq(OddsTable.format(1000000), "100.0000%")
end)

test("disclosure sums to exactly 100.0000% across 500 seeded random tables", function(t)
	local rng = Rng.new("odds-disclosure")
	for tableIndex = 1, 500 do
		local entries = {}
		local n = rng:int(1, 60)
		local maxWeight = if tableIndex % 3 == 0 then 7 else 1000000
		for index = 1, n do
			table.insert(entries, { id = "outcome_" .. index, weight = rng:int(1, maxWeight) })
		end
		local weights, total = {}, 0
		for _, entry in entries do
			table.insert(weights, entry.weight)
			total += entry.weight
		end
		local units = OddsTable.apportion(weights)
		local sum, textSum = 0, 0
		for index, value in units do
			sum += value
			textSum += parse(OddsTable.format(value))
			local exact = weights[index] * OddsTable.SCALE / total
			t.ok(math.abs(value - exact) < 1, "each share is within one unit of exact")
		end
		t.eq(sum, OddsTable.SCALE, "table " .. tableIndex .. " units")
		t.eq(textSum, OddsTable.SCALE, "table " .. tableIndex .. " shown text")
		if #OddsTable.validate(entries) == 0 then
			local disclosure = OddsTable.new(entries, rng):disclose()
			t.eq(disclosure.total, OddsTable.SCALE)
		end
	end
end)

test("largest remainder breaks ties by order and never shows a share above its ceiling", function(t)
	t.eq(OddsTable.apportion({ 1, 1, 1 }), { 333334, 333333, 333333 })
	t.eq(OddsTable.apportion({ 1, 2 }), { 333333, 666667 })
	t.eq(OddsTable.apportion({ 7 }), { 1000000 })
	t.throws(function()
		OddsTable.apportion({ 1, 0 })
	end)
	t.throws(function()
		OddsTable.apportion({ 1.5 })
	end)
	t.throws(function()
		OddsTable.apportion({ 2 ^ 31, 1 })
	end)
end)

test("validate refuses bad entries, bad pity and outcomes shown as 0.0000%", function(t)
	t.eq(OddsTable.validate(ENTRIES), {})
	t.ok(contains(OddsTable.validate({}), "non-empty list"))
	local problems = OddsTable.validate({
		{ id = "a", weight = 0 },
		{ id = "a", weight = 1.5 },
		{ id = "B", weight = 1 },
		{ id = "c", weight = 1, chance = 0.5 },
		{ id = "d", weight = 1, once = "yes" },
	}, { pity = { threshold = 1, targets = { "zzz" } }, name = "Bad" })
	for _, needle in
		{
			"entry a: weight must be an integer >= 1",
			"entry a: duplicate id",
			"entry B: id is not a label",
			'entry c: unknown key "chance"',
			"entry d: once must be a boolean",
			"pity.threshold must be an integer >= 2",
			'pity target "zzz" is not an entry',
			"name must be a label",
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	t.ok(contains(OddsTable.validate({ { id = "a", weight = 2 ^ 31 }, { id = "b", weight = 1 } }), "exceeds"))
	local zero = OddsTable.validate({ { id = "tiny", weight = 1 }, { id = "huge", weight = 2 ^ 31 - 1 } })
	t.ok(contains(zero, "entry tiny would be shown as 0.0000%"), table.concat(zero, " | "))
	t.throws(function()
		OddsTable.new({ { id = "a", weight = 0 } })
	end)
end)

test("a paid roll refuses without the policy's explicit yes (fail closed)", function(t)
	local paid = OddsTable.new(ENTRIES, Rng.new(1), { paid = true, name = "paid_table" })
	local text = errorText(function()
		paid:roll()
	end)
	t.ok(string.find(text, "paid roll refused (policy_missing)", 1, true) ~= nil, text)
	t.ok(string.find(
		errorText(function()
			paid:roll({ policyAllows = false })
		end),
		"policy_denied",
		1,
		true
	) ~= nil)
	t.ok(string.find(
		errorText(function()
			paid:roll({ policyAllows = "yes" :: any })
		end),
		"policy_denied",
		1,
		true
	) ~= nil, "truthy is not true")
	t.eq(
		{ paid:tryRoll({ policyAllows = FakeEconomyStore.policy({ "trading" }) }) },
		{ false, "policy_denied" }
	)
	t.eq({
		paid:tryRoll({
			policyAllows = function(): boolean
				error("PolicyService unavailable")
			end,
		}),
	}, { false, "policy_error" })
	local granted = paid:roll({ policyAllows = FakeEconomyStore.policy({ "paidRandomItems" }) })
	t.ok(granted.paid and type(granted.id) == "string")
	t.ok(paid:roll({ policyAllows = true }).paid)
	local free = OddsTable.new(ENTRIES, Rng.new(1))
	t.ok(not free:roll().paid, "free rolls need no policy")
	t.eq({ free:tryRoll({ paid = true }) }, { false, "policy_missing" }, "ctx.paid gates a free table")
	t.ok(paid:disclose().paid, "disclosure says the table is paid")
end)

test("chi-square sanity on 100k seeded rolls, and the same seed repeats", function(t)
	local odds = OddsTable.new(ENTRIES, Rng.new("chi-square"))
	local counts = {}
	local n = 100000
	for _ = 1, n do
		local id = odds:roll().id
		counts[id] = (counts[id] or 0) + 1
	end
	local chi = 0
	for _, entry in ENTRIES do
		local expected = n * entry.weight / 1000
		chi += ((counts[entry.id] or 0) - expected) ^ 2 / expected
	end
	-- 4 degrees of freedom; the 0.999 quantile of chi-square(4) is 18.467.
	t.ok(chi < 18.467, string.format("chi-square %.3f", chi))
	local a = OddsTable.new(ENTRIES, Rng.new(42))
	local b = OddsTable.new(ENTRIES, Rng.new(42))
	for _ = 1, 200 do
		t.eq(a:roll().id, b:roll().id)
	end
	t.eq({ OddsTable.new(ENTRIES):tryRoll() }, { false, "no_rng" })
	t.ok(type(OddsTable.new(ENTRIES):roll({ rng = Rng.new(3) }).id) == "string", "ctx.rng")
end)

test("once-only outcomes leave rolls and disclosure when owned", function(t)
	local odds = OddsTable.new(ENTRIES, Rng.new("once"))
	local before = odds:disclose()
	t.eq(#before.entries, 5)
	t.eq(before.entries[5].text, "0.5000%")
	local after = odds:disclose({ owned = { outcome_e = true, outcome_a = true } })
	t.eq(#after.entries, 4, "only once-only entries drop when owned")
	local sum = 0
	for _, line in after.entries do
		sum += parse(line.text)
	end
	t.eq(sum, OddsTable.SCALE)
	t.eq(after.entries[1].text, "50.2513%")
	for _ = 1, 3000 do
		t.ok(odds:roll({ owned = { outcome_e = true } }).id ~= "outcome_e")
	end
	local solo = OddsTable.new({ { id = "only", weight = 1, once = true } }, Rng.new(1))
	t.eq({ solo:tryRoll({ owned = { only = true } }) }, { false, "no_outcomes" })
	t.throws(function()
		solo:disclose({ owned = { only = true } })
	end)
	t.eq(odds:disclose({ exclude = { outcome_a = true } }).entries[1].id, "outcome_b")
end)

test("boosts change rolls and disclosure identically", function(t)
	local odds = OddsTable.new(ENTRIES, Rng.new("boost"))
	local boosted = odds:disclose({ boost = { outcome_e = 4 } })
	t.eq(boosted.entries[5].weight, 20)
	t.eq(
		boosted.entries[5].text,
		string.format("%s", OddsTable.format(OddsTable.apportion({ 500, 300, 150, 45, 20 })[5]))
	)
	local hits = 0
	for _ = 1, 20000 do
		if odds:roll({ boost = { outcome_e = 4 } }).id == "outcome_e" then
			hits += 1
		end
	end
	t.ok(hits > 250 and hits < 550, "about 1.97% of 20000 (" .. hits .. ")")
	t.eq({ odds:tryRoll({ boost = { outcome_e = 1.5 } }) }, { false, "invalid_boost" })
	t.eq({ odds:tryRoll({ boost = { missing = 2 } }) }, { false, "invalid_boost" })
end)

test("pity guarantees a target on the threshold roll and is disclosed", function(t)
	local odds = OddsTable.new(
		{ { id = "common_a", weight = 999 }, { id = "rare_a", weight = 1 } },
		Rng.new("pity"),
		{ pity = { threshold = 3, targets = { "rare_a" } } }
	)
	local first = odds:roll({ pity = 0 })
	t.eq(first.pity, if first.id == "rare_a" then 0 else 1)
	local d = odds:disclose({ pity = 1 })
	t.ok(not d.guaranteed)
	t.eq(d.pity.rollsLeft, 1)
	t.eq(d.pity.odds, { { id = "rare_a", units = 1000000, percent = 100, text = "100.0000%", weight = 1 } })
	local guaranteed = odds:disclose({ pity = 2 })
	t.ok(guaranteed.guaranteed)
	t.eq(#guaranteed.entries, 1)
	t.eq(guaranteed.entries[1].text, "100.0000%")
	local result = odds:roll({ pity = 2 })
	t.eq({ result.id, result.pity, result.pityTriggered }, { "rare_a", 0, true })
	-- A run of rolls never goes three in a row without the target.
	local count, longest, streak = 0, 0, 0
	for _ = 1, 3000 do
		local r = odds:roll({ pity = count })
		count = r.pity
		streak = if r.id == "rare_a" then 0 else streak + 1
		longest = math.max(longest, streak)
	end
	t.ok(longest <= 2, "longest run without a target " .. longest)
	t.eq({ odds:tryRoll({ pity = -1 }) }, { false, "invalid_pity" })
	local ownedTarget = odds:disclose({ pity = 2, exclude = { rare_a = true } })
	t.ok(not ownedTarget.guaranteed, "pity cannot apply when every target is gone")
	t.eq(OddsTable.new(ENTRIES, Rng.new(1)):roll().pity, 0, "no pity rule, no count")
end)

return cases
