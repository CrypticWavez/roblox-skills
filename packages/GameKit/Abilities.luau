--!strict
-- @tier T0
-- Abilities: data-defined abilities and a server-side caster. A definition is
--   { id, cost? = { [pool] = amount }, cooldown, charges?, castTime?, channel?, tickInterval?,
--     effects = { { kind, phase? = "release" | "tick" | "end", ...data } }, target? = "none" |
--     "self" | "unit" | "point", range?, blockedBy? = { status tags }, interruptible?,
--     refundOnInterrupt? (0-1), gcd? }.
-- No content ships: ids, numbers and effect kinds are the game's.
--   * cast(id, target) runs the pipeline: known ability, caster alive, not busy, not blocked by a
--     status tag (StatusEffects:hasTag), global and own cooldown ready (Cooldowns, server clock),
--     target shape and range (origin/locate hooks) and the optional checkTarget hook, then cost
--     (Vitals:canSpend for every pool, then spend). Cost and cooldown are committed when the cast
--     starts, so cast-cancel spam burns cooldowns instead of dodging them. A refusal returns a
--     reason and changes nothing.
--   * step() (never yields; call it from BindToSimulation) finishes wind-ups, emits channel
--     ticks on exact times and interrupts casts when the caster dies or gets a blocking status.
--   * Effects are reported, not applied: events { kind = "effect", ability, effect, phase,
--     target, t } go to the caller (and the `effect` Signal), which applies damage, statuses or
--     knockback with the other cores.
--   * The caster's state is an Fsm (idle, casting, channeling); serialize() is its fsm/1 string.
local Check = require("./Check")
local Fsm = require("./Fsm")
local Signal = require("./Signal")

local Abilities = {}
Abilities.MAX_ABILITIES = 256
Abilities.MAX_EFFECTS = 32
Abilities.MAX_COOLDOWN = 3600
Abilities.MAX_CAST = 60
Abilities.MAX_TICKS_PER_STEP = 16
Abilities.RANGE_TOLERANCE = 1 -- studs of slack on range checks (convention)
Abilities.TARGETS = table.freeze({ none = true, self = true, unit = true, point = true })
Abilities.PHASES = table.freeze({ release = true, tick = true, ["end"] = true })

export type V3 = { x: number, y: number, z: number }
export type Effect = { kind: string, phase: string?, [string]: any }
export type Definition = {
	id: string,
	cost: { [string]: number }?,
	cooldown: number,
	charges: number?,
	castTime: number?,
	channel: number?,
	tickInterval: number?,
	effects: { Effect },
	target: string?,
	range: number?,
	blockedBy: { string }?,
	interruptible: boolean?,
	refundOnInterrupt: number?,
	gcd: boolean?,
}
export type Book = { abilities: { [string]: Definition }, ids: { string } }
export type Event = {
	kind: string, -- "cast_start" | "release" | "effect" | "channel_tick" | "channel_end" | "interrupted"
	ability: string,
	t: number,
	target: any?,
	effect: Effect?,
	phase: string?,
	reason: string?,
	tick: number?,
	refund: { [string]: number }?,
}

local function isVec(value: any): boolean
	return type(value) == "table"
		and Check.finite(value.x)
		and Check.finite(value.y)
		and Check.finite(value.z)
end

local function inRange(value: any, lo: number, hi: number): boolean
	return Check.finite(value) and value >= lo and value <= hi
end

