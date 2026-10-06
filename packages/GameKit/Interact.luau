--!strict
-- @tier T0
-- Interact: server validation of interaction requests. Targets are data:
--   { id, position?, kind = "prompt" | "touch", maxDistance?, holdDuration?, cooldown?,
--     sharedCooldown?, exclusive?, lineOfSight?, radius?, touch? = { damage?, kill?, interval?,
--     damageKind? }, gate? = { order, finish? }, data? }
-- Prompts (ProximityPrompt in InteractRoblox) go begin -> finish: the server times the hold on
-- its own clock (both requests travel with similar latency), re-checks distance and line of
-- sight at the end, and applies per-player rate limits and cooldowns. Touch targets cover kill
-- parts, hazard parts and lap/sector gates: a touch is accepted only when the toucher is
-- actually near the part (a forged touch from across the map is refused) and re-arms per player
-- after `interval`. Every refusal is a reason string; nothing raises on client input.
-- Defaults follow ProximityPrompt (MaxActivationDistance 10, HoldDuration 0,
-- RequiresLineOfSight true); the rate limit, hold slack and touch slack are conventions.
local Check = require("./Check")
local Signal = require("./Signal")
local Vec = require("../SceneKit/Vec")

local Interact = {}
Interact.MAX_DISTANCE = 10 -- ProximityPrompt.MaxActivationDistance default
Interact.DISTANCE_SLACK = 2 -- studs for latency and character size (convention)
Interact.HOLD_SLACK = 0.1 -- seconds a hold may come up short (convention)
Interact.TOUCH_RADIUS = 4 -- studs (convention)
Interact.RATE = 8 -- requests per window per player (convention)
Interact.RATE_WINDOW = 1 -- seconds (convention)
Interact.MAX_TARGETS = 4096
Interact.KINDS = table.freeze({ prompt = true, touch = true })

export type V3 = Vec.V3
export type TargetDef = {
	id: string,
	position: V3?,
	kind: string?,
	maxDistance: number?,
	holdDuration: number?,
	cooldown: number?,
	sharedCooldown: number?,
	exclusive: boolean?,
	lineOfSight: boolean?,
	radius: number?,
	touch: { damage: number?, kill: boolean?, interval: number?, damageKind: string? }?,
	gate: { order: number, finish: boolean? }?,
	data: any?,
}
export type Set = { targets: { [string]: TargetDef }, ids: { string } }
export type Event = {
	kind: string, -- "triggered" | "hazard" | "kill" | "gate"
	player: any,
	target: string,
	t: number,
	damage: number?,
	damageKind: string?,
	order: number?,
	finish: boolean?,
	data: any?,
}
export type Options = {
	rate: number?,
	window: number?,
	lineOfSight: ((from: V3, to: V3, target: string) -> boolean)?,
	locate: ((target: string) -> V3?)?,
}

local function isVec(value: any): boolean
	return type(value) == "table"
		and Check.finite(value.x)
		and Check.finite(value.y)
		and Check.finite(value.z)
end

local function nonNegative(value: any, hi: number): boolean
	return Check.finite(value) and value >= 0 and value <= hi
end

