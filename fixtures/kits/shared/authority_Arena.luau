--!strict
-- G2 authority fixture core (ModuleScript ReplicatedStorage.KitFixtures.authority_Arena): a
-- neutral, server-authoritative test arena composed from the action kit. The Studio fixture
-- (server/authority_Sim.server.luau + client/authority_Input.client.luau) drives it with real
-- players; tests/gamekit_slices_action.spec.luau (slice round_arena) and
-- tests/gamekit_action_authority.spec.luau drive it with seeded bots in Lune. Not game content:
-- bodies are markers, every number in CONFIG is a fixture value (not tuning), names are
-- function names.
--   * Bodies are server-owned kinematic markers. Clients only send input (move direction,
--     sprint, dash) and hit claims; the server moves bodies in one fixed step.
--   * step(): RoundLoop.tick -> Movement controllers move active bodies (clamped to the floor)
--     -> Vitals regen -> the Hitbox validator records poses (the rewind history) -> the Zones
--     tracker reports hazard ticks and kill volumes, applied through Vitals -> RoundLoop.tick
--     again so a last-standing round ends in the same step.
--   * claim(): rate of fire through Cooldowns ("primary"), then Hitbox.validator (rewind at
--     most 200 ms, origin, range, angle, hit point, target alive). Accepted claims damage the
--     target through Vitals with a source record; a lethal hit eliminates it from the round.
--   * input(): a token bucket per body (rate_limited), malformed payloads refused (bad_input),
--     move vectors longer than 1 clamped and counted (a speed hack gains nothing).
-- No requires: kit modules come from the loader given to new (like ctx.kit in probes).
local Arena = {}
Arena.__index = Arena

-- Fixture values (not tuning). Distances in studs, times in seconds.
Arena.CONFIG = table.freeze({
	half = 32, -- the floor is 2 * half square, centred on origin
	bodyHeight = 2.5, -- body centre above the floor
	bodyRadius = 1,
	bodyHalf = 1.5, -- half length of the body capsule's segment
	spawnRadius = 20,
	health = 100,
	stamina = 100,
	staminaRegen = 20,
	primaryDamage = 20,
	primaryCooldown = 0.25,
	primaryRange = 60,
	maxAngle = 10, -- degrees between the aim and the claimed hit point
	inputRate = 60, -- inputs per second per body
	inputBurst = 10,
	maxBodies = 32,
	maxStep = 0.1, -- a longer gap between steps is integrated as this much
	durations = table.freeze({ intermission = 3, active = 60, results = 3 }),
	minPlayers = 1,
})

-- Raw IAS actions the client fixture builds (AuthorityRoblox.buildActions; G4's InputMap
-- replaces this raw build after merge). Names are functions, bindings are defaults.
Arena.ACTIONS = table.freeze({
	context = "SETUP_ONLY_Authority",
	priority = 1,
	actions = {
		{
			name = "gameplay.move",
			type = "Direction2D",
			bindings = { { up = "W", down = "S", left = "A", right = "D" }, { keyCode = "Thumbstick1" } },
		},
		{
			name = "gameplay.sprint",
			type = "Bool",
			bindings = { { keyCode = "LeftShift" }, { keyCode = "ButtonL3" } },
		},
		{ name = "gameplay.dash", type = "Bool", bindings = { { keyCode = "Q" }, { keyCode = "ButtonB" } } },
		{
			name = "gameplay.primary",
			type = "Bool",
			bindings = { { keyCode = "MouseLeftButton" }, { keyCode = "ButtonR2" } },
		},
	},
})

export type V3 = { x: number, y: number, z: number }
export type Options = {
	seed: (number | string)?,
	origin: V3?,
	durations: { intermission: number?, active: number?, results: number? }?,
	minPlayers: number?,
	endOnAlive: number?, -- end the active phase when this many or fewer bodies are left
	lineOfSight: ((origin: V3, point: V3, claim: any) -> boolean)?,
}

