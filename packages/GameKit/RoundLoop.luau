--!strict
-- @tier T0
-- RoundLoop: a round cycle on the Stage 0 Fsm: lobby (wait for minPlayers) -> intermission
-- (countdown; aborts to lobby when players drop below minPlayers) -> active (timed or untimed;
-- ends on time, finish(), last players standing or an empty round) -> results -> next round.
-- intermission and results are optional phases; lobby and active are required.
--   * tick(now) is the only clock input and never yields (the adapter calls it from
--     RunService:BindToSimulation with time()). Phase ends are exact: when a tick arrives late,
--     the next phase starts at the previous phase's end time, not at the tick, so 60 ticks a
--     second and one tick a second give the same timeline.
--   * Late joiners follow lateJoin: "spectate" (watch, play next round), "queue" (wait off
--     screen, play next round) or "join" (play now, optionally only within joinWindow seconds of
--     the start). A player who was in this round and left or was eliminated comes back as a
--     spectator whatever the policy (no rejoin-to-respawn).
--   * phaseChanged fires (phase, from, info) after each transition; snapshot() is the
--     attribute-sized view (phase, timeLeft, round, counts, fsm/1 string) the adapter mirrors.
--   local spec = RoundLoop.define({ durations = { intermission = 10, active = 120, results = 8 }, minPlayers = 2 })
--   local loop = RoundLoop.new(spec, nil, env)
--   loop:join(userId); loop:tick(time())
local Check = require("./Check")
local Fsm = require("./Fsm")
local Signal = require("./Signal")

local RoundLoop = {}
RoundLoop.__index = RoundLoop
RoundLoop.PHASES = table.freeze({ "lobby", "intermission", "active", "results" })
RoundLoop.LATE_JOIN = table.freeze({ spectate = true, queue = true, join = true })
RoundLoop.MAX_DURATION = 86400
RoundLoop.MAX_PLAYERS = 1000
RoundLoop.MAX_TRANSITIONS_PER_TICK = 8

export type Definition = {
	phases: { string }?,
	durations: { intermission: number?, active: number?, results: number? },
	minPlayers: number,
	maxPlayers: number?,
	lateJoin: string?,
	joinWindow: number?,
	endOnAlive: number?,
}
export type Spec = {
	phases: { [string]: boolean },
	order: { string },
	durations: { intermission: number?, active: number?, results: number? },
	minPlayers: number,
	maxPlayers: number,
	lateJoin: string,
	joinWindow: number?,
	endOnAlive: number?,
	fsm: any,
}
export type Event = {
	kind: string, -- "phase"
	phase: string,
	from: string,
	at: number,
	round: number,
	reason: string,
	result: any?,
}

