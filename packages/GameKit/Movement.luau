--!strict
-- @tier T0
-- Movement: movement abilities as data on top of the engine's character physics: sprint (with
-- an optional stamina pool), jump with coyote time, a jump buffer and air jumps (double jump),
-- dash (charges, air dashes, cooldown, cost), slide (speed decay, jump cancel) and ledge
-- rules (height band, reach, approach angle: only climb a ledge you are moving towards).
--   * The controller decides; the adapter applies. step() returns the walk speed to set, an
--     override velocity while dashing or sliding, and events (jump with its launch velocity,
--     land, dash, slide, climb). Input arrives as setInput(move, sprint) from IAS actions in
--     MovementRoblox; grounded comes from the Humanoid. step never yields (BindToSimulation).
--   * Requests are untrusted: request("dash", direction) refuses with a reason (busy,
--     cooldown, no_air_dash, bad_direction, cost, ...) and changes nothing.
--   * checkTravel/watcher are the server's teleport and speed check: a body may not cover more
--     ground than the fastest move allows (plus a tolerance), nor rise faster than a jump or a
--     ledge climb. The watcher keeps the last accepted position to rubber-band to.
-- Engine defaults (WalkSpeed 16, JumpHeight 7.2, Gravity 196.2) are the defaults here; every
-- other number is the game's. Coyote time, jump buffer and travel tolerances are conventions.
local Check = require("./Check")
local Fsm = require("./Fsm")
local Signal = require("./Signal")
local Vec = require("../SceneKit/Vec")

local Movement = {}
Movement.WALK_SPEED = 16 -- Humanoid.WalkSpeed default
Movement.JUMP_HEIGHT = 7.2 -- Humanoid.JumpHeight default
Movement.GRAVITY = 196.2 -- Workspace.Gravity default
Movement.COYOTE_TIME = 0.1 -- seconds (convention)
Movement.JUMP_BUFFER = 0.1 -- seconds (convention)
Movement.TOLERANCE = 1.25 -- travel check speed multiplier (convention)
Movement.SLACK = 2 -- travel check studs of slack per observation (convention)
Movement.MAX_SPEED = 1000
-- After a jump the Humanoid can still report the floor for a frame; landing waits until it has
-- reported leaving the ground once, or this long (a jump blocked by a ceiling). Convention.
Movement.TAKEOFF_GRACE = 0.2

export type V3 = Vec.V3
export type Definition = {
	walkSpeed: number?,
	gravity: number?,
	sprint: { multiplier: number, pool: string?, drain: number?, minToStart: number? }?,
	jump: { height: number?, airJumps: number?, airJumpHeight: number?, coyoteTime: number?, buffer: number? }?,
	dash: {
		distance: number,
		duration: number,
		cooldown: number?,
		charges: number?,
		airDashes: number?,
		cost: { pool: string, amount: number }?,
	}?,
	slide: {
		speed: number,
		duration: number,
		minSpeed: number?,
		friction: number?,
		cooldown: number?,
		jumpCancel: boolean?,
	}?,
	ledge: { minHeight: number, maxHeight: number, maxDistance: number, maxAngle: number?, climbTime: number }?,
}
export type Spec = {
	walkSpeed: number,
	gravity: number,
	sprint: any?,
	jump: any,
	dash: any?,
	slide: any?,
	ledge: any?,
	jumpVelocity: number,
	airJumpVelocity: number,
}
export type Event = { kind: string, t: number, [string]: any }
export type Output = { mode: string, walkSpeed: number, velocity: V3?, events: { Event } }
export type Probe = { height: number, distance: number, normal: V3 }

local function within(value: any, lo: number, hi: number): boolean
	return Check.finite(value) and value >= lo and value <= hi
end