type Body = {
	id: any,
	key: string,
	vitals: any,
	cooldowns: any,
	controller: any,
	position: V3,
	facing: V3,
	move: V3,
	sprint: boolean,
	wantsDash: boolean,
	active: boolean,
	latency: number,
	tokens: number,
	tokensAt: number,
	seq: number,
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validId(id: any): boolean
	if type(id) == "number" then
		return finite(id) and id == math.floor(id)
	end
	return type(id) == "string" and string.match(id, "^[%w_]+$") ~= nil and #id <= 64
end

local function round3(value: number): number
	return math.floor(value * 1000 + 0.5) / 1000
end

local function count(map: { [string]: number }, key: string)
	map[key] = (map[key] or 0) + 1
end

-- kit(path) returns a kit module ("GameKit/Vitals"); env is a GameKit Env.
function Arena.new(kit: (path: string) -> any, env: any, options: Options?): any
	assert(type(kit) == "function", "Arena.new needs a kit loader")
	assert(type(env) == "table" and type(env.clock) == "function", "Arena.new needs an env")
	local opts: Options = options or {}
	local config = Arena.CONFIG
	local Vec = kit("SceneKit/Vec")
	local Hitbox = kit("GameKit/Hitbox")
	local Zones = kit("GameKit/Zones")
	local origin: V3 = opts.origin or Vec.new(0, 0, 0)
	local durations = opts.durations or config.durations
	local self: any = setmetatable({}, Arena)
	self._kit = {
		Vec = Vec,
		Hitbox = Hitbox,
		Zones = Zones,
		Vitals = kit("GameKit/Vitals"),
		Cooldowns = kit("GameKit/Cooldowns"),
		Movement = kit("GameKit/Movement"),
	}
	self._env = env
	self._rng = env.rng(opts.seed or 0)
	self.origin = origin
	self.loop = kit("GameKit/RoundLoop").new(
		kit("GameKit/RoundLoop").define({
			durations = {
				intermission = durations.intermission,
				active = durations.active,
				results = durations.results,
			},
			minPlayers = opts.minPlayers or config.minPlayers,
			maxPlayers = config.maxBodies,
			lateJoin = "spectate",
			endOnAlive = opts.endOnAlive,
		}),
		nil,
		env
	)
	local centre = origin.y + config.bodyHeight
	self.zones = Zones.define({
		{ id = "centre", kind = "area", shape = Zones.sphere(Vec.new(origin.x, centre, origin.z), 6) },
		{
			id = "hazard_pad",
			kind = "hazard",
			shape = Zones.box(Vec.new(origin.x + 14, centre, origin.z), Vec.new(8, 6, 8)),
			hazard = { amount = 5, interval = 0.5, damageKind = "hazard" },
		},
		{
			id = "pit",
			kind = "kill",
			shape = Zones.box(Vec.new(origin.x - 14, centre, origin.z + 6), Vec.new(6, 6, 6)),
		},
	})
	self.tracker = Zones.tracker(self.zones, { maxBodies = config.maxBodies }, env)
	self._bodies = {} :: { [string]: Body }
	self._order = {} :: { string }
	self.validator = Hitbox.validator({
		maxRange = config.primaryRange,
		maxRewind = Hitbox.MAX_REWIND,
		maxAngle = config.maxAngle,
		lineOfSight = opts.lineOfSight,
		alive = function(id: any): boolean
			local body = self._bodies[tostring(id)]
			return body ~= nil and body.active
		end,
	}, env)
	self._vitalsSpec = self._kit.Vitals.define({
		pools = {
			health = { max = config.health },
			stamina = { max = config.stamina, regen = config.staminaRegen, regenDelay = 1 },
		},
	})
	self._moveSpec = self._kit.Movement.define({
		sprint = { multiplier = 1.5, pool = "stamina", drain = 25, minToStart = 10 },
		dash = { distance = 12, duration = 0.2, cooldown = 1.5 },
	})
	self._last = env.clock()
	self._pending = {}
	self._stats = {
		inputs = 0,
		clamped = 0,
		inputRejected = {} :: { [string]: number },
		accepted = 0,
		claimRejected = {} :: { [string]: number },
		deaths = 0,
	}
	return self
end

local function log(self: any, event: { [string]: any })
	event.t = round3(self._env.clock())
	table.insert(self._pending, event)
end

local function capsule(self: any, position: V3): any
	local Vec = self._kit.Vec
	local half = Arena.CONFIG.bodyHalf
	return self._kit.Hitbox.capsule(
		Vec.add(position, Vec.new(0, -half, 0)),
		Vec.add(position, Vec.new(0, half, 0)),
		Arena.CONFIG.bodyRadius
	)
end

local function find(self: any, id: any): Body?
	if not validId(id) then
		return nil
	end
	return self._bodies[tostring(id)]
end

-- Adds a body for id (a UserId or a label). (ok, roleOrReason).
function Arena.join(self: any, id: any): (boolean, string)
	if not validId(id) then
		return false, "bad_id"
	end
	local key = tostring(id)
	if self._bodies[key] then
		return false, "already_joined"
	end
	if #self._order >= Arena.CONFIG.maxBodies then
		return false, "full"
	end
	local ok, role = self.loop:join(id)
	if not ok then
		return false, role
	end
	local env = self._env
	local kit = self._kit
	local vitals = kit.Vitals.new(self._vitalsSpec, { seed = key }, env)
	local cooldowns = kit.Cooldowns.new(env)
	local body: Body = {
		id = id,
		key = key,
		vitals = vitals,
		cooldowns = cooldowns,
		controller = kit.Movement.new(self._moveSpec, { vitals = vitals, cooldowns = cooldowns }, env),
		position = kit.Vec.new(self.origin.x, self.origin.y + Arena.CONFIG.bodyHeight, self.origin.z),
		facing = kit.Vec.new(0, 0, -1),
		move = kit.Vec.new(0, 0, 0),
		sprint = false,
		wantsDash = false,
		active = false,
		latency = 0,
		tokens = Arena.CONFIG.inputBurst,
		tokensAt = env.clock(),
		seq = -1,
	}
	self._bodies[key] = body
	table.insert(self._order, key)
	log(self, { kind = "join", body = key, role = role })
	return true, role
end

-- Removes id's body. (ok, reason?).
function Arena.leave(self: any, id: any): (boolean, string?)
	local body = find(self, id)
	if body == nil then
		return false, "unknown_body"
	end
	local b = body :: Body
	self.loop:leave(b.id)
	self.tracker:remove(b.key)
	self.validator:remove(b.id)
	b.controller:destroy()
	b.vitals:destroy()
	self._bodies[b.key] = nil
	table.remove(self._order, table.find(self._order, b.key) :: number)
	log(self, { kind = "leave", body = b.key })
	return true, nil
end

-- Server-measured one-way latency (seconds) for a body; the validator clamps it to 200 ms.
function Arena.setLatency(self: any, id: any, seconds: number)
	local body = find(self, id)
	if body and finite(seconds) then
		(body :: Body).latency = math.max(0, seconds)
		self.validator:setLatency((body :: Body).id, seconds)
	end
end

-- Untrusted client input { move = { x, z }?, sprint = bool?, dash = bool?, seq = integer? }.
-- (ok, reason?) with unknown_body, rate_limited, bad_input or stale.
function Arena.input(self: any, id: any, payload: any): (boolean, string?)
	local body = find(self, id)
	if body == nil then
		count(self._stats.inputRejected, "unknown_body")
		return false, "unknown_body"
	end
	local b = body :: Body
	local now = self._env.clock()
	-- Tokens first, so malformed spam still spends them.
	local config = Arena.CONFIG
	b.tokens = math.min(config.inputBurst, b.tokens + math.max(0, now - b.tokensAt) * config.inputRate)
	b.tokensAt = now
	if b.tokens < 1 then
		count(self._stats.inputRejected, "rate_limited")
		return false, "rate_limited"
	end
	b.tokens -= 1
	local move = if type(payload) == "table" then payload.move else nil
	if
		type(payload) ~= "table"
		or (move ~= nil and (type(move) ~= "table" or not finite(move.x) or not finite(move.z)))
		or (payload.sprint ~= nil and type(payload.sprint) ~= "boolean")
		or (payload.dash ~= nil and type(payload.dash) ~= "boolean")
		or (
			payload.seq ~= nil
			and (not finite(payload.seq) or payload.seq ~= math.floor(payload.seq) or payload.seq < 0)
		)
	then
		count(self._stats.inputRejected, "bad_input")
		log(self, { kind = "input_rejected", body = b.key, reason = "bad_input" })
		return false, "bad_input"
	end
	-- Each message is a whole input state; with seq, an older one arriving late (unreliable,
	-- reordered remotes) never overrides a newer one.
	if payload.seq ~= nil then
		if payload.seq <= b.seq then
			count(self._stats.inputRejected, "stale")
			return false, "stale"
		end
		b.seq = payload.seq
	end
	self._stats.inputs += 1
	if move ~= nil then
		local x, z = move.x, move.z
		local length = math.sqrt(x * x + z * z)
		if length > 1 + 1e-3 then
			x, z = x / length, z / length
			self._stats.clamped += 1
		end
		b.move = self._kit.Vec.new(x, 0, z)
	end
	if payload.sprint ~= nil then
		b.sprint = payload.sprint
	end
	if payload.dash == true then
		b.wantsDash = true
	end
	return true, nil
end

-- Untrusted hit claim { target, time, origin, direction, hitPoint?, shotId? } from id's client.
-- (ok, reason?, record?) where record is the Vitals damage record of an accepted claim.
function Arena.claim(self: any, id: any, payload: any): (boolean, string?, any?)
	local body = find(self, id)
	local reason: string? = nil
	if body == nil then
		reason = "unknown_body"
	elseif type(payload) ~= "table" then
		reason = "bad_claim"
	elseif self.loop:phase() ~= "active" then
		reason = "not_active"
	elseif not (body :: Body).active then
		reason = "shooter_out"
	end
	local target = if reason == nil then find(self, payload.target) else nil
	if reason == nil and target == nil then
		reason = "unknown_target"
	end
	if reason == nil then
		local fired = (body :: Body).cooldowns:use("primary", Arena.CONFIG.primaryCooldown)
		if not fired then
			reason = "cooldown"
		end
	end
	if reason == nil then
		local b, tb = body :: Body, target :: Body
		local ok, why = self.validator:check({
			shooter = b.id,
			target = tb.id,
			time = payload.time,
			origin = payload.origin,
			direction = payload.direction,
			hitPoint = payload.hitPoint,
			shotId = payload.shotId,
		})
		if ok then
			local record = tb.vitals:damage({
				amount = Arena.CONFIG.primaryDamage,
				kind = "primary",
				source = { attacker = b.id, position = payload.origin },
			})
			self._stats.accepted += 1
			log(self, {
				kind = "hit",
				body = tb.key,
				attacker = b.key,
				applied = record.applied,
				lethal = record.lethal,
			})
			if record.lethal then
				self:_out(tb, b.key, "primary")
			end
			return true, nil, record
		end
		reason = why
	end
	local why = reason :: string
	count(self._stats.claimRejected, why)
	log(self, { kind = "claim_rejected", body = if body then (body :: Body).key else nil, reason = why })
	return false, why, nil
end

-- A body leaves play this round (death, kill volume).
function Arena._out(self: any, body: Body, killer: string?, cause: string)
	if not body.active then
		return
	end
	body.active = false
	self._stats.deaths += 1
	self.loop:eliminate(body.id)
	self.tracker:remove(body.key)
	log(self, { kind = "out", body = body.key, killer = killer, cause = cause })
end

local function zoneEvents(self: any, events: { any })
	for _, event in events do
		local body = self._bodies[tostring(event.body)]
		if body == nil or not body.active then
			continue
		end
		log(self, { kind = event.kind, body = body.key, zone = event.zone })
		if event.kind == "hazard" then
			local record = body.vitals:damage({ amount = event.amount, kind = event.damageKind })
			log(self, { kind = "hazard_damage", body = body.key, applied = record.applied })
			if record.lethal then
				self:_out(body, nil, "hazard")
			end
		elseif event.kind == "kill" then
			body.vitals:kill(nil, "kill_zone")
			self:_out(body, nil, "kill_zone")
		end
	end
end

local function spawn(self: any)
	local Vec = self._kit.Vec
	local alive = self.loop:alive()
	local turn = self._rng:range(0, 2 * math.pi)
	for index, id in alive do
		local body = self._bodies[tostring(id)]
		if body then
			local angle = turn + (index - 1) * 2 * math.pi / math.max(1, #alive)
			body.position = Vec.new(
				self.origin.x + math.cos(angle) * Arena.CONFIG.spawnRadius,
				self.origin.y + Arena.CONFIG.bodyHeight,
				self.origin.z + math.sin(angle) * Arena.CONFIG.spawnRadius
			)
			body.vitals:reset()
			body.controller:reset()
			body.cooldowns:clear()
			body.move = Vec.new(0, 0, 0)
			body.sprint = false
			body.wantsDash = false
			body.active = true
			-- A spawn is a teleport: the rewind history starts again.
			self.validator:remove(body.id)
			self.validator:setLatency(body.id, body.latency)
			self.validator:record(body.id, capsule(self, body.position))
			zoneEvents(self, (self.tracker:update(body.key, body.position)))
			log(self, {
				kind = "spawn",
				body = body.key,
				x = round3(body.position.x - self.origin.x),
				z = round3(body.position.z - self.origin.z),
			})
		end
	end
end

local function phases(self: any, events: { any })
	for _, event in events do
		log(self, { kind = "phase", phase = event.phase, from = event.from, reason = event.reason })
		if event.phase == "active" then
			spawn(self)
		elseif event.from == "active" then
			for _, key in self._order do
				local body = self._bodies[key]
				body.active = false
				self.tracker:remove(key)
			end
		end
	end
end

-- One simulation step at env.clock() (call it from RunService:BindToSimulation). Returns the
-- events since the last step (claims and inputs between steps included). Never yields.
function Arena.step(self: any): { any }
	local env = self._env
	local Vec = self._kit.Vec
	local config = Arena.CONFIG
	local now = env.clock()
	local dt = math.clamp(now - self._last, 0, config.maxStep)
	self._last = now
	phases(self, self.loop:tick(now))
	local limit = config.half - config.bodyRadius
	for _, key in self._order do
		local body = self._bodies[key]
		if not body.active then
			continue
		end
		local controller = body.controller
		controller:setInput(body.move, body.sprint)
		if body.wantsDash then
			body.wantsDash = false
			local direction = if Vec.length(body.move) > 1e-6 then body.move else body.facing
			local ok = controller:request("dash", direction)
			if ok then
				log(self, { kind = "dash", body = key })
			end
		end
		local out = controller:step()
		local velocity = out.velocity or Vec.scale(body.move, out.walkSpeed)
		local x = math.clamp(body.position.x + velocity.x * dt, self.origin.x - limit, self.origin.x + limit)
		local z = math.clamp(body.position.z + velocity.z * dt, self.origin.z - limit, self.origin.z + limit)
		body.position = Vec.new(x, body.position.y, z)
		if Vec.length(body.move) > 1e-6 then
			body.facing = Vec.unit(body.move)
		end
		body.vitals:step(dt)
		self.validator:record(body.id, capsule(self, body.position))
		zoneEvents(self, (self.tracker:update(key, body.position)))
	end
	phases(self, self.loop:tick(now))
	local events = self._pending
	self._pending = {}
	return events
end

-- Server-side teleport of an active body (admin and test setups): clamps to the floor, restarts
-- its rewind history and updates the zone tracker. (ok, reason?).
function Arena.place(self: any, id: any, x: number, z: number): (boolean, string?)
	local body = find(self, id)
	if body == nil then
		return false, "unknown_body"
	end
	local b = body :: Body
	if not b.active then
		return false, "inactive"
	end
	if not finite(x) or not finite(z) then
		return false, "bad_position"
	end
	local limit = Arena.CONFIG.half - Arena.CONFIG.bodyRadius
	b.position = self._kit.Vec.new(
		self.origin.x + math.clamp(x, -limit, limit),
		b.position.y,
		self.origin.z + math.clamp(z, -limit, limit)
	)
	self.validator:remove(b.id)
	self.validator:setLatency(b.id, b.latency)
	self.validator:record(b.id, capsule(self, b.position))
	-- Not a sweep from the old position: the body did not travel the path in between.
	self.tracker:remove(b.key)
	zoneEvents(self, (self.tracker:update(b.key, b.position)))
	return true, nil
end

-- Body ids in join order.
function Arena.bodies(self: any): { any }
	local list = {}
	for _, key in self._order do
		table.insert(list, self._bodies[key].id)
	end
	return list
end

function Arena.position(self: any, id: any): V3?
	local body = find(self, id)
	return if body then (body :: Body).position else nil
end

function Arena.isActive(self: any, id: any): boolean
	local body = find(self, id)
	return body ~= nil and (body :: Body).active
end

-- id's recorded body shape at server time t (what a client with that view saw), or nil.
function Arena.poseAt(self: any, id: any, t: number): any?
	local body = find(self, id)
	if body == nil then
		return nil
	end
	local history = self.validator:history((body :: Body).id)
	return if history then (history :: any):at(t) else nil
end

-- Attributes for the round holder Instance (at most 64; the server fixture writes them).
function Arena.roundAttributes(self: any): { [string]: any }
	local snapshot = self.loop:snapshot(self._env.clock())
	return {
		RoundPhase = snapshot.phase,
		RoundTimeLeft = snapshot.timeLeft,
		RoundNumber = snapshot.round,
		RoundPlayers = snapshot.players,
		RoundAlive = snapshot.alive,
		RoundState = snapshot.state,
		ArenaClock = self._env.clock(),
	}
end

-- Attributes for one body's marker part.
function Arena.bodyAttributes(self: any, id: any): { [string]: any }?
	local body = find(self, id)
	if body == nil then
		return nil
	end
	local b = body :: Body
	return {
		BodyId = b.key,
		Health = (b.vitals:get("health")),
		Stamina = (b.vitals:get("stamina")),
		Active = b.active,
		Mode = b.controller:mode(),
		Sprinting = b.controller:sprinting(),
	}
end

-- Counters: inputs, clamped, inputRejected, accepted, claimRejected, deaths.
function Arena.stats(self: any): { [string]: any }
	local copy = table.clone(self._stats)
	copy.inputRejected = table.clone(self._stats.inputRejected)
	copy.claimRejected = table.clone(self._stats.claimRejected)
	return copy
end

-- A deterministic summary (positions relative to origin, rounded to 1e-3).
function Arena.snapshot(self: any): { [string]: any }
	local bodies = {}
	for _, key in self._order do
		local body = self._bodies[key]
		bodies[key] = {
			x = round3(body.position.x - self.origin.x),
			z = round3(body.position.z - self.origin.z),
			health = (body.vitals:get("health")),
			stamina = (body.vitals:get("stamina")),
			active = body.active,
			role = self.loop:role(body.id),
		}
	end
	return { phase = self.loop:phase(), round = self.loop:round(), bodies = bodies }
end

function Arena.destroy(self: any)
	for _, key in table.clone(self._order) do
		self:leave(self._bodies[key].id)
	end
	self.tracker:destroy()
	self.loop:destroy()
end

return Arena
