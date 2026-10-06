--!strict
-- @tier T0
-- Queue: a pure matchmaking queue. A ticket is a party (1..maxPartySize players) with an optional
-- skill rating and a pool label (mode, region: tickets only match inside their pool).
-- plan(now) groups tickets into matches of `teams` teams of `teamSize` players:
--   * a party is never split across teams or matches;
--   * the oldest waiting ticket anchors a match, and tickets join it oldest first while their
--     skill is inside the anchor's band, which starts at skill.initial and widens by
--     skill.widenPerSecond while the anchor waits, up to skill.max;
--   * parties go to teams largest first, each to the team with the most free slots (ties: the
--     lower skill total, then the lower index), which also balances team skill;
--   * with `partial`, an anchor that waited `partial.after` seconds may start a match with at
--     least partial.minPlayers players, every team non-empty and team sizes within
--     partial.maxImbalance;
--   * tickets older than expireAfter are dropped (listed in plan.expired).
-- Ordering is by enqueue time, then ticket id; there is no randomness, so the same tickets at the
-- same time give the same plan (tests/golden/gamekit_platform_queue.json pins one). plan() never
-- changes the queue; take() commits a plan. Greedy selection can miss an exact fill another
-- choice would find; such tickets wait for the next plan. Cost is about O(tickets^2) per plan:
-- keep maxTickets per pool modest and plan every few seconds, not every frame.
-- MemoryQueueRoblox moves tickets between servers, TeleportRoblox sends a match to its server and
-- PartyRoblox builds tickets from Roblox parties.
local Check = require("./Check")

local Queue = {}

Queue.DEFAULTS = table.freeze({
	teams = 2,
	teamSize = 4,
	maxTickets = 1000,
	skill = table.freeze({ initial = 100, widenPerSecond = 10, max = 1000 }), -- conventions
	pool = "default",
})
Queue.ADD_REASONS = table.freeze({
	"invalid_ticket", -- bad id, players, skill, pool or time
	"party_too_large", -- more players than maxPartySize
	"duplicate_ticket", -- the ticket id is queued
	"player_queued", -- a player is already in another ticket
	"full", -- maxTickets reached
})

export type SkillOptions = { initial: number, widenPerSecond: number, max: number }
export type PartialOptions = { after: number, minPlayers: number, maxImbalance: number? }
export type Options = {
	teams: number?,
	teamSize: number?,
	maxPartySize: number?,
	skill: SkillOptions | false | nil,
	partial: PartialOptions?,
	expireAfter: number?,
	maxTickets: number?,
}
export type Ticket = { id: string, players: { number }, skill: number?, pool: string?, at: number? }
export type Team = { players: { number }, tickets: { string }, skill: number }
export type Match = {
	id: string,
	pool: string,
	tickets: { string },
	teams: { Team },
	players: number,
	partial: boolean,
	spread: number,
	waited: number,
}
export type Plan = { matches: { Match }, expired: { string }, waiting: number }

local function ticketId(value: any): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 64
		and string.match(value, "^[%w_%-:%.]+$") ~= nil
end

local function intIn(value: any, low: number, high: number): boolean
	return Check.integer(value) and value >= low and value <= high
end

local function nonNegative(value: any): boolean
	return Check.finite(value) and value >= 0
end