-- Problems with a definition (empty when valid).
function Movement.validate(def: any): { string }
	if type(def) ~= "table" then
		return { "definition must be a table" }
	end
	local problems = {}
	local function need(ok: boolean, message: string)
		if not ok then
			table.insert(problems, message)
		end
	end
	need(
		def.walkSpeed == nil or (within(def.walkSpeed, 0, Movement.MAX_SPEED) and def.walkSpeed > 0),
		"walkSpeed must be in (0, 1000]"
	)
	need(
		def.gravity == nil or (Check.finite(def.gravity) and def.gravity > 0),
		"gravity must be a finite number > 0"
	)
	local sprint = def.sprint
	if sprint ~= nil then
		if type(sprint) ~= "table" then
			table.insert(problems, "sprint must be a table")
		else
			need(
				within(sprint.multiplier, 1, 10) and sprint.multiplier > 1,
				"sprint.multiplier must be in (1, 10]"
			)
			need(sprint.pool == nil or Check.label(sprint.pool), "sprint.pool must be a label")
			need(sprint.drain == nil or within(sprint.drain, 0, 1e6), "sprint.drain must be >= 0 per second")
			need(
				sprint.minToStart == nil or within(sprint.minToStart, 0, 1e6),
				"sprint.minToStart must be >= 0"
			)
			need(
				(sprint.drain == nil and sprint.minToStart == nil) or sprint.pool ~= nil,
				"sprint.drain and minToStart need sprint.pool"
			)
		end
	end
	local jump = def.jump
	if jump ~= nil then
		if type(jump) ~= "table" then
			table.insert(problems, "jump must be a table")
		else
			need(jump.height == nil or within(jump.height, 0, 1000), "jump.height must be 0-1000 studs")
			need(
				jump.airJumpHeight == nil or within(jump.airJumpHeight, 0, 1000),
				"jump.airJumpHeight must be 0-1000 studs"
			)
			need(
				jump.airJumps == nil
					or (Check.integer(jump.airJumps) and jump.airJumps >= 0 and jump.airJumps <= 10),
				"jump.airJumps must be an integer 0-10"
			)
			need(
				jump.coyoteTime == nil or within(jump.coyoteTime, 0, 1),
				"jump.coyoteTime must be 0-1 seconds"
			)
			need(jump.buffer == nil or within(jump.buffer, 0, 1), "jump.buffer must be 0-1 seconds")
		end
	end
	local dash = def.dash
	if dash ~= nil then
		if type(dash) ~= "table" then
			table.insert(problems, "dash must be a table")
		else
			need(within(dash.distance, 0, 1000) and dash.distance > 0, "dash.distance must be in (0, 1000]")
			need(within(dash.duration, 0, 2) and dash.duration > 0, "dash.duration must be in (0, 2]")
			need(
				dash.cooldown == nil or within(dash.cooldown, 0, 3600),
				"dash.cooldown must be 0-3600 seconds"
			)
			need(
				dash.charges == nil
					or (Check.integer(dash.charges) and dash.charges >= 1 and dash.charges <= 9),
				"dash.charges must be an integer 1-9"
			)
			need(
				dash.airDashes == nil
					or (Check.integer(dash.airDashes) and dash.airDashes >= 0 and dash.airDashes <= 9),
				"dash.airDashes must be an integer 0-9"
			)
			if dash.cost ~= nil then
				need(
					type(dash.cost) == "table"
						and Check.label(dash.cost.pool)
						and within(dash.cost.amount, 0, 1e6),
					"dash.cost must be { pool, amount >= 0 }"
				)
			end
			if Check.finite(dash.distance) and Check.finite(dash.duration) and dash.duration > 0 then
				need(
					dash.distance / dash.duration <= Movement.MAX_SPEED,
					"dash speed (distance / duration) must be <= 1000"
				)
			end
		end
	end
	local slide = def.slide
	if slide ~= nil then
		if type(slide) ~= "table" then
			table.insert(problems, "slide must be a table")
		else
			need(
				within(slide.speed, 0, Movement.MAX_SPEED) and slide.speed > 0,
				"slide.speed must be in (0, 1000]"
			)
			need(within(slide.duration, 0, 5) and slide.duration > 0, "slide.duration must be in (0, 5]")
			need(
				slide.minSpeed == nil or within(slide.minSpeed, 0, Movement.MAX_SPEED),
				"slide.minSpeed must be 0-1000"
			)
			need(
				slide.friction == nil or within(slide.friction, 0, 1e4),
				"slide.friction must be >= 0 (studs/s^2)"
			)
			need(
				slide.cooldown == nil or within(slide.cooldown, 0, 3600),
				"slide.cooldown must be 0-3600 seconds"
			)
			need(
				slide.jumpCancel == nil or type(slide.jumpCancel) == "boolean",
				"slide.jumpCancel must be a boolean"
			)
		end
	end
	local ledge = def.ledge
	if ledge ~= nil then
		if type(ledge) ~= "table" then
			table.insert(problems, "ledge must be a table")
		else
			need(within(ledge.minHeight, 0, 1000), "ledge.minHeight must be 0-1000 studs")
			need(
				within(ledge.maxHeight, 0, 1000)
					and Check.finite(ledge.minHeight)
					and ledge.maxHeight > ledge.minHeight,
				"ledge.maxHeight must be above minHeight"
			)
			need(
				within(ledge.maxDistance, 0, 100) and ledge.maxDistance > 0,
				"ledge.maxDistance must be in (0, 100]"
			)
			need(
				ledge.maxAngle == nil or within(ledge.maxAngle, 0, 90),
				"ledge.maxAngle must be 0-90 degrees"
			)
			need(within(ledge.climbTime, 0, 10) and ledge.climbTime > 0, "ledge.climbTime must be in (0, 10]")
		end
	end
	return problems
