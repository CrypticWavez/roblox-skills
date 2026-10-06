--!strict
-- @tier T0
-- Vitals: server-authoritative resource pools (health is required; shield, stamina or any other
-- label pool are optional) with a damage pipeline, death, an optional downed state, revive and
-- regen. Damage runs through modifiers in priority order (crit, resist, armour, cap or the
-- game's own), then is rounded (integer-safe by default) and absorbed by the pools in `absorb`
-- order (shield before health). Every hit returns a record { ok, reason?, amount, applied,
-- absorbed, overkill, lethal, source, t } and goes into a bounded log for kill credit and
-- assists. Untrusted numbers (NaN, inf, negative) are rejected with a reason, never raised;
-- definitions are game data and raise. step(dt) regenerates and runs the bleed-out timer; it
-- never yields, so the adapter can call it from RunService:BindToSimulation.
--   local spec = Vitals.define({ pools = { health = { max = 100 }, shield = { max = 50, regen = 10, regenDelay = 3 } } })
--   local v = Vitals.new(spec, { modifiers = { Vitals.resist("fire", 0.5) } }, env)
--   local record = v:damage({ amount = 30, kind = "fire", source = { attacker = "2" } })
local Check = require("./Check")
local Signal = require("./Signal")

local Vitals = {}
Vitals.__index = Vitals
Vitals.MAX_POOLS = 16
Vitals.MAX_VALUE = 2147483647
Vitals.DEFAULT_LOG = 16
Vitals.POOL_NAME_MAX = 32
Vitals.ROUNDING = table.freeze({ round = true, floor = true, ceil = true, none = true })

export type V3 = { x: number, y: number, z: number }
export type PoolDef = { max: number, start: number?, regen: number?, regenDelay: number? }
export type DownedDef = { bleedout: number, reviveHealth: number?, finishable: boolean? }
export type Source = {
	attacker: (string | number)?,
	ability: string?,
	weapon: string?,
	position: V3?,
}
export type DamageContext = {
	amount: number,
	kind: string,
	crit: boolean,
	source: Source,
	tags: { [string]: boolean },
	cancelled: string?,
	vitals: any,
	rng: () -> number,
	changedBy: { string },
}
export type Modifier = { id: string, priority: number?, apply: (ctx: DamageContext) -> () }
export type Definition = {
	pools: { [string]: PoolDef },
	absorb: { string }?,
	rounding: string?,
	downed: DownedDef?,
	reviveHealth: number?,
	logSize: number?,
	modifiers: { Modifier }?,
}
export type Spec = {
	pools: { [string]: PoolDef },
	names: { string },
	absorb: { string },
	rounding: string,
	downed: DownedDef?,
	reviveHealth: number?,
	logSize: number,
	modifiers: { Modifier },
}
export type DamageInfo = {
	amount: any,
	kind: string?,
	crit: boolean?,
	source: Source?,
	tags: { string }?,
}
export type Record = {
	ok: boolean,
	reason: string?,
	cancelledBy: string?,
	requested: number,
	amount: number,
	applied: number,
	absorbed: { [string]: number },
	overkill: number,
	kind: string,
	crit: boolean,
	lethal: boolean,
	state: string,
	source: Source,
	t: number,
}

type VitalsFields = {
	spec: Spec,
	changed: Signal.Signal,
	damaged: Signal.Signal,
	died: Signal.Signal,
	downed: Signal.Signal,
	revived: Signal.Signal,
	_env: any,
	_values: { [string]: number },
	_max: { [string]: number },
	_carry: { [string]: number },
	_lastDrain: { [string]: number },
	_state: string,
	_downedAt: number,
	_downedBy: Record?,
	_invulnerableUntil: number,
	_modifiers: { Modifier },
	_log: { Record },
	_logHead: number,
	_rng: any,
	_seed: (number | string)?,
	_lastRecord: Record?,
}
export type Vitals = typeof(setmetatable({} :: VitalsFields, Vitals))

local function isVec(value: any): boolean
	return type(value) == "table"
		and Check.finite(value.x)
		and Check.finite(value.y)
		and Check.finite(value.z)
end

local function round(mode: string, value: number): number
	if mode == "round" then
		return math.floor(value + 0.5)
	elseif mode == "floor" then
		return math.floor(value)
	elseif mode == "ceil" then
		return math.ceil(value - 1e-9)
	end
	return value
end

local function sortModifiers(list: { Modifier }): { Modifier }
	local out = table.clone(list)
	table.sort(out, function(a: Modifier, b: Modifier): boolean
		local pa, pb = a.priority or 50, b.priority or 50
		if pa ~= pb then
			return pa < pb
		end
		return a.id < b.id
	end)
	return out
end

local function modifierProblems(list: any, where: string, problems: { string })
	if list == nil then
		return
	end
	if type(list) ~= "table" then
		table.insert(problems, where .. " must be a list")
		return
	end
	local seen: { [string]: boolean } = {}
	for index, modifier in list do
		local at = string.format("%s[%s]", where, tostring(index))
		if type(modifier) ~= "table" then
			table.insert(problems, at .. " must be a table")
		elseif not Check.label(modifier.id) then
			table.insert(problems, at .. ": id must be a label")
		elseif seen[modifier.id] then
			table.insert(problems, at .. ": duplicate id " .. modifier.id)
		elseif modifier.priority ~= nil and not Check.finite(modifier.priority) then
			table.insert(problems, at .. ": priority must be finite")
		elseif type(modifier.apply) ~= "function" then
			table.insert(problems, at .. ": apply must be a function")
		else
			seen[modifier.id] = true
		end
	end
end

-- Problems with a definition (empty when valid).
function Vitals.validate(def: any): { string }
	if type(def) ~= "table" then
		return { "definition must be a table" }
	end
	local problems: { string } = {}
	local rounding = def.rounding or "round"
	if not Vitals.ROUNDING[rounding] then
		table.insert(
			problems,
			"rounding must be round, floor, ceil or none (got " .. Check.describe(rounding) .. ")"
		)
		rounding = "round"
	end
	local integer = rounding ~= "none"
	local pools = def.pools
	if type(pools) ~= "table" or next(pools) == nil then
		table.insert(
			problems,
			"pools must be a non-empty map of name -> { max, start?, regen?, regenDelay? }"
		)
		return problems
	end
	local count = 0
	for name, pool in pools do
		count += 1
		if not Check.label(name, Vitals.POOL_NAME_MAX) then
			table.insert(
				problems,
				string.format(
					"pool %s: name must be a label of at most %d characters",
					Check.describe(name),
					Vitals.POOL_NAME_MAX
				)
			)
			continue
		end
		if type(pool) ~= "table" then
			table.insert(problems, "pool " .. name .. " must be a table")
			continue
		end
		local maxOk = Check.finite(pool.max) and pool.max > 0 and pool.max <= Vitals.MAX_VALUE
		if not maxOk then
			table.insert(
				problems,
				string.format("pool %s: max must be a finite number in (0, %d]", name, Vitals.MAX_VALUE)
			)
		elseif integer and not Check.integer(pool.max) then
			table.insert(
				problems,
				"pool " .. name .. ": max must be an integer (rounding is " .. rounding .. ")"
			)
		end
		if pool.start ~= nil then
			if not Check.finite(pool.start) or pool.start < 0 or (maxOk and pool.start > pool.max) then
				table.insert(problems, "pool " .. name .. ": start must be finite, >= 0 and <= max")
			elseif integer and not Check.integer(pool.start) then
				table.insert(problems, "pool " .. name .. ": start must be an integer")
			end
		end
		for _, key in { "regen", "regenDelay" } do
			local value = pool[key]
			if value ~= nil and (not Check.finite(value) or value < 0) then
				table.insert(problems, string.format("pool %s: %s must be a finite number >= 0", name, key))
			end
		end
	end
	if count > Vitals.MAX_POOLS then
		table.insert(problems, string.format("at most %d pools (each is 2 attributes)", Vitals.MAX_POOLS))
	end
	if type(pools.health) ~= "table" then
		table.insert(problems, "a health pool is required")
	end
	if def.absorb ~= nil then
		if type(def.absorb) ~= "table" or #def.absorb == 0 then
			table.insert(problems, "absorb must be a non-empty list of pool names")
		else
			local seen: { [string]: boolean } = {}
			for _, name in def.absorb do
				if type(name) ~= "string" or pools[name] == nil then
					table.insert(problems, "absorb names unknown pool " .. Check.describe(name))
				elseif seen[name] then
					table.insert(problems, "absorb lists " .. name .. " twice")
				end
				if type(name) == "string" then
					seen[name] = true
				end
			end
			if def.absorb[#def.absorb] ~= "health" then
				table.insert(problems, "absorb must end with health")
			end
		end
	end
	local healthMax = if type(pools.health) == "table" then pools.health.max else nil
	local function checkRevive(value: any, where: string)
		if value ~= nil then
			if not Check.finite(value) or value <= 0 or (Check.finite(healthMax) and value > healthMax) then
				table.insert(problems, where .. " must be finite, > 0 and <= health max")
			elseif integer and not Check.integer(value) then
				table.insert(problems, where .. " must be an integer")
			end
		end
	end
	checkRevive(def.reviveHealth, "reviveHealth")
	if def.downed ~= nil then
		if type(def.downed) ~= "table" then
			table.insert(problems, "downed must be a table")
		else
			if not Check.finite(def.downed.bleedout) or def.downed.bleedout <= 0 then
				table.insert(problems, "downed.bleedout must be a finite number > 0")
			end
			checkRevive(def.downed.reviveHealth, "downed.reviveHealth")
			if def.downed.finishable ~= nil and type(def.downed.finishable) ~= "boolean" then
				table.insert(problems, "downed.finishable must be a boolean")
			end
		end
	end
	if def.logSize ~= nil and (not Check.integer(def.logSize) or def.logSize < 1 or def.logSize > 256) then
		table.insert(problems, "logSize must be an integer 1-256")
	end
	modifierProblems(def.modifiers, "modifiers", problems)
	return problems
end

-- Validates and freezes a definition (modifier functions are kept as they are).
function Vitals.define(def: Definition): Spec
	local problems = Vitals.validate(def)
	if #problems > 0 then
		error("Vitals.define: " .. table.concat(problems, "; "), 2)
	end
	local pools: { [string]: PoolDef } = {}
	local names: { string } = {}
	for name, pool in def.pools do
		pools[name] = table.freeze({
			max = pool.max,
			start = if pool.start ~= nil then pool.start else pool.max,
			regen = pool.regen or 0,
			regenDelay = pool.regenDelay or 0,
		})
		table.insert(names, name)
	end
	table.sort(names)
	local absorb = def.absorb
	if absorb == nil then
		absorb = if pools.shield ~= nil then { "shield", "health" } else { "health" }
	end
	return table.freeze({
		pools = table.freeze(pools),
		names = table.freeze(names),
		absorb = table.freeze(table.clone(absorb :: { string })),
		rounding = def.rounding or "round",
		downed = if def.downed then table.freeze(table.clone(def.downed)) else nil,
		reviveHealth = def.reviveHealth,
		logSize = def.logSize or Vitals.DEFAULT_LOG,
		modifiers = table.freeze(sortModifiers(def.modifiers or {})),
	})
end

-- ---------------------------------------------------------------- built-in modifiers

-- Multiplies damage of one kind (or every kind with "*") by (1 - fraction); a negative fraction
-- is a weakness. fraction is clamped to [-1, 1].
function Vitals.resist(kind: string, fraction: number, priority: number?): Modifier
	assert(kind == "*" or Check.label(kind), "Vitals.resist: kind must be a label or *")
	Check.assertFinite(fraction, "Vitals.resist fraction")
	local f = math.clamp(fraction, -1, 1)
	return {
		id = "resist_" .. (if kind == "*" then "all" else kind),
		priority = priority or 20,
		apply = function(ctx: DamageContext)
			if kind == "*" or ctx.kind == kind then
				ctx.amount *= 1 - f
			end
		end,
	}
end

-- Armour rating: damage x scale / (scale + rating) (rating 100, scale 100 halves damage). Kinds
-- listed in bypass (e.g. "true_damage") ignore it.
function Vitals.armor(rating: number, scale: number?, bypass: { string }?, priority: number?): Modifier
	Check.assertFinite(rating, "Vitals.armor rating")
	local s = scale or 100
	assert(Check.finite(s) and s > 0, "Vitals.armor: scale must be > 0")
	assert(rating >= 0, "Vitals.armor: rating must be >= 0")
	local skip: { [string]: boolean } = {}
	local bypassKinds: { string } = bypass or {}
	for _, kind in bypassKinds do
		skip[kind] = true
	end
	return {
		id = "armor",
		priority = priority or 30,
		apply = function(ctx: DamageContext)
			if not skip[ctx.kind] then
				ctx.amount *= s / (s + rating)
			end
		end,
	}
end

-- Flat reduction per hit (never below 0).
function Vitals.flatArmor(amount: number, priority: number?): Modifier
	Check.assertFinite(amount, "Vitals.flatArmor amount")
	return {
		id = "flat_armor",
		priority = priority or 35,
		apply = function(ctx: DamageContext)
			ctx.amount = math.max(0, ctx.amount - amount)
		end,
	}
end

-- Critical hits: a hit already flagged crit (the server decided, e.g. a head hitbox) or a roll
-- under chance (seeded Rng from the env) multiplies the amount.
function Vitals.crit(multiplier: number, chance: number?, priority: number?): Modifier
	Check.assertFinite(multiplier, "Vitals.crit multiplier")
	local c = chance or 0
	assert(Check.finite(c) and c >= 0 and c <= 1, "Vitals.crit: chance must be 0-1")
	return {
		id = "crit",
		priority = priority or 10,
		apply = function(ctx: DamageContext)
			if not ctx.crit and c > 0 and ctx.rng() < c then
				ctx.crit = true
			end
			if ctx.crit then
				ctx.amount *= multiplier
			end
		end,
	}
end

-- Caps a single hit.
function Vitals.cap(maxPerHit: number, priority: number?): Modifier
	Check.assertFinite(maxPerHit, "Vitals.cap maxPerHit")
	return {
		id = "cap",
		priority = priority or 90,
		apply = function(ctx: DamageContext)
			ctx.amount = math.min(ctx.amount, maxPerHit)
		end,
	}
end

-- Multiplies by a value read at hit time (a StatusEffects multiplier such as damage_taken).
function Vitals.scale(id: string, read: () -> number, priority: number?): Modifier
	assert(Check.label(id), "Vitals.scale: id must be a label")
	return {
		id = id,
		priority = priority or 40,
		apply = function(ctx: DamageContext)
			ctx.amount *= read()
		end,
	}
end

-- ---------------------------------------------------------------- instances

export type Options = { modifiers: { Modifier }?, seed: (number | string)? }

function Vitals.new(spec: Spec, options: Options?, env: any): Vitals
	assert(type(spec) == "table" and table.isfrozen(spec), "Vitals.new needs a spec from Vitals.define")
	assert(type(env) == "table" and type(env.clock) == "function", "Vitals.new needs an env with clock()")
	local modifiers = table.clone(spec.modifiers)
	if options and options.modifiers then
		local problems = {}
		modifierProblems(options.modifiers, "options.modifiers", problems)
		local ids: { [string]: boolean } = {}
		for _, modifier in spec.modifiers do
			ids[modifier.id] = true
		end
		for _, modifier in options.modifiers do
			if ids[modifier.id] then
				table.insert(problems, "modifier " .. modifier.id .. " is already in the spec")
			end
			table.insert(modifiers, modifier)
		end
		if #problems > 0 then
			error("Vitals.new: " .. table.concat(problems, "; "), 2)
		end
	end
	local self = setmetatable({
		spec = spec,
		changed = Signal.new(env),
		damaged = Signal.new(env),
		died = Signal.new(env),
		downed = Signal.new(env),
		revived = Signal.new(env),
		_env = env,
		_values = {},
		_max = {},
		_carry = {},
		_lastDrain = {},
		_state = "alive",
		_downedAt = 0,
		_downedBy = nil,
		_invulnerableUntil = -math.huge,
		_modifiers = sortModifiers(modifiers),
		_log = {},
		_logHead = 0,
		_rng = nil,
		_seed = options and options.seed,
		_lastRecord = nil,
	}, Vitals)
	for _, name in spec.names do
		local pool = spec.pools[name]
		self._values[name] = pool.start :: number
		self._max[name] = pool.max
		self._carry[name] = 0
		self._lastDrain[name] = -math.huge
	end
	return self
end

local function setValue(self: Vitals, pool: string, value: number)
	if self._values[pool] ~= value then
		self._values[pool] = value
		self.changed:Fire(pool, value, self._max[pool])
	end
end

local function roll(self: Vitals): number
	if self._rng == nil then
		self._rng = self._env.rng(self._seed)
	end
	return self._rng:next()
end

local function cleanSource(source: any): Source
	local out: Source = {}
	if type(source) ~= "table" then
		return out
	end
	local attacker = source.attacker
	if (type(attacker) == "string" and #attacker >= 1 and #attacker <= 64) or Check.finite(attacker) then
		out.attacker = attacker
	end
	if Check.label(source.ability) then
		out.ability = source.ability
	end
	if Check.label(source.weapon) then
		out.weapon = source.weapon
	end
	if isVec(source.position) then
		out.position = { x = source.position.x, y = source.position.y, z = source.position.z }
	end
	return out
end

local function remember(self: Vitals, record: Record)
	local size = self.spec.logSize
	self._logHead = self._logHead % size + 1
	self._log[self._logHead] = record
	self._lastRecord = record
end

local function rejected(self: Vitals, reason: string, requested: number, kind: string, source: Source): Record
	return {
		ok = false,
		reason = reason,
		requested = requested,
		amount = 0,
		applied = 0,
		absorbed = {},
		overkill = 0,
		kind = kind,
		crit = false,
		lethal = false,
		state = self._state,
		source = source,
		t = self._env.clock(),
	}
end

local function die(self: Vitals, record: Record)
	self._state = "dead"
	self._downedBy = nil
	record.lethal = true
	record.state = "dead"
	self.died:Fire(record)
end

-- Applies damage through the modifier pipeline. Never raises on bad input: the record says why
-- it was rejected (bad_input, bad_amount, bad_kind, dead, invulnerable, cancelled).
function Vitals.damage(self: Vitals, info: DamageInfo): Record
	if type(info) ~= "table" then
		return rejected(self, "bad_input", 0, "generic", {})
	end
	local source = cleanSource(info.source)
	local kind = if info.kind == nil then "generic" else info.kind
	local amount = info.amount
	if not Check.finite(amount) or amount < 0 then
		return rejected(
			self,
			"bad_amount",
			0,
			if Check.label(kind) then kind :: string else "generic",
			source
		)
	end
	if not Check.label(kind) then
		return rejected(self, "bad_kind", amount, "generic", source)
	end
	local requested = math.min(amount, Vitals.MAX_VALUE)
	if self._state == "dead" then
		return rejected(self, "dead", requested, kind :: string, source)
	end
	local now = self._env.clock()
	if now < self._invulnerableUntil then
		return rejected(self, "invulnerable", requested, kind :: string, source)
	end
	local tags: { [string]: boolean } = {}
	if type(info.tags) == "table" then
		for _, tag in info.tags do
			if Check.label(tag) then
				tags[tag] = true
			end
		end
	end
	local ctx: DamageContext = {
		amount = requested,
		kind = kind :: string,
		crit = info.crit == true,
		source = source,
		tags = tags,
		cancelled = nil,
		vitals = self,
		rng = function(): number
			return roll(self)
		end,
		changedBy = {},
	}
	for _, modifier in self._modifiers do
		local before = ctx.amount
		local ok: boolean, err: any = pcall(modifier.apply, ctx)
		if not ok then
			self._env.report(string.format("Vitals: modifier %s failed: %s", modifier.id, tostring(err)))
			ctx.amount = before
		elseif not Check.finite(ctx.amount) or ctx.amount < 0 then
			self._env.report(
				string.format(
					"Vitals: modifier %s produced %s; ignored",
					modifier.id,
					Check.describe(ctx.amount)
				)
			)
			ctx.amount = before
		elseif ctx.amount ~= before then
			table.insert(ctx.changedBy, modifier.id)
		end
		if ctx.cancelled ~= nil then
			break
		end
	end
	if ctx.cancelled ~= nil then
		local record = rejected(self, "cancelled", requested, ctx.kind, source)
		record.cancelledBy = if Check.label(ctx.cancelled) then ctx.cancelled else "modifier"
		return record
	end
	local final = math.min(round(self.spec.rounding, ctx.amount), Vitals.MAX_VALUE)
	local record: Record = {
		ok = true,
		reason = nil,
		requested = requested,
		amount = final,
		applied = 0,
		absorbed = {},
		overkill = 0,
		kind = ctx.kind,
		crit = ctx.crit,
		lethal = false,
		state = self._state,
		source = source,
		t = now,
	}
	if self._state == "downed" then
		local downedDef = self.spec.downed :: DownedDef
		if final > 0 and downedDef.finishable ~= false then
			record.applied = 0
			remember(self, record)
			self.damaged:Fire(record)
			die(self, record)
		end
		return record
	end
	local remaining = final
	for _, pool in self.spec.absorb do
		if final > 0 then
			self._lastDrain[pool] = now
			self._carry[pool] = 0
		end
		local value = self._values[pool]
		local take = math.min(value, remaining)
		if take > 0 then
			record.absorbed[pool] = take
			remaining -= take
			setValue(self, pool, value - take)
		end
	end
	record.overkill = remaining
	record.applied = final - remaining
	remember(self, record)
	if self._values.health <= 0 then
		if self.spec.downed ~= nil then
			self._state = "downed"
			self._downedAt = now
			self._downedBy = record
			record.state = "downed"
			record.lethal = false
			self.damaged:Fire(record)
			self.downed:Fire(record)
		else
			self.damaged:Fire(record)
			die(self, record)
		end
	else
		record.state = self._state
		self.damaged:Fire(record)
	end
	return record
end

-- Heals health (alive only). Returns (applied, reason?) with reason bad_amount or not_alive.
function Vitals.heal(self: Vitals, amount: any): (number, string?)
	if not Check.finite(amount) or amount < 0 then
		return 0, "bad_amount"
	end
	if self._state ~= "alive" then
		return 0, "not_alive"
	end
	local value = self._values.health
	local gain =
		math.min(round(self.spec.rounding, math.min(amount, Vitals.MAX_VALUE)), self._max.health - value)
	if gain > 0 then
		setValue(self, "health", value + gain)
	end
	return math.max(gain, 0), nil
end

-- Whether pool holds at least amount (integer pools round the cost up).
function Vitals.canSpend(self: Vitals, pool: string, amount: any): boolean
	if self._values[pool] == nil or not Check.finite(amount) or amount < 0 or self._state ~= "alive" then
		return false
	end
	local cost = if self.spec.rounding == "none" then amount else math.ceil(amount - 1e-9)
	return self._values[pool] >= cost
end

-- Spends from a pool (stamina, mana, ammo). (ok, reason?) with unknown_pool, bad_amount,
-- not_alive or insufficient. Integer pools round the cost up, so fractional costs are never free.
function Vitals.spend(self: Vitals, pool: string, amount: any): (boolean, string?)
	if self._values[pool] == nil then
		return false, "unknown_pool"
	end
	if not Check.finite(amount) or amount < 0 then
		return false, "bad_amount"
	end
	if self._state ~= "alive" then
		return false, "not_alive"
	end
	local cost = if self.spec.rounding == "none" then amount else math.ceil(amount - 1e-9)
	local value = self._values[pool]
	if value < cost then
		return false, "insufficient"
	end
	if cost > 0 then
		self._lastDrain[pool] = self._env.clock()
		self._carry[pool] = 0
		setValue(self, pool, value - cost)
	end
	return true, nil
end

-- Adds to a pool up to its max (pickups); health goes through heal. Returns the amount added.
function Vitals.restore(self: Vitals, pool: string, amount: any): number
	if pool == "health" then
		return (self:heal(amount))
	end
	local value = self._values[pool]
	if value == nil or not Check.finite(amount) or amount < 0 or self._state == "dead" then
		return 0
	end
	local gain = math.min(round(self.spec.rounding, amount), self._max[pool] - value)
	if gain > 0 then
		setValue(self, pool, value + gain)
	end
	return math.max(gain, 0)
end

-- Sets a pool directly (respawn, admin); clamped to [0, max]. Setting health to 0 kills.
function Vitals.set(self: Vitals, pool: string, value: number)
	assert(self._values[pool] ~= nil, "Vitals.set: unknown pool " .. tostring(pool))
	Check.assertFinite(value, "Vitals.set value")
	local v = math.clamp(round(self.spec.rounding, value), 0, self._max[pool])
	setValue(self, pool, v)
	if pool == "health" and v <= 0 and self._state ~= "dead" then
		local record = rejected(self, "set", 0, "generic", {})
		record.ok = true
		record.reason = nil
		remember(self, record)
		die(self, record)
	end
end

-- Changes a pool's max; keepRatio scales the current value with it, else the value is clamped.
function Vitals.setMax(self: Vitals, pool: string, max: number, keepRatio: boolean?)
	assert(self._values[pool] ~= nil, "Vitals.setMax: unknown pool " .. tostring(pool))
	assert(
		Check.finite(max) and max > 0 and max <= Vitals.MAX_VALUE,
		"Vitals.setMax: max must be finite and in (0, MAX_VALUE]"
	)
	local m = round(self.spec.rounding, max)
	assert(m > 0, "Vitals.setMax: max rounds to 0")
	local old = self._max[pool]
	self._max[pool] = m
	local value = self._values[pool]
	local nextValue = if keepRatio then round(self.spec.rounding, value * m / old) else math.min(value, m)
	if self._values[pool] ~= nextValue then
		setValue(self, pool, math.clamp(nextValue, 0, m))
	else
		self.changed:Fire(pool, value, m)
	end
end

-- Kills now (kill volume, out of bounds, admin). Returns the lethal record (nil when already dead).
function Vitals.kill(self: Vitals, source: Source?, kind: string?): Record?
	if self._state == "dead" then
		return nil
	end
	local record = rejected(
		self,
		"kill",
		0,
		if Check.label(kind) then kind :: string else "generic",
		cleanSource(source)
	)
	record.ok = true
	record.reason = nil
	record.applied = self._values.health
	if record.applied > 0 then
		record.absorbed.health = record.applied
	end
	setValue(self, "health", 0)
	remember(self, record)
	die(self, record)
	return record
end

-- Revives from downed or dead. health defaults to downed.reviveHealth (from downed), then
-- reviveHealth, then max. invulnerable gives spawn protection; refill resets the other pools to
-- their start values. Returns false when already alive.
function Vitals.revive(
	self: Vitals,
	options: { health: number?, invulnerable: number?, refill: boolean? }?
): boolean
	if self._state == "alive" then
		return false
	end
	local wasDowned = self._state == "downed"
	local health = options and options.health
	if health == nil then
		local downedDef = self.spec.downed
		health = if wasDowned
				and downedDef
				and downedDef.reviveHealth
			then downedDef.reviveHealth
			else self.spec.reviveHealth or self._max.health
	end
	Check.assertFinite(health, "Vitals.revive health")
	self._state = "alive"
	self._downedBy = nil
	if options and options.refill then
		for _, name in self.spec.names do
			if name ~= "health" then
				setValue(self, name, math.min(self.spec.pools[name].start :: number, self._max[name]))
			end
		end
	end
	setValue(self, "health", math.clamp(round(self.spec.rounding, health :: number), 1, self._max.health))
	if options and options.invulnerable then
		self:setInvulnerable(options.invulnerable)
	end
	self.revived:Fire()
	return true
end

-- Full reset for a respawn: every pool to its start value, alive, log cleared.
function Vitals.reset(self: Vitals)
	self._state = "alive"
	self._downedBy = nil
	self._log = {}
	self._logHead = 0
	self._lastRecord = nil
	for _, name in self.spec.names do
		self._carry[name] = 0
		self._lastDrain[name] = -math.huge
		setValue(self, name, math.min(self.spec.pools[name].start :: number, self._max[name]))
	end
end

-- Ignores damage for seconds from now (spawn protection, dodge frames).
function Vitals.setInvulnerable(self: Vitals, seconds: number)
	Check.assertFinite(seconds, "Vitals.setInvulnerable seconds")
	self._invulnerableUntil = self._env.clock() + math.max(0, seconds)
end

function Vitals.invulnerable(self: Vitals): boolean
	return self._env.clock() < self._invulnerableUntil
end

-- Regenerates pools and runs the bleed-out timer. Non-yielding; dt must be finite and >= 0.
function Vitals.step(self: Vitals, dt: number)
	if not Check.finite(dt) or dt < 0 then
		self._env.report("Vitals.step: dt must be finite and >= 0 (got " .. Check.describe(dt) .. ")")
		return
	end
	local now = self._env.clock()
	if self._state == "downed" then
		local downedDef = self.spec.downed :: DownedDef
		if now - self._downedAt >= downedDef.bleedout then
			local cause = self._downedBy
			local record = rejected(
				self,
				"bleedout",
				0,
				if cause then cause.kind else "generic",
				if cause then cause.source else {}
			)
			record.ok = true
			record.reason = "bleedout"
			remember(self, record)
			die(self, record)
		end
		return
	end
	if self._state ~= "alive" then
		return
	end
	for _, name in self.spec.names do
		local pool = self.spec.pools[name]
		local regen = pool.regen :: number
		local value = self._values[name]
		local max = self._max[name]
		if regen > 0 and value < max and now - self._lastDrain[name] >= (pool.regenDelay :: number) then
			local gain = regen * dt + self._carry[name]
			if self.spec.rounding ~= "none" then
				local whole = math.floor(gain)
				self._carry[name] = gain - whole
				gain = whole
			end
			local nextValue = math.min(max, value + gain)
			if nextValue >= max then
				self._carry[name] = 0
			end
			setValue(self, name, nextValue)
		end
	end
end

-- ---------------------------------------------------------------- reads

function Vitals.state(self: Vitals): string
	return self._state
end

function Vitals.alive(self: Vitals): boolean
	return self._state == "alive"
end

-- (value, max) of a pool; nil for an unknown pool.
function Vitals.get(self: Vitals, pool: string): (number?, number?)
	return self._values[pool], self._max[pool]
end

-- Damage records newest first, optionally only those within window seconds.
function Vitals.recent(self: Vitals, window: number?): { Record }
	local out = {}
	local size = self.spec.logSize
	local now = self._env.clock()
	for offset = 0, size - 1 do
		local index = (self._logHead - offset - 1) % size + 1
		local record = self._log[index]
		if record == nil then
			break
		end
		if window == nil or now - record.t <= window then
			table.insert(out, record)
		end
	end
	return out
end

-- The attacker credited with the last lethal (or downing) record, if any.
function Vitals.killer(self: Vitals): (string | number)?
	local last = self._lastRecord
	if last and (last.lethal or self._state ~= "alive") then
		return last.source.attacker
	end
	return nil
end

-- Attackers who applied damage within window seconds, by total damage (descending), then id.
-- exclude drops one attacker (usually the killer).
function Vitals.assists(
	self: Vitals,
	window: number,
	exclude: (string | number)?
): { { attacker: string | number, damage: number } }
	Check.assertFinite(window, "Vitals.assists window")
	local totals: { [string]: { attacker: string | number, damage: number } } = {}
	for _, record in self:recent(window) do
		local attacker = record.source.attacker
		if attacker ~= nil and attacker ~= exclude and record.applied > 0 then
			local key = tostring(attacker)
			local entry = totals[key] or { attacker = attacker, damage = 0 }
			entry.damage += record.applied
			totals[key] = entry
		end
	end
	local out = {}
	for _, entry in totals do
		table.insert(out, entry)
	end
	table.sort(out, function(a, b): boolean
		if a.damage ~= b.damage then
			return a.damage > b.damage
		end
		return tostring(a.attacker) < tostring(b.attacker)
	end)
	return out
end

-- Flat attribute map: state plus <pool> and <pool>Max for each pool (at most 33 attributes).
function Vitals.snapshot(self: Vitals): { [string]: string | number }
	local out: { [string]: string | number } = { state = self._state }
	for _, name in self.spec.names do
		out[name] = self._values[name]
		out[name .. "Max"] = self._max[name]
	end
	return out
end

function Vitals.destroy(self: Vitals)
	for _, signal in { self.changed, self.damaged, self.died, self.downed, self.revived } do
		signal:Destroy()
	end
end

return Vitals