-- Problems with an options table (empty when usable).
function Queue.validate(options: any): { string }
	if options ~= nil and type(options) ~= "table" then
		return { "options must be a table" }
	end
	local opts = options or {}
	local problems = {}
	local teams = if opts.teams == nil then Queue.DEFAULTS.teams else opts.teams
	local teamSize = if opts.teamSize == nil then Queue.DEFAULTS.teamSize else opts.teamSize
	if not intIn(teams, 1, 16) then
		table.insert(problems, "teams must be an integer from 1 to 16")
	end
	if not intIn(teamSize, 1, 100) then
		table.insert(problems, "teamSize must be an integer from 1 to 100")
	end
	if
		opts.maxPartySize ~= nil
		and not intIn(opts.maxPartySize, 1, if Check.integer(teamSize) then teamSize else 1)
	then
		table.insert(problems, "maxPartySize must be an integer from 1 to teamSize")
	end
	if opts.maxTickets ~= nil and not intIn(opts.maxTickets, 1, 100000) then
		table.insert(problems, "maxTickets must be an integer from 1 to 100000")
	end
	if opts.expireAfter ~= nil and not (Check.finite(opts.expireAfter) and opts.expireAfter > 0) then
		table.insert(problems, "expireAfter must be a finite number > 0")
	end
	local skill = opts.skill
	if skill ~= nil and skill ~= false then
		if type(skill) ~= "table" then
			table.insert(problems, "skill must be a table or false")
		else
			for _, key in { "initial", "widenPerSecond", "max" } do
				if not nonNegative(skill[key]) then
					table.insert(problems, "skill." .. key .. " must be a finite number >= 0")
				end
			end
			if nonNegative(skill.initial) and nonNegative(skill.max) and skill.max < skill.initial then
				table.insert(problems, "skill.max must be >= skill.initial")
			end
		end
	end
	local partial = opts.partial
	if partial ~= nil then
		if type(partial) ~= "table" then
			table.insert(problems, "partial must be a table")
		else
			if not nonNegative(partial.after) then
				table.insert(problems, "partial.after must be a finite number >= 0")
			end
			-- with invalid teams or teamSize (already reported) check against the widest valid range
			local validTeams = intIn(teams, 1, 16)
			local low = if validTeams then teams else 1
			local high = if validTeams and intIn(teamSize, 1, 100) then teams * teamSize else 1600
			if not intIn(partial.minPlayers, low, high) then
				table.insert(problems, "partial.minPlayers must be an integer from teams to teams * teamSize")
			end
			if partial.maxImbalance ~= nil and not intIn(partial.maxImbalance, 0, 100) then
				table.insert(problems, "partial.maxImbalance must be an integer from 0 to 100")
			end
		end
	end
	return problems
end

type Config = {
	teams: number,
	teamSize: number,
	capacity: number,
	maxPartySize: number,
	skill: SkillOptions?,
	partial: PartialOptions?,
	expireAfter: number?,
	maxTickets: number,
}

local function config(options: Options?): Config
	local problems = Queue.validate(options)
	if #problems > 0 then
		error("Queue: " .. table.concat(problems, "; "), 3)
	end
	local opts: Options = options or {}
	local teams = opts.teams or Queue.DEFAULTS.teams
	local teamSize = opts.teamSize or Queue.DEFAULTS.teamSize
	local skill: SkillOptions? = nil
	if opts.skill ~= false then
		skill = table.clone((opts.skill or Queue.DEFAULTS.skill) :: SkillOptions)
	end
	local partial: PartialOptions? = nil
	if opts.partial ~= nil then
		partial = table.clone(opts.partial)
		local p = partial :: PartialOptions
		p.maxImbalance = p.maxImbalance or 1
	end
	return {
		teams = teams,
		teamSize = teamSize,
		capacity = teams * teamSize,
		maxPartySize = opts.maxPartySize or teamSize,
		skill = skill,
		partial = partial,
		expireAfter = opts.expireAfter,
		maxTickets = opts.maxTickets or Queue.DEFAULTS.maxTickets,
	}
end

-- Problems with one ticket under a config (empty when valid). at must already be set.
local function ticketProblem(ticket: any, cfg: Config): string?
	if type(ticket) ~= "table" or not ticketId(ticket.id) then
		return "invalid_ticket"
	end
	local players = ticket.players
	if type(players) ~= "table" or #players < 1 then
		return "invalid_ticket"
	end
	local seen = {}
	local count = 0
	for _, userId in players do
		count += 1
		if not intIn(userId, 1, 9007199254740991) or seen[userId] then
			return "invalid_ticket"
		end
		seen[userId] = true
	end
	if count ~= #players then
		return "invalid_ticket"
	end
	if ticket.pool ~= nil and not Check.label(ticket.pool) then
		return "invalid_ticket"
	end
	if not Check.finite(ticket.at) then
		return "invalid_ticket"
	end
	if cfg.skill ~= nil and not Check.finite(ticket.skill) then
		return "invalid_ticket"
	end
	if ticket.skill ~= nil and not Check.finite(ticket.skill) then
		return "invalid_ticket"
	end
	if #players > cfg.maxPartySize then
		return "party_too_large"
	end
	return nil
end

local function older(a: any, b: any): boolean
	if a.at ~= b.at then
		return a.at < b.at
	end
	return a.id < b.id
end

-- The skill band of a ticket at time now (math.huge when skill is off).
local function bandOf(ticket: any, cfg: Config, now: number): number
	local skill = cfg.skill
	if skill == nil then
		return math.huge
	end
	return math.min(skill.max, skill.initial + skill.widenPerSecond * math.max(0, now - ticket.at))
end