end

function Movement.define(def: Definition): Spec
	local problems = Movement.validate(def)
	if #problems > 0 then
		error("Movement.define: " .. table.concat(problems, "; "), 2)
	end
	local gravity = def.gravity or Movement.GRAVITY
	local jump = def.jump or {}
	local height = jump.height or Movement.JUMP_HEIGHT
	local airHeight = jump.airJumpHeight or height
	return Check.freeze({
		walkSpeed = def.walkSpeed or Movement.WALK_SPEED,
		gravity = gravity,
		sprint = def.sprint and Check.copy(def.sprint),
		jump = {
			height = height,
			airJumps = jump.airJumps or 0,
			coyoteTime = jump.coyoteTime or Movement.COYOTE_TIME,
			buffer = jump.buffer or Movement.JUMP_BUFFER,
		},
		dash = def.dash and Check.copy(def.dash),
		slide = def.slide and Check.copy(def.slide),
		ledge = def.ledge and Check.copy(def.ledge),
		jumpVelocity = math.sqrt(2 * gravity * height),
		airJumpVelocity = math.sqrt(2 * gravity * airHeight),
	}) :: Spec
end

-- The fastest horizontal speed and rise rate any move in spec allows (for travel checks).
function Movement.limits(spec: Spec): { horizontal: number, rise: number }
	local horizontal = spec.walkSpeed * (if spec.sprint then spec.sprint.multiplier else 1)
	if spec.dash then
		horizontal = math.max(horizontal, spec.dash.distance / spec.dash.duration)
	end
	if spec.slide then
		horizontal = math.max(horizontal, spec.slide.speed)
	end
	local rise = math.max(spec.jumpVelocity, spec.airJumpVelocity)
	if spec.ledge then
		rise = math.max(rise, spec.ledge.maxHeight / spec.ledge.climbTime)
	end
	return { horizontal = horizontal, rise = rise }
end