-- Problems with a definition (empty when valid).
function RoundLoop.validate(def: any): { string }
	if type(def) ~= "table" then
		return { "definition must be a table" }
	end
	local problems = {}
	local phases = def.phases or RoundLoop.PHASES
	local present = {}
	if type(phases) ~= "table" then
		table.insert(problems, "phases must be a list")
		phases = {}
	end
	local last = 0
	for _, phase in phases do
		local index = table.find(RoundLoop.PHASES, phase)
		if index == nil then
			table.insert(
				problems,
				string.format("unknown phase %q (lobby, intermission, active, results)", tostring(phase))
			)
		elseif index <= last then
			table.insert(
				problems,
				"phases must be in the order lobby, intermission, active, results without repeats"
			)
		else
			last = index
			present[phase] = true
		end
	end
	if not present.lobby or not present.active then
		table.insert(problems, "phases must include lobby and active")
	end
	local durations = def.durations
	if type(durations) ~= "table" then
		table.insert(problems, "durations must be a table")
		durations = {}
	end
	local function duration(name: string, required: boolean)
		local value = durations[name]
		if value == nil then
			if required then
				table.insert(
					problems,
					string.format("durations.%s is required when the %s phase is used", name, name)
				)
			end
			return
		end
		if not Check.finite(value) or value <= 0 or value > RoundLoop.MAX_DURATION then
			table.insert(
				problems,
				string.format("durations.%s must be in (0, %d] seconds", name, RoundLoop.MAX_DURATION)
			)
		end
	end
	duration("intermission", present.intermission == true)
	duration("results", present.results == true)
	duration("active", false)
	if not Check.integer(def.minPlayers) or def.minPlayers < 1 or def.minPlayers > RoundLoop.MAX_PLAYERS then
		table.insert(problems, string.format("minPlayers must be an integer 1-%d", RoundLoop.MAX_PLAYERS))
	end
	if def.maxPlayers ~= nil then
		if not Check.integer(def.maxPlayers) or def.maxPlayers > RoundLoop.MAX_PLAYERS then
			table.insert(
				problems,
				string.format("maxPlayers must be an integer up to %d", RoundLoop.MAX_PLAYERS)
			)
		elseif Check.integer(def.minPlayers) and def.maxPlayers < def.minPlayers then
			table.insert(problems, "maxPlayers must be >= minPlayers")
		end
	end
	if def.lateJoin ~= nil and not RoundLoop.LATE_JOIN[def.lateJoin] then
		table.insert(problems, "lateJoin must be spectate, queue or join")
	end
	if def.joinWindow ~= nil then
		if def.lateJoin ~= "join" then
			table.insert(problems, "joinWindow only applies to lateJoin = join")
		elseif not Check.finite(def.joinWindow) or def.joinWindow <= 0 then
			table.insert(problems, "joinWindow must be a finite number > 0 (seconds)")
		end
	end
	if def.endOnAlive ~= nil then
		if not Check.integer(def.endOnAlive) or def.endOnAlive < 0 then
			table.insert(problems, "endOnAlive must be an integer >= 0")
		elseif Check.integer(def.minPlayers) and def.endOnAlive >= def.minPlayers then
			table.insert(problems, "endOnAlive must be below minPlayers or every round ends at once")
		end
	end
	return problems
end

local function fsmFor(present: { [string]: boolean }): any
	local states = { lobby = {}, active = {} }
	local transitions = {}
	local function add(from: string, event: string, to: string)
		table.insert(transitions, { from = from, event = event, to = to })
	end
	local afterLobby = if present.intermission then "intermission" else "active"
	if present.intermission then
		states.intermission = {}
		add("lobby", "ready", "intermission")
		add("intermission", "abort", "lobby")
		add("intermission", "start", "active")
	else
		add("lobby", "start", "active")
	end
	if present.results then
		states.results = {}
		add("active", "finish", "results")
		add("results", "next", afterLobby)
		add("results", "idle", "lobby")
	else
		add("active", "finish", afterLobby)
	end
	add("active", "idle", "lobby")
	add("*", "reset", "lobby")
	return Fsm.define({ name = "round", initial = "lobby", states = states, transitions = transitions })
end

-- A frozen spec; raises with every problem.
function RoundLoop.define(def: Definition): Spec
	local problems = RoundLoop.validate(def)
	if #problems > 0 then
		error("RoundLoop.define: " .. table.concat(problems, "; "), 2)
	end
	local present = {}
	local order = {}
	local phases: { string } = def.phases or RoundLoop.PHASES
	for _, phase in phases do
		present[phase] = true
		table.insert(order, phase)
	end
	return table.freeze({
		phases = table.freeze(present),
		order = table.freeze(order),
		durations = table.freeze({
			intermission = def.durations.intermission,
			active = def.durations.active,
			results = def.durations.results,
		}),
		minPlayers = def.minPlayers,
		maxPlayers = def.maxPlayers or RoundLoop.MAX_PLAYERS,
		lateJoin = def.lateJoin or "spectate",
		joinWindow = def.joinWindow,
		endOnAlive = def.endOnAlive,
		fsm = fsmFor(present),
	})
end

-- ---------------------------------------------------------------- loop

type Fields = {
	spec: Spec,
	phaseChanged: Signal.Signal,
	_env: any,
	_machine: any,
	_now: number,
	_startedAt: number,
	_endsAt: number?,
	_round: number,
	_order: { any }, -- join order of present players
	_roles: { [any]: string },
	_spent: { [any]: boolean }, -- left or eliminated during the current round
	_result: any?,
}
export type RoundLoop = typeof(setmetatable({} :: Fields, RoundLoop))

