--!strict
-- @tier T0
-- Objectives: quests, achievements and daily tasks as data. An objective counts one counter:
--   { id, counter, target, mode? = "sum" | "max" | "latest", filter? = { [field] = value },
--     requires? = { ids }, reset? = "never" | "daily" | "weekly", reward? }
-- record(counter, amount, context) feeds every unlocked objective on that counter whose filter
-- matches the context fields. States: locked (a prerequisite is not completed yet) -> tracked
-- -> completed -> claimed. claim(id) hands back the reward data exactly once (the caller grants
-- it). refresh(utc) restarts daily and weekly objectives when the server UTC day or week changes
-- (Streaks.dayIndex/weekIndex with the same offset). Events: a kit-event/1 progression event
-- when an objective completes (path = id, level = times completed) and a custom
-- "objective_claimed" event on claim. No objectives ship here.
local Check = require("./Check")
local Events = require("./Events")
local Streaks = require("./Streaks")

local Objectives = {}
Objectives.SCHEMA = "objectives/1"
Objectives.MODES = table.freeze({ "sum", "max", "latest" })
Objectives.RESETS = table.freeze({ "never", "daily", "weekly" })
Objectives.STATES = table.freeze({ "locked", "tracked", "completed", "claimed" })

local Tracker = {}
Tracker.__index = Tracker

export type Def = {
	id: string,
	counter: string,
	target: number,
	mode: string,
	filter: { [string]: any }?,
	requires: { string },
	reset: string,
	reward: any?,
}
export type Spec = { defs: { Def }, byId: { [string]: Def }, byCounter: { [string]: { Def } } }

-- Problems with objective definitions (empty when valid): shapes, duplicate ids, unknown or
-- cyclic prerequisites.
function Objectives.validate(defs: any): { string }
	if type(defs) ~= "table" then
		return { "defs must be a list of objectives" }
	end
	local problems = {}
	local byId: { [string]: any } = {}
	for index, def in defs do
		local where = "objective "
			.. (if type(def) == "table" and type(def.id) == "string" then def.id else "#" .. tostring(index))
		local function problem(text: string, ...: any)
			table.insert(problems, where .. ": " .. string.format(text, ...))
		end
		if type(def) ~= "table" then
			problem("must be a table")
			continue
		end
		if not Check.label(def.id) then
			problem("id %s is not a label", Check.describe(def.id))
		elseif byId[def.id] then
			problem("duplicate id")
		else
			byId[def.id] = def
		end
		if not Check.label(def.counter) then
			problem("counter %s is not a label", Check.describe(def.counter))
		end
		if not (Check.integer(def.target) and def.target >= 1) then
			problem("target must be an integer >= 1")
		end
		if def.mode ~= nil and not table.find(Objectives.MODES, def.mode) then
			problem("mode must be sum, max or latest")
		end
		if def.reset ~= nil and not table.find(Objectives.RESETS, def.reset) then
			problem("reset must be never, daily or weekly")
		end
		if def.filter ~= nil then
			if type(def.filter) ~= "table" then
				problem("filter must map field labels to values")
			else
				for key, value in def.filter do
					local kind = type(value)
					if
						not Check.label(key)
						or not (
							kind == "string"
							or kind == "boolean"
							or (kind == "number" and Check.finite(value))
						)
					then
						problem(
							"filter %s must map a label to a string, number or boolean",
							Check.describe(key)
						)
					end
				end
			end
		end
		if def.requires ~= nil and type(def.requires) ~= "table" then
			problem("requires must be a list of objective ids")
		end
		for key in def do
			if
				not table.find(
					{ "id", "counter", "target", "mode", "filter", "requires", "reset", "reward" },
					key
				)
			then
				problem("unknown key %s", Check.describe(key))
			end
		end
	end
	-- Prerequisites must exist and must not form a cycle.
	local color: { [string]: number } = {}
	local function visit(id: string, trail: { string }): boolean
		if color[id] == 2 then
			return true
		end
		if color[id] == 1 then
			table.insert(problems, "requires cycle: " .. table.concat(trail, " -> ") .. " -> " .. id)
			return false
		end
		color[id] = 1
		table.insert(trail, id)
		for _, need in byId[id].requires or {} do
			if byId[need] == nil then
				table.insert(
					problems,
					string.format("objective %s: requires unknown objective %s", id, Check.describe(need))
				)
			elseif need == id then
				table.insert(problems, string.format("objective %s: requires itself", id))
			elseif not visit(need, trail) then
				table.remove(trail)
				color[id] = 2
				return false
			end
		end
		table.remove(trail)
		color[id] = 2
		return true
	end
	local ids = {}
	for id in byId do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		if color[id] == nil then
			visit(id, {})
		end
	end
	return problems