-- Problems with a target list (empty when valid).
function Interact.validate(defs: any): { string }
	if type(defs) ~= "table" then
		return { "targets must be a list" }
	end
	local problems = {}
	if #defs > Interact.MAX_TARGETS then
		table.insert(problems, string.format("at most %d targets", Interact.MAX_TARGETS))
	end
	local seen = {}
	for index, def in defs do
		local where = string.format("targets[%d]", index)
		local function need(ok: boolean, message: string)
			if not ok then
				table.insert(problems, where .. message)
			end
		end
		if type(def) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		need(Check.label(def.id), ".id must be a label")
		if type(def.id) == "string" then
			need(not seen[def.id], string.format(".id %q is duplicated", def.id))
			seen[def.id] = true
		end
		local kind = def.kind or "prompt"
		need(Interact.KINDS[kind] == true, ".kind must be prompt or touch")
		need(def.position == nil or isVec(def.position), ".position must be a finite vector")
		need(
			def.maxDistance == nil or (nonNegative(def.maxDistance, 1000) and def.maxDistance > 0),
			".maxDistance must be in (0, 1000]"
		)
		need(
			def.holdDuration == nil or nonNegative(def.holdDuration, 60),
			".holdDuration must be 0-60 seconds"
		)
		need(def.cooldown == nil or nonNegative(def.cooldown, 86400), ".cooldown must be 0-86400 seconds")
		need(
			def.sharedCooldown == nil or nonNegative(def.sharedCooldown, 86400),
			".sharedCooldown must be 0-86400 seconds"
		)
		need(def.exclusive == nil or type(def.exclusive) == "boolean", ".exclusive must be a boolean")
		need(def.lineOfSight == nil or type(def.lineOfSight) == "boolean", ".lineOfSight must be a boolean")
		need(
			def.radius == nil or (nonNegative(def.radius, 1000) and def.radius > 0),
			".radius must be in (0, 1000]"
		)
		local touch = def.touch
		if touch ~= nil then
			need(kind == "touch", ".touch is only for kind touch")
			if type(touch) ~= "table" then
				table.insert(problems, where .. ".touch must be a table")
			else
				need(
					touch.damage == nil or (Check.finite(touch.damage) and touch.damage > 0),
					".touch.damage must be > 0"
				)
				need(touch.kill == nil or type(touch.kill) == "boolean", ".touch.kill must be a boolean")
				need(
					touch.interval == nil or nonNegative(touch.interval, 3600),
					".touch.interval must be 0-3600 seconds"
				)
				need(
					touch.damageKind == nil or Check.label(touch.damageKind),
					".touch.damageKind must be a label"
				)
			end
		end
		local gate = def.gate
		if gate ~= nil then
			need(kind == "touch", ".gate is only for kind touch")
			need(
				type(gate) == "table" and Check.integer(gate.order) and gate.order >= 1,
				".gate.order must be an integer >= 1"
			)
			need(
				type(gate) ~= "table" or gate.finish == nil or type(gate.finish) == "boolean",
				".gate.finish must be a boolean"
			)
		end
		if kind == "touch" then
			need(def.touch ~= nil or def.gate ~= nil or def.data ~= nil, " (touch) needs touch, gate or data")
			need(def.holdDuration == nil, ".holdDuration is only for prompts")
		end
	end
	return problems
end

function Interact.define(defs: { TargetDef }): Set
	local problems = Interact.validate(defs)
	if #problems > 0 then
		error("Interact.define: " .. table.concat(problems, "; "), 2)
	end
	local targets = {}
	local ids = {}
	for _, def in defs do
		targets[def.id] = Check.freeze(Check.copy(def))
		table.insert(ids, def.id)
	end
	table.sort(ids)
	return table.freeze({ targets = table.freeze(targets), ids = table.freeze(ids) })
end

-- ---------------------------------------------------------------- server

local Server = {}
Server.__index = Server

type Bucket = { tokens: number, at: number }
type Fields = {
	set: Set,
	triggered: Signal.Signal,
	touched: Signal.Signal,
	_env: any,
	_options: Options,
	_holds: { [any]: { [string]: number } },
	_users: { [string]: any },
	_cooldowns: { [string]: number }, -- "<player>|<target>" -> ready time
	_shared: { [string]: number },
	_buckets: { [any]: Bucket },
	_enabled: { [string]: boolean },
	_stats: { [string]: number },
}
export type Server = typeof(setmetatable({} :: Fields, Server))

function Interact.server(set: Set, options: Options?, env: any): Server
	assert(type(set) == "table" and table.isfrozen(set), "Interact.server needs a set from Interact.define")
	assert(type(env) == "table" and type(env.clock) == "function", "Interact.server needs env.clock")
	local opts = options or {}
	if opts.rate ~= nil then
		assert(Check.integer(opts.rate) and opts.rate >= 1, "Interact.server: rate must be an integer >= 1")
	end
	if opts.window ~= nil then
		assert(Check.finite(opts.window) and opts.window > 0, "Interact.server: window must be > 0")
	end
	return setmetatable({
		set = set,
		triggered = Signal.new(env),
		touched = Signal.new(env),
		_env = env,
		_options = opts,
		_holds = {},
		_users = {},
		_cooldowns = {},
		_shared = {},
		_buckets = {},
		_enabled = {},
		_stats = {},
	}, Server)
