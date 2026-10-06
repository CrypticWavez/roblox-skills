--!strict
-- @tier T0
-- Onboarding: an ordered list of step names run as a GameKit/Fsm (one state per step, then
-- "done"), with kit-event/1 onboarding funnel events (LogOnboardingFunnelStepEvent via G1's
-- Telemetry) and resume after rejoin. The completed set persists through an injected key store;
-- on load the current step is the first one not completed, so a changed step list resumes
-- sensibly and a completed step never reports twice. complete(step) writes the store first
-- and emits only after the write succeeded (emit after the durable write). The game names the
-- steps; none ship here. Steps are numbered 1..n (at most 100, the funnel limit).
local Check = require("./Check")
local Events = require("./Events")
local Fsm = require("./Fsm")

local Onboarding = {}
Onboarding.__index = Onboarding
Onboarding.SCHEMA = "onboarding/1"
Onboarding.DONE = "done"

export type Store = { get: (self: any, key: string) -> any, set: (self: any, key: string, value: any) -> () }
export type Options = {
	steps: { string },
	store: Store?,
	storeKey: string?, -- default "onboarding"
	sink: Events.Sink?,
	player: string?,
	allowSkipAhead: boolean?, -- complete(a later step) also completes the ones before it
	report: ((message: string) -> ())?,
}
type OnboardingFields = {
	notes: { string },
	_steps: { string },
	_index: { [string]: number },
	_completed: { [string]: boolean },
	_skipped: boolean,
	_machine: Fsm.Machine,
	_spec: Fsm.Spec,
	_options: Options,
	_report: (message: string) -> (),
}
export type Onboarding = typeof(setmetatable({} :: OnboardingFields, Onboarding))

-- Problems with a step list (empty when valid).
function Onboarding.validate(steps: any): { string }
	if type(steps) ~= "table" or #steps == 0 then
		return { "steps must be a non-empty list of labels" }
	end
	local problems = {}
	if #steps > Events.LIMITS.funnelSteps then
		table.insert(problems, string.format("at most %d steps (funnel limit)", Events.LIMITS.funnelSteps))
	end
	local seen = {}
	for index, step in steps do
		if not Check.label(step) then
			table.insert(problems, string.format("step %d %s is not a label", index, Check.describe(step)))
		elseif step == Onboarding.DONE then
			table.insert(problems, "step name done is reserved")
		elseif seen[step] then
			table.insert(problems, "duplicate step " .. step)
		end
		seen[step] = true
	end
	return problems
end

local function spec(steps: { string }): Fsm.Spec
	local states: { [string]: any } = { [Onboarding.DONE] = { terminal = true } }
	local transitions = {}
	for index, step in steps do
		states[step] = {}
		table.insert(
			transitions,
			{ from = step, event = "complete", to = steps[index + 1] or Onboarding.DONE }
		)
	end
	table.insert(transitions, { from = "*", event = "skip", to = Onboarding.DONE })
	return Fsm.define({ name = "onboarding", initial = steps[1], states = states, transitions = transitions })
end

local function firstOpen(self: Onboarding): string
	if self._skipped then
		return Onboarding.DONE
	end
	for _, step in self._steps do
		if not self._completed[step] then
			return step
		end
	end
	return Onboarding.DONE
end

-- Onboarding for one player, resumed from the store when it holds onboarding/1 data.
-- Raises on invalid options. onboarding.notes lists load repairs.
function Onboarding.new(options: Options, env: any?): Onboarding
	assert(type(options) == "table", "Onboarding.new: options must be a table")
	local problems = Onboarding.validate(options.steps)
	local store = options.store
	if
		store ~= nil
		and (type(store) ~= "table" or type(store.get) ~= "function" or type(store.set) ~= "function")
	then
		table.insert(problems, "store must have get and set methods")
	end
	if #problems > 0 then
		error("Onboarding.new: " .. table.concat(problems, "; "), 2)
	end
	local steps = table.clone(options.steps)
	local index = {}
	for i, step in steps do
		index[step] = i
	end
	local fsmSpec = spec(steps)
	local self = setmetatable({
		notes = {},
		_steps = steps,
		_index = index,
		_completed = {},
		_skipped = false,
		_machine = Fsm.new(fsmSpec, nil, env),
		_spec = fsmSpec,
		_options = options,
		_report = options.report
			or (env and type(env.report) == "function" and env.report)
			or function(_message: string) end,
	}, Onboarding)
	if store then
		local ok, data = pcall(store.get, store, options.storeKey or "onboarding")
		if not ok then
			error("Onboarding.new: store:get failed: " .. tostring(data), 2)
		end
		if data ~= nil then
			if type(data) ~= "table" or data.schema ~= Onboarding.SCHEMA then
				table.insert(self.notes, "stored data is not onboarding/1; starting over")
			else
				for _, step in data.completed or {} do
					if index[step] then
						self._completed[step] = true
					else
						table.insert(
							self.notes,
							"completed step " .. Check.describe(step) .. " is no longer a step"
						)
					end
				end
				self._skipped = data.skipped == true
			end
		end
	end
	local restored =
		Fsm.restore(fsmSpec, string.format("%s:onboarding:%s", Fsm.FORMAT, firstOpen(self)), nil, env)
	self._machine = restored :: Fsm.Machine
	return self
