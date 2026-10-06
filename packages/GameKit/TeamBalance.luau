--!strict
-- @tier T0
-- TeamBalance: deterministic, skill- and party-aware team split. Parties stay together unless a
-- party is larger than a team (it is then split and reported); units (parties or solo players)
-- go largest skill first to the team with the lowest total that still has room, then pairwise
-- unit swaps that shrink the skill spread are applied until none helps. Same players, same
-- teams: ties break by team index and player id, never by chance. Skill is any finite number
-- >= 0 the game supplies (an MMR, a level, a win rate); TeamBalance never stores it.
local Check = require("./Check")

local TeamBalance = {}

export type Player = { id: string | number, skill: number, party: string? }
export type Options = {
	teams: number?, -- default 2
	maxSizeDiff: number?, -- largest allowed difference between team sizes (default 1)
	swapRounds: number?, -- improvement passes (default 32)
}
export type Result = {
	teams: { { string | number } },
	totals: { number },
	sizes: { number },
	spread: number, -- highest total - lowest total
	splitParties: { string },
}

local function idKey(id: any): string
	return (if type(id) == "number" then "n:" else "s:") .. tostring(id)
end

-- Problems with players and options (empty when valid).
function TeamBalance.validate(players: any, options: Options?): { string }
	local problems = {}
	local teams = options and options.teams or 2
	if not Check.integer(teams) or teams < 2 then
		table.insert(problems, "teams must be an integer >= 2")
	end
	local diff = options and options.maxSizeDiff
	if diff ~= nil and (not Check.integer(diff) or diff < 0) then
		table.insert(problems, "maxSizeDiff must be an integer >= 0")
	end
	if type(players) ~= "table" then
		table.insert(problems, "players must be a list")
		return problems
	end
	local seen = {}
	for index, player in players do
		if type(player) ~= "table" then
			table.insert(problems, string.format("player %d must be a table", index))
			continue
		end
		local id = player.id
		if type(id) ~= "string" and not Check.integer(id) then
			table.insert(problems, string.format("player %d id must be a string or an integer", index))
		elseif seen[idKey(id)] then
			table.insert(problems, string.format("player %d duplicate id %s", index, tostring(id)))
		else
			seen[idKey(id)] = true
		end
		if not Check.finite(player.skill) or player.skill < 0 then
			table.insert(
				problems,
				string.format("player %s skill must be a finite number >= 0", tostring(id))
			)
		end
		if player.party ~= nil and not Check.label(player.party) then
			table.insert(problems, string.format("player %s party must be a label", tostring(id)))
		end
	end
	return problems
end

local function byId(a: Player, b: Player): boolean
	if type(a.id) ~= type(b.id) then
		return type(a.id) == "number"
	end
	return (a.id :: any) < (b.id :: any)
end

local function bySkill(a: Player, b: Player): boolean
	if a.skill ~= b.skill then
		return a.skill > b.skill
	end
	return byId(a, b)
end

type Unit = { players: { Player }, skill: number, key: string }

-- Splits players into teams. Raises with every problem joined when the input is invalid.
function TeamBalance.split(players: { Player }, options: Options?): Result
	local problems = TeamBalance.validate(players, options)
	if #problems > 0 then
		error("TeamBalance.split: " .. table.concat(problems, "; "), 2)
	end
	local teamCount = options and options.teams or 2
	local maxDiff = options and options.maxSizeDiff or 1
	local rounds = options and options.swapRounds or 32
	local capacity = math.ceil(#players / teamCount)

	-- Units: parties (sorted members) and solo players; oversized parties split into chunks.
	local parties: { [string]: { Player } } = {}
	local units: { Unit } = {}
	local splitParties = {}
	for _, player in players do
		if player.party then
			parties[player.party] = parties[player.party] or {}
			table.insert(parties[player.party], player)
		else
			table.insert(units, { players = { player }, skill = player.skill, key = idKey(player.id) })
		end
	end
	local partyNames = {}
	for name in parties do
		table.insert(partyNames, name)
	end
	table.sort(partyNames)
	for _, name in partyNames do
		local members = parties[name]
		table.sort(members, bySkill)
		local chunk: { Player } = {}
		if #members > capacity then
			table.insert(splitParties, name)
		end
		for _, member in members do
			table.insert(chunk, member)
			if #chunk == capacity then
				table.insert(units, { players = chunk, skill = 0, key = "p:" .. name .. ":" .. #units })
				chunk = {}
			end
		end
		if #chunk > 0 then
			table.insert(units, { players = chunk, skill = 0, key = "p:" .. name .. ":" .. #units })
		end
	end
	for _, unit in units do
		local sum = 0
		for _, p in unit.players do
			sum += p.skill
		end
		unit.skill = sum
	end
	table.sort(units, function(a, b)
		if a.skill ~= b.skill then
			return a.skill > b.skill
		end
		if #a.players ~= #b.players then
			return #a.players > #b.players
		end
		return a.key < b.key
	end)

	local teams: { { Unit } } = {}
	local totals, sizes = {}, {}
	for t = 1, teamCount do
		teams[t], totals[t], sizes[t] = {}, 0, 0
	end
	for _, unit in units do
		local best = nil
		for t = 1, teamCount do
			if sizes[t] + #unit.players <= capacity then
				if
					best == nil
					or totals[t] < totals[best]
					or (totals[t] == totals[best] and sizes[t] < sizes[best])
				then
					best = t
				end
			end
		end
		if best == nil then
			-- No team has room (parties forced it): the smallest team takes it.
			best = 1
			for t = 2, teamCount do
				if sizes[t] < sizes[best] then
					best = t
				end
			end
		end
		table.insert(teams[best], unit)
		totals[best] += unit.skill
		sizes[best] += #unit.players
	end

	-- Swap units between two teams while that lowers the spread and keeps sizes within maxDiff.
	local function spreadOf(): number
		local lo, hi = math.huge, -math.huge
		for t = 1, teamCount do
			lo, hi = math.min(lo, totals[t]), math.max(hi, totals[t])
		end
		return hi - lo
	end
	local function sizesOk(): boolean
		local lo, hi = math.huge, -math.huge
		for t = 1, teamCount do
			lo, hi = math.min(lo, sizes[t]), math.max(hi, sizes[t])
		end
		return hi - lo <= maxDiff
	end
	for _ = 1, rounds do
		local current = spreadOf()
		local improved = false
		for a = 1, teamCount do
			for b = a + 1, teamCount do
				for i, ua in teams[a] do
					for j, ub in teams[b] do
						local da, db = #ub.players - #ua.players, #ua.players - #ub.players
						totals[a] += ub.skill - ua.skill
						totals[b] += ua.skill - ub.skill
						sizes[a] += da
						sizes[b] += db
						if spreadOf() < current - 1e-9 and sizesOk() then
							teams[a][i], teams[b][j] = ub, ua
							improved = true
							break
						end
						totals[a] -= ub.skill - ua.skill
						totals[b] -= ua.skill - ub.skill
						sizes[a] -= da
						sizes[b] -= db
					end
					if improved then
						break
					end
				end
				if improved then
					break
				end
			end
			if improved then
				break
			end
		end
		if not improved then
			break
		end
	end

	local out = {}
	for t = 1, teamCount do
		local members: { Player } = {}
		for _, unit in teams[t] do
			for _, p in unit.players do
				table.insert(members, p)
			end
		end
		table.sort(members, bySkill)
		local ids = {}
		for _, p in members do
			table.insert(ids, p.id)
		end
		out[t] = ids
	end
	return { teams = out, totals = totals, sizes = sizes, spread = spreadOf(), splitParties = splitParties }
end

return TeamBalance