end

-- A frozen spec. Raises with every problem listed.
function Objectives.define(defs: { any }): Spec
	local problems = Objectives.validate(defs)
	if #problems > 0 then
		error("Objectives.define: " .. table.concat(problems, "; "), 2)
	end
	local list, byId, byCounter = {}, {}, {}
	for _, raw in defs do
		local def: Def = {
			id = raw.id,
			counter = raw.counter,
			target = raw.target,
			mode = raw.mode or "sum",
			filter = raw.filter and table.clone(raw.filter),
			requires = if raw.requires then table.clone(raw.requires) else {},
			reset = raw.reset or "never",
			reward = raw.reward ~= nil and Check.copy(raw.reward) or nil,
		}
		Check.freeze(def)
		table.insert(list, def)
		byId[def.id] = def
		byCounter[def.counter] = byCounter[def.counter] or {}
		table.insert(byCounter[def.counter], def)
	end
	return Check.freeze({ defs = list, byId = byId, byCounter = byCounter })
end

type Entry = { progress: number, state: string, cycle: number?, completions: number }
type TrackerFields = {
	notes: { string },
	_spec: Spec,
	_entries: { [string]: Entry },
	_sink: Events.Sink?,
	_player: string?,
	_offset: number?,
}
export type Tracker = typeof(setmetatable({} :: TrackerFields, Tracker))
export type Options = { sink: Events.Sink?, player: string?, offset: number?, data: any? }

local function emit(self: Tracker, event: any)
	local sink = self._sink
	if sink == nil then
		return
	end
	if self._player then
		event.player = self._player
	end
	pcall(function()
		(sink :: any):emit(event)
	end)
end

local function unlocked(self: Tracker, def: Def): boolean
	for _, need in def.requires do
		local state = self._entries[need].state
		if state ~= "completed" and state ~= "claimed" then
			return false
		end
	end
	return true
end

-- Re-derives locked/tracked for every objective after a change (prerequisites may complete).
local function relock(self: Tracker)
	for _, def in self._spec.defs do
		local entry = self._entries[def.id]
		if entry.state == "locked" and unlocked(self, def) then
			entry.state = "tracked"
		elseif entry.state == "tracked" and not unlocked(self, def) then
			entry.state = "locked"
		end
	end
end

local function complete(self: Tracker, def: Def, entry: Entry, completed: { string })
	if entry.state == "tracked" and entry.progress >= def.target then
		entry.state = "completed"
		entry.completions += 1
		table.insert(completed, def.id)
		emit(
			self,
			Events.progression(
				"objective_complete",
				{ path = def.id, status = "complete", level = entry.completions }
			)
		)
	end
end

-- A tracker for one player. Loads objectives/1 data when given; unknown ids are dropped with a
-- note, progress is clamped to integers >= 0.
function Objectives.new(spec: Spec, options: Options?, _env: any?): Tracker
	assert(
		type(spec) == "table" and table.isfrozen(spec) and spec.byId,
		"Objectives.new needs a spec from define"
	)
	local opts: Options = options or {}
	if opts.offset ~= nil then
		assert(
			Check.integer(opts.offset) and math.abs(opts.offset) < Streaks.DAY,
			"offset must be whole seconds within a day"
		)
	end
	local self = setmetatable({
		notes = {},
		_spec = spec,
		_entries = {},
		_sink = opts.sink,
		_player = opts.player,
		_offset = opts.offset,
	}, Tracker)
	for _, def in spec.defs do
		self._entries[def.id] = { progress = 0, state = "locked", cycle = nil, completions = 0 }
	end
	local data = opts.data
	if data ~= nil then
		if type(data) ~= "table" or data.schema ~= Objectives.SCHEMA or type(data.entries) ~= "table" then
			table.insert(self.notes, "stored data is not objectives/1; starting fresh")
		else
			for id, raw in data.entries do
				local entry = self._entries[id]
				if entry == nil then
					table.insert(self.notes, "dropped unknown objective " .. Check.describe(id))
					continue
				end
				if type(raw) ~= "table" then
					continue
				end
				entry.progress = if Check.integer(raw.progress) and raw.progress >= 0 then raw.progress else 0
				entry.completions = if Check.integer(raw.completions) and raw.completions >= 0
					then raw.completions
					else 0
				entry.cycle = if Check.integer(raw.cycle) then raw.cycle else nil
				if raw.state == "completed" or raw.state == "claimed" then
					entry.state = raw.state
				end
			end
		end
	end
	relock(self)
	return self
