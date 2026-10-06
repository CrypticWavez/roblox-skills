--!strict
-- @tier T0
-- Fsm: validated finite-state machines as data. Fsm.define checks a definition once and freezes
-- it; Fsm.new runs it. Definition:
--   { name = "round"?, initial = "lobby",
--     states = { lobby = {}, active = {}, done = { terminal = true } },
--     transitions = { { from = "lobby", event = "start", to = "active", guard = fn? }, ... } }
-- from = "*" matches every non-terminal state; transitions are tried in order (specific before
-- wildcard), and the first whose guard(ctx, from, event) is true wins. send() called from inside
-- a hook queues the event (at most QUEUE_LIMIT) and returns (true, "queued"); the queue drains
-- after the current transition (a queued event that no longer matches is dropped). serialize() gives "fsm/1:<name>:<state>" for one string
-- attribute (Server Authority keeps machine state in attributes); Fsm.restore reads it back.
local Check = require("./Check")
local Signal = require("./Signal")

local Fsm = {}
Fsm.QUEUE_LIMIT = 32
Fsm.FORMAT = "fsm/1"

export type Guard = (ctx: any, from: string, event: string) -> boolean
export type Transition = { from: string, event: string, to: string, guard: Guard? }
export type Definition = {
	name: string?,
	initial: string,
	states: { [string]: { terminal: boolean? } },
	transitions: { Transition },
}
export type Spec = {
	name: string,
	initial: string,
	states: { [string]: { terminal: boolean? } },
	transitions: { Transition },
	events: { [string]: boolean },
}
export type Hooks = {
	onEnter: ((state: string, ctx: any, from: string?, event: string?) -> ())?,
	onExit: ((state: string, ctx: any, to: string, event: string) -> ())?,
	onTransition: ((from: string, to: string, event: string, ctx: any) -> ())?,
}

local Machine = {}
Machine.__index = Machine

