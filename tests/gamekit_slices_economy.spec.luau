--!strict
-- Economy slices: two seeded end-to-end loops composed from the G3 kits, with invariants checked
-- every run and a digest per slice stored in tests/golden/gamekit-economy.json (same seed, same
-- digest; a changed digest is a behaviour change that must be intended).
--   plot_generator   tycoon / idle: plots, an unlock graph of buttons paid through Wallet,
--                    generators with storage caps, collection, offline earnings under a cap
--   collection_loop  pet collection / simulator: earn, an odds table with pity and exact
--                    disclosure, inventory with several follower slots, selling when full,
--                    objectives, progression, followers formation and a closing trade
-- Every number is a neutral fixture number; nothing here is tuned for a game.
local Events = require("../packages/GameKit/Events")
local Followers = require("../packages/GameKit/Followers")
local Generators = require("../packages/GameKit/Generators")
local Inventory = require("../packages/GameKit/Inventory")
local ItemDefs = require("../packages/GameKit/ItemDefs")
local Objectives = require("../packages/GameKit/Objectives")
local OddsTable = require("../packages/GameKit/OddsTable")
local Plots = require("../packages/GameKit/Plots")
local Progression = require("../packages/GameKit/Progression")
local Rng = require("../packages/ProcGen/Rng")
local Trade = require("../packages/GameKit/Trade")
local UnlockGraph = require("../packages/GameKit/UnlockGraph")
local Wallet = require("../packages/GameKit/Wallet")
local FakeEnv = require("./fakes/FakeEnv")
local Golden = require("./lib/Golden")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local UTC0 = 1791244800 -- 2026-10-06T00:00:00Z

-- Per player and currency: sum of credits minus debits seen in wallet events.
local function ledger(sink: any): { [string]: { [string]: number } }
	local out = {}
	for _, event in sink.events do
		if event.economy then
			local player = event.player or "?"
			out[player] = out[player] or {}
			local sign = if event.economy.flow == "source" then 1 else -1
			out[player][event.economy.currency] = (out[player][event.economy.currency] or 0)
				+ sign * event.economy.amount
		end
	end
	return out
end

local function eventCounts(sink: any): { [string]: number }
	local out = {}
	for _, event in sink.events do
		out[event.name] = (out[event.name] or 0) + 1
	end
	return out
end

-- ---------------------------------------------------------------- plot_generator

local BUTTONS = {
	{ id = "gen_a_1" },
	{ id = "gen_a_2", requires = { "gen_a_1" }, cost = { currency_a = 20 } },
	{ id = "gen_b_1", requires = { "gen_a_1" }, cost = { currency_a = 35 } },
	{ id = "boost_a", requires = { "gen_a_2", "gen_b_1" }, mode = "any", cost = { currency_a = 60 } },
	{ id = "gen_b_2", requires = { "gen_a_2", "gen_b_1" }, cost = { currency_a = 80, currency_b = 5 } },
}
local EFFECTS: { [string]: (gens: any) -> () } = {
	gen_a_1 = function(gens)
		gens:add("gen_a")
	end,
	gen_a_2 = function(gens)
		gens:add("gen_a")
	end,
	gen_b_1 = function(gens)
		gens:add("gen_b")
	end,
	gen_b_2 = function(gens)
		gens:add("gen_b")
	end,
	boost_a = function(gens)
		gens:setMultiplier(2, "gen_a")
	end,
}

-- Collects every generator into the wallet. A full wallet (clamp cap) takes what fits and the
-- rest goes back to generator storage (Generators.putBack), so nothing is created or lost.
local function collectInto(p: any, reason: string, problems: { string })
	for _, gen in { "gen_a", "gen_b" } do
		for currency, amount in p.gens:collect(gen) do
			local ok, err, applied = p.wallet:credit(currency, amount, reason)
			local kept = if ok then applied or amount else 0
			if not ok and err ~= "at_cap" then
				table.insert(problems, p.key .. " credit refused: " .. tostring(err))
			end
			if kept < amount then
				p.gens:putBack(gen, amount - kept)
				p.putBack += amount - kept
			end
		end
	end
end