local function validateOne(def: any, where: string, problems: { string })
	if type(def) ~= "table" then
		table.insert(problems, where .. " must be a table")
		return
	end
	if not Check.label(def.id) then
		table.insert(problems, where .. ".id must be a label")
	end
	if not inRange(def.cooldown, 0, Abilities.MAX_COOLDOWN) then
		table.insert(
			problems,
			string.format("%s.cooldown must be 0-%d seconds", where, Abilities.MAX_COOLDOWN)
		)
	end
	if def.charges ~= nil and (not Check.integer(def.charges) or def.charges < 1 or def.charges > 99) then
		table.insert(problems, where .. ".charges must be an integer 1-99")
	end
	if def.charges ~= nil and def.cooldown == 0 then
		table.insert(problems, where .. ".charges need a cooldown > 0")
	end
	for _, field in { "castTime", "channel" } do
		if def[field] ~= nil and not inRange(def[field], 0, Abilities.MAX_CAST) then
			table.insert(
				problems,
				string.format("%s.%s must be 0-%d seconds", where, field, Abilities.MAX_CAST)
			)
		end
	end
	if Check.finite(def.channel) and def.channel > 0 then
		if not Check.finite(def.tickInterval) or def.tickInterval <= 0 then
			table.insert(problems, where .. ".tickInterval must be > 0 for a channel")
		end
	elseif def.tickInterval ~= nil then
		table.insert(problems, where .. ".tickInterval only applies to a channel")
	end
	if def.cost ~= nil then
		if type(def.cost) ~= "table" then
			table.insert(problems, where .. ".cost must map pool labels to amounts")
		else
			for pool, amount in def.cost do
				if not Check.label(pool) or not Check.finite(amount) or amount <= 0 then
					table.insert(problems, where .. ".cost must map pool labels to finite amounts > 0")
					break
				end
			end
		end
	end
	if type(def.effects) ~= "table" or #def.effects > Abilities.MAX_EFFECTS then
		table.insert(
			problems,
			string.format("%s.effects must be a list of at most %d effects", where, Abilities.MAX_EFFECTS)
		)
	else
		for index, effect in def.effects do
			if type(effect) ~= "table" or not Check.label(effect.kind) then
				table.insert(problems, string.format("%s.effects[%d].kind must be a label", where, index))
			elseif effect.phase ~= nil and not Abilities.PHASES[effect.phase] then
				table.insert(
					problems,
					string.format("%s.effects[%d].phase must be release, tick or end", where, index)
				)
			elseif
				(effect.phase == "tick" or effect.phase == "end")
				and not (Check.finite(def.channel) and def.channel > 0)
			then
				table.insert(
					problems,
					string.format(
						"%s.effects[%d] uses phase %s without a channel",
						where,
						index,
						effect.phase
					)
				)
			end
		end
	end
	if def.target ~= nil and not Abilities.TARGETS[def.target] then
		table.insert(problems, where .. ".target must be none, self, unit or point")
	end
	if def.range ~= nil and (not Check.finite(def.range) or def.range <= 0) then
		table.insert(problems, where .. ".range must be a finite number > 0")
	end
	if def.blockedBy ~= nil then
		local ok = type(def.blockedBy) == "table"
		if ok then
			for _, tag in def.blockedBy do
				ok = ok and Check.label(tag)
			end
		end
		if not ok then
			table.insert(problems, where .. ".blockedBy must be a list of status tags")
		end
	end
	if def.interruptible ~= nil and type(def.interruptible) ~= "boolean" then
		table.insert(problems, where .. ".interruptible must be a boolean")
	end
	if def.refundOnInterrupt ~= nil and not inRange(def.refundOnInterrupt, 0, 1) then
		table.insert(problems, where .. ".refundOnInterrupt must be 0-1")
	end
	if def.gcd ~= nil and type(def.gcd) ~= "boolean" then
		table.insert(problems, where .. ".gcd must be a boolean")
	end
end

-- Problems with a list of ability definitions (empty when valid).
function Abilities.validate(defs: any): { string }
	if type(defs) ~= "table" then
		return { "abilities must be a list" }
	end
	local problems = {}
	if #defs > Abilities.MAX_ABILITIES then
		table.insert(problems, string.format("at most %d abilities", Abilities.MAX_ABILITIES))
	end
	local seen = {}
	for index, def in defs do
		local where = string.format("abilities[%d]", index)
		validateOne(def, where, problems)
		if type(def) == "table" and type(def.id) == "string" then
			if seen[def.id] then
				table.insert(problems, string.format("%s.id %q is duplicated", where, def.id))
			end
			seen[def.id] = true
		end
	end
	return problems
end

