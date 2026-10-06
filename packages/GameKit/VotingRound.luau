--!strict
-- @tier T0
-- VotingRound: judging rounds for fashion, build and talent games. Phases (GameKit/Fsm):
-- submitting -> voting -> closed. Each player submits one entry (plain data, replaceable while
-- submitting). startVoting() needs at least two entries and deals every voter a seeded ballot
-- order of the other entries (never their own). vote(voter, owner, score) refuses self votes,
-- unknown entries, scores outside the integer scale and (by default) voters without an entry;
-- a revote replaces the earlier score unless allowRevote is false. close() ranks entries by
-- mean score (compared exactly as fractions), then by number of votes, then by the tie-break:
-- "seeded" (a fixed seeded order, so the same round always ranks the same) or "shared" (tied
-- entries share a rank). Entries with fewer than minVotes votes rank after the rest. A player
-- who leaves is removed with their entry and votes. No scales or rewards ship here.
local Check = require("./Check")
local Fsm = require("./Fsm")
local Rng = require("../ProcGen/Rng")

local VotingRound = {}
VotingRound.__index = VotingRound

VotingRound.SPEC = Fsm.define({
	name = "voting_round",
	initial = "submitting",
	states = { submitting = {}, voting = {}, closed = { terminal = true } },
	transitions = {
		{ from = "submitting", event = "start_voting", to = "voting" },
		{ from = "voting", event = "close", to = "closed" },
		{ from = "submitting", event = "close", to = "closed" },
	},
})

export type Options = {
	id: string,
	seed: number | string,
	scale: { min: number, max: number }?, -- default 1..5 (convention)
	tieBreak: ("seeded" | "shared")?,
	votersMustSubmit: boolean?, -- default true
	allowRevote: boolean?, -- default true
	minVotes: number?, -- default 0
}
export type Result = {
	owner: string,
	rank: number,
	sum: number,
	count: number,
	mean: number,
	qualified: boolean,
	entry: any,
}

type RoundFields = {
	id: string,
	_machine: Fsm.Machine,
	_options: Options,
	_scale: { min: number, max: number },
	_entries: { [string]: any },
	_order: { string },
	_votes: { [string]: { [string]: number } }, -- voter -> owner -> score
	_ballots: { [string]: { string } },
	_rng: Rng.Rng,
	_results: { Result }?,
}
export type VotingRound = typeof(setmetatable({} :: RoundFields, VotingRound))

local function token(value: any): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 64
		and string.match(value, "^[%w_%.:%-]+$") ~= nil
end

-- A round. Raises on invalid options. env.rng is used when given, else ProcGen/Rng.
function VotingRound.new(options: Options, env: any?): VotingRound
	assert(type(options) == "table", "VotingRound.new: options must be a table")
	local problems = {}
	if not Check.label(options.id) then
		table.insert(problems, "id must be a label")
	end
	if options.seed == nil then
		table.insert(problems, "seed is required (rounds are reproducible)")
	end
	local scale = options.scale or { min = 1, max = 5 }
	if
		not (
			type(scale) == "table"
			and Check.integer(scale.min)
			and Check.integer(scale.max)
			and scale.min < scale.max
		)
	then
		table.insert(problems, "scale must be { min, max } integers with min < max")
	end
	if options.tieBreak ~= nil and options.tieBreak ~= "seeded" and options.tieBreak ~= "shared" then
		table.insert(problems, "tieBreak must be seeded or shared")
	end
	if options.minVotes ~= nil and not (Check.integer(options.minVotes) and options.minVotes >= 0) then
		table.insert(problems, "minVotes must be an integer >= 0")
	end
	if #problems > 0 then
		error("VotingRound.new: " .. table.concat(problems, "; "), 2)
	end
	-- The seed is hashed with the round id, so nearby numeric seeds still deal unrelated ballots.
	local key = "voting_round:" .. options.id .. ":" .. tostring(options.seed)
	local rng = if env and type(env.rng) == "function" then env.rng(key) else Rng.new(key)
	return setmetatable({
		id = options.id,
		_machine = Fsm.new(VotingRound.SPEC, nil, env),
		_options = options,
		_scale = { min = scale.min, max = scale.max },
		_entries = {},
		_order = {},
		_votes = {},
		_ballots = {},
		_rng = rng,
		_results = nil,
	}, VotingRound)
end

function VotingRound.phase(self: VotingRound): string
	return self._machine:state()
end

-- Submits or replaces player's entry while submitting. (ok, reason) with wrong_phase,
-- invalid_player or invalid_entry.
function VotingRound.submit(self: VotingRound, player: string, entry: any?): (boolean, string?)
	if self:phase() ~= "submitting" then
		return false, "wrong_phase"
	end
	if not token(player) then
		return false, "invalid_player"
	end
	if entry ~= nil and type(entry) ~= "table" then
		return false, "invalid_entry"
	end
	if self._entries[player] == nil then
		table.insert(self._order, player)
	end
	self._entries[player] = if entry ~= nil then Check.copy(entry) else {}
	return true, nil
end

-- Removes a player who left: their entry, their ballot and the votes they cast or received.
function VotingRound.remove(self: VotingRound, player: string): boolean
	if self:phase() == "closed" then
		return false
	end
	local index = table.find(self._order, player)
	if index then
		table.remove(self._order, index)
	end
	self._entries[player] = nil
	self._votes[player] = nil
	self._ballots[player] = nil
	for _, votes in self._votes do
		votes[player] = nil
	end
	for _, ballot in self._ballots do
		local at = table.find(ballot, player)
		if at then
			table.remove(ballot, at)
		end
	end
	return index ~= nil