local function plotGenerator(seed: string): (any, { string })
	local env = FakeEnv.new({ start = 0 })
	local sink = Events.recorder({ clock = env.clock, strict = true })
	local problems = {}
	local layout = {}
	for index = 1, 4 do
		local x = (index - 1) * 100
		table.insert(layout, {
			id = "plot_" .. index,
			bounds = { min = { x = x, y = 0, z = 0 }, max = { x = x + 80, y = 40, z = 80 } },
		})
	end
	local plots = Plots.new({ plots = layout, assign = "seeded", seed = seed }, env)
	local graph = UnlockGraph.define(BUTTONS)
	local players = {}
	for _, key in { "p1", "p2", "p3" } do
		local ok, plot = plots:claim(key)
		if not ok then
			table.insert(problems, key .. " got no plot: " .. plot)
		end
		local wallet = Wallet.new({
			currencies = { currency_a = {}, currency_b = { cap = 40, overflow = "clamp" } },
			sink = sink,
			player = key,
		}, env)
		local gens = Generators.new({
			{ id = "gen_a", currency = "currency_a", rate = 0.5, storage = 60 },
			{ id = "gen_b", currency = "currency_b", rate = 0.05, storage = 10 },
		}, { offlineCap = 3600, offlineRate = 0.5 })
		local tracker = UnlockGraph.new(graph, { sink = sink, player = key })
		table.insert(players, {
			key = key,
			wallet = wallet,
			gens = gens,
			tracker = tracker,
			rng = Rng.new(seed .. ":" .. key),
			nextCollect = 0,
			unlockOrder = {},
			putBack = 0,
		})
	end
	for second = 0, 900, 5 do
		for _, p in players do
			p.gens:tick(second)
			if second >= p.nextCollect then
				p.nextCollect = second + p.rng:int(10, 30)
				collectInto(p, "Gameplay", problems)
				for _, id in p.tracker:available() do
					local ok = p.tracker:unlock(id, p.wallet)
					if ok then
						EFFECTS[id](p.gens)
						table.insert(p.unlockOrder, { id = id, at = second })
					end
				end
			end
		end
	end
	-- Everyone leaves at 900 s and rejoins two hours later (offline credit is capped at 3600 s).
	local offline = {}
	for _, p in players do
		p.gens:markSeen(UTC0 + 900)
		local result = p.gens:offline(UTC0 + 900 + 7200)
		offline[p.key] = result
		-- Offline production lands in generator storage (capped there); collect it once.
		collectInto(p, "TimedReward", problems)
		local again = p.gens:offline(UTC0 + 900 + 7200)
		if next(again.produced) ~= nil then
			table.insert(problems, p.key .. " offline credited twice")
		end
	end
	-- Invariants.
	local seen = {}
	for plot, owner in plots:snapshot() do
		if seen[owner] then
			table.insert(problems, owner .. " owns two plots")
		end
		seen[owner] = plot
	end
	local flows = ledger(sink)
	local state = { plots = plots:snapshot(), players = {}, events = eventCounts(sink) }
	for _, p in players do
		for _, currency in { "currency_a", "currency_b" } do
			local balance = p.wallet:balance(currency)
			local net = (flows[p.key] or {})[currency] or 0
			if balance ~= net then
				table.insert(
					problems,
					string.format("%s %s balance %d but events net %d", p.key, currency, balance, net)
				)
			end
			if balance < 0 then
				table.insert(problems, p.key .. " negative " .. currency)
			end
		end
		for _, id in p.tracker:unlocked() do
			if not p.tracker:requirementsMet(id) then
				table.insert(problems, p.key .. " unlocked " .. id .. " without its requirements")
			end
		end
		state.players[p.key] = {
			plot = plots:plotOf(p.key),
			balances = p.wallet:balances(),
			unlocks = p.unlockOrder,
			generators = p.gens:serialize(),
			offline = offline[p.key],
			putBack = p.putBack,
		}
	end
	if #sink.rejected > 0 then
		table.insert(problems, #sink.rejected .. " events rejected by the strict recorder")
	end
	return state, problems
end

-- ---------------------------------------------------------------- collection_loop

local ITEMS = ItemDefs.registry({
	{ id = "follower_a", kind = "follower", stackable = false, maxStack = 1, slot = "follower" },
	{ id = "follower_b", kind = "follower", stackable = false, maxStack = 1, slot = "follower" },
	{ id = "follower_c", kind = "follower", stackable = false, maxStack = 1, slot = "follower" },
})
local SLOTS = { follower_1 = "follower", follower_2 = "follower", follower_3 = "follower" }
local ROLL_COST, SELL_VALUE, CAPACITY = 25, 5, 12

local function power(entry: any): number
	return entry.data and entry.data.power or 0
end

local function collectionLoop(seed: string): (any, { string })
	local env = FakeEnv.new({ start = 0 })
	local sink = Events.recorder({ clock = env.clock, strict = true })
	local problems = {}
	local odds = OddsTable.new({
		{ id = "follower_a", weight = 60 },
		{ id = "follower_b", weight = 30 },
		{ id = "follower_c", weight = 10 },
	}, Rng.new(seed .. ":odds"), { name = "table_a", pity = { threshold = 10, targets = { "follower_c" } } })
	local disclosure = odds:disclose()
	local units = 0
	for _, line in disclosure.entries do
		units += line.units
	end
	if units ~= OddsTable.SCALE then
		table.insert(problems, "disclosure sums to " .. units)
	end
	local paidTable = OddsTable.new(odds:entries(), Rng.new(seed .. ":paid"), { paid = true })
	local paidOk, paidReason = paidTable:tryRoll({})
	if paidOk or paidReason ~= "policy_missing" then
		table.insert(problems, "a paid roll without policy was not refused")
	end
	local objectives = Objectives.define({ { id = "roll_10", counter = "roll", target = 10 } })
	local curve = Progression.curve({ kind = "linear", base = 50, step = 25, maxLevel = 20 })
	local players = {}
	for _, key in { "p1", "p2" } do
		table.insert(players, {
			key = key,
			wallet = Wallet.new({ currencies = { currency_a = {} }, sink = sink, player = key }, env),
			inventory = Inventory.new(
				{ items = ITEMS, owner = key, capacity = CAPACITY, equipSlots = SLOTS },
				env
			),
			objectives = Objectives.new(objectives, { sink = sink, player = key }),
			track = Progression.new({ curve = curve, path = "level", sink = sink, player = key }, env),
			rng = Rng.new(seed .. ":" .. key),
			pity = 0,
			longestDry = 0,
			rolls = {},
			sold = 0,
		})
	end
	for _ = 1, 300 do
		for _, p in players do
			local earned = p.rng:int(1, 8)
			p.wallet:credit("currency_a", earned, "Gameplay")
			p.track:addXp(earned)
			if p.wallet:balance("currency_a") < ROLL_COST then
				continue
			end
			if p.inventory:free() == 0 then
				-- Sell the weakest unequipped follower to make room.
				local weakest = nil
				for _, entry in p.inventory:entries() do
					if
						not p.inventory:isEquipped(entry.uid)
						and (weakest == nil or power(entry) < power(weakest))
					then
						weakest = entry
					end
				end
				if weakest and p.inventory:apply({ { op = "remove", uid = weakest.uid } }) then
					p.wallet:credit("currency_a", SELL_VALUE, "sell", { sku = weakest.item })
					p.sold += 1
				end
			end
			local ok = p.wallet:debit("currency_a", ROLL_COST, "Shop", { sku = "table_a" })
			if not ok then
				continue
			end
			local result = odds:roll({ pity = p.pity })
			p.pity = result.pity
			p.longestDry = math.max(p.longestDry, result.pity)
			p.rolls[result.id] = (p.rolls[result.id] or 0) + 1
			local added = p.inventory:add(result.id, 1, { power = p.rng:int(1, 100) })
			if not added then
				table.insert(problems, p.key .. " rolled into a full inventory")
			end
			p.objectives:record("roll", 1)
			-- Equip the three strongest followers.
			local ranked = p.inventory:entries()
			table.sort(ranked, function(a: any, b: any): boolean
				if power(a) ~= power(b) then
					return power(a) > power(b)
				end
				return a.uid < b.uid
			end)
			local ops = {}
			for index = 1, 3 do
				if ranked[index] then
					table.insert(ops, { op = "equip", uid = ranked[index].uid, slot = "follower_" .. index })
				end
			end
			if not p.inventory:apply(ops) then
				table.insert(problems, p.key .. " could not equip")
			end
		end
	end
	-- Followers stand in an arc behind each leader.
	local formations = {}
	for _, p in players do
		local group = Followers.new({ formation = "arc", spacing = 3, distance = 6 })
		for index = 1, 3 do
			local uid = p.inventory:equipped("follower_" .. index)
			if uid then
				group:add(uid)
			end
		end
		local frames = group:step(0, { position = { x = 0, y = 0, z = 0 }, yaw = 30 })
		local placed = {}
		for _, frame in frames do
			table.insert(placed, {
				slot = frame.slot,
				x = math.round(frame.position.x * 1000) / 1000,
				z = math.round(frame.position.z * 1000) / 1000,
			})
		end
		formations[p.key] = placed
	end
	-- A closing trade: p1's weakest unequipped follower for 10 currency_a from p2.
	local a, b = players[1], players[2]
	local offerUid = nil
	for _, entry in a.inventory:entries() do
		if
			not a.inventory:isEquipped(entry.uid)
			and (offerUid == nil or power(entry) < power(a.inventory:get(offerUid)))
		then
			offerUid = entry.uid
		end
	end
	if b.inventory:free() == 0 then
		local spare = nil
		for _, entry in b.inventory:entries() do
			if not b.inventory:isEquipped(entry.uid) then
				spare = entry
			end
		end
		b.inventory:apply({ { op = "remove", uid = spare.uid } })
		b.wallet:credit("currency_a", SELL_VALUE, "sell", { sku = spare.item })
		b.sold += 1
	end
	local trade = Trade.new(
		{ id = "slice_trade", a = a, b = b, countdown = 1, currencies = { "currency_a" }, sink = sink },
		env
	)
	trade:addInstance("a", offerUid)
	trade:setCurrency("b", "currency_a", 10)
	trade:accept("a", trade:revision())
	trade:accept("b", trade:revision())
	env:advance(1)
	trade:confirm("a")
	trade:confirm("b")
	if trade:state() ~= "committed" then
		table.insert(
			problems,
			"the closing trade did not commit: " .. trade:state() .. " " .. tostring(trade:reason())
		)
	end
	if b.inventory:get(offerUid) == nil or a.inventory:get(offerUid) ~= nil then
		table.insert(problems, "the traded follower did not move exactly once")
	end
	-- Invariants.
	local flows = ledger(sink)
	local state = {
		disclosure = {},
		players = {},
		formations = formations,
		trade = trade:serialize(),
		events = eventCounts(sink),
	}
	for _, line in disclosure.entries do
		table.insert(state.disclosure, line.id .. " " .. line.text)
	end
	for _, p in players do
		if p.longestDry > 10 then
			table.insert(problems, p.key .. " went " .. p.longestDry .. " rolls without a pity target")
		end
		if p.wallet:balance("currency_a") ~= (flows[p.key] or {}).currency_a then
			table.insert(problems, p.key .. " wallet and events disagree")
		end
		local rolled = 0
		for _, count in p.rolls do
			rolled += count
		end
		local held = #p.inventory:entries()
		local traded = if p == a then -1 else 1
		if held ~= rolled - p.sold + traded then
			table.insert(
				problems,
				string.format(
					"%s holds %d followers after %d rolls, %d sold, %d traded",
					p.key,
					held,
					rolled,
					p.sold,
					traded
				)
			)
		end
		state.players[p.key] = {
			rolls = p.rolls,
			sold = p.sold,
			level = p.track:level(),
			objective = p.objectives:state("roll_10"),
			balance = p.wallet:balance("currency_a"),
			equipped = p.inventory:equipped(),
			held = held,
		}
	end
	if #sink.rejected > 0 then
		table.insert(problems, #sink.rejected .. " events rejected by the strict recorder")
	end
	return state, problems
end

local SLICES: { [string]: (seed: string) -> (any, { string }) } = {
	plot_generator = plotGenerator,
	collection_loop = collectionLoop,
}

test("plot_generator keeps its invariants and repeats for the same seed", function(t)
	local state, problems = plotGenerator("plot_generator")
	t.eq(problems, {}, table.concat(problems, " | "))
	local again = plotGenerator("plot_generator")
	t.eq(Golden.digest(again), Golden.digest(state))
	for _, p in state.players do
		t.ok(#p.unlocks >= 3, "players progress through the buttons")
		t.ok(p.offline.capped and p.offline.seconds == 3600, "offline earnings use the cap")
	end
	local other = plotGenerator("plot_generator_other")
	t.ok(Golden.digest(other) ~= Golden.digest(state), "another seed plays differently")
end)

test("collection_loop keeps its invariants and repeats for the same seed", function(t)
	local state, problems = collectionLoop("collection_loop")
	t.eq(problems, {}, table.concat(problems, " | "))
	t.eq(Golden.digest(collectionLoop("collection_loop")), Golden.digest(state))
	t.eq(state.trade, "fsm/1:trade:committed")
	for _, p in state.players do
		t.eq(p.objective, "completed")
		t.ok(p.sold > 0, "the loop fills the inventory and sells")
		t.ok(p.equipped.follower_3 ~= nil)
	end
end)

test("slice digests match tests/golden/gamekit-economy.json", function(t)
	local golden = {}
	for name, run in SLICES do
		local state = run(name)
		golden[name] = { digest = Golden.digest(state), events = state.events }
	end
	Golden.assert("gamekit-economy", golden)
	t.ok(true)
end)

return cases