local function skillOf(ticket: any, cfg: Config): number
	if cfg.skill == nil then
		return 0
	end
	return ticket.skill
end

-- Assigns tickets to teams (largest party first, most free slots, lower skill total, lower
-- index). Returns the teams, or nil when a party fits no team.
local function pack(tickets: { any }, cfg: Config): { Team }?
	local order = table.clone(tickets)
	table.sort(order, function(a: any, b: any): boolean
		if #a.players ~= #b.players then
			return #a.players > #b.players
		end
		local sa, sb = skillOf(a, cfg), skillOf(b, cfg)
		if sa ~= sb then
			return sa > sb
		end
		return older(a, b)
	end)
	local teams: { Team } = {}
	local used: { number } = {}
	for index = 1, cfg.teams do
		teams[index] = { players = {}, tickets = {}, skill = 0 }
		used[index] = 0
	end
	for _, ticket in order do
		local size = #ticket.players
		local best: number? = nil
		for index = 1, cfg.teams do
			local free = cfg.teamSize - used[index]
			if free >= size then
				if best == nil then
					best = index
				else
					local bestFree = cfg.teamSize - used[best]
					if free > bestFree or (free == bestFree and teams[index].skill < teams[best].skill) then
						best = index
					end
				end
			end
		end
		if best == nil then
			return nil
		end
		local team = teams[best]
		used[best] += size
		team.skill += skillOf(ticket, cfg) * size
		table.insert(team.tickets, ticket.id)
		for _, userId in ticket.players do
			table.insert(team.players, userId)
		end
	end
	return teams
end

local function partialOk(teams: { Team }, cfg: Config): boolean
	local partial = cfg.partial :: PartialOptions
	local low, high = math.huge, 0
	for _, team in teams do
		local n = #team.players
		low, high = math.min(low, n), math.max(high, n)
	end
	return low >= 1 and high - low <= (partial.maxImbalance :: number)
end

-- The plan for a list of tickets at time now (tickets need at). Pure; used by Queue objects and
-- by MemoryQueueRoblox on a batch read from a MemoryStore queue.
function Queue.planTickets(tickets: { Ticket }, options: Options?, now: number): Plan
	local cfg = config(options)
	assert(Check.finite(now), "Queue.planTickets: now must be a finite number")
	return Queue._plan(tickets, cfg, now)
end

function Queue._plan(tickets: { any }, cfg: Config, now: number): Plan
	local plan: Plan = { matches = {}, expired = {}, waiting = 0 }
	local byPool: { [string]: { any } } = {}
	local pools: { string } = {}
	local ordered = table.clone(tickets)
	table.sort(ordered, older)
	for _, ticket in ordered do
		if cfg.expireAfter ~= nil and now - ticket.at >= cfg.expireAfter then
			table.insert(plan.expired, ticket.id)
			continue
		end
		local pool = ticket.pool or Queue.DEFAULTS.pool
		if byPool[pool] == nil then
			byPool[pool] = {}
			table.insert(pools, pool)
		end
		table.insert(byPool[pool], ticket)
	end
	table.sort(pools)
	for _, pool in pools do
		local list = byPool[pool]
		local used: { [string]: boolean } = {}
		for _, anchor in list do
			if used[anchor.id] then
				continue
			end
			local band = bandOf(anchor, cfg, now)
			local anchorSkill = skillOf(anchor, cfg)
			local selected = { anchor }
			local count = #anchor.players
			local teams = pack(selected, cfg)
			for _, candidate in list do
				if count >= cfg.capacity then
					break
				end
				if used[candidate.id] or candidate == anchor then
					continue
				end
				if math.abs(skillOf(candidate, cfg) - anchorSkill) > band then
					continue
				end
				local size = #candidate.players
				if count + size > cfg.capacity then
					continue
				end
				table.insert(selected, candidate)
				local packed = pack(selected, cfg)
				if packed == nil then
					table.remove(selected)
				else
					teams = packed
					count += size
				end
			end
			local full = count == cfg.capacity
			local partial = false
			if not full and cfg.partial ~= nil then
				local p = cfg.partial :: PartialOptions
				partial = now - anchor.at >= p.after
					and count >= p.minPlayers
					and teams ~= nil
					and partialOk(teams :: { Team }, cfg)
			end
			if not full and not partial then
				continue
			end
			local low, high = math.huge, -math.huge
			local ids = {}
			for _, ticket in selected do
				used[ticket.id] = true
				table.insert(ids, ticket.id)
				local s = skillOf(ticket, cfg)
				low, high = math.min(low, s), math.max(high, s)
			end
			table.insert(plan.matches, {
				id = "match:" .. anchor.id,
				pool = pool,
				tickets = ids,
				teams = teams :: { Team },
				players = count,
				partial = partial,
				spread = high - low,
				waited = math.max(0, now - anchor.at),
			})
		end
		for _, ticket in list do
			if not used[ticket.id] then
				plan.waiting += 1
			end
		end
	end
	return plan