end

-- The current step name, or nil when onboarding is done (completed or skipped).
function Onboarding.current(self: Onboarding): string?
	local state = self._machine:state()
	return if state == Onboarding.DONE then nil else state
end

-- 1-based number of the current step (n + 1 when done).
function Onboarding.stepNumber(self: Onboarding): number
	local current = self:current()
	return if current then self._index[current] else #self._steps + 1
end

function Onboarding.isDone(self: Onboarding): boolean
	return self._machine:state() == Onboarding.DONE
end

function Onboarding.isCompleted(self: Onboarding, step: string): boolean
	return self._completed[step] == true
end

-- { completed, total, skipped }
function Onboarding.progress(self: Onboarding): any
	local done = 0
	for _ in self._completed do
		done += 1
	end
	return { completed = done, total = #self._steps, skipped = self._skipped }
end

function Onboarding.serialize(self: Onboarding): any
	local completed = {}
	for _, step in self._steps do
		if self._completed[step] then
			table.insert(completed, step)
		end
	end
	return {
		schema = Onboarding.SCHEMA,
		completed = completed,
		skipped = self._skipped,
		state = self._machine:serialize(),
	}
end

local function persist(self: Onboarding): boolean
	local store = self._options.store
	if store == nil then
		return true
	end
	local ok, err = pcall(store.set, store, self._options.storeKey or "onboarding", self:serialize())
	if not ok then
		self._report("Onboarding: store:set failed: " .. tostring(err))
	end
	return ok
end

local function emit(self: Onboarding, event: any)
	local sink = self._options.sink
	if sink == nil then
		return
	end
	if self._options.player then
		event.player = self._options.player
	end
	local ok, err = pcall(function()
		(sink :: any):emit(event)
	end)
	if not ok then
		self._report("Onboarding: sink error: " .. tostring(err))
	end
end

-- Completes step. (true, nil) after a new completion, (true, "already") for a step done before
-- (no event: resume-safe), or (false, reason) with unknown_step, done, out_of_order (a later step
-- while allowSkipAhead is off) or store_failed (nothing changed, nothing reported).
function Onboarding.complete(self: Onboarding, step: string): (boolean, string?)
	local target = self._index[step]
	if target == nil then
		return false, "unknown_step"
	end
	if self._completed[step] then
		return true, "already"
	end
	if self:isDone() then
		return false, "done"
	end
	local current = self._index[self:current() :: string]
	if target > current and not self._options.allowSkipAhead then
		return false, "out_of_order"
	end
	local newly = {}
	for i = current, target do
		if not self._completed[self._steps[i]] then
			self._completed[self._steps[i]] = true
			table.insert(newly, i)
		end
	end
	local before = self._machine:state()
	local nextState = firstOpen(self)
	if not persist(self) then
		for _, i in newly do
			self._completed[self._steps[i]] = nil
		end
		return false, "store_failed"
	end
	self._machine =
		Fsm.restore(self._spec, string.format("%s:onboarding:%s", Fsm.FORMAT, nextState)) :: Fsm.Machine
	for _, i in newly do
		emit(self, Events.onboarding("onboarding_step", { step = i, step_name = self._steps[i] }))
	end
	if before ~= Onboarding.DONE and nextState == Onboarding.DONE then
		emit(self, Events.custom("onboarding_complete", #self._steps))
	end
	return true, nil
end

-- Marks onboarding done without completing the rest (a returning player opting out). Emits a
-- custom onboarding_skipped event with the step number skipped from.
function Onboarding.skip(self: Onboarding): (boolean, string?)
	if self:isDone() then
		return false, "done"
	end
	local from = self:stepNumber()
	self._skipped = true
	if not persist(self) then
		self._skipped = false
		return false, "store_failed"
	end
	self._machine:send("skip")
	emit(self, Events.custom("onboarding_skipped", from))
	return true, nil
end

return Onboarding