end

local function matches(filter: { [string]: any }?, context: { [string]: any }?): boolean
	if filter == nil then
		return true
	end
	if context == nil then
		return false
	end
	for key, value in filter do
		if context[key] ~= value then
			return false
		end
	end
	return true
end

-- Feeds amount (integer >= 0) of counter to matching objectives. Returns the ids that completed.
function Tracker.record(
	self: Tracker,
	counter: string,
	amount: number,
	context: { [string]: any }?
): { string }
	assert(Check.integer(amount) and amount >= 0, "Objectives: amount must be an integer >= 0")
	local completed = {}
	for _, def in self._spec.byCounter[counter] or {} do
		local entry = self._entries[def.id]
		if entry.state ~= "tracked" or not matches(def.filter, context) then
			continue
		end
		if def.mode == "sum" then
			entry.progress = math.min(entry.progress + amount, Check.MAX_SAFE_INTEGER)
		elseif def.mode == "max" then
			entry.progress = math.max(entry.progress, amount)
		else
			entry.progress = amount
		end
		complete(self, def, entry, completed)
	end
	if #completed > 0 then
		relock(self)
		-- Objectives unlocked by these completions may already be satisfied (max/latest modes keep
		-- no history, so only their own future records count).
	end
	return completed
end

-- Claims a completed objective's reward once: (true, nil, reward) or (false, reason) with
-- unknown, locked, not_completed or already_claimed.
function Tracker.claim(self: Tracker, id: string): (boolean, string?, any)
	local def = self._spec.byId[id]
	if def == nil then
		return false, "unknown", nil
	end
	local entry = self._entries[id]
	if entry.state == "claimed" then
		return false, "already_claimed", nil
	elseif entry.state == "locked" then
		return false, "locked", nil
	elseif entry.state ~= "completed" then
		return false, "not_completed", nil
	end
	entry.state = "claimed"
	emit(self, Events.custom("objective_claimed", nil, { objective = id }))
	relock(self)
	return true, nil, if def.reward ~= nil then Check.copy(def.reward) else nil
end

-- Restarts daily/weekly objectives whose UTC cycle changed. Returns the ids restarted.
function Tracker.refresh(self: Tracker, utc: number): { string }
	local day = Streaks.dayIndex(utc, self._offset)
	local week = Streaks.weekIndex(utc, self._offset)
	local restarted = {}
	for _, def in self._spec.defs do
		if def.reset == "never" then
			continue
		end
		local entry = self._entries[def.id]
		local cycle = if def.reset == "daily" then day else week
		if entry.cycle == nil then
			entry.cycle = cycle
		elseif entry.cycle ~= cycle then
			entry.cycle = cycle
			entry.progress = 0
			entry.state = "locked"
			table.insert(restarted, def.id)
		end
	end
	relock(self)
	return restarted
end

function Tracker.state(self: Tracker, id: string): string?
	local entry = self._entries[id]
	return entry and entry.state
end

-- (progress, target) for an objective, or nil.
function Tracker.progress(self: Tracker, id: string): (number?, number?)
	local entry = self._entries[id]
	if entry == nil then
		return nil, nil
	end
	return entry.progress, self._spec.byId[id].target
end

-- Every objective in definition order: { id, state, progress, target, completions }.
function Tracker.list(self: Tracker): { any }
	local out = {}
	for _, def in self._spec.defs do
		local entry = self._entries[def.id]
		table.insert(out, {
			id = def.id,
			state = entry.state,
			progress = entry.progress,
			target = def.target,
			completions = entry.completions,
		})
	end
	return out
end

function Tracker.serialize(self: Tracker): any
	local entries = {}
	for id, entry in self._entries do
		entries[id] = {
			progress = entry.progress,
			state = entry.state,
			cycle = entry.cycle,
			completions = entry.completions,
		}
	end
	return { schema = Objectives.SCHEMA, entries = entries }
end

return Objectives