end

local function refuse(self: Server, reason: string): (boolean, string, nil)
	self._stats[reason] = (self._stats[reason] or 0) + 1
	return false, reason, nil
end

-- Token bucket per player: rate requests per window, refilled continuously.
local function allow(self: Server, player: any, now: number): boolean
	local rate = self._options.rate or Interact.RATE
	local window = self._options.window or Interact.RATE_WINDOW
	local bucket = self._buckets[player]
	if bucket == nil then
		bucket = { tokens = rate, at = now }
		self._buckets[player] = bucket
	end
	local b = bucket :: Bucket
	b.tokens = math.min(rate, b.tokens + (now - b.at) * rate / window)
	b.at = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

local function where(self: Server, def: TargetDef): V3?
	local locate = self._options.locate
	if locate then
		local found = locate(def.id)
		if found ~= nil then
			return if isVec(found) then found else nil
		end
	end
	return def.position
end

-- Shared checks for every request. Returns (def, position) or (nil, reason).
local function common(
	self: Server,
	player: any,
	id: any,
	position: any,
	kind: string,
	now: number
): (TargetDef?, any)
	if player == nil then
		return nil, "bad_input"
	end
	if not allow(self, player, now) then
		return nil, "rate_limited"
	end
	local def = if type(id) == "string" then self.set.targets[id] else nil
	if def == nil then
		return nil, "unknown_target"
	end
	if (def.kind or "prompt") ~= kind then
		return nil, "wrong_kind"
	end
	if self._enabled[def.id] == false then
		return nil, "disabled"
	end
	if not isVec(position) then
		return nil, "bad_input"
	end
	local target = where(self, def)
	if target == nil then
		return nil, "unknown_target"
	end
	local limit = if kind == "touch"
		then (def.radius or Interact.TOUCH_RADIUS) + Interact.DISTANCE_SLACK
		else (def.maxDistance or Interact.MAX_DISTANCE) + Interact.DISTANCE_SLACK
	if Vec.length(Vec.sub(position, target :: V3)) > limit then
		return nil, "too_far"
	end
	if kind == "prompt" and def.lineOfSight ~= false and self._options.lineOfSight then
		if not self._options.lineOfSight(position, target :: V3, def.id) then
			return nil, "no_line_of_sight"
		end
	end
	return def, target
end

local function cooldownKey(player: any, id: string): string
	return tostring(player) .. "|" .. id
end

local function onCooldown(self: Server, player: any, def: TargetDef, now: number): boolean
	local own = self._cooldowns[cooldownKey(player, def.id)]
	local shared = self._shared[def.id]
	return (own ~= nil and now < own) or (shared ~= nil and now < shared)
end

-- A prompt hold starts (PromptButtonHoldBegan). (ok, reason?).
function Server.begin(self: Server, player: any, id: any, position: any): (boolean, string?)
	local now = self._env.clock()
	local def, reason = common(self, player, id, position, "prompt", now)
	if def == nil then
		return refuse(self, reason)
	end
	local d = def :: TargetDef
	if onCooldown(self, player, d, now) then
		return refuse(self, "cooldown")
	end
	if d.exclusive and self._users[d.id] ~= nil and self._users[d.id] ~= player then
		return refuse(self, "busy")
	end
	self._holds[player] = self._holds[player] or {}
	self._holds[player][d.id] = now
	if d.exclusive then
		self._users[d.id] = player
	end
	return true, nil
end

-- A prompt hold ends without triggering (PromptButtonHoldEnded, walked away).
function Server.cancel(self: Server, player: any, id: string)
	local holds = self._holds[player]
	if holds then
		holds[id] = nil
	end
	if self._users[id] == player then
		self._users[id] = nil
	end
end

