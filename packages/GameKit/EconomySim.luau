--!strict
-- @tier T0
-- EconomySim: an offline Monte Carlo of earn and spend curves for tuning. It runs in Lune (specs,
-- tools); never on a live server. Every number comes from the caller; nothing is chosen here.
--
--   EconomySim.run({
--     seed, players,
--     sessions = { count, seconds = n | { min, max }, gap? = n | { min, max } },
--     horizon? = play seconds per player (the last session is cut short),
--     currencies = { [id] = { initial?, cap?, overflow? = "clamp" | "reject" } },
--     rates? = { [currency] = units per second while playing (fractions carry) },
--     offline? = { [currency] = { perSecond, capSeconds } } (between sessions, whole units),
--     actions = { { id, every = n | { min, max }, chance?, limit?, earn?, spend?, needs? } },
--     milestones? = { { id, currency, threshold, measure? = "balance" | "earned" } },
--     targets? = { [currency] = { sinkRatio? = { min?, max? }, netPerHour? = { min?, max? } } },
--     percentiles? = { 10, 50, 90 }, step? = 60, maxEvents?,
--   }) -> economy-sim/1 report
--
-- Actions fire every `every` seconds of play (drawn per firing), pass a chance roll, then apply
-- atomically like Wallet.transact: all spends and earns or nothing (blocked by needs,
-- insufficient_funds or at_cap for "reject" currencies; "clamp" wastes the overflow). Passive
-- rates are integrated every `step` seconds. The report has, per currency, sourced, sunk and
-- wasted totals with a per-source breakdown, the sink ratio (sunk / sourced), percentiles of end
-- balance and of net change per play hour (inflation of the supply a player holds), mean curves
-- per session index, and per milestone the reached fraction and time-to-threshold percentiles in
-- play seconds and sessions (absent when that share of players never reached it). Percentiles
-- are nearest-rank. Same options and seed give the same report.
local Check = require("./Check")
local Rng = require("../ProcGen/Rng")

local EconomySim = {}
EconomySim.SCHEMA = "economy-sim/1"
EconomySim.PERCENTILES = table.freeze({ 10, 50, 90 })
EconomySim.STEP = 60 -- passive integration step in seconds (convention)
EconomySim.MAX_EVENTS = 5000000 -- work bound per run (convention)
EconomySim.MAX_PLAYERS = 100000

export type Range = number | { min: number, max: number }
export type Action = {
	id: string,
	every: Range,
	chance: number?,
	limit: number?,
	earn: { [string]: Range }?,
	spend: { [string]: Range }?,
	needs: { [string]: number }?,
}
export type Options = {
	seed: number | string,
	players: number,
	sessions: { count: number, seconds: Range, gap: Range? },
	horizon: number?,
	currencies: { [string]: { initial: number?, cap: number?, overflow: ("clamp" | "reject")? } },
	rates: { [string]: number }?,
	offline: { [string]: { perSecond: number, capSeconds: number } }?,
	actions: { Action },
	milestones: { { id: string, currency: string, threshold: number, measure: ("balance" | "earned")? } }?,
	targets: {
		[string]: { sinkRatio: { min: number?, max: number? }?, netPerHour: { min: number?, max: number? }? },
	}?,
	percentiles: { number }?,
	step: number?,
	maxEvents: number?,
}

local function round4(value: number): number
	return math.floor(value * 10000 + 0.5) / 10000
end

local function sortedKeys(map: { [string]: any }?): { string }
	local keys = {}
	for key in map or {} do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function rangeOk(value: any, low: number): boolean
	if type(value) == "number" then
		return Check.integer(value) and value >= low
	end
	return type(value) == "table"
		and Check.integer(value.min)
		and Check.integer(value.max)
		and value.min >= low
		and value.min <= value.max
end

local function rangeMin(value: Range): number
	return if type(value) == "number" then value else value.min
end

local function rangeMax(value: Range): number
	return if type(value) == "number" then value else value.max
end

local function draw(rng: Rng.Rng, value: Range): number
	if type(value) == "number" then
		return value
	end
	if value.min == value.max then
		return value.min
	end
	return rng:int(value.min, value.max)
end