end

local Methods = {}
Methods.__index = Methods

-- A queue object. env supplies clock() for tickets without `at` and plans without `now`.
function Queue.new(options: Options?, env: any?): any
	local cfg = config(options)
	local self = setmetatable({
		_cfg = cfg,
		_env = env,
		_tickets = {},
		_players = {},
		_count = 0,
	}, Methods)
	return self
end

local function nowOf(self: any, now: number?): number
	if now ~= nil then
		assert(Check.finite(now), "Queue: now must be a finite number")
		return now
	end
	assert(self._env ~= nil and type(self._env.clock) == "function", "Queue: pass now or an env with clock")
	return self._env.clock()
end

-- Queues a ticket (copied). Returns (true) or (false, reason) with Queue.ADD_REASONS.
function Methods.add(self: any, ticket: Ticket): (boolean, string?)
	if type(ticket) ~= "table" then
		return false, "invalid_ticket"
	end
	local copy = Check.copy(ticket) :: any
	if copy.at == nil then
		if self._env == nil or type(self._env.clock) ~= "function" then
			return false, "invalid_ticket"
		end
		copy.at = self._env.clock()
	end
	local problem = ticketProblem(copy, self._cfg)
	if problem then
		return false, problem
	end
	if self._tickets[copy.id] ~= nil then
		return false, "duplicate_ticket"
	end
	for _, userId in copy.players do
		if self._players[userId] ~= nil then
			return false, "player_queued"
		end
	end
	if self._count >= self._cfg.maxTickets then
		return false, "full"
	end
	self._tickets[copy.id] = copy
	self._count += 1
	for _, userId in copy.players do
		self._players[userId] = copy.id
	end
	return true, nil
end

-- Removes a ticket. Returns whether it was queued.
function Methods.remove(self: any, id: string): boolean
	local ticket = self._tickets[id]
	if ticket == nil then
		return false
	end
	self._tickets[id] = nil
	self._count -= 1
	for _, userId in ticket.players do
		if self._players[userId] == id then
			self._players[userId] = nil
		end
	end
	return true
end

-- Removes the ticket holding userId (a party leaves together). Returns the ticket id or nil.
function Methods.removePlayer(self: any, userId: number): string?
	local id = self._players[userId]
	if id ~= nil then
		self:remove(id)
	end
	return id
end

function Methods.ticketOf(self: any, userId: number): string?
	return self._players[userId]
end

function Methods.get(self: any, id: string): Ticket?
	local ticket = self._tickets[id]
	return if ticket then Check.copy(ticket) else nil
end

-- (tickets, players) queued.
function Methods.size(self: any): (number, number)
	local players = 0
	for _ in self._players do
		players += 1
	end
	return self._count, players
end

-- The ticket's current skill band (math.huge with skill off), or nil when not queued.
function Methods.band(self: any, id: string, now: number?): number?
	local ticket = self._tickets[id]
	if ticket == nil then
		return nil
	end
	return bandOf(ticket, self._cfg, nowOf(self, now))
end

-- Every queued ticket (copies), oldest first.
function Methods.snapshot(self: any): { Ticket }
	local out = {}
	for _, ticket in self._tickets do
		table.insert(out, Check.copy(ticket))
	end
	table.sort(out, older)
	return out
end

-- The plan at time now without changing the queue.
function Methods.plan(self: any, now: number?): Plan
	local list = {}
	for _, ticket in self._tickets do
		table.insert(list, ticket)
	end
	-- plans hold only fresh tables (ids, user ids, numbers), never the queue's tickets
	return Queue._plan(list, self._cfg, nowOf(self, now))
end

-- Plans and commits: matched and expired tickets leave the queue. Returns the plan.
function Methods.take(self: any, now: number?): Plan
	local plan = self:plan(now)
	for _, match in plan.matches do
		for _, id in match.tickets do
			self:remove(id)
		end
	end
	for _, id in plan.expired do
		self:remove(id)
	end
	return plan
end

return Queue