-- A frozen ability book; raises with every problem.
function Abilities.define(defs: { Definition }): Book
	local problems = Abilities.validate(defs)
	if #problems > 0 then
		error("Abilities.define: " .. table.concat(problems, "; "), 2)
	end
	local abilities = {}
	local ids = {}
	for _, def in defs do
		abilities[def.id] = Check.freeze(Check.copy(def))
		table.insert(ids, def.id)
	end
	table.sort(ids)
	return table.freeze({ abilities = table.freeze(abilities), ids = table.freeze(ids) })
end

local STATE_SPEC = Fsm.define({
	name = "ability",
	initial = "idle",
	states = { idle = {}, casting = {}, channeling = {} },
	transitions = {
		{ from = "idle", event = "cast", to = "casting" },
		{ from = "idle", event = "channel", to = "channeling" },
		{ from = "casting", event = "channel", to = "channeling" },
		{ from = "casting", event = "release", to = "idle" },
		{ from = "channeling", event = "finish", to = "idle" },
		{ from = "*", event = "interrupt", to = "idle" },
		{ from = "*", event = "reset", to = "idle" },
	},
})

-- ---------------------------------------------------------------- caster

local Caster = {}
Caster.__index = Caster

export type Options = {
	vitals: any?, -- Vitals instance (alive, canSpend, spend, restore)
	cooldowns: any, -- Cooldowns instance (server clock)
	statuses: any?, -- StatusEffects instance (hasTag)
	gcd: number?, -- global cooldown seconds for abilities with gcd ~= false
	origin: (() -> V3?)?, -- the caster's position, for range checks
	locate: ((target: any) -> V3?)?, -- a unit target's position, for range checks
	checkTarget: ((def: Definition, target: any) -> (boolean, string?))?, -- line of sight, teams
}
type Fields = {
	book: Book,
	effect: Signal.Signal,
	_env: any,
	_options: Options,
	_machine: any,
	_current: Definition?,
	_target: any,
	_releaseAt: number,
	_channelEnd: number,
	_nextTick: number,
	_ticks: number,
	_spent: { [string]: number },
}
export type Caster = typeof(setmetatable({} :: Fields, Caster))

function Abilities.caster(book: Book, options: Options, env: any): Caster
	assert(
		type(book) == "table" and table.isfrozen(book),
		"Abilities.caster needs a book from Abilities.define"
	)
	assert(type(options) == "table" and options.cooldowns ~= nil, "Abilities.caster needs options.cooldowns")
	assert(type(env) == "table" and type(env.clock) == "function", "Abilities.caster needs env.clock")
	if options.gcd ~= nil then
		assert(
			inRange(options.gcd, 0, Abilities.MAX_COOLDOWN),
			"Abilities.caster: gcd must be 0-3600 seconds"
		)
	end
	return setmetatable({
		book = book,
		effect = Signal.new(env),
		_env = env,
		_options = options,
		_machine = Fsm.new(STATE_SPEC, nil, env),
		_current = nil,
		_target = nil,
		_releaseAt = 0,
		_channelEnd = 0,
		_nextTick = 0,
		_ticks = 0,
		_spent = {},
	}, Caster)
end

function Caster.state(self: Caster): string
	return self._machine:state()
end

function Caster.current(self: Caster): string?
	return self._current and self._current.id
end

function Caster.serialize(self: Caster): string
	return self._machine:serialize()
end

local function key(id: string): string
	return "ability:" .. id
end

local function blocked(self: Caster, def: Definition): string?
	local statuses = self._options.statuses
	if statuses and def.blockedBy then
		for _, tag in def.blockedBy do
			if statuses:hasTag(tag) then
				return tag
			end
		end
	end
	return nil
end

local function costPools(def: Definition): { string }
	local pools = {}
	local cost: { [string]: number } = def.cost or {}
	for pool in cost do
		table.insert(pools, pool)
	end
	table.sort(pools)
	return pools
end

local function emitEffects(
	self: Caster,
	events: { Event },
	def: Definition,
	phase: string,
	t: number,
	tick: number?
)
	for _, effect in def.effects do
		if (effect.phase or "release") == phase then
			local event: Event = {
				kind = "effect",
				ability = def.id,
				t = t,
				target = self._target,
				effect = effect,
				phase = phase,
				tick = tick,
			}
			table.insert(events, event)
			self.effect:Fire(event)
		end
	end