-- Whether moving from -> to in dt seconds is possible within limits. (ok, reason?, detail) with
-- bad_input, teleport (horizontal) or fly (rising too fast). Falling is never limited.
function Movement.checkTravel(
	limits: { horizontal: number, rise: number },
	from: any,
	to: any,
	dt: number,
	options: { tolerance: number?, slack: number? }?
): (boolean, string?, { [string]: number })
	local detail = {}
	local function vec(value: any): boolean
		return type(value) == "table"
			and Check.finite(value.x)
			and Check.finite(value.y)
			and Check.finite(value.z)
	end
	if not vec(from) or not vec(to) or not Check.finite(dt) or dt < 0 then
		return false, "bad_input", detail
	end
	local tolerance = (options and options.tolerance) or Movement.TOLERANCE
	local slack = (options and options.slack) or Movement.SLACK
	local dx, dz = to.x - from.x, to.z - from.z
	local horizontal = math.sqrt(dx * dx + dz * dz)
	local rise = to.y - from.y
	detail.horizontal = horizontal
	detail.allowed = limits.horizontal * tolerance * dt + slack
	if horizontal > detail.allowed then
		return false, "teleport", detail
	end
	detail.rise = rise
	detail.allowedRise = limits.rise * tolerance * dt + slack
	if rise > detail.allowedRise then
		return false, "fly", detail
	end
	return true, nil, detail
end

-- ---------------------------------------------------------------- watcher (server)

local Watcher = {}
Watcher.__index = Watcher

type Track = { position: V3, at: number, strikes: number }
type WatcherFields = {
	limits: { horizontal: number, rise: number },
	_env: any,
	_options: { tolerance: number?, slack: number? },
	_tracks: { [any]: Track },
}
export type Watcher = typeof(setmetatable({} :: WatcherFields, Watcher))

function Movement.watcher(spec: Spec, options: { tolerance: number?, slack: number? }?, env: any): Watcher
	assert(type(env) == "table" and type(env.clock) == "function", "Movement.watcher needs env.clock")
	return setmetatable(
		{ limits = Movement.limits(spec), _env = env, _options = options or {}, _tracks = {} },
		Watcher
	)
end

-- Checks a server-observed position. (ok, reason?, detail); on a refusal detail.resetTo is the
-- last accepted position (rubber-band there) and detail.strikes counts refusals in a row.
function Watcher.observe(self: Watcher, id: any, position: any): (boolean, string?, { [string]: any })
	local now = self._env.clock()
	local track = self._tracks[id]
	if track == nil then
		if
			type(position) ~= "table"
			or not (Check.finite(position.x) and Check.finite(position.y) and Check.finite(position.z))
		then
			return false, "bad_input", {}
		end
		self._tracks[id] = { position = Vec.new(position.x, position.y, position.z), at = now, strikes = 0 }
		return true, nil, {}
	end
	local t = track :: Track
	local ok, reason, detail =
		Movement.checkTravel(self.limits, t.position, position, now - t.at, self._options)
	local out: { [string]: any } = detail
	if ok then
		t.position = Vec.new(position.x, position.y, position.z)
		t.at = now
		t.strikes = 0
	else
		t.strikes += 1
		out.resetTo = Vec.new(t.position.x, t.position.y, t.position.z)
		out.strikes = t.strikes
	end
	return ok, reason, out
end

-- A server-granted teleport (spawn, checkpoint): accept the new position without a check.
function Watcher.teleport(self: Watcher, id: any, position: V3)
	self._tracks[id] =
		{ position = Vec.new(position.x, position.y, position.z), at = self._env.clock(), strikes = 0 }
end

function Watcher.forget(self: Watcher, id: any)
	self._tracks[id] = nil
end

-- ---------------------------------------------------------------- controller