type MachineFields = {
	spec: Spec,
	changed: Signal.Signal,
	_state: string,
	_hooks: Hooks,
	_queue: { { event: string, ctx: any } },
	_busy: boolean,
}
export type Machine = typeof(setmetatable({} :: MachineFields, Machine))

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- Problems with a definition (empty when it is valid): names, unknown states, unreachable
-- states, non-terminal dead ends, terminal states with transitions, shadowed transitions.
function Fsm.validate(def: any): { string }
	if type(def) ~= "table" then
		return { "definition must be a table" }
	end
	local problems = {}
	local function problem(text: string, ...: any)
		table.insert(problems, string.format(text, ...))
	end
	if def.name ~= nil and not Check.label(def.name) then
		problem("name %s is not a label", Check.describe(def.name))
	end
	local states = def.states
	if type(states) ~= "table" or next(states) == nil then
		problem("states must be a non-empty map of name -> { terminal? }")
		return problems
	end
	for name, info in states do
		if not Check.label(name) then
			problem("state %s is not a label", Check.describe(name))
		elseif type(info) ~= "table" then
			problem("state %s must map to a table", name)
		elseif info.terminal ~= nil and type(info.terminal) ~= "boolean" then
			problem("state %s: terminal must be a boolean", name)
		end
	end
	local function isTerminal(name: string): boolean
		local info = states[name]
		return type(info) == "table" and info.terminal == true
	end
	if type(def.initial) ~= "string" or states[def.initial] == nil then
		problem("initial %s is not a state", Check.describe(def.initial))
	end
	local transitions = def.transitions
	if type(transitions) ~= "table" then
		problem("transitions must be a list")
		return problems
	end
	local outgoing: { [string]: boolean } = {}
	local wildcardTargets: { string } = {}
	local edges: { [string]: { string } } = {}
	local unguarded: { [string]: number } = {}
	for index, t in transitions do
		local where = "transition " .. tostring(index)
		if type(t) ~= "table" then
			problem("%s must be a table", where)
			continue
		end
		local ok = true
		if not Check.label(t.event) then
			problem("%s: event %s is not a label", where, Check.describe(t.event))
			ok = false
		end
		if t.from ~= "*" and (type(t.from) ~= "string" or states[t.from] == nil) then
			problem("%s: from %s is not a state", where, Check.describe(t.from))
			ok = false
		end
		if type(t.to) ~= "string" or states[t.to] == nil then
			problem("%s: to %s is not a state", where, Check.describe(t.to))
			ok = false
		end
		if t.guard ~= nil and type(t.guard) ~= "function" then
			problem("%s: guard must be a function", where)
			ok = false
		end
		if not ok then
			continue
		end
		if t.from ~= "*" and isTerminal(t.from) then
			problem("%s: terminal state %s has a transition", where, t.from)
		end
		-- An unguarded transition hides every later one with the same from and event (wildcards
		-- are tried after specific transitions, so only an earlier wildcard hides a wildcard).
		local key = t.from .. "\0" .. t.event
		if unguarded[key] then
			problem(
				"%s: shadowed by unguarded transition %d (%s on %s)",
				where,
				unguarded[key],
				t.from,
				t.event
			)
		end
		if t.guard == nil and unguarded[key] == nil then
			unguarded[key] = index
		end
		if t.from == "*" then
			table.insert(wildcardTargets, t.to)
		else
			outgoing[t.from] = true
			edges[t.from] = edges[t.from] or {}
			table.insert(edges[t.from], t.to)
		end
	end
	if #problems > 0 then
		return problems
	end
	-- Reachability from initial: wildcard transitions leave every reachable non-terminal state.
	local seen: { [string]: boolean } = { [def.initial] = true }
	local queue = { def.initial }
	while #queue > 0 do
		local state = table.remove(queue, 1) :: string
		local targets = table.clone(edges[state] or {})
		if not isTerminal(state) then
			for _, target in wildcardTargets do
				table.insert(targets, target)
			end
		end
		for _, target in targets do
			if not seen[target] then
				seen[target] = true
				table.insert(queue, target)
			end
		end
	end
	for _, name in sortedKeys(states) do
		if not seen[name] then
			problem("state %s is unreachable from %s", name, def.initial)
		end
		if not isTerminal(name) and not outgoing[name] and #wildcardTargets == 0 then
			problem("state %s is a dead end (no transitions; mark it terminal if intended)", name)
		end
	end
	return problems
end

-- Validates and freezes a definition. Raises with every problem listed.
function Fsm.define(def: Definition): Spec
	local problems = Fsm.validate(def)
	if #problems > 0 then
		error("Fsm.define: " .. table.concat(problems, "; "), 2)
	end
	local events: { [string]: boolean } = {}
	local transitions: { Transition } = {}
	-- Specific transitions are tried before wildcards; declaration order is kept within each.
	for pass = 1, 2 do
		for _, t in def.transitions do
			if (pass == 1) == (t.from ~= "*") then
				events[t.event] = true
				table.insert(
					transitions,
					table.freeze({ from = t.from, event = t.event, to = t.to, guard = t.guard })
				)
			end
		end
	end
	local states = {}
	for name, info in def.states do
		states[name] = table.freeze({ terminal = info.terminal == true })
	end
	return table.freeze({
		name = def.name or "fsm",
		initial = def.initial,
		states = table.freeze(states),
		transitions = table.freeze(transitions),
		events = table.freeze(events),
	})
end

local function isSpec(spec: any): boolean
	return type(spec) == "table" and table.isfrozen(spec) and type(spec.events) == "table"
end

local function newMachine(spec: Spec, state: string, hooks: Hooks?, env: any?): Machine
	return setmetatable({
		spec = spec,
		changed = Signal.new(env),
		_state = state,
		_hooks = hooks or {},
		_queue = {},
		_busy = false,
	}, Machine)
end