function RoundLoop.new(spec: Spec, _options: any?, env: any): RoundLoop
	assert(
		type(spec) == "table" and table.isfrozen(spec) and spec.fsm,
		"RoundLoop.new needs a spec from RoundLoop.define"
	)
	assert(type(env) == "table" and type(env.clock) == "function", "RoundLoop.new needs env.clock")
	local now = env.clock()
	return setmetatable({
		spec = spec,
		phaseChanged = Signal.new(env),
		_env = env,
		_machine = Fsm.new(spec.fsm, nil, env),
		_now = now,
		_startedAt = now,
		_endsAt = nil,
		_round = 0,
		_order = {},
		_roles = {},
		_spent = {},
		_result = nil,
	}, RoundLoop)
end

function RoundLoop.phase(self: RoundLoop): string
	return self._machine:state()
end

function RoundLoop.round(self: RoundLoop): number
	return self._round
end

function RoundLoop.role(self: RoundLoop, id: any): string?
	return self._roles[id]
end

function RoundLoop.result(self: RoundLoop): any?
	return self._result
end

local function listRole(self: RoundLoop, role: string): { any }
	local list = {}
	for _, id in self._order do
		if self._roles[id] == role then
			table.insert(list, id)
		end
	end
	return list
end

-- Present players (any role), in join order.
function RoundLoop.players(self: RoundLoop): { any }
	return table.clone(self._order)
end

-- Players still in play this round, in join order.
function RoundLoop.alive(self: RoundLoop): { any }
	return listRole(self, "participant")
end

function RoundLoop.spectators(self: RoundLoop): { any }
	return listRole(self, "spectator")
end

function RoundLoop.queued(self: RoundLoop): { any }
	return listRole(self, "queued")
end

-- Seconds left in the current phase (nil when it has no end).
function RoundLoop.timeLeft(self: RoundLoop, now: number?): number?
	if self._endsAt == nil then
		return nil
	end
	return math.max(0, (self._endsAt :: number) - (now or self._now))
end

local function durationOf(self: RoundLoop, phase: string): number?
	if phase == "intermission" then
		return self.spec.durations.intermission
	elseif phase == "active" then
		return self.spec.durations.active
	elseif phase == "results" then
		return self.spec.durations.results
	end
	return nil
end

local function transition(self: RoundLoop, event: string, at: number, reason: string, events: { Event })
	local from = self:phase()
	local ok, why = self._machine:send(event)
	assert(ok, "RoundLoop: internal transition refused: " .. tostring(why))
	local phase = self:phase()
	self._startedAt = at
	local duration = durationOf(self, phase)
	self._endsAt = if duration then at + duration else nil
	if phase == "active" then
		self._round += 1
		self._result = nil
		table.clear(self._spent)
		-- Everyone present plays, in join order, up to maxPlayers; the rest wait in the queue.
		local count = 0
		for _, id in self._order do
			if count < self.spec.maxPlayers then
				self._roles[id] = "participant"
				count += 1
			else
				self._roles[id] = "queued"
			end
		end
	elseif phase == "lobby" or phase == "intermission" then
		for _, id in self._order do
			self._roles[id] = "waiting"
		end
	end
	local event_: Event =
		{ kind = "phase", phase = phase, from = from, at = at, round = self._round, reason = reason }
	if phase == "results" or (from == "active" and phase ~= "active") then
		event_.result = self._result
	end
	table.insert(events, event_)
	self.phaseChanged:Fire(phase, from, event_)
end

local function enough(self: RoundLoop): boolean
	return #self._order >= self.spec.minPlayers
end

-- Advances the loop to now. Returns the phase events (several when a late tick crosses more
-- than one phase end). A tick earlier than the last one is ignored.
function RoundLoop.tick(self: RoundLoop, now: number?): { Event }
	local events: { Event } = {}
	local t = now or self._env.clock()
	if not Check.finite(t) or t < self._now then
		return events
	end
	self._now = t
	for _ = 1, RoundLoop.MAX_TRANSITIONS_PER_TICK do
		local phase = self:phase()
		local endsAt = self._endsAt
		if phase == "lobby" then
			if not enough(self) then
				break
			end
			transition(
				self,
				if self.spec.phases.intermission then "ready" else "start",
				t,
				"enough_players",
				events
			)
		elseif phase == "intermission" then
			if not enough(self) then
				transition(self, "abort", t, "not_enough_players", events)
			elseif endsAt and t >= endsAt then
				transition(self, "start", endsAt, "countdown", events)
			else
				break
			end
		elseif phase == "active" then
			local alive = #self:alive()
			if alive == 0 then
				transition(self, "idle", t, "empty", events)
			elseif self.spec.endOnAlive ~= nil and alive <= self.spec.endOnAlive then
				self._result = { reason = "last_standing", survivors = self:alive() }
				transition(self, "finish", t, "last_standing", events)
			elseif endsAt and t >= endsAt then
				self._result = { reason = "time", survivors = self:alive() }
				transition(self, "finish", endsAt, "time", events)
			else
				break
			end
		elseif phase == "results" then
			if endsAt and t >= endsAt then
				if enough(self) then
					transition(self, "next", endsAt, "next_round", events)
				else
					transition(self, "idle", endsAt, "not_enough_players", events)
				end
			else
				break
			end
		else
			break
		end
	end
	return events