end

local function release(self: Caster, at: number, events: { Event })
	local def = self._current :: Definition
	table.insert(events, { kind = "release", ability = def.id, t = at, target = self._target })
	emitEffects(self, events, def, "release", at)
	local channel = def.channel or 0
	if channel > 0 then
		self._channelEnd = at + channel
		self._nextTick = at + (def.tickInterval :: number)
		self._machine:send("channel")
	else
		if self:state() == "casting" then
			self._machine:send("release")
		end
		self._current = nil
		self._target = nil
	end
end

-- Checks everything cast() checks without committing. (ok, reason?, detail?).
function Caster.check(self: Caster, id: any, target: any?): (boolean, string?, any?)
	local def = if type(id) == "string" then self.book.abilities[id] else nil
	if def == nil then
		return false, "unknown_ability", nil
	end
	local vitals = self._options.vitals
	if vitals and not vitals:alive() then
		return false, "dead", nil
	end
	if self:state() ~= "idle" then
		return false, "busy", self._current and self._current.id
	end
	local tag = blocked(self, def)
	if tag then
		return false, "blocked", tag
	end
	local cooldowns = self._options.cooldowns
	if
		def.gcd ~= false
		and self._options.gcd
		and self._options.gcd > 0
		and not cooldowns:ready("ability:_gcd")
	then
		return false, "global_cooldown", cooldowns:remaining("ability:_gcd")
	end
	if def.cooldown > 0 and not cooldowns:ready(key(def.id)) then
		return false, "cooldown", cooldowns:remaining(key(def.id))
	end
	local kind = def.target or "none"
	if kind == "unit" then
		if target == nil or (type(target) ~= "string" and type(target) ~= "number") then
			return false, "bad_target", nil
		end
	elseif kind == "point" then
		if not isVec(target) then
			return false, "bad_target", nil
		end
	end
	if def.range and (kind == "unit" or kind == "point") and self._options.origin then
		local origin = self._options.origin()
		local where = if kind == "point"
			then target
			else (self._options.locate and self._options.locate(target))
		if origin == nil or where == nil or not isVec(where) then
			return false, "bad_target", nil
		end
		local dx, dy, dz = where.x - origin.x, where.y - origin.y, where.z - origin.z
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		if distance > def.range + Abilities.RANGE_TOLERANCE then
			return false, "out_of_range", distance
		end
	end
	if self._options.checkTarget then
		local ok, reason = self._options.checkTarget(def, target)
		if not ok then
			return false, reason or "bad_target", nil
		end
	end
	if vitals then
		for _, pool in costPools(def) do
			if not vitals:canSpend(pool, (def.cost :: any)[pool]) then
				return false, "cost", pool
			end
		end
	elseif def.cost and next(def.cost) ~= nil then
		return false, "cost", "no_vitals"
	end
	return true, nil, nil
end

-- Starts an ability. (true, nil, events) or (false, reason, detail) with unknown_ability, dead,
-- busy, blocked, global_cooldown, cooldown, bad_target, out_of_range, cost or the
-- checkTarget hook's reason.
function Caster.cast(self: Caster, id: any, target: any?): (boolean, string?, any)
	local ok, reason, detail = self:check(id, target)
	if not ok then
		return false, reason, detail
	end
	local def = self.book.abilities[id]
	local now = self._env.clock()
	local events: { Event } = {}
	-- Commit: cost, then cooldowns.
	table.clear(self._spent)
	local vitals = self._options.vitals
	if vitals then
		for _, pool in costPools(def) do
			local amount = (def.cost :: any)[pool]
			local spent, why = vitals:spend(pool, amount)
			if not spent then
				-- canSpend said yes a moment ago; refund what was taken and refuse.
				for paid, value in self._spent do
					vitals:restore(paid, value)
				end
				table.clear(self._spent)
				return false, "cost", why
			end
			self._spent[pool] = amount
		end
	end
	local cooldowns = self._options.cooldowns
	if def.cooldown > 0 then
		cooldowns:use(key(def.id), def.cooldown, def.charges)
	end
	if def.gcd ~= false and self._options.gcd and self._options.gcd > 0 then
		cooldowns:use("ability:_gcd", self._options.gcd)
	end
	self._current = def
	self._target = target
	self._ticks = 0
	local castTime = def.castTime or 0
	table.insert(events, { kind = "cast_start", ability = def.id, t = now, target = target })
	if castTime > 0 then
		self._releaseAt = now + castTime
		self._machine:send("cast")
	else
		release(self, now, events)
	end
	return true, nil, events