-- A machine in spec.initial. onEnter(initial, nil) runs now. machine.changed fires
-- (from, to, event) after every transition; pass env to give the signal an env.
function Fsm.new(spec: Spec, hooks: Hooks?, env: any?): Machine
	assert(isSpec(spec), "Fsm.new needs a spec from Fsm.define")
	local machine = newMachine(spec, spec.initial, hooks, env)
	local onEnter = machine._hooks.onEnter
	if onEnter then
		onEnter(spec.initial, nil, nil, nil)
	end
	return machine
end

-- The transition send(event, ctx) would take now, or nil and the reason it would not.
local function pick(self: Machine, event: string, ctx: any): (Transition?, string?)
	local spec = self.spec
	if not spec.events[event] then
		return nil, "unknown_event"
	end
	local state = self._state
	local terminal = spec.states[state].terminal
	local matched = false
	for _, t in spec.transitions do
		if t.event == event and (t.from == state or (t.from == "*" and not terminal)) then
			matched = true
			if t.guard == nil or t.guard(ctx, state, event) == true then
				return t, nil
			end
		end
	end
	return nil, if matched then "guard_rejected" else "no_transition"
end

local function apply(self: Machine, t: Transition, event: string, ctx: any)
	local from = self._state
	local hooks = self._hooks
	if hooks.onExit then
		hooks.onExit(from, ctx, t.to, event)
	end
	self._state = t.to
	if hooks.onTransition then
		hooks.onTransition(from, t.to, event, ctx)
	end
	if hooks.onEnter then
		hooks.onEnter(t.to, ctx, from, event)
	end
	self.changed:Fire(from, t.to, event)
end

-- Sends an event. Returns (true, nil) after a transition, (true, "queued") when called from a
-- hook, or (false, reason): unknown_event, no_transition, guard_rejected, queue_full.
-- A hook or guard error resets the queue and is re-raised.
function Machine.send(self: Machine, event: string, ctx: any?): (boolean, string?)
	if self._busy then
		if #self._queue >= Fsm.QUEUE_LIMIT then
			return false, "queue_full"
		end
		table.insert(self._queue, { event = event, ctx = ctx })
		return true, "queued"
	end
	local t, reason = pick(self, event, ctx)
	if not t then
		return false, reason
	end
	self._busy = true
	local ok, err = pcall(function()
		apply(self, t :: Transition, event, ctx)
		while #self._queue > 0 do
			local item = table.remove(self._queue, 1) :: { event: string, ctx: any }
			local next_ = pick(self, item.event, item.ctx)
			if next_ then
				apply(self, next_, item.event, item.ctx)
			end
		end
	end)
	self._busy = false
	if not ok then
		self._queue = {}
		error(err, 0)
	end
	return true, nil
end

-- Whether send(event, ctx) would transition now (guards run; hooks do not).
function Machine.can(self: Machine, event: string, ctx: any?): boolean
	return (pick(self, event, ctx)) ~= nil
end

function Machine.state(self: Machine): string
	return self._state
end

-- Pending events queued from hooks (always 0 outside a transition).
function Machine.pending(self: Machine): number
	return #self._queue
end

function Machine.serialize(self: Machine): string
	return string.format("%s:%s:%s", Fsm.FORMAT, self.spec.name, self._state)
end

-- A machine restored from serialize() output, without running onEnter; or nil and a reason
-- (bad_format, wrong_spec, unknown_state) for text that does not belong to this spec.
function Fsm.restore(spec: Spec, text: any, hooks: Hooks?, env: any?): (Machine?, string?)
	assert(isSpec(spec), "Fsm.restore needs a spec from Fsm.define")
	if type(text) ~= "string" then
		return nil, "bad_format"
	end
	local format, name, state = string.match(text, "^([%w/]+):([a-z][a-z0-9_]*):([a-z][a-z0-9_]*)$")
	if format ~= Fsm.FORMAT then
		return nil, "bad_format"
	end
	if name ~= spec.name then
		return nil, "wrong_spec"
	end
	if spec.states[state :: string] == nil then
		return nil, "unknown_state"
	end
	return newMachine(spec, state :: string, hooks, env), nil
end

return Fsm
