--!strict
-- GameKit/Plots (validation, deterministic claim order under races, release, lookups) and
-- GameKit/Generators (fractional carry, storage caps, multipliers, offline earnings from server
-- UTC under a cap, clock skew, once-only offline credit, persistence).
local Generators = require("../packages/GameKit/Generators")
local Plots = require("../packages/GameKit/Plots")
local Wallet = require("../packages/GameKit/Wallet")
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

local function grid(n: number): { any }
	local plots = {}
	for index = 1, n do
		local x = (index - 1) * 100
		table.insert(plots, {
			id = "plot_" .. index,
			bounds = { min = { x = x, y = 0, z = 0 }, max = { x = x + 80, y = 50, z = 80 } },
		})
	end
	return plots
end

-- ---------------------------------------------------------------- Plots

test("plot validation refuses bad ids, boxes and overlaps", function(t)
	t.eq(Plots.validate(grid(3)), {})
	t.ok(contains(Plots.validate({}), "non-empty"))
	local problems = Plots.validate({
		{ id = "a", bounds = { min = { x = 0, y = 0, z = 0 }, max = { x = 10, y = 10, z = 10 } } },
		{ id = "b", bounds = { min = { x = 5, y = 5, z = 5 }, max = { x = 15, y = 15, z = 15 } } },
		{ id = "a", bounds = { min = { x = 50, y = 0, z = 0 }, max = { x = 60, y = 10, z = 10 } } },
		{ id = "c", bounds = { min = { x = 0, y = 0, z = 0 }, max = { x = 0, y = 10, z = 10 } } },
		{ id = "d", bounds = { min = { x = 0 / 0, y = 0, z = 0 }, max = { x = 1, y = 1, z = 1 } } },
		{
			id = "E",
			bounds = { min = { x = 90, y = 0, z = 0 }, max = { x = 95, y = 1, z = 1 } },
			order = 1.5,
		},
	})
	for _, needle in
		{
			"plots a and b overlap",
			"plot a: duplicate id",
			"plot c: bounds min must be below max",
			"plot d: bounds needs min and max",
			"plot E: id is not a label",
			"plot E: order must be an integer",
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	t.eq(
		Plots.validate({
			{ id = "a", bounds = { min = { x = 0, y = 0, z = 0 }, max = { x = 10, y = 10, z = 10 } } },
			{ id = "b", bounds = { min = { x = 10, y = 0, z = 0 }, max = { x = 20, y = 10, z = 10 } } },
		}),
		{},
		"touching faces do not overlap"
	)
	t.throws(function()
		Plots.new({ plots = grid(2), assign = "random" } :: any)
	end)
	t.throws(function()
		Plots.new({ plots = grid(2), assign = "seeded" })
	end)
end)

test("racing claims resolve in call order, one plot per owner, idempotent", function(t)
	local plots = Plots.new({ plots = grid(3) })
	t.eq({ plots:claim("p1", "plot_2") }, { true, "plot_2" })
	t.eq({ plots:claim("p2", "plot_2") }, { true, "plot_1" }, "the second claimer falls back")
	t.eq({ plots:claim("p1", "plot_3") }, { true, "plot_2" }, "an owner keeps their plot")
	t.eq({ plots:claim("p3") }, { true, "plot_3" })
	t.eq({ plots:claim("p4") }, { false, "full" })
	t.eq({ plots:claim("p4", "plot_9") }, { false, "unknown_plot" })
	t.eq({ plots:claim("") }, { false, "invalid_owner" })
	t.eq(plots:snapshot(), { plot_1 = "p2", plot_2 = "p1", plot_3 = "p3" })
	t.eq({ plots:release("p1") }, { true, "plot_2" })
	t.eq({ plots:release("p1") }, { false, "not_owner" })
	t.eq(plots:free(), { "plot_2" })
	t.eq({ plots:claim("p4") }, { true, "plot_2" })
	local strict = Plots.new({ plots = grid(2), fallback = false })
	strict:claim("p1", "plot_1")
	t.eq({ strict:claim("p2", "plot_1") }, { false, "taken" })
end)

test("concurrent claim threads never share a plot (FakeEnv threads)", function(t)
	local env = FakeEnv.new()
	local plots = Plots.new({ plots = grid(4) }, env)
	local results = {}
	for index = 1, 6 do
		env.defer(function()
			local ok, id = plots:claim("p" .. index, "plot_1")
			results[index] = if ok then id else "none:" .. id
		end)
	end
	env:flush()
	t.eq(results, { "plot_1", "plot_2", "plot_3", "plot_4", "none:full", "none:full" })
	local owners = {}
	for id, owner in plots:snapshot() do
		t.ok(not owners[owner], "one plot per owner")
		owners[owner] = id
	end
end)

test("seeded assignment is a fixed permutation; nearest picks the closest free plot", function(t)
	local function order(seed: string): { string }
		local plots = Plots.new({ plots = grid(6), assign = "seeded", seed = seed })
		local out = {}
		for index = 1, 6 do
			table.insert(out, select(2, plots:claim("p" .. index)) :: string)
		end
		return out
	end
	t.eq(order("server"), order("server"), "same seed, same order")
	t.ok(table.concat(order("server")) ~= table.concat(order("other")), "seed changes the order")
	local env = FakeEnv.new()
	t.eq(
		Plots.new({ plots = grid(6), assign = "seeded", seed = "server" }, env):free(),
		Plots.new({ plots = grid(6), assign = "seeded", seed = "server" }):free(),
		"env.rng and Rng agree"
	)
	local nearest = Plots.new({ plots = grid(3), assign = "nearest" })
	t.eq({ nearest:claim("p1", nil, { near = { x = 250, y = 0, z = 40 } }) }, { true, "plot_3" })
	t.eq({ nearest:claim("p2", nil, { near = { x = 250, y = 0, z = 40 } }) }, { true, "plot_2" })
	t.eq({ nearest:claim("p3") }, { true, "plot_1" }, "no position falls back to order")
end)

test("lookups by position and ownership", function(t)
	local plots = Plots.new({ plots = grid(2) })
	plots:claim("p1")
	t.eq(plots:at({ x = 40, y = 10, z = 40 }), "plot_1")
	t.eq(plots:at({ x = 90, y = 10, z = 40 }), nil, "the gap between plots")
	t.eq(plots:at({ x = 180, y = 50, z = 80 }), "plot_2", "bounds are inclusive")
	t.eq(plots:at({ x = 0 / 0, y = 0, z = 0 }), nil)
	t.ok(plots:owns("p1", { x = 1, y = 1, z = 1 }))
	t.ok(not plots:owns("p1", { x = 150, y = 1, z = 1 }))
	t.eq(plots:ownerOf("plot_1"), "p1")
	t.eq(plots:plotOf("p1"), "plot_1")
	t.eq(assert(plots:get("plot_2")).bounds.min.x, 100)
	t.eq(plots:count(), 2)
	local fired = {}
	plots.claimed:Connect(function(id, owner)
		table.insert(fired, id .. ":" .. owner)
	end)
	plots:claim("p2")
	t.eq(fired, { "plot_2:p2" })
end)

-- ---------------------------------------------------------------- Generators

local DEFS = {
	{ id = "gen_a", currency = "currency_a", rate = 0.4, storage = 100 },
	{ id = "gen_b", currency = "currency_a", rate = 2, maxCount = 3 },
	{ id = "gen_c", currency = "currency_b", rate = 1 },
}

test("generator validation", function(t)
	t.eq(Generators.validate(DEFS), {})
	local problems = Generators.validate({
		{ id = "a", currency = "c", rate = 0 },
		{ id = "a", currency = "C", rate = 1, storage = 0, maxCount = 1.5 },
	}, { offlineCap = -1, offlineRate = 2, maxStep = 0 })
	for _, needle in
		{
			"generator a: rate must be",
			"generator a: duplicate id",
			"currency is not a label",
			"storage must be an integer",
			"maxCount must be an integer",
			"offlineCap must be",
			"offlineRate must be within 0..1",
			"maxStep must be",
		}
	do
		t.ok(contains(problems, needle), needle)
	end
	t.throws(function()
		Generators.new({})
	end)
end)

test("ticks credit whole units and carry fractions; storage caps waste the rest", function(t)
	local gens = Generators.new(DEFS)
	t.ok((gens:add("gen_a", 1)))
	t.eq({ gens:add("gen_b", 4) }, { false, "max_count" })
	t.eq({ gens:add("gen_x") }, { false, "unknown" })
	t.eq({ gens:add("gen_a", 0) }, { false, "invalid_count" })
	t.eq(gens:tick(10), {}, "first tick starts the clock")
	t.eq(gens:tick(11), {}, "0.4 carried")
	t.eq(gens:tick(12), {}, "0.8 carried")
	t.eq(gens:tick(13), { currency_a = 1 }, "1.2 -> 1, carry 0.2")
	t.eq(gens:tick(5), {}, "a clock going backwards restarts without producing")
	t.eq(gens:tick(245), { currency_a = 96 }, "0.2 + 96 -> 96, carry 0.2")
	t.eq(gens:stored("gen_a"), 97)
	t.eq(gens:tick(255), { currency_a = 3 }, "4.2 due but storage 100 takes 3; the rest is wasted")
	t.eq(gens:stored("gen_a"), 100)
	t.eq(gens:tick(300), {})
	t.eq(gens:collect(), { currency_a = 100 })
	t.eq(gens:stored(), { gen_a = 0, gen_b = 0, gen_c = 0 })
	gens:add("gen_b", 2)
	gens:setMultiplier(1.5)
	gens:setMultiplier(2, "gen_b")
	t.eq(gens:rates(), { currency_a = 0.4 * 1.5 + 2 * 2 * 1.5 * 2, currency_b = 0 })
	t.eq(gens:tick(301), { currency_a = 12 })
	t.throws(function()
		gens:setMultiplier(-1)
	end)
	t.throws(function()
		gens:tick(0 / 0)
	end)
	t.ok((gens:remove("gen_b", 2)))
	t.eq({ gens:remove("gen_b", 1) }, { false, "invalid_count" })
end)

test("offline earnings use server UTC under the cap, credit once and ignore skew", function(t)
	local gens = Generators.new(DEFS, { offlineCap = 3600, offlineRate = 0.5 })
	gens:add("gen_c", 2)
	t.eq(gens:offline(1000).seconds, 0, "first join has no earlier save")
	gens:markSeen(1000)
	local short = gens:offline(1600)
	t.eq({ short.seconds, short.capped, short.produced }, { 600, false, { currency_b = 600 } })
	t.eq(gens:offline(1600).seconds, 0, "a second call credits nothing")
	gens:markSeen(2000)
	local long = gens:offline(2000 + 86400)
	t.eq(
		{ long.seconds, long.elapsed, long.capped, long.produced },
		{ 3600, 86400, true, { currency_b = 3600 } }
	)
	gens:markSeen(5000)
	local skew = gens:offline(4000)
	t.eq({ skew.seconds, skew.skew, skew.produced }, { 0, true, {} })
	local none = Generators.new(DEFS)
	none:add("gen_c")
	none:markSeen(0)
	t.eq(none:offline(500).produced, {}, "offlineCap defaults to 0: no offline earnings")
	t.throws(function()
		gens:offline(-1)
	end)
end)

test("collected output credits a wallet; a refused credit is put back", function(t)
	local gens = Generators.new(DEFS)
	local wallet = Wallet.new({ currencies = { currency_a = { cap = 5 }, currency_b = {} } })
	gens:add("gen_b")
	gens:tick(0)
	gens:tick(4)
	local collected = gens:collect("gen_b")
	t.eq(collected, { currency_a = 8 })
	local ok, err = wallet:credit("currency_a", collected.currency_a, "TimedReward")
	t.eq({ ok, err }, { false, "at_cap" })
	gens:putBack("gen_b", collected.currency_a)
	t.eq(gens:stored("gen_b"), 8, "nothing lost")
end)

test("generator state round-trips and drops unknown ids with notes", function(t)
	local gens = Generators.new(DEFS, { offlineCap = 60 })
	gens:add("gen_a", 2)
	gens:setMultiplier(3, "gen_a")
	gens:tick(0)
	gens:tick(1.3)
	gens:markSeen(77)
	local again = Generators.new(DEFS, { offlineCap = 60, data = gens:serialize() })
	t.eq(again:serialize(), gens:serialize())
	local dropped = Generators.new(DEFS, {
		data = {
			schema = "generators/1",
			count = { gen_retired = 4, gen_a = -1 },
			stored = { gen_b = 2.5 },
		},
	})
	t.ok(contains(dropped.notes, 'dropped count for unknown generator "gen_retired"'))
	t.ok(contains(dropped.notes, "count.gen_a invalid"))
	t.ok(contains(dropped.notes, "stored.gen_b invalid"))
	t.ok(contains(Generators.new(DEFS, { data = "x" }).notes, "not generators/1"))
end)

return cases
