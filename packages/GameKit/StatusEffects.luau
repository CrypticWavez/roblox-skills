--!strict
-- @tier T0
-- StatusEffects: timed effects on one entity (stun, slow, burn, shield-up; names are the game's)
-- defined as data. Each effect has a duration (0 = until removed), a stacking rule, a stack cap,
-- an optional tick interval, tags (what it is: "stun", "slow", "silence") and stat modifiers
-- (multiplicative per stack, read with multiplier("speed")). Immunity blocks re-application by id
-- or by tag ("tag:stun"), and immunityAfter grants it automatically when an effect ends (a
-- simple diminishing-returns rule against stun-locks). step(dt) emits tick and expired events in
-- id order, at most MAX_TICKS_PER_STEP per effect per step, and never yields. Refreshing an
-- effect keeps its tick schedule, so re-applying fast cannot starve or double its ticks.
-- serialize() packs active effects and immunities into one attribute string (se/1).
--   local book = StatusEffects.define({ { id = "slow_a", duration = 3, tags = { "slow" }, modifiers = { speed = 0.6 } } })
--   local fx = StatusEffects.new(book, nil, env); fx:apply("slow_a", { source = "2" })
--   humanoidSpeed = base * fx:multiplier("speed")
local Check = require("./Check")
local Signal = require("./Signal")

local StatusEffects = {}
StatusEffects.__index = StatusEffects
StatusEffects.FORMAT = "se/1"
StatusEffects.MAX_STACKS = 99
StatusEffects.DEFAULT_LIMIT = 32
StatusEffects.MAX_TICKS_PER_STEP = 64
StatusEffects.STACKING =
	table.freeze({ refresh = true, extend = true, stack = true, replace = true, ignore = true })

export type EffectDef = {
	id: string,
	duration: number,
	stacking: string?,
	maxStacks: number?,
	maxDuration: number?,
	tickInterval: number?,
	tags: { string }?,
	modifiers: { [string]: number }?,
	immunityAfter: number?,
	dispellable: boolean?,
}
export type Book = { effects: { [string]: EffectDef }, ids: { string } }
export type ApplyOptions = { source: any?, stacks: number?, duration: number?, magnitude: number? }
export type Event = {
	kind: string,
	id: string,
	stacks: number,
	magnitude: number,
	source: any,
	t: number,
}

type Active = {
	id: string,
	def: EffectDef,
	timers: { number },
	nextTick: number?,
	source: any,
	magnitude: number,
}
type Fields = {
	book: Book,
	applied: Signal.Signal,
	removed: Signal.Signal,
	ticked: Signal.Signal,
	expired: Signal.Signal,
	_env: any,
	_active: { [string]: Active },
	_count: number,
	_limit: number,
	_immunity: { [string]: number },
}
export type StatusEffects = typeof(setmetatable({} :: Fields, StatusEffects))

local function effectProblems(def: any, where: string, problems: { string })
	if type(def) ~= "table" then
		table.insert(problems, where .. " must be a table")
		return
	end
	if not Check.label(def.id) then
		table.insert(problems, where .. ": id must be a label")
	end
	if not Check.finite(def.duration) or def.duration < 0 then
		table.insert(problems, where .. ": duration must be a finite number >= 0 (0 = until removed)")
	end
	if def.stacking ~= nil and not StatusEffects.STACKING[def.stacking] then
		table.insert(problems, where .. ": stacking must be refresh, extend, stack, replace or ignore")
	end
	if
		def.maxStacks ~= nil
		and (
			not Check.integer(def.maxStacks)
			or def.maxStacks < 1
			or def.maxStacks > StatusEffects.MAX_STACKS
		)
	then
		table.insert(
			problems,
			string.format("%s: maxStacks must be an integer 1-%d", where, StatusEffects.MAX_STACKS)
		)
	end
	if def.maxDuration ~= nil and (not Check.finite(def.maxDuration) or def.maxDuration <= 0) then
		table.insert(problems, where .. ": maxDuration must be a finite number > 0")
	end
	if def.tickInterval ~= nil and (not Check.finite(def.tickInterval) or def.tickInterval <= 0) then
		table.insert(problems, where .. ": tickInterval must be a finite number > 0")
	end
	if def.immunityAfter ~= nil and (not Check.finite(def.immunityAfter) or def.immunityAfter < 0) then
		table.insert(problems, where .. ": immunityAfter must be a finite number >= 0")
	end
	if def.dispellable ~= nil and type(def.dispellable) ~= "boolean" then
		table.insert(problems, where .. ": dispellable must be a boolean")
	end
	if def.tags ~= nil then
		if type(def.tags) ~= "table" then
			table.insert(problems, where .. ": tags must be a list of labels")
		else
			for _, tag in def.tags do
				if not Check.label(tag) then
					table.insert(problems, where .. ": tag " .. Check.describe(tag) .. " is not a label")
				end
			end
		end
	end
	if def.modifiers ~= nil then
		if type(def.modifiers) ~= "table" then
			table.insert(problems, where .. ": modifiers must map stat labels to factors")
		else
			for stat, factor in def.modifiers do
				if not Check.label(stat) or not Check.finite(factor) or factor < 0 then
					table.insert(
						problems,
						string.format(
							"%s: modifier %s must be a label -> finite factor >= 0",
							where,
							Check.describe(stat)
						)
					)
				end
			end
		end
	end
end

-- Problems with a list of effect definitions (empty when valid).
function StatusEffects.validate(defs: any): { string }
	if type(defs) ~= "table" then
		return { "effects must be a list" }
	end
	local problems: { string } = {}
	local seen: { [string]: boolean } = {}
	for index, def in defs do
		local where = "effect " .. tostring(index)
		effectProblems(def, where, problems)
		if type(def) == "table" and Check.label(def.id) then
			if seen[def.id] then
				table.insert(problems, where .. ": duplicate id " .. def.id)
			end
			seen[def.id] = true
		end
	end
	return problems
end

function StatusEffects.define(defs: { EffectDef }): Book
	local problems = StatusEffects.validate(defs)
	if #problems > 0 then
		error("StatusEffects.define: " .. table.concat(problems, "; "), 2)
	end
	local effects: { [string]: EffectDef } = {}
	local ids: { string } = {}
	for _, def in defs do
		local copy = Check.copy(def)
		copy.stacking = copy.stacking or "refresh"
		copy.maxStacks = copy.maxStacks or 1
		copy.tags = copy.tags or {}
		copy.modifiers = copy.modifiers or {}
		copy.dispellable = copy.dispellable ~= false
		effects[def.id] = Check.freeze(copy)
		table.insert(ids, def.id)
	end
	table.sort(ids)
	return table.freeze({ effects = table.freeze(effects), ids = table.freeze(ids) })
end

function StatusEffects.new(book: Book, options: { limit: number? }?, env: any): StatusEffects
	assert(
		type(book) == "table" and table.isfrozen(book),
		"StatusEffects.new needs a book from StatusEffects.define"
	)
	assert(
		type(env) == "table" and type(env.clock) == "function",
		"StatusEffects.new needs an env with clock()"
	)
	local limit = (options and options.limit) or StatusEffects.DEFAULT_LIMIT
	assert(Check.integer(limit) and limit >= 1, "StatusEffects.new: limit must be an integer >= 1")
	return setmetatable({
		book = book,
		applied = Signal.new(env),
		removed = Signal.new(env),
		ticked = Signal.new(env),
		expired = Signal.new(env),
		_env = env,
		_active = {},
		_count = 0,
		_limit = limit,
		_immunity = {},
	}, StatusEffects)
end

local function immuneTo(self: StatusEffects, def: EffectDef, now: number): boolean
	if (self._immunity[def.id] or -math.huge) > now then
		return true
	end
	for _, tag in def.tags :: { string } do
		if (self._immunity["tag:" .. tag] or -math.huge) > now then
			return true
		end
	end
	return false
end

local function expiryFor(_def: EffectDef, duration: number, now: number): number
	if duration == 0 then
		return math.huge
	end
	return now + duration
end

-- Applies an effect. (ok, reason?) with unknown_effect, bad_input, immune, ignored, full.
-- options.duration overrides the definition (capped at maxDuration when set); stacks defaults 1.
function StatusEffects.apply(self: StatusEffects, id: string, options: ApplyOptions?): (boolean, string?)
	local def = self.book.effects[id]
	if def == nil then
		return false, "unknown_effect"
	end
	local stacks = (options and options.stacks) or 1
	local duration = (options and options.duration) or def.duration
	local magnitude = (options and options.magnitude) or 1
	if
		not Check.integer(stacks)
		or stacks < 1
		or not Check.finite(duration)
		or duration < 0
		or not Check.finite(magnitude)
	then
		return false, "bad_input"
	end
	if def.maxDuration then
		duration = math.min(duration, def.maxDuration)
	end
	local now = self._env.clock()
	if immuneTo(self, def, now) then
		return false, "immune"
	end
	local maxStacks = def.maxStacks :: number
	local active = self._active[id]
	if active ~= nil and def.stacking == "ignore" then
		return false, "ignored"
	end
	if active == nil then
		if self._count >= self._limit then
			return false, "full"
		end
		local expiry = expiryFor(def, duration, now)
		local timers = table.create(math.min(stacks, maxStacks), expiry)
		active = {
			id = id,
			def = def,
			timers = timers,
			nextTick = if def.tickInterval then now + def.tickInterval else nil,
			source = options and options.source,
			magnitude = magnitude,
		}
		self._active[id] = active
		self._count += 1
	else
		local a = active :: Active
		local mode = def.stacking
		a.source = if options and options.source ~= nil then options.source else a.source
		a.magnitude = math.max(a.magnitude, magnitude)
		if mode == "replace" then
			a.timers = table.create(math.min(stacks, maxStacks), expiryFor(def, duration, now))
			a.magnitude = magnitude
			a.nextTick = if def.tickInterval then now + def.tickInterval else nil
		elseif mode == "stack" then
			for _ = 1, stacks do
				table.insert(a.timers, expiryFor(def, duration, now))
			end
			table.sort(a.timers)
			while #a.timers > maxStacks do
				table.remove(a.timers, 1) -- the stack closest to expiring goes first
			end
		else
			local expiry
			if mode == "extend" then
				local latest = a.timers[#a.timers]
				expiry = if duration == 0 or latest == math.huge
					then math.huge
					else math.max(latest, now) + duration
				if def.maxDuration and expiry ~= math.huge then
					expiry = math.min(expiry, now + def.maxDuration)
				end
			else -- refresh
				expiry = expiryFor(def, duration, now)
			end
			local count = math.min(#a.timers + stacks, maxStacks)
			a.timers = table.create(count, expiry)
		end
	end
	self.applied:Fire(id, #(active :: Active).timers)
	return true, nil
end

local function drop(self: StatusEffects, id: string, reason: string)
	local active = self._active[id]
	if active == nil then
		return
	end
	self._active[id] = nil
	self._count -= 1
	local after = active.def.immunityAfter
	if after and after > 0 and reason == "expired" then
		local now = self._env.clock()
		self._immunity[id] = math.max(self._immunity[id] or -math.huge, now + after)
	end
	self.removed:Fire(id, reason)
end

-- Removes an effect now; returns whether it was active.
function StatusEffects.remove(self: StatusEffects, id: string): boolean
	if self._active[id] == nil then
		return false
	end
	drop(self, id, "removed")
	return true
end

-- Removes every effect carrying tag; returns how many.
function StatusEffects.removeTag(self: StatusEffects, tag: string): number
	local ids = {}
	for id, active in self._active do
		if table.find(active.def.tags :: { string }, tag) then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ids do
		drop(self, id, "removed")
	end
	return #ids
end

-- Removes every dispellable effect (optionally only those with tag); returns how many.
function StatusEffects.dispel(self: StatusEffects, tag: string?): number
	local ids = {}
	for id, active in self._active do
		if active.def.dispellable and (tag == nil or table.find(active.def.tags :: { string }, tag)) then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ids do
		drop(self, id, "dispelled")
	end
	return #ids
end

function StatusEffects.clear(self: StatusEffects)
	local ids = {}
	for id in self._active do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		drop(self, id, "cleared")
	end
	self._immunity = {}
end

-- Blocks applying an id (or "tag:<tag>") for seconds from now.
function StatusEffects.grantImmunity(self: StatusEffects, key: string, seconds: number)
	assert(type(key) == "string" and #key > 0, "StatusEffects.grantImmunity: key must be a string")
	Check.assertFinite(seconds, "StatusEffects.grantImmunity seconds")
	local now = self._env.clock()
	self._immunity[key] = math.max(self._immunity[key] or -math.huge, now + math.max(0, seconds))
end

function StatusEffects.isImmune(self: StatusEffects, id: string): boolean
	local def = self.book.effects[id]
	if def == nil then
		return false
	end
	return immuneTo(self, def, self._env.clock())
end

-- Advances ticks and expiries. Returns the events of this step (also fired on the signals).
function StatusEffects.step(self: StatusEffects, _dt: number?): { Event }
	local now = self._env.clock()
	local events: { Event } = {}
	local ids = {}
	for id in self._active do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local active = self._active[id]
		local def = active.def
		local lastExpiry = active.timers[#active.timers]
		local interval = def.tickInterval
		if interval and active.nextTick then
			local ticks = 0
			while (active.nextTick :: number) <= now and (active.nextTick :: number) <= lastExpiry do
				ticks += 1
				if ticks > StatusEffects.MAX_TICKS_PER_STEP then
					-- A huge step (server hitch) skips the backlog instead of looping without bound.
					active.nextTick = now + interval
					break
				end
				local at = active.nextTick :: number
				-- Stacks alive at the tick time.
				local stacks = 0
				for _, expiry in active.timers do
					if expiry >= at then
						stacks += 1
					end
				end
				local event: Event = {
					kind = "tick",
					id = id,
					stacks = stacks,
					magnitude = active.magnitude,
					source = active.source,
					t = at,
				}
				table.insert(events, event)
				self.ticked:Fire(event)
				active.nextTick = at + interval
			end
		end
		local kept = {}
		for _, expiry in active.timers do
			if expiry > now then
				table.insert(kept, expiry)
			end
		end
		active.timers = kept
		if #kept == 0 then
			local event: Event = {
				kind = "expired",
				id = id,
				stacks = 0,
				magnitude = active.magnitude,
				source = active.source,
				t = now,
			}
			table.insert(events, event)
			drop(self, id, "expired")
			self.expired:Fire(id)
		end
	end
	for key, untilTime in self._immunity do
		if untilTime <= now then
			self._immunity[key] = nil
		end
	end
	return events
end

-- ---------------------------------------------------------------- reads

function StatusEffects.has(self: StatusEffects, id: string): boolean
	return self._active[id] ~= nil
end

function StatusEffects.hasTag(self: StatusEffects, tag: string): boolean
	for _, active in self._active do
		if table.find(active.def.tags :: { string }, tag) then
			return true
		end
	end
	return false
end

function StatusEffects.stacks(self: StatusEffects, id: string): number
	local active = self._active[id]
	return if active then #active.timers else 0
end

-- Seconds until the effect fully ends (math.huge for an effect that lasts until removed).
function StatusEffects.remaining(self: StatusEffects, id: string): number
	local active = self._active[id]
	if active == nil then
		return 0
	end
	return math.max(0, active.timers[#active.timers] - self._env.clock())
end

-- Product of factor^stacks over active effects that modify stat (1 when none does).
function StatusEffects.multiplier(self: StatusEffects, stat: string): number
	local ids = {}
	for id, active in self._active do
		if (active.def.modifiers :: { [string]: number })[stat] ~= nil then
			table.insert(ids, id)
		end
	end
	table.sort(ids) -- a fixed order keeps the floating-point product identical everywhere
	local product = 1
	for _, id in ids do
		local active = self._active[id]
		product *= (active.def.modifiers :: { [string]: number })[stat] ^ #active.timers
	end
	return product
end

-- Active effects sorted by id: { id, stacks, remaining, tags }.
function StatusEffects.list(
	self: StatusEffects
): { { id: string, stacks: number, remaining: number, tags: { string } } }
	local out = {}
	for _, id in self.book.ids do
		if self._active[id] then
			table.insert(out, {
				id = id,
				stacks = self:stacks(id),
				remaining = self:remaining(id),
				tags = self._active[id].def.tags :: { string },
			})
		end
	end
	return out
end

-- ---------------------------------------------------------------- serialise

local function formatRemaining(value: number): string
	if value == math.huge then
		return "p"
	end
	return string.format("%.3f", math.max(0, value))
end

-- One attribute string: "se/1;<id>=<r>,<r>;!<key>=<r>" (r = remaining seconds, p = permanent).
function StatusEffects.serialize(self: StatusEffects): string
	local now = self._env.clock()
	local parts = { StatusEffects.FORMAT }
	for _, id in self.book.ids do
		local active = self._active[id]
		if active then
			local values = {}
			for _, expiry in active.timers do
				table.insert(values, formatRemaining(expiry - now))
			end
			table.insert(parts, id .. "=" .. table.concat(values, ","))
		end
	end
	local keys = {}
	for key, untilTime in self._immunity do
		if untilTime > now then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	for _, key in keys do
		table.insert(parts, "!" .. key .. "=" .. formatRemaining(self._immunity[key] - now))
	end
	return table.concat(parts, ";")
end

-- A container rebuilt from serialize() output, or nil and bad_format / unknown_effect.
-- Ticks restart one interval after the restore; sources and magnitudes are not carried.
function StatusEffects.restore(
	book: Book,
	text: any,
	options: { limit: number? }?,
	env: any
): (StatusEffects?, string?)
	if type(text) ~= "string" or #text > 4096 then
		return nil, "bad_format"
	end
	local parts = string.split(text, ";")
	if parts[1] ~= StatusEffects.FORMAT then
		return nil, "bad_format"
	end
	local container = StatusEffects.new(book, options, env)
	local now = env.clock()
	local function parseRemaining(value: string): number?
		if value == "p" then
			return math.huge
		end
		local number = tonumber(value)
		if number == nil or not Check.finite(number) or number < 0 then
			return nil
		end
		return now + number
	end
	for index = 2, #parts do
		local part = parts[index]
		local immune, key, values = string.match(part, "^(!?)([%w_:]+)=([%w%.,]+)$")
		if key == nil then
			return nil, "bad_format"
		end
		if immune == "!" then
			local untilTime = parseRemaining(values :: string)
			if untilTime == nil or untilTime == math.huge then
				return nil, "bad_format"
			end
			container._immunity[key :: string] = untilTime
			continue
		end
		local def = book.effects[key :: string]
		if def == nil then
			return nil, "unknown_effect"
		end
		local timers = {}
		for _, value in string.split(values :: string, ",") do
			local expiry = parseRemaining(value)
			if expiry == nil then
				return nil, "bad_format"
			end
			table.insert(timers, expiry)
		end
		if #timers == 0 or #timers > (def.maxStacks :: number) or container._count >= container._limit then
			return nil, "bad_format"
		end
		table.sort(timers)
		container._active[key :: string] = {
			id = key :: string,
			def = def,
			timers = timers,
			nextTick = if def.tickInterval then now + def.tickInterval else nil,
			source = nil,
			magnitude = 1,
		}
		container._count += 1
	end
	return container, nil
end

function StatusEffects.destroy(self: StatusEffects)
	for _, signal in { self.applied, self.removed, self.ticked, self.expired } do
		signal:Destroy()
	end
end

return StatusEffects