local MODES = Fsm.define({
	name = "move",
	initial = "ground",
	states = { ground = {}, air = {}, dash = {}, slide = {}, climb = {} },
	transitions = {
		{ from = "ground", event = "to_air", to = "air" },
		{ from = "dash", event = "to_air", to = "air" },
		{ from = "slide", event = "to_air", to = "air" },
		{ from = "air", event = "to_ground", to = "ground" },
		{ from = "dash", event = "to_ground", to = "ground" },
		{ from = "slide", event = "to_ground", to = "ground" },
		{ from = "climb", event = "to_ground", to = "ground" },
		{ from = "ground", event = "to_dash", to = "dash" },
		{ from = "air", event = "to_dash", to = "dash" },
		{ from = "slide", event = "to_dash", to = "dash" },
		{ from = "ground", event = "to_slide", to = "slide" },
		{ from = "ground", event = "to_climb", to = "climb" },
		{ from = "air", event = "to_climb", to = "climb" },
		{ from = "*", event = "reset", to = "ground" },
	},
})

local Controller = {}
Controller.__index = Controller

type Fields = {
	spec: Spec,
	changed: Signal.Signal,
	_env: any,
	_vitals: any?,
	_cooldowns: any?,
	_machine: any,
	_move: V3,
	_sprintHeld: boolean,
	_sprinting: boolean,
	_exhausted: boolean,
	_drainCarry: number,
	_grounded: boolean,
	_leftGroundAt: number,
	_jumpedSinceGround: boolean,
	_takeoffAt: number?,
	_airJumps: number,
	_airDashes: number,
	_bufferedAt: number?,
	_velocity: V3?,
	_endsAt: number,
	_slideStart: number,
	_lastStep: number,
	_pending: { Event },
}
export type Controller = typeof(setmetatable({} :: Fields, Controller))

function Movement.new(spec: Spec, options: { vitals: any?, cooldowns: any? }?, env: any): Controller
	assert(
		type(spec) == "table" and table.isfrozen(spec) and spec.jumpVelocity,
		"Movement.new needs a spec from Movement.define"
	)
	assert(type(env) == "table" and type(env.clock) == "function", "Movement.new needs env.clock")
	local opts = options or {}
	if spec.dash and (spec.dash.cooldown or 0) > 0 or spec.slide and (spec.slide.cooldown or 0) > 0 then
		assert(opts.cooldowns, "Movement.new: dash or slide cooldowns need options.cooldowns")
	end
	if (spec.sprint and spec.sprint.pool) or (spec.dash and spec.dash.cost) then
		assert(opts.vitals, "Movement.new: sprint pools and dash costs need options.vitals")
	end
	local now = env.clock()
	return setmetatable({
		spec = spec,
		changed = Signal.new(env),
		_env = env,
		_vitals = opts.vitals,
		_cooldowns = opts.cooldowns,
		_machine = Fsm.new(MODES, nil, env),
		_move = Vec.new(0, 0, 0),
		_sprintHeld = false,
		_sprinting = false,
		_exhausted = false,
		_drainCarry = 0,
		_grounded = true,
		_leftGroundAt = now,
		_jumpedSinceGround = false,
		_takeoffAt = nil,
		_airJumps = spec.jump.airJumps,
		_airDashes = if spec.dash then spec.dash.airDashes or 1 else 0,
		_bufferedAt = nil,
		_velocity = nil,
		_endsAt = 0,
		_slideStart = 0,
		_lastStep = now,
		_pending = {},
	}, Controller)
end

function Controller.mode(self: Controller): string
	return self._machine:state()
end

function Controller.serialize(self: Controller): string
	return self._machine:serialize()
end

function Controller.sprinting(self: Controller): boolean
	return self._sprinting
end

local function push(self: Controller, event: Event)
	table.insert(self._pending, event)
end

local function go(self: Controller, mode: string)
	if self:mode() ~= mode then
		local from = self:mode()
		self._machine:send("to_" .. mode)
		self.changed:Fire(mode, from)
	end
end