-- Nearest-rank percentile of an ascending list (nil when empty or the rank is math.huge).
function EconomySim.percentile(sorted: { number }, p: number): number?
	if #sorted == 0 then
		return nil
	end
	local rank = math.clamp(math.ceil(p / 100 * #sorted), 1, #sorted)
	local value = sorted[rank]
	if value == math.huge then
		return nil
	end
	return value
end

local function bounds(problems: { string }, where: string, value: any)
	if value == nil then
		return
	end
	if type(value) ~= "table" then
		table.insert(problems, where .. " must be { min?, max? }")
		return
	end
	if
		(value.min ~= nil and not Check.finite(value.min))
		or (value.max ~= nil and not Check.finite(value.max))
	then
		table.insert(problems, where .. " bounds must be finite numbers")
	elseif value.min ~= nil and value.max ~= nil and value.min > value.max then
		table.insert(problems, where .. " min is above max")
	end
end

-- Problems with options (empty when valid), including the estimated work bound.
function EconomySim.validate(options: any): { string }
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	local problems = {}
	if type(options.seed) ~= "number" and type(options.seed) ~= "string" then
		table.insert(problems, "seed is required (number or string)")
	end
	if
		not (
			Check.integer(options.players)
			and options.players >= 1
			and options.players <= EconomySim.MAX_PLAYERS
		)
	then
		table.insert(problems, "players must be an integer from 1 to " .. EconomySim.MAX_PLAYERS)
	end
	local sessions = options.sessions
	if type(sessions) ~= "table" then
		table.insert(problems, "sessions must be { count, seconds, gap? }")
	else
		if not (Check.integer(sessions.count) and sessions.count >= 1) then
			table.insert(problems, "sessions.count must be an integer >= 1")
		end
		if not rangeOk(sessions.seconds, 1) then
			table.insert(problems, "sessions.seconds must be an integer >= 1 or { min, max }")
		end
		if sessions.gap ~= nil and not rangeOk(sessions.gap, 0) then
			table.insert(problems, "sessions.gap must be an integer >= 0 or { min, max }")
		end
	end
	if options.horizon ~= nil and not (Check.integer(options.horizon) and options.horizon >= 1) then
		table.insert(problems, "horizon must be an integer >= 1 (play seconds)")
	end
	local currencies = options.currencies
	if type(currencies) ~= "table" or next(currencies) == nil then
		table.insert(problems, "currencies must be a non-empty map")
		currencies = {}
	end
	for id, config in currencies do
		local where = "currency " .. Check.describe(id)
		if not Check.label(id) then
			table.insert(problems, where .. ": id must be a label")
		end
		if type(config) ~= "table" then
			table.insert(problems, where .. ": config must be a table")
			continue
		end
		if config.initial ~= nil and not (Check.integer(config.initial) and config.initial >= 0) then
			table.insert(problems, where .. ": initial must be an integer >= 0")
		end
		if config.cap ~= nil and not (Check.integer(config.cap) and config.cap >= 1) then
			table.insert(problems, where .. ": cap must be an integer >= 1")
		elseif config.cap ~= nil and config.initial ~= nil and config.initial > config.cap then
			table.insert(problems, where .. ": initial is above cap")
		end
		if config.overflow ~= nil and config.overflow ~= "clamp" and config.overflow ~= "reject" then
			table.insert(problems, where .. ": overflow must be clamp or reject")
		end
	end
	local function known(where: string, currency: any)
		if currencies[currency] == nil then
			table.insert(problems, where .. ": unknown currency " .. Check.describe(currency))
		end
	end
	for currency, rate in options.rates or {} do
		known("rates", currency)
		if not (Check.finite(rate) and rate >= 0) then
			table.insert(problems, "rates." .. tostring(currency) .. " must be a finite number >= 0")
		end
	end
	for currency, config in options.offline or {} do
		known("offline", currency)
		if
			type(config) ~= "table"
			or not (Check.finite(config.perSecond) and config.perSecond >= 0)
			or not (Check.integer(config.capSeconds) and config.capSeconds >= 0)
		then
			table.insert(
				problems,
				"offline." .. tostring(currency) .. " must be { perSecond >= 0, capSeconds >= 0 }"
			)
		end
	end
	local minEvery = math.huge
	if type(options.actions) ~= "table" then
		table.insert(problems, "actions must be a list (it may be empty)")
	else
		local seen = {}
		for index, action in options.actions do
			local where = "action "
				.. (
					if type(action) == "table" and type(action.id) == "string"
						then action.id
						else "#" .. index
				)
			if type(action) ~= "table" then
				table.insert(problems, where .. ": must be a table")
				continue
			end
			if not Check.label(action.id) then
				table.insert(problems, where .. ": id must be a label")
			elseif seen[action.id] then
				table.insert(problems, where .. ": duplicate id")
			end
			seen[action.id] = true
			if not rangeOk(action.every, 1) then
				table.insert(problems, where .. ": every must be an integer >= 1 or { min, max } (seconds)")
			else
				minEvery = math.min(minEvery, rangeMin(action.every))
			end
			if
				action.chance ~= nil
				and not (Check.finite(action.chance) and action.chance > 0 and action.chance <= 1)
			then
				table.insert(problems, where .. ": chance must be in (0, 1]")
			end
			if action.limit ~= nil and not (Check.integer(action.limit) and action.limit >= 1) then
				table.insert(problems, where .. ": limit must be an integer >= 1 (per session)")
			end
			if action.earn == nil and action.spend == nil then
				table.insert(problems, where .. ": needs earn or spend")
			end
			for _, key in { "earn", "spend" } do
				local map = action[key]
				if map ~= nil and type(map) ~= "table" then
					table.insert(problems, where .. ": " .. key .. " must map currency -> amount")
					continue
				end
				for currency, amount in map or {} do
					known(where .. " " .. key, currency)
					if not rangeOk(amount, 0) then
						table.insert(
							problems,
							where
								.. ": "
								.. key
								.. "."
								.. tostring(currency)
								.. " must be an integer >= 0 or { min, max }"
						)
					end
				end
			end
			for currency, amount in action.needs or {} do
				known(where .. " needs", currency)
				if not (Check.integer(amount) and amount >= 0) then
					table.insert(
						problems,
						where .. ": needs." .. tostring(currency) .. " must be an integer >= 0"
					)
				end
			end
			for key in action do
				if not table.find({ "id", "every", "chance", "limit", "earn", "spend", "needs" }, key) then
					table.insert(problems, where .. ": unknown key " .. Check.describe(key))
				end
			end
		end
	end
	local milestoneIds = {}
	for index, milestone in options.milestones or {} do
		local where = "milestone "
			.. (
				if type(milestone) == "table" and type(milestone.id) == "string"
					then milestone.id
					else "#" .. index
			)
		if type(milestone) ~= "table" or not Check.label(milestone.id) then
			table.insert(problems, where .. ": needs a label id")
			continue
		end
		if milestoneIds[milestone.id] then
			table.insert(problems, where .. ": duplicate id")
		end
		milestoneIds[milestone.id] = true
		known(where, milestone.currency)
		if not (Check.integer(milestone.threshold) and milestone.threshold >= 1) then
			table.insert(problems, where .. ": threshold must be an integer >= 1")
		end
		if milestone.measure ~= nil and milestone.measure ~= "balance" and milestone.measure ~= "earned" then
			table.insert(problems, where .. ": measure must be balance or earned")
		end
	end
	for currency, target in options.targets or {} do
		known("targets", currency)
		if type(target) ~= "table" then
			table.insert(problems, "targets." .. tostring(currency) .. " must be a table")
		else
			bounds(problems, "targets." .. tostring(currency) .. ".sinkRatio", target.sinkRatio)
			bounds(problems, "targets." .. tostring(currency) .. ".netPerHour", target.netPerHour)
		end
	end
	if options.percentiles ~= nil then
		local ok = type(options.percentiles) == "table" and #options.percentiles > 0
		for _, p in (if ok then options.percentiles else {}) :: { any } do
			ok = ok and Check.integer(p) and p >= 1 and p <= 100
		end
		if not ok then
			table.insert(problems, "percentiles must be a non-empty list of integers from 1 to 100")
		end
	end
	if options.step ~= nil and not (Check.integer(options.step) and options.step >= 1) then
		table.insert(problems, "step must be an integer >= 1 (seconds)")
	end
	if options.maxEvents ~= nil and not (Check.integer(options.maxEvents) and options.maxEvents >= 1) then
		table.insert(problems, "maxEvents must be an integer >= 1")
	end
	if #problems == 0 then
		local seconds = rangeMax(sessions.seconds)
		local perSession = seconds / (options.step or EconomySim.STEP) + 1
		if minEvery < math.huge then
			perSession += #options.actions * (seconds / minEvery + 1)
		end
		local estimate = options.players * sessions.count * perSession
		local limit = options.maxEvents or EconomySim.MAX_EVENTS
		if estimate > limit then
			table.insert(
				problems,
				string.format(
					"estimated work %d events passes maxEvents %d (fewer players, sessions or a larger step)",
					math.ceil(estimate),
					limit
				)
			)
		end
	end
	return problems
end

local function sortedCopy(values: { number }): { number }
	local sorted = table.clone(values)
	table.sort(sorted)
	return sorted
end

local function percentiles(values: { number }, ps: { number }, rounding: boolean): { [string]: number }
	local sorted = sortedCopy(values)
	local out = {}
	for _, p in ps do
		local value = EconomySim.percentile(sorted, p)
		if value ~= nil then
			out["p" .. p] = if rounding then round4(value) else value
		end
	end
	return out
end

-- Runs the simulation. Raises with every problem listed when options are invalid.
function EconomySim.run(options: Options): any
	local problems = EconomySim.validate(options)
	if #problems > 0 then
		error("EconomySim.run: " .. table.concat(problems, "; "), 2)
	end
	local ps = options.percentiles or EconomySim.PERCENTILES
	local step = options.step or EconomySim.STEP
	local currencyIds = sortedKeys(options.currencies)
	local rateIds = {}
	for _, id in currencyIds do
		if (options.rates or {})[id] and (options.rates :: any)[id] > 0 then
			table.insert(rateIds, id)
		end
	end
	local actions = options.actions
	local milestones = options.milestones or {}
	local sessionCount = options.sessions.count

	-- Aggregates.
	local totals = {}
	for _, id in currencyIds do
		totals[id] = {
			sourced = 0,
			sunk = 0,
			wasted = 0,
			sources = {},
			sinks = {},
			endBalance = {},
			netPerHour = {},
			sourcedPerHour = {},
			sunkPerHour = {},
			bySession = {},
		}
		for s = 1, sessionCount do
			totals[id].bySession[s] = { players = 0, balance = 0, sourced = 0, sunk = 0 }
		end
	end
	local actionStats = {}
	for _, action in actions do
		actionStats[action.id] = { fired = 0, blocked = 0, skipped = 0, limited = 0, blockedBy = {} }
	end
	local milestoneSeconds, milestoneSessions = {}, {}
	for _, milestone in milestones do
		milestoneSeconds[milestone.id] = {}
		milestoneSessions[milestone.id] = {}
	end
	local played = {}

	for player = 1, options.players do
		local rng = Rng.new("economy_sim:" .. tostring(options.seed) .. ":player:" .. player)
		local balance, earned, carry = {}, {}, {}
		local sourced, sunk = {}, {}
		for _, id in currencyIds do
			balance[id] = options.currencies[id].initial or 0
			earned[id] = 0
			carry[id] = 0
			sourced[id] = 0
			sunk[id] = 0
		end
		local reachedAt: { [string]: { number } } = {}
		local playTime = 0
		local session = 0

		local function checkMilestones(currency: string, now: number)
			for _, milestone in milestones do
				if milestone.currency == currency and reachedAt[milestone.id] == nil then
					local value = if milestone.measure == "earned"
						then earned[currency]
						else balance[currency]
					if value >= milestone.threshold then
						reachedAt[milestone.id] = { playTime + now, session }
					end
				end
			end
		end

		-- Credits up to the cap; returns the applied amount (the rest is wasted).
		local function credit(currency: string, amount: number, source: string, now: number): number
			if amount <= 0 then
				return 0
			end
			local cap = options.currencies[currency].cap
			local applied = amount
			if cap ~= nil and balance[currency] + amount > cap then
				applied = math.max(cap - balance[currency], 0)
				totals[currency].wasted += amount - applied
			end
			balance[currency] += applied
			earned[currency] += applied
			sourced[currency] += applied
			totals[currency].sources[source] = (totals[currency].sources[source] or 0) + applied
			checkMilestones(currency, now)
			return applied
		end

		local function passive(dt: number, now: number)
			if dt <= 0 then
				return
			end
			for _, id in rateIds do
				carry[id] += (options.rates :: any)[id] * dt
				local whole = math.floor(carry[id] + 1e-9)
				if whole > 0 then
					carry[id] -= whole
					credit(id, whole, "passive", now)
				end
			end
		end

		local function fire(action: Action, stats: any, now: number)
			if action.chance ~= nil and action.chance < 1 and rng:next() >= action.chance then
				stats.skipped += 1
				return
			end
			local spends, earns = {}, {}
			for _, id in sortedKeys(action.spend) do
				spends[id] = draw(rng, (action.spend :: any)[id])
			end
			for _, id in sortedKeys(action.earn) do
				earns[id] = draw(rng, (action.earn :: any)[id])
			end
			local reason: string? = nil
			for id, need in action.needs or {} do
				if balance[id] < need then
					reason = "needs"
				end
			end
			if reason == nil then
				for id, amount in spends do
					if balance[id] < amount then
						reason = "insufficient_funds"
					end
				end
			end
			if reason == nil then
				for id, amount in earns do
					local config = options.currencies[id]
					local after = balance[id] - (spends[id] or 0) + amount
					if config.cap ~= nil and config.overflow == "reject" and after > config.cap then
						reason = "at_cap"
					end
				end
			end
			if reason then
				stats.blocked += 1
				stats.blockedBy[reason] = (stats.blockedBy[reason] or 0) + 1
				return
			end
			for _, id in sortedKeys(spends) do
				local amount = spends[id]
				if amount > 0 then
					balance[id] -= amount
					sunk[id] += amount
					totals[id].sinks[action.id] = (totals[id].sinks[action.id] or 0) + amount
				end
			end
			for _, id in sortedKeys(earns) do
				credit(id, earns[id], action.id, now)
			end
			stats.fired += 1
		end

		for s = 1, sessionCount do
			if options.horizon ~= nil and playTime >= options.horizon then
				break
			end
			session = s
			if s > 1 and options.sessions.gap ~= nil then
				local gap = draw(rng, options.sessions.gap)
				for _, id in sortedKeys(options.offline) do
					local config = (options.offline :: any)[id]
					credit(
						id,
						math.floor(math.min(gap, config.capSeconds) * config.perSecond + 1e-9),
						"offline",
						0
					)
				end
			end
			local length = draw(rng, options.sessions.seconds)
			if options.horizon ~= nil then
				length = math.min(length, options.horizon - playTime)
			end
			local nextAt, firedThisSession = {}, {}
			for index, action in actions do
				nextAt[index] = draw(rng, action.every)
				firedThisSession[index] = 0
			end
			local now = 0
			local nextPassive = step
			while true do
				local soonest = math.min(nextPassive, length)
				for index in actions do
					soonest = math.min(soonest, nextAt[index])
				end
				if soonest > length then
					break
				end
				passive(soonest - now, soonest)
				now = soonest
				if now == nextPassive then
					nextPassive += step
				end
				for index, action in actions do
					if nextAt[index] == now then
						local stats = actionStats[action.id]
						if action.limit ~= nil and firedThisSession[index] >= action.limit then
							stats.limited += 1
						else
							local before = stats.fired
							fire(action, stats, now)
							if stats.fired > before then
								firedThisSession[index] += 1
							end
						end
						nextAt[index] = now + draw(rng, action.every)
					end
				end
				if now >= length then
					break
				end
			end
			playTime += length
			for _, id in currencyIds do
				local row = totals[id].bySession[s]
				row.players += 1
				row.balance += balance[id]
				row.sourced += sourced[id]
				row.sunk += sunk[id]
			end
		end

		table.insert(played, playTime)
		local hours = playTime / 3600
		for _, id in currencyIds do
			local total = totals[id]
			total.sourced += sourced[id]
			total.sunk += sunk[id]
			table.insert(total.endBalance, balance[id])
			local initial = options.currencies[id].initial or 0
			table.insert(total.netPerHour, if hours > 0 then (balance[id] - initial) / hours else 0)
			table.insert(total.sourcedPerHour, if hours > 0 then sourced[id] / hours else 0)
			table.insert(total.sunkPerHour, if hours > 0 then sunk[id] / hours else 0)
		end
		for _, milestone in milestones do
			local at = reachedAt[milestone.id]
			table.insert(milestoneSeconds[milestone.id], if at then at[1] else math.huge)
			table.insert(milestoneSessions[milestone.id], if at then at[2] else math.huge)
		end
	end

	-- Report.
	local report: any = {
		schema = EconomySim.SCHEMA,
		seed = tostring(options.seed),
		players = options.players,
		percentiles = table.clone(ps),
		playSeconds = percentiles(played, ps, false),
		currencies = {},
		actions = {},
		milestones = {},
		checks = {},
		ok = true,
		warnings = {},
	}
	for _, id in currencyIds do
		local total = totals[id]
		local bySession = {}
		for s, row in total.bySession do
			if row.players > 0 then
				table.insert(bySession, {
					session = s,
					players = row.players,
					balance = round4(row.balance / row.players),
					sourced = round4(row.sourced / row.players),
					sunk = round4(row.sunk / row.players),
				})
			end
		end
		local sinkRatio = if total.sourced > 0 then round4(total.sunk / total.sourced) else 0
		report.currencies[id] = {
			sourced = total.sourced,
			sunk = total.sunk,
			wasted = total.wasted,
			sinkRatio = sinkRatio,
			sources = total.sources,
			sinks = total.sinks,
			endBalance = percentiles(total.endBalance, ps, false),
			netPerHour = percentiles(total.netPerHour, ps, true),
			sourcedPerHour = percentiles(total.sourcedPerHour, ps, true),
			sunkPerHour = percentiles(total.sunkPerHour, ps, true),
			bySession = bySession,
		}
		if total.sourced == 0 then
			table.insert(report.warnings, id .. ": never sourced")
		elseif total.sunk == 0 then
			table.insert(report.warnings, id .. ": sourced but never sunk (no sink in the simulated loop)")
		end
		if total.wasted > 0 then
			table.insert(report.warnings, string.format("%s: %d units wasted at the cap", id, total.wasted))
		end
		local target = (options.targets or {})[id]
		if target then
			local median = EconomySim.percentile(sortedCopy(total.netPerHour), 50) or 0
			for _, metric in { "sinkRatio", "netPerHour" } do
				local band = (target :: any)[metric]
				if band then
					local value = if metric == "sinkRatio" then sinkRatio else round4(median)
					local ok = (band.min == nil or value >= band.min)
						and (band.max == nil or value <= band.max)
					table.insert(report.checks, {
						currency = id,
						metric = if metric == "sinkRatio" then "sinkRatio" else "netPerHour.p50",
						value = value,
						min = band.min,
						max = band.max,
						ok = ok,
					})
					report.ok = report.ok and ok
				end
			end
		end
	end
	for _, action in actions do
		local stats = actionStats[action.id]
		report.actions[action.id] = stats
		if stats.fired == 0 then
			table.insert(
				report.warnings,
				string.format("action %s never fired (%d blocked)", action.id, stats.blocked)
			)
		end
	end
	for _, milestone in milestones do
		local reached = 0
		for _, seconds in milestoneSeconds[milestone.id] do
			if seconds < math.huge then
				reached += 1
			end
		end
		report.milestones[milestone.id] = {
			currency = milestone.currency,
			threshold = milestone.threshold,
			measure = milestone.measure or "balance",
			reached = round4(reached / options.players),
			playSeconds = percentiles(milestoneSeconds[milestone.id], ps, false),
			sessions = percentiles(milestoneSessions[milestone.id], ps, false),
		}
		if reached == 0 then
			table.insert(report.warnings, "milestone " .. milestone.id .. ": no simulated player reached it")
		end
	end
	return report
end

-- Short human-readable lines for a report (tools and spec output).
function EconomySim.summary(report: any): { string }
	local lines = {
		string.format("%s seed=%s players=%d", report.schema, report.seed, report.players),
	}
	for _, id in sortedKeys(report.currencies) do
		local c = report.currencies[id]
		table.insert(
			lines,
			string.format(
				"%s sourced=%d sunk=%d wasted=%d sinkRatio=%.4f netPerHour.p50=%s",
				id,
				c.sourced,
				c.sunk,
				c.wasted,
				c.sinkRatio,
				tostring(c.netPerHour.p50)
			)
		)
	end
	for _, id in sortedKeys(report.milestones) do
		local m = report.milestones[id]
		table.insert(
			lines,
			string.format(
				"milestone %s reached=%.4f playSeconds.p50=%s",
				id,
				m.reached,
				tostring(m.playSeconds.p50)
			)
		)
	end
	for _, check in report.checks do
		table.insert(
			lines,
			string.format(
				"check %s %s=%s %s",
				check.currency,
				check.metric,
				tostring(check.value),
				if check.ok then "PASS" else "FAIL"
			)
		)
	end
	for _, warning in report.warnings do
		table.insert(lines, "warning " .. warning)
	end
	return lines
end

return EconomySim