end

function VotingRound.entries(self: VotingRound): { string }
	return table.clone(self._order)
end

-- Opens voting and deals seeded ballots. (ok, reason) with wrong_phase or not_enough_entries.
function VotingRound.startVoting(self: VotingRound): (boolean, string?)
	if self:phase() ~= "submitting" then
		return false, "wrong_phase"
	end
	if #self._order < 2 then
		return false, "not_enough_entries"
	end
	local owners = table.clone(self._order)
	table.sort(owners)
	for _, voter in owners do
		local ballot = {}
		for _, owner in owners do
			if owner ~= voter then
				table.insert(ballot, owner)
			end
		end
		self._rng:fork("ballot:" .. voter):shuffle(ballot)
		self._ballots[voter] = ballot
	end
	self._machine:send("start_voting")
	return true, nil
end

-- The entries voter judges, in their seeded order (empty for a voter without a ballot).
function VotingRound.ballot(self: VotingRound, voter: string): { string }
	local ballot = self._ballots[voter]
	if ballot then
		return table.clone(ballot)
	end
	if self._options.votersMustSubmit == false and self:phase() == "voting" then
		-- Spectators judge every entry, in a seeded order of their own.
		local all = table.clone(self._order)
		table.sort(all)
		self._rng:fork("ballot:" .. voter):shuffle(all)
		self._ballots[voter] = all
		return table.clone(all)
	end
	return {}
end

-- Casts or replaces a score. (ok, reason) with wrong_phase, invalid_player, self_vote,
-- unknown_entry, not_a_participant, invalid_score or already_voted.
function VotingRound.vote(self: VotingRound, voter: string, owner: string, score: number): (boolean, string?)
	if self:phase() ~= "voting" then
		return false, "wrong_phase"
	end
	if not token(voter) then
		return false, "invalid_player"
	end
	if voter == owner then
		return false, "self_vote"
	end
	if self._entries[owner] == nil then
		return false, "unknown_entry"
	end
	if self._options.votersMustSubmit ~= false and self._entries[voter] == nil then
		return false, "not_a_participant"
	end
	if not (Check.integer(score) and score >= self._scale.min and score <= self._scale.max) then
		return false, "invalid_score"
	end
	local votes = self._votes[voter]
	if votes == nil then
		votes = {}
		self._votes[voter] = votes
	end
	if votes[owner] ~= nil and self._options.allowRevote == false then
		return false, "already_voted"
	end
	votes[owner] = score
	return true, nil
end

-- Votes cast by voter (owner -> score).
function VotingRound.votesBy(self: VotingRound, voter: string): { [string]: number }
	return table.clone(self._votes[voter] or {})
end

local function tally(self: VotingRound): { Result }
	local results: { [string]: Result } = {}
	for _, owner in self._order do
		results[owner] = {
			owner = owner,
			rank = 0,
			sum = 0,
			count = 0,
			mean = 0,
			qualified = false,
			entry = Check.copy(self._entries[owner]),
		}
	end
	for _, votes in self._votes do
		for owner, score in votes do
			local result = results[owner]
			if result then
				result.sum += score
				result.count += 1
			end
		end
	end
	local minVotes = self._options.minVotes or 0
	local list = {}
	for _, owner in self._order do
		local result = results[owner]
		result.mean = if result.count > 0 then result.sum / result.count else 0
		result.qualified = result.count >= minVotes and result.count > 0
		table.insert(list, result)
	end
	-- A fixed seeded order for ties, independent of submission order.
	local seededOrder = table.clone(self._order)
	table.sort(seededOrder)
	self._rng:fork("tiebreak"):shuffle(seededOrder)
	local tiePosition = {}
	for index, owner in seededOrder do
		tiePosition[owner] = index
	end
	local function compare(a: Result, b: Result): number
		if a.qualified ~= b.qualified then
			return if a.qualified then -1 else 1
		end
		-- Exact mean comparison: a.sum / a.count vs b.sum / b.count without floating error.
		local left, right = a.sum * math.max(b.count, 1), b.sum * math.max(a.count, 1)
		if left ~= right then
			return if left > right then -1 else 1
		end
		if a.count ~= b.count then
			return if a.count > b.count then -1 else 1
		end
		return 0
	end
	table.sort(list, function(a: Result, b: Result): boolean
		local c = compare(a, b)
		if c ~= 0 then
			return c < 0
		end
		return tiePosition[a.owner] < tiePosition[b.owner]
	end)
	local shared = self._options.tieBreak == "shared"
	for index, result in list do
		if shared and index > 1 and compare(list[index - 1], result) == 0 then
			result.rank = list[index - 1].rank
		else
			result.rank = index
		end
	end
	return list
end

-- Closes the round and returns the ranked results (also later from results()).
function VotingRound.close(self: VotingRound): { Result }
	if self:phase() ~= "closed" then
		self._results = tally(self)
		self._machine:send("close")
	end
	return Check.copy(self._results :: { Result })
end

-- Ranked results after close (nil before), or a live preview with preview = true.
function VotingRound.results(self: VotingRound, preview: boolean?): { Result }?
	if self._results then
		return Check.copy(self._results)
	end
	if preview then
		return tally(self)
	end
	return nil
end

return VotingRound