-- Movement input from the adapter: a direction (horizontal; clamped to length 1; non-finite is
-- zero) and whether sprint is held.
function Controller.setInput(self: Controller, move: any, sprint: any)
	local x, z = 0, 0
	if type(move) == "table" and Check.finite(move.x) and Check.finite(move.z) then
		x, z = move.x, move.z
	end
	local length = math.sqrt(x * x + z * z)
	if length > 1 then
		x, z = x / length, z / length
	end
	self._move = Vec.new(x, 0, z)
	self._sprintHeld = sprint == true
end

function Controller.setGrounded(self: Controller, grounded: boolean)
	self._grounded = grounded == true
	if not self._grounded then
		self._takeoffAt = nil
	end
end

local function landed(self: Controller, now: number)
	self._airJumps = self.spec.jump.airJumps
	self._airDashes = if self.spec.dash then self.spec.dash.airDashes or 1 else 0
	self._jumpedSinceGround = false
	push(self, { kind = "land", t = now })
end

local function doJump(self: Controller, now: number, air: boolean)
	local velocity = if air then self.spec.airJumpVelocity else self.spec.jumpVelocity
	self._jumpedSinceGround = true
	self._bufferedAt = nil
	self._velocity = nil
	self._takeoffAt = if self._grounded then now else nil
	go(self, "air")
	push(self, { kind = "jump", t = now, air = air, velocity = velocity })
end

local function horizontalSpeed(self: Controller): number
	local moving = Vec.length(self._move)
	local base = self.spec.walkSpeed * (if self._sprinting then (self.spec.sprint :: any).multiplier else 1)
	return base * moving
end

local function jump(self: Controller, now: number): (boolean, string?)
	local mode = self:mode()
	local spec = self.spec
	if mode == "ground" then
		doJump(self, now, false)
		return true, nil
	elseif mode == "slide" then
		if spec.slide.jumpCancel == false then
			return false, "busy"
		end
		push(self, { kind = "slide_end", t = now, reason = "jump" })
		doJump(self, now, false)
		return true, nil
	elseif mode == "air" then
		if not self._jumpedSinceGround and now - self._leftGroundAt <= spec.jump.coyoteTime + 1e-9 then
			doJump(self, now, false)
			return true, nil
		end
		if self._airJumps > 0 then
			self._airJumps -= 1
			doJump(self, now, true)
			return true, nil
		end
		if spec.jump.buffer > 0 then
			self._bufferedAt = now
			return true, "buffered"
		end
		return false, "no_jumps"
	end
	return false, "busy"
end

local function dash(self: Controller, now: number, direction: any): (boolean, string?)
	local def = self.spec.dash
	if def == nil then
		return false, "disabled"
	end
	local mode = self:mode()
	if mode == "dash" or mode == "climb" then
		return false, "busy"
	end
	local dir = direction
	if dir == nil then
		dir = self._move
	end
	if type(dir) ~= "table" or not Check.finite(dir.x) or not Check.finite(dir.z) then
		return false, "bad_direction"
	end
	local length = math.sqrt(dir.x * dir.x + dir.z * dir.z)
	if length < 1e-6 then
		return false, "bad_direction"
	end
	local airborne = mode == "air"
	if airborne and self._airDashes <= 0 then
		return false, "no_air_dash"
	end
	local cooldown = def.cooldown or 0
	if cooldown > 0 and not self._cooldowns:ready("move:dash") then
		return false, "cooldown"
	end
	if def.cost and not self._vitals:canSpend(def.cost.pool, def.cost.amount) then
		return false, "cost"
	end
	if def.cost then
		self._vitals:spend(def.cost.pool, def.cost.amount)
	end
	if cooldown > 0 then
		self._cooldowns:use("move:dash", cooldown, def.charges)
	end
	if airborne then
		self._airDashes -= 1
	end
	if mode == "slide" then
		push(self, { kind = "slide_end", t = now, reason = "dash" })
	end
	local speed = def.distance / def.duration
	self._velocity = Vec.new(dir.x / length * speed, 0, dir.z / length * speed)
	self._endsAt = now + def.duration
	go(self, "dash")
	push(self, { kind = "dash_start", t = now, velocity = self._velocity, duration = def.duration })
	return true, nil