-- The prompt fires (Triggered). (ok, reason?, event?) with the begin() reasons plus not_held
-- and too_quick for holds the server did not see last long enough.
function Server.finish(self: Server, player: any, id: any, position: any): (boolean, string?, Event?)
	local now = self._env.clock()
	local def, reason = common(self, player, id, position, "prompt", now)
	if def == nil then
		if type(id) == "string" then
			self:cancel(player, id)
		end
		return refuse(self, reason)
	end
	local d = def :: TargetDef
	local hold = d.holdDuration or 0
	local holds = self._holds[player]
	local started = holds and holds[d.id]
	if hold > 0 then
		if started == nil then
			return refuse(self, "not_held")
		end
		if now - (started :: number) < hold - Interact.HOLD_SLACK - 1e-9 then
			self:cancel(player, d.id)
			return refuse(self, "too_quick")
		end
	end
	if onCooldown(self, player, d, now) then
		self:cancel(player, d.id)
		return refuse(self, "cooldown")
	end
	if d.exclusive and self._users[d.id] ~= nil and self._users[d.id] ~= player then
		return refuse(self, "busy")
	end
	self:cancel(player, d.id)
	if d.cooldown and d.cooldown > 0 then
		self._cooldowns[cooldownKey(player, d.id)] = now + d.cooldown
	end
	if d.sharedCooldown and d.sharedCooldown > 0 then
		self._shared[d.id] = now + d.sharedCooldown
	end
	local event: Event = { kind = "triggered", player = player, target = d.id, t = now, data = d.data }
	self._stats.accepted = (self._stats.accepted or 0) + 1
	self.triggered:Fire(event)
	return true, nil, event
end

-- A touch on a touch target (BasePart.Touched resolved to a player). (ok, reason?, event?):
-- event.kind is "kill", "hazard", "gate" or "touched" (data only). Re-arms per player after
-- touch.interval (default 0.5 s for hazards, 0 for gates; a convention).
function Server.touch(self: Server, player: any, id: any, position: any): (boolean, string?, Event?)
	local now = self._env.clock()
	local def, reason = common(self, player, id, position, "touch", now)
	if def == nil then
		return refuse(self, reason)
	end
	local d = def :: TargetDef
	local key = cooldownKey(player, d.id)
	local ready = self._cooldowns[key]
	if ready ~= nil and now < ready then
		return refuse(self, "cooldown")
	end
	local touch = d.touch
	local interval = if touch and touch.interval ~= nil then touch.interval elseif touch then 0.5 else 0
	if interval > 0 then
		self._cooldowns[key] = now + interval
	end
	local event: Event
	if touch and touch.kill then
		event = {
			kind = "kill",
			player = player,
			target = d.id,
			t = now,
			damageKind = touch.damageKind or "kill",
			data = d.data,
		}
	elseif touch and touch.damage then
		event = {
			kind = "hazard",
			player = player,
			target = d.id,
			t = now,
			damage = touch.damage,
			damageKind = touch.damageKind or "hazard",
			data = d.data,
		}
	elseif d.gate then
		event = {
			kind = "gate",
			player = player,
			target = d.id,
			t = now,
			order = d.gate.order,
			finish = d.gate.finish == true,
			data = d.data,
		}
	else
		event = { kind = "touched", player = player, target = d.id, t = now, data = d.data }
	end
	self._stats.accepted = (self._stats.accepted or 0) + 1
	self.touched:Fire(event)
	return true, nil, event
end

function Server.setEnabled(self: Server, id: string, enabled: boolean)
	self._enabled[id] = if enabled then nil else false
	if not enabled then
		self._users[id] = nil
		for _, holds in self._holds do
			holds[id] = nil
		end
	end
end

-- Seconds until player may use id again (0 when ready).
function Server.remaining(self: Server, player: any, id: string): number
	local now = self._env.clock()
	local own = self._cooldowns[cooldownKey(player, id)] or 0
	local shared = self._shared[id] or 0
	return math.max(0, own - now, shared - now)
end

-- Drops a player's holds, rate bucket and exclusive locks (PlayerRemoving).
function Server.forget(self: Server, player: any)
	self._holds[player] = nil
	self._buckets[player] = nil
	for id, user in self._users do
		if user == player then
			self._users[id] = nil
		end
	end
	local prefix = tostring(player) .. "|"
	for key in self._cooldowns do
		if string.sub(key, 1, #prefix) == prefix then
			self._cooldowns[key] = nil
		end
	end
end

-- Counts of accepted requests and of each refusal reason.
function Server.stats(self: Server): { [string]: number }
	return table.clone(self._stats)
end

function Server.destroy(self: Server)
	self.triggered:Destroy()
	self.touched:Destroy()
end

return Interact