end

-- Ends the active phase now with a game-supplied result (winner ids, scores). (ok, reason?).
function RoundLoop.finish(self: RoundLoop, result: any?, now: number?): (boolean, string?, { Event }?)
	if self:phase() ~= "active" then
		return false, "not_active", nil
	end
	local t = now or self._now
	if not Check.finite(t) or t < self._now then
		t = self._now
	end
	self._now = t
	self._result = if result ~= nil
		then Check.copy(result)
		else { reason = "finished", survivors = self:alive() }
	local events = {}
	transition(self, "finish", t, "finished", events)
	return true, nil, events
end

-- Adds a player. (true, role) or (false, reason) with bad_id, already_joined or full.
function RoundLoop.join(self: RoundLoop, id: any): (boolean, string)
	if
		id == nil
		or (type(id) ~= "string" and type(id) ~= "number")
		or (type(id) == "number" and not Check.finite(id))
	then
		return false, "bad_id"
	end
	if self._roles[id] ~= nil then
		return false, "already_joined"
	end
	if #self._order >= RoundLoop.MAX_PLAYERS then
		return false, "full"
	end
	table.insert(self._order, id)
	local role = "waiting"
	if self:phase() == "active" then
		local policy = self.spec.lateJoin
		local inWindow = self.spec.joinWindow == nil
			or self._now - self._startedAt <= (self.spec.joinWindow :: number)
		local spent = self._spent[id] == true
		if not spent and policy == "join" and inWindow and #self:alive() < self.spec.maxPlayers then
			role = "participant"
		elseif not spent and policy == "queue" then
			role = "queued"
		else
			role = "spectator"
		end
	end
	self._roles[id] = role
	return true, role
end

-- Removes a player. (true) or (false, "unknown").
function RoundLoop.leave(self: RoundLoop, id: any): (boolean, string?)
	if id == nil or self._roles[id] == nil then
		return false, "unknown"
	end
	if self:phase() == "active" and self._roles[id] == "participant" then
		self._spent[id] = true
	end
	self._roles[id] = nil
	table.remove(self._order, table.find(self._order, id) :: number)
	return true, nil
end

-- Takes a participant out of the current round (they spectate). (ok, reason?).
function RoundLoop.eliminate(self: RoundLoop, id: any): (boolean, string?)
	if self:phase() ~= "active" then
		return false, "not_active"
	end
	if self._roles[id] ~= "participant" then
		return false, "not_participant"
	end
	self._roles[id] = "spectator"
	self._spent[id] = true
	return true, nil
end

-- Back to the lobby now (admin reset or shutdown).
function RoundLoop.reset(self: RoundLoop): { Event }
	local events = {}
	if self:phase() ~= "lobby" then
		transition(self, "reset", self._now, "reset", events)
	end
	return events
end

-- The attribute-sized view for replication (the adapter writes these as attributes).
function RoundLoop.snapshot(self: RoundLoop, now: number?): { [string]: any }
	local left = self:timeLeft(now)
	return {
		phase = self:phase(),
		timeLeft = if left then math.ceil(left) else -1,
		round = self._round,
		players = #self._order,
		alive = #self:alive(),
		state = self._machine:serialize(),
	}
end

function RoundLoop.destroy(self: RoundLoop)
	self.phaseChanged:Destroy()
	self._machine.changed:Destroy()
	table.clear(self._roles)
	table.clear(self._order)
end

return RoundLoop