end

local function slide(self: Controller, now: number): (boolean, string?)
	local def = self.spec.slide
	if def == nil then
		return false, "disabled"
	end
	if self:mode() ~= "ground" or not self._grounded then
		return false, "busy"
	end
	local speed = horizontalSpeed(self)
	if speed < 1e-6 or speed < (def.minSpeed or self.spec.walkSpeed) - 1e-9 then
		return false, "too_slow"
	end
	local cooldown = def.cooldown or 0
	if cooldown > 0 then
		if not self._cooldowns:ready("move:slide") then
			return false, "cooldown"
		end
		self._cooldowns:use("move:slide", cooldown)
	end
	local dir = Vec.unit(self._move)
	self._velocity = Vec.scale(dir, def.speed)
	self._slideStart = now
	self._endsAt = now + def.duration
	go(self, "slide")
	push(self, { kind = "slide_start", t = now, velocity = self._velocity })
	return true, nil
end

local function ledge(self: Controller, now: number, probe: any): (boolean, string?)
	local def = self.spec.ledge
	if def == nil then
		return false, "disabled"
	end
	local mode = self:mode()
	if mode ~= "ground" and mode ~= "air" then
		return false, "busy"
	end
	if
		type(probe) ~= "table"
		or not Check.finite(probe.height)
		or not Check.finite(probe.distance)
		or type(probe.normal) ~= "table"
		or not Check.finite(probe.normal.x)
		or not Check.finite(probe.normal.z)
	then
		return false, "bad_probe"
	end
	if probe.height < def.minHeight then
		return false, "too_low"
	end
	if probe.height > def.maxHeight then
		return false, "too_high"
	end
	if probe.distance < 0 or probe.distance > def.maxDistance then
		return false, "too_far"
	end
	local nx, nz = probe.normal.x, probe.normal.z
	local nl = math.sqrt(nx * nx + nz * nz)
	local ml = Vec.length(self._move)
	if nl < 1e-6 or ml < 1e-6 then
		return false, "not_facing"
	end
	-- Moving into the wall: the move direction against the wall normal, within maxAngle.
	local cosine = -(self._move.x * nx + self._move.z * nz) / (nl * ml)
	if cosine < math.cos(math.rad(def.maxAngle or 45)) - 1e-9 then
		return false, "not_facing"
	end
	self._velocity = nil
	self._endsAt = now + def.climbTime
	go(self, "climb")
	push(self, { kind = "climb_start", t = now, height = probe.height, duration = def.climbTime })
	return true, nil
end