end

local function interrupt(self: Caster, reason: string, events: { Event }, at: number): boolean
	local def = self._current
	if def == nil then
		return false
	end
	local refund = nil
	local fraction = def.refundOnInterrupt or 0
	local vitals = self._options.vitals
	if fraction > 0 and vitals and self:state() == "casting" then
		refund = {}
		for pool, amount in self._spent do
			refund[pool] = vitals:restore(pool, amount * fraction)
		end
	end
	table.insert(events, { kind = "interrupted", ability = def.id, t = at, reason = reason, refund = refund })
	self._machine:send("interrupt")
	self._current = nil
	self._target = nil
	return true
end

-- Interrupts the current cast or channel (stun, movement, a parry). Abilities with
-- interruptible = false ignore it unless force is set (death, reset). Returns the events.
function Caster.interrupt(self: Caster, reason: string?, force: boolean?): { Event }
	local events: { Event } = {}
	local def = self._current
	if def == nil or (def.interruptible == false and not force) then
		return events
	end
	interrupt(self, reason or "interrupted", events, self._env.clock())
	return events
end

-- Advances casts and channels to the env clock. Never yields.
function Caster.step(self: Caster): { Event }
	local events: { Event } = {}
	local def = self._current
	if def == nil then
		return events
	end
	local now = self._env.clock()
	local vitals = self._options.vitals
	if vitals and not vitals:alive() then
		interrupt(self, "dead", events, now)
		return events
	end
	local tag = blocked(self, def)
	if tag and def.interruptible ~= false then
		interrupt(self, "blocked", events, now)
		return events
	end
	if self:state() == "casting" then
		if now + 1e-9 < self._releaseAt then
			return events
		end
		release(self, self._releaseAt, events)
	end
	if self:state() == "channeling" then
		local interval = def.tickInterval :: number
		local emitted = 0
		while self._nextTick <= self._channelEnd + 1e-9 and self._nextTick <= now + 1e-9 do
			if emitted >= Abilities.MAX_TICKS_PER_STEP then
				break
			end
			emitted += 1
			self._ticks += 1
			table.insert(events, {
				kind = "channel_tick",
				ability = def.id,
				t = self._nextTick,
				target = self._target,
				tick = self._ticks,
			})
			emitEffects(self, events, def, "tick", self._nextTick, self._ticks)
			self._nextTick += interval
		end
		if now + 1e-9 >= self._channelEnd and self._nextTick > self._channelEnd + 1e-9 then
			table.insert(
				events,
				{ kind = "channel_end", ability = def.id, t = self._channelEnd, target = self._target }
			)
			emitEffects(self, events, def, "end", self._channelEnd)
			self._machine:send("finish")
			self._current = nil
			self._target = nil
		end
	end
	return events
end

-- Seconds until id can be cast again (cooldown and global cooldown), 0 when ready.
function Caster.remaining(self: Caster, id: string): number
	local def = self.book.abilities[id]
	if def == nil then
		return 0
	end
	local cooldowns = self._options.cooldowns
	local own = if def.cooldown > 0 then cooldowns:remaining(key(id)) else 0
	local global = if def.gcd ~= false and self._options.gcd then cooldowns:remaining("ability:_gcd") else 0
	return math.max(own, global)
end

function Caster.reset(self: Caster)
	self._machine:send("reset")
	self._current = nil
	self._target = nil
end

function Caster.destroy(self: Caster)
	self.effect:Destroy()
	self._machine.changed:Destroy()
end

return Abilities