-- A movement request: "jump", "dash" (direction?), "slide" or "ledge" (probe { height,
-- distance, normal } from the adapter's raycasts). (ok, reason?); (true, "buffered") for a jump
-- held until landing.
function Controller.request(self: Controller, action: any, arg: any?): (boolean, string?)
	local now = self._env.clock()
	if action == "jump" then
		return jump(self, now)
	elseif action == "dash" then
		return dash(self, now, arg)
	elseif action == "slide" then
		return slide(self, now)
	elseif action == "ledge" then
		return ledge(self, now, arg)
	end
	return false, "unknown_action"
end

-- Advances timers to the env clock and returns what the adapter applies. Never yields.
function Controller.step(self: Controller): Output
	local now = self._env.clock()
	local dt = math.max(0, now - self._lastStep)
	self._lastStep = now
	local spec = self.spec
	local mode = self:mode()

	-- Timed modes end first.
	if mode == "dash" and now + 1e-9 >= self._endsAt then
		push(self, { kind = "dash_end", t = self._endsAt })
		self._velocity = nil
		go(self, if self._grounded then "ground" else "air")
		if not self._grounded then
			self._leftGroundAt = self._endsAt
			self._jumpedSinceGround = true -- no coyote jump after a dash off a ledge
		end
	elseif mode == "slide" then
		if now + 1e-9 >= self._endsAt or not self._grounded then
			push(self, {
				kind = "slide_end",
				t = math.min(now, self._endsAt),
				reason = if self._grounded then "time" else "fell",
			})
			self._velocity = nil
			go(self, if self._grounded then "ground" else "air")
			if not self._grounded then
				self._leftGroundAt = now
			end
		else
			local def = spec.slide :: any
			local speed = math.max(0, def.speed - (def.friction or 0) * (now - self._slideStart))
			self._velocity = Vec.scale(Vec.unit(self._velocity :: V3), speed)
		end
	elseif mode == "climb" and now + 1e-9 >= self._endsAt then
		push(self, { kind = "climb_end", t = self._endsAt })
		go(self, "ground")
		landed(self, self._endsAt)
	end

	-- Ground contact.
	mode = self:mode()
	local takingOff = self._takeoffAt ~= nil and now - (self._takeoffAt :: number) < Movement.TAKEOFF_GRACE
	if mode == "air" and self._grounded and not takingOff then
		self._takeoffAt = nil
		go(self, "ground")
		landed(self, now)
		if self._bufferedAt and now - (self._bufferedAt :: number) <= spec.jump.buffer + 1e-9 then
			doJump(self, now, false)
		end
		self._bufferedAt = nil
	elseif mode == "ground" and not self._grounded then
		go(self, "air")
		self._leftGroundAt = now
	end

	-- Sprint and stamina.
	local sprint = spec.sprint
	local moving = Vec.length(self._move) > 1e-6
	local wants = sprint ~= nil and self._sprintHeld and moving and self:mode() ~= "climb"
	if sprint and sprint.pool then
		local vitals = self._vitals :: any
		if self._exhausted and (vitals:get(sprint.pool) or 0) >= (sprint.minToStart or 0) then
			self._exhausted = false
		end
		if
			wants
			and not self._sprinting
			and (self._exhausted or (vitals:get(sprint.pool) or 0) < (sprint.minToStart or 0))
		then
			wants = false
		end
		if wants and self._sprinting and (sprint.drain or 0) > 0 then
			self._drainCarry += (sprint.drain :: number) * dt
			local whole = math.floor(self._drainCarry + 1e-9)
			if whole >= 1 then
				local ok = vitals:spend(sprint.pool, whole)
				if ok then
					self._drainCarry -= whole
				else
					wants = false
					self._exhausted = true
					self._drainCarry = 0
				end
			end
		end
	end
	if wants ~= self._sprinting then
		self._sprinting = wants
		push(self, { kind = if wants then "sprint_start" else "sprint_end", t = now })
	end

	local walkSpeed = spec.walkSpeed * (if self._sprinting then (sprint :: any).multiplier else 1)
	local velocity = self._velocity
	if velocity then
		walkSpeed = math.max(walkSpeed, Vec.length(velocity :: V3))
	end
	local events = self._pending
	self._pending = {}
	return { mode = self:mode(), walkSpeed = walkSpeed, velocity = velocity, events = events }
end

-- The horizontal speed the controller allows right now (for per-player server checks).
function Controller.maxSpeed(self: Controller): number
	local speed = self.spec.walkSpeed * (if self._sprinting then (self.spec.sprint :: any).multiplier else 1)
	if self._velocity then
		speed = math.max(speed, Vec.length(self._velocity :: V3))
	end
	return speed
end

function Controller.reset(self: Controller)
	self._machine:send("reset")
	self._velocity = nil
	self._bufferedAt = nil
	self._sprinting = false
	self._exhausted = false
	self._pending = {}
	landed(self, self._env.clock())
	self._pending = {}
end

function Controller.destroy(self: Controller)
	self.changed:Destroy()
	self._machine.changed:Destroy()
end

return Movement
