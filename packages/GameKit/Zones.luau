--!strict
-- @tier T0
-- Zones: data-defined volumes (AABB, sphere, polygon prism) with exact signed distances,
-- containment with hysteresis, swept crossing tests and a per-body tracker that emits
-- enter/exit events, hazard ticks, kill-volume hits and gate crossings (with direction).
--   * A body enters a zone when its signed distance is <= 0 and leaves only when it is more than
--     `hysteresis` studs outside (default 0.5, a convention), so jitter on a boundary does not
--     flicker. Gates and kill volumes are also swept: a body that passes through between two
--     updates still enters and exits (no tunnelling).
--   * Hazards (`hazard = { amount, interval, damageKind?, immediate? }`) tick on the server clock
--     while a body is inside; kill volumes emit `kill` on entry. The tracker only reports: the
--     caller applies damage through Vitals.
--   * Zones.course() turns gate crossings (`gate = { order, finish?, direction?, minTime? }`) into
--     sectors, laps and a finish, refusing gates out of order, crossed backwards or reached faster
--     than `minTime` after the previous one (teleport and shortcut exploits).
--   * Positions are untrusted (a client may own its character's physics): non-finite ones are
--     refused with a reason, never raised. update/step never yield (BindToSimulation-safe).
--   local set = Zones.define({ { id = "pit", shape = Zones.box(v(0, -5, 0), v(20, 4, 20)), kind = "kill" } })
--   local tracker = Zones.tracker(set, nil, env)
--   for _, event in tracker:update("p1", position) do ... end
local Check = require("./Check")
local Signal = require("./Signal")
local Vec = require("../SceneKit/Vec")

local Zones = {}
Zones.HYSTERESIS = 0.5 -- studs (convention)
Zones.MAX_ZONES = 256
Zones.MAX_BODIES = 1024
Zones.MAX_POINTS = 64
Zones.MAX_EXTENT = 65536 -- studs; sanity bound (convention)
Zones.MAX_TICKS_PER_UPDATE = 8 -- hazard ticks owed after a long gap are capped (convention)
Zones.TIME_EPSILON = 1e-6 -- seconds; summed float steps (10 x 0.1) still reach a tick time
Zones.KINDS = table.freeze({ area = true, hazard = true, kill = true, gate = true })

export type V3 = Vec.V3
export type V2 = { x: number, z: number }
export type Shape = {
	kind: string, -- "aabb" | "sphere" | "prism"
	min: V3?,
	max: V3?,
	center: V3?,
	radius: number?,
	points: { V2 }?,
	minY: number?,
	maxY: number?,
}
export type HazardDef = { amount: number, interval: number, damageKind: string?, immediate: boolean? }
export type GateDef = { order: number, finish: boolean?, direction: V3?, minTime: number? }
export type ZoneDef = {
	id: string,
	shape: Shape,
	kind: string?,
	hysteresis: number?,
	priority: number?,
	tags: { string }?,
	hazard: HazardDef?,
	gate: GateDef?,
	data: any?,
}
export type Zone = {
	id: string,
	shape: Shape,
	kind: string,
	hysteresis: number,
	priority: number,
	tags: { string },
	hazard: HazardDef?,
	gate: GateDef?,
	data: any?,
	swept: boolean,
}
export type Set = { zones: { [string]: Zone }, ids: { string } }
export type Event = {
	kind: string, -- "enter" | "exit" | "hazard" | "kill"
	body: any,
	zone: string,
	t: number,
	forward: boolean?,
	swept: boolean?,
	amount: number?,
	damageKind: string?,
	reason: string?,
}

local function isVec(value: any): boolean
	return type(value) == "table"
		and Check.finite(value.x)
		and Check.finite(value.y)
		and Check.finite(value.z)
end

local function small(value: any): boolean
	return Check.finite(value) and math.abs(value) <= Zones.MAX_EXTENT
end

-- ---------------------------------------------------------------- shapes

function Zones.aabb(min: V3, max: V3): Shape
	return {
		kind = "aabb",
		min = Vec.new(math.min(min.x, max.x), math.min(min.y, max.y), math.min(min.z, max.z)),
		max = Vec.new(math.max(min.x, max.x), math.max(min.y, max.y), math.max(min.z, max.z)),
	}
end

function Zones.box(center: V3, size: V3): Shape
	local h = Vec.scale(size, 0.5)
	return { kind = "aabb", min = Vec.sub(center, h), max = Vec.add(center, h) }
end

function Zones.sphere(center: V3, radius: number): Shape
	return { kind = "sphere", center = Vec.new(center.x, center.y, center.z), radius = radius }
end

-- A vertical prism: a simple polygon in the XZ plane extruded from minY to maxY.
function Zones.prism(points: { V2 }, minY: number, maxY: number): Shape
	local copy = {}
	for index, point in points do
		copy[index] = { x = point.x, z = point.z }
	end
	return { kind = "prism", points = copy, minY = minY, maxY = maxY }
end

local function cross2(ax: number, az: number, bx: number, bz: number): number
	return ax * bz - az * bx
end

-- Proper or touching intersection of segments p1p2 and p3p4 in XZ.
local function segmentsIntersect(p1: V2, p2: V2, p3: V2, p4: V2): boolean
	local d1 = cross2(p4.x - p3.x, p4.z - p3.z, p1.x - p3.x, p1.z - p3.z)
	local d2 = cross2(p4.x - p3.x, p4.z - p3.z, p2.x - p3.x, p2.z - p3.z)
	local d3 = cross2(p2.x - p1.x, p2.z - p1.z, p3.x - p1.x, p3.z - p1.z)
	local d4 = cross2(p2.x - p1.x, p2.z - p1.z, p4.x - p1.x, p4.z - p1.z)
	if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)) then
		return true
	end
	local function onSegment(a: V2, b: V2, p: V2, d: number): boolean
		return d == 0
			and math.min(a.x, b.x) <= p.x
			and p.x <= math.max(a.x, b.x)
			and math.min(a.z, b.z) <= p.z
			and p.z <= math.max(a.z, b.z)
	end
	return onSegment(p3, p4, p1, d1)
		or onSegment(p3, p4, p2, d2)
		or onSegment(p1, p2, p3, d3)
		or onSegment(p1, p2, p4, d4)
end

-- Problems with a shape (empty when valid).
function Zones.validateShape(shape: any): { string }
	if type(shape) ~= "table" then
		return { "shape must be a table" }
	end
	local problems = {}
	if shape.kind == "aabb" then
		if not isVec(shape.min) or not isVec(shape.max) then
			table.insert(problems, "aabb needs finite min and max vectors")
		elseif
			not (small(shape.min.x) and small(shape.min.y) and small(shape.min.z))
			or not (small(shape.max.x) and small(shape.max.y) and small(shape.max.z))
		then
			table.insert(problems, string.format("aabb corners must be within %d studs", Zones.MAX_EXTENT))
		elseif shape.min.x > shape.max.x or shape.min.y > shape.max.y or shape.min.z > shape.max.z then
			table.insert(problems, "aabb min must be <= max on every axis")
		end
	elseif shape.kind == "sphere" then
		if not isVec(shape.center) then
			table.insert(problems, "sphere needs a finite center")
		end
		if not small(shape.radius) or shape.radius <= 0 then
			table.insert(problems, "sphere radius must be a finite number > 0")
		end
	elseif shape.kind == "prism" then
		if not small(shape.minY) or not small(shape.maxY) or shape.minY >= shape.maxY then
			table.insert(problems, "prism needs finite minY < maxY")
		end
		local points = shape.points
		if type(points) ~= "table" or #points < 3 or #points > Zones.MAX_POINTS then
			table.insert(problems, string.format("prism needs 3-%d points", Zones.MAX_POINTS))
			return problems
		end
		for index, point in points do
			if type(point) ~= "table" or not small(point.x) or not small(point.z) then
				table.insert(problems, string.format("prism point %d must have finite x and z", index))
				return problems
			end
		end
		local area = 0
		local n = #points
		for index = 1, n do
			local a, b = points[index], points[index % n + 1]
			area += cross2(a.x, a.z, b.x, b.z)
		end
		if math.abs(area) < 1e-9 then
			table.insert(problems, "prism polygon has no area")
		end
		for i = 1, n do
			for j = i + 1, n do
				local adjacent = j == i + 1 or (i == 1 and j == n)
				if
					not adjacent
					and segmentsIntersect(points[i], points[i % n + 1], points[j], points[j % n + 1])
				then
					table.insert(
						problems,
						string.format("prism polygon edges %d and %d cross (not simple)", i, j)
					)
					return problems
				end
			end
		end
	else
		table.insert(problems, "shape kind must be aabb, sphere or prism")
	end
	return problems
end

-- Signed distance of p in XZ to a polygon (negative inside).
local function polygonDistance(points: { V2 }, px: number, pz: number): number
	local inside = false
	local best = math.huge
	local n = #points
	for index = 1, n do
		local a, b = points[index], points[index % n + 1]
		if (a.z > pz) ~= (b.z > pz) then
			local x = a.x + (pz - a.z) * (b.x - a.x) / (b.z - a.z)
			if px < x then
				inside = not inside
			end
		end
		local ex, ez = b.x - a.x, b.z - a.z
		local len2 = ex * ex + ez * ez
		local s = if len2 > 0 then math.clamp(((px - a.x) * ex + (pz - a.z) * ez) / len2, 0, 1) else 0
		local dx, dz = px - (a.x + ex * s), pz - (a.z + ez * s)
		best = math.min(best, math.sqrt(dx * dx + dz * dz))
	end
	return if inside then -best else best
end

-- Signed distance from p to the shape's surface: negative inside, 0 on it, positive outside.
function Zones.distance(shape: Shape, p: V3): number
	if shape.kind == "sphere" then
		return Vec.length(Vec.sub(p, shape.center :: V3)) - (shape.radius :: number)
	elseif shape.kind == "aabb" then
		local lo, hi = shape.min :: V3, shape.max :: V3
		local qx = math.max(lo.x - p.x, p.x - hi.x)
		local qy = math.max(lo.y - p.y, p.y - hi.y)
		local qz = math.max(lo.z - p.z, p.z - hi.z)
		local ox, oy, oz = math.max(qx, 0), math.max(qy, 0), math.max(qz, 0)
		return math.sqrt(ox * ox + oy * oy + oz * oz) + math.min(math.max(qx, qy, qz), 0)
	end
	local dxz = polygonDistance(shape.points :: { V2 }, p.x, p.z)
	local dy = math.max((shape.minY :: number) - p.y, p.y - (shape.maxY :: number))
	if dxz > 0 and dy > 0 then
		return math.sqrt(dxz * dxz + dy * dy)
	end
	return math.max(dxz, dy)
end

function Zones.contains(shape: Shape, p: V3, margin: number?): boolean
	return Zones.distance(shape, p) <= (margin or 0)
end

function Zones.bounds(shape: Shape): (V3, V3)
	if shape.kind == "aabb" then
		return shape.min :: V3, shape.max :: V3
	elseif shape.kind == "sphere" then
		local r = shape.radius :: number
		local c = shape.center :: V3
		return Vec.new(c.x - r, c.y - r, c.z - r), Vec.new(c.x + r, c.y + r, c.z + r)
	end
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for _, point in shape.points :: { V2 } do
		minX, maxX = math.min(minX, point.x), math.max(maxX, point.x)
		minZ, maxZ = math.min(minZ, point.z), math.max(maxZ, point.z)
	end
	return Vec.new(minX, shape.minY :: number, minZ), Vec.new(maxX, shape.maxY :: number, maxZ)
end

-- Parameter interval [t0, t1] within [0, 1] where a + (b - a) t lies between lo and hi on one axis.
local function slab(a: number, d: number, lo: number, hi: number, t0: number, t1: number): (number, number)
	if math.abs(d) < 1e-12 then
		if a < lo or a > hi then
			return 1, 0
		end
		return t0, t1
	end
	local u, v = (lo - a) / d, (hi - a) / d
	if u > v then
		u, v = v, u
	end
	return math.max(t0, u), math.min(t1, v)
end

-- First point of segment a -> b inside the shape: (true, fraction 0-1) or (false). Exact for
-- every kind; used for swept gates and kill volumes.
function Zones.crosses(shape: Shape, a: V3, b: V3): (boolean, number?)
	local d = Vec.sub(b, a)
	if shape.kind == "sphere" then
		local m = Vec.sub(a, shape.center :: V3)
		local r = shape.radius :: number
		local c = Vec.dot(m, m) - r * r
		if c <= 0 then
			return true, 0
		end
		local qa, qb = Vec.dot(d, d), Vec.dot(m, d)
		if qa < 1e-12 or qb >= 0 then
			return false, nil
		end
		local disc = qb * qb - qa * c
		if disc < 0 then
			return false, nil
		end
		local t = (-qb - math.sqrt(disc)) / qa
		if t > 1 then
			return false, nil
		end
		return true, math.max(0, t)
	elseif shape.kind == "aabb" then
		local lo, hi = shape.min :: V3, shape.max :: V3
		local t0, t1 = slab(a.x, d.x, lo.x, hi.x, 0, 1)
		t0, t1 = slab(a.y, d.y, lo.y, hi.y, t0, t1)
		t0, t1 = slab(a.z, d.z, lo.z, hi.z, t0, t1)
		if t0 > t1 then
			return false, nil
		end
		return true, t0
	end
	local t0, t1 = slab(a.y, d.y, shape.minY :: number, shape.maxY :: number, 0, 1)
	if t0 > t1 then
		return false, nil
	end
	local points = shape.points :: { V2 }
	local start = { x = a.x + d.x * t0, z = a.z + d.z * t0 }
	local finish = { x = a.x + d.x * t1, z = a.z + d.z * t1 }
	if polygonDistance(points, start.x, start.z) <= 0 then
		return true, t0
	end
	-- Earliest edge crossing along the clipped segment.
	local best: number? = nil
	local sx, sz = finish.x - start.x, finish.z - start.z
	local n = #points
	for index = 1, n do
		local p, q = points[index], points[index % n + 1]
		local ex, ez = q.x - p.x, q.z - p.z
		local denom = cross2(sx, sz, ex, ez)
		if math.abs(denom) > 1e-12 then
			local u = cross2(p.x - start.x, p.z - start.z, ex, ez) / denom
			local w = cross2(p.x - start.x, p.z - start.z, sx, sz) / denom
			if u >= 0 and u <= 1 and w >= 0 and w <= 1 and (best == nil or u < best) then
				best = u
			end
		end
	end
	if best == nil then
		return false, nil
	end
	return true, t0 + (t1 - t0) * (best :: number)
end

-- ---------------------------------------------------------------- definitions

local function validateZone(def: any, where: string, problems: { string })
	if type(def) ~= "table" then
		table.insert(problems, where .. " must be a table")
		return
	end
	if not Check.label(def.id) then
		table.insert(problems, where .. ".id must be a label")
	end
	for _, problem in Zones.validateShape(def.shape) do
		table.insert(problems, where .. ".shape: " .. problem)
	end
	local kind = def.kind or "area"
	if not Zones.KINDS[kind] then
		table.insert(problems, where .. ".kind must be area, hazard, kill or gate")
	end
	if
		def.hysteresis ~= nil
		and (not Check.finite(def.hysteresis) or def.hysteresis < 0 or def.hysteresis > 64)
	then
		table.insert(problems, where .. ".hysteresis must be 0-64 studs")
	end
	if def.priority ~= nil and not Check.integer(def.priority) then
		table.insert(problems, where .. ".priority must be an integer")
	end
	if def.tags ~= nil then
		if type(def.tags) ~= "table" then
			table.insert(problems, where .. ".tags must be a list of labels")
		else
			for _, tag in def.tags do
				if not Check.label(tag) then
					table.insert(problems, where .. ".tags must be a list of labels")
					break
				end
			end
		end
	end
	local hazard = def.hazard
	if kind == "hazard" and type(hazard) ~= "table" then
		table.insert(problems, where .. ".hazard { amount, interval } is required for kind hazard")
	elseif hazard ~= nil then
		if kind ~= "hazard" then
			table.insert(problems, where .. ".hazard is only for kind hazard")
		elseif type(hazard) ~= "table" then
			table.insert(problems, where .. ".hazard must be a table")
		else
			if not Check.finite(hazard.amount) or hazard.amount <= 0 then
				table.insert(problems, where .. ".hazard.amount must be a finite number > 0")
			end
			if not Check.finite(hazard.interval) or hazard.interval <= 0 then
				table.insert(problems, where .. ".hazard.interval must be a finite number > 0 (seconds)")
			end
			if hazard.damageKind ~= nil and not Check.label(hazard.damageKind) then
				table.insert(problems, where .. ".hazard.damageKind must be a label")
			end
			if hazard.immediate ~= nil and type(hazard.immediate) ~= "boolean" then
				table.insert(problems, where .. ".hazard.immediate must be a boolean")
			end
		end
	end
	local gate = def.gate
	if kind == "gate" and type(gate) ~= "table" then
		table.insert(problems, where .. ".gate { order } is required for kind gate")
	elseif gate ~= nil then
		if kind ~= "gate" then
			table.insert(problems, where .. ".gate is only for kind gate")
		elseif type(gate) ~= "table" then
			table.insert(problems, where .. ".gate must be a table")
		else
			if not Check.integer(gate.order) or gate.order < 1 or gate.order > Zones.MAX_ZONES then
				table.insert(problems, where .. ".gate.order must be an integer 1-" .. Zones.MAX_ZONES)
			end
			if gate.finish ~= nil and type(gate.finish) ~= "boolean" then
				table.insert(problems, where .. ".gate.finish must be a boolean")
			end
			if gate.direction ~= nil and (not isVec(gate.direction) or Vec.length(gate.direction) < 1e-9) then
				table.insert(problems, where .. ".gate.direction must be a non-zero finite vector")
			end
			if gate.minTime ~= nil and (not Check.finite(gate.minTime) or gate.minTime < 0) then
				table.insert(problems, where .. ".gate.minTime must be a finite number >= 0 (seconds)")
			end
		end
	end
end

-- Problems with a zone list (empty when valid).
function Zones.validate(defs: any): { string }
	if type(defs) ~= "table" then
		return { "zones must be a list" }
	end
	local problems = {}
	if #defs == 0 or #defs > Zones.MAX_ZONES then
		table.insert(problems, string.format("zones must list 1-%d zones", Zones.MAX_ZONES))
	end
	local seen = {}
	for index, def in defs do
		validateZone(def, string.format("zones[%d]", index), problems)
		if type(def) == "table" and type(def.id) == "string" then
			if seen[def.id] then
				table.insert(problems, string.format("zones[%d].id %q is duplicated", index, def.id))
			end
			seen[def.id] = true
		end
	end
	return problems
end

-- A frozen, validated zone set; raises with every problem.
function Zones.define(defs: { ZoneDef }): Set
	local problems = Zones.validate(defs)
	if #problems > 0 then
		error("Zones.define: " .. table.concat(problems, "; "), 2)
	end
	local zones: { [string]: Zone } = {}
	local ids = {}
	for _, def in defs do
		local kind = def.kind or "area"
		local gate = def.gate and Check.copy(def.gate)
		if gate and gate.direction then
			gate.direction = Vec.unit(gate.direction)
		end
		zones[def.id] = Check.freeze({
			id = def.id,
			shape = Check.copy(def.shape),
			kind = kind,
			hysteresis = def.hysteresis or Zones.HYSTERESIS,
			priority = def.priority or 0,
			tags = def.tags and Check.copy(def.tags) or {},
			hazard = def.hazard and Check.copy(def.hazard),
			gate = gate,
			data = def.data ~= nil and Check.copy(def.data) or nil,
			swept = kind == "gate" or kind == "kill",
		}) :: Zone
		table.insert(ids, def.id)
	end
	table.sort(ids)
	return table.freeze({ zones = table.freeze(zones), ids = table.freeze(ids) })
end

-- ---------------------------------------------------------------- tracker

type Body = {
	position: V3?,
	inside: { [string]: boolean },
	nextTick: { [string]: number },
}

local Tracker = {}
Tracker.__index = Tracker

type TrackerFields = {
	set: Set,
	_env: any,
	_bodies: { [any]: Body },
	_count: number,
	_max: number,
	entered: Signal.Signal,
	exited: Signal.Signal,
	hazard: Signal.Signal,
	killed: Signal.Signal,
}
export type Tracker = typeof(setmetatable({} :: TrackerFields, Tracker))

function Zones.tracker(set: Set, options: { maxBodies: number? }?, env: any): Tracker
	assert(type(set) == "table" and table.isfrozen(set), "Zones.tracker needs a set from Zones.define")
	assert(type(env) == "table" and type(env.clock) == "function", "Zones.tracker needs env.clock")
	local max = (options and options.maxBodies) or Zones.MAX_BODIES
	assert(Check.integer(max) and max >= 1, "Zones.tracker: maxBodies must be an integer >= 1")
	return setmetatable({
		set = set,
		_env = env,
		_bodies = {},
		_count = 0,
		_max = max,
		entered = Signal.new(env),
		exited = Signal.new(env),
		hazard = Signal.new(env),
		killed = Signal.new(env),
	}, Tracker)
end

local function emit(self: Tracker, events: { Event }, event: Event)
	table.insert(events, event)
	if event.kind == "enter" then
		self.entered:Fire(event.body, event.zone, event)
	elseif event.kind == "exit" then
		self.exited:Fire(event.body, event.zone, event)
	elseif event.kind == "hazard" then
		self.hazard:Fire(event.body, event.zone, event.amount, event.damageKind)
	elseif event.kind == "kill" then
		self.killed:Fire(event.body, event.zone)
	end
end

local function forwardOf(zone: Zone, from: V3?, to: V3): boolean?
	local gate = zone.gate
	if gate == nil or gate.direction == nil or from == nil then
		return nil
	end
	local moved = Vec.sub(to, from :: V3)
	if Vec.length(moved) < 1e-9 then
		return nil
	end
	return Vec.dot(moved, gate.direction :: V3) > 0
end

local function enterZone(
	self: Tracker,
	events: { Event },
	body: Body,
	id: any,
	zone: Zone,
	now: number,
	forward: boolean?,
	swept: boolean?
)
	body.inside[zone.id] = true
	emit(
		self,
		events,
		{ kind = "enter", body = id, zone = zone.id, t = now, forward = forward, swept = swept }
	)
	if zone.kind == "kill" then
		emit(self, events, { kind = "kill", body = id, zone = zone.id, t = now })
	elseif zone.kind == "hazard" then
		local hazard = zone.hazard :: HazardDef
		if hazard.immediate ~= false then
			emit(self, events, {
				kind = "hazard",
				body = id,
				zone = zone.id,
				t = now,
				amount = hazard.amount,
				damageKind = hazard.damageKind or "hazard",
			})
		end
		body.nextTick[zone.id] = now + hazard.interval
	end
end

local function exitZone(
	self: Tracker,
	events: { Event },
	body: Body,
	id: any,
	zone: Zone,
	now: number,
	reason: string?
)
	body.inside[zone.id] = nil
	body.nextTick[zone.id] = nil
	emit(self, events, { kind = "exit", body = id, zone = zone.id, t = now, reason = reason })
end

-- Moves one body to position at the env clock. Returns the events in a stable order (zone ids
-- sorted; exits before enters within a zone), or ({}, reason) with bad_position or full.
function Tracker.update(self: Tracker, id: any, position: any): ({ Event }, string?)
	local events: { Event } = {}
	if id == nil then
		return events, "bad_body"
	end
	if not isVec(position) then
		return events, "bad_position"
	end
	local body = self._bodies[id]
	if body == nil then
		if self._count >= self._max then
			return events, "full"
		end
		body = { position = nil, inside = {}, nextTick = {} }
		self._bodies[id] = body
		self._count += 1
	end
	local b = body :: Body
	local now = self._env.clock()
	local from = b.position
	local to = Vec.new(position.x, position.y, position.z)
	for _, zoneId in self.set.ids do
		local zone = self.set.zones[zoneId]
		local d = Zones.distance(zone.shape, to)
		if b.inside[zoneId] then
			if d > zone.hysteresis then
				exitZone(self, events, b, id, zone, now)
			elseif zone.kind == "hazard" then
				local hazard = zone.hazard :: HazardDef
				local ticks = 0
				while now + Zones.TIME_EPSILON >= b.nextTick[zoneId] and ticks < Zones.MAX_TICKS_PER_UPDATE do
					ticks += 1
					emit(self, events, {
						kind = "hazard",
						body = id,
						zone = zoneId,
						t = now,
						amount = hazard.amount,
						damageKind = hazard.damageKind or "hazard",
					})
					b.nextTick[zoneId] += hazard.interval
				end
				if now + Zones.TIME_EPSILON >= b.nextTick[zoneId] then
					-- Owed ticks beyond the cap are dropped, not banked.
					b.nextTick[zoneId] = now + hazard.interval
				end
			end
		elseif d <= 0 then
			enterZone(self, events, b, id, zone, now, forwardOf(zone, from, to), nil)
		elseif zone.swept and from ~= nil then
			local crossed = Zones.crosses(zone.shape, from :: V3, to)
			if crossed then
				-- Passed through between updates: enter and leave in the same step.
				enterZone(self, events, b, id, zone, now, forwardOf(zone, from, to), true)
				exitZone(self, events, b, id, zone, now, "swept")
			end
		end
	end
	b.position = to
	return events, nil
end

-- Updates every listed body ({ [id] = position }) in sorted id order (ids of one type).
function Tracker.step(self: Tracker, positions: { [any]: any }): { Event }
	local ids = {}
	for id in positions do
		table.insert(ids, id)
	end
	table.sort(ids, function(a: any, b: any): boolean
		if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	local all = {}
	for _, id in ids do
		local events = self:update(id, positions[id])
		for _, event in events do
			table.insert(all, event)
		end
	end
	return all
end

-- Forgets a body, exiting every zone it was in (reason "removed").
function Tracker.remove(self: Tracker, id: any): { Event }
	local events: { Event } = {}
	local body = self._bodies[id]
	if body == nil then
		return events
	end
	local now = self._env.clock()
	for _, zoneId in self.set.ids do
		if body.inside[zoneId] then
			exitZone(self, events, body, id, self.set.zones[zoneId], now, "removed")
		end
	end
	self._bodies[id] = nil
	self._count -= 1
	return events
end

-- Zone ids the body is in, highest priority first (then by id).
function Tracker.inside(self: Tracker, id: any): { string }
	local body = self._bodies[id]
	local list = {}
	if body == nil then
		return list
	end
	for _, zoneId in self.set.ids do
		if body.inside[zoneId] then
			table.insert(list, zoneId)
		end
	end
	table.sort(list, function(a: string, b: string): boolean
		local pa, pb = self.set.zones[a].priority, self.set.zones[b].priority
		if pa ~= pb then
			return pa > pb
		end
		return a < b
	end)
	return list
end

function Tracker.current(self: Tracker, id: any): string?
	return self:inside(id)[1]
end

function Tracker.isInside(self: Tracker, id: any, zoneId: string): boolean
	local body = self._bodies[id]
	return body ~= nil and body.inside[zoneId] == true
end

-- Bodies inside a zone, sorted by tostring.
function Tracker.occupants(self: Tracker, zoneId: string): { any }
	local list = {}
	for id, body in self._bodies do
		if body.inside[zoneId] then
			table.insert(list, id)
		end
	end
	table.sort(list, function(a: any, b: any): boolean
		return tostring(a) < tostring(b)
	end)
	return list
end

function Tracker.count(self: Tracker): number
	return self._count
end

function Tracker.destroy(self: Tracker)
	self.entered:Destroy()
	self.exited:Destroy()
	self.hazard:Destroy()
	self.killed:Destroy()
	table.clear(self._bodies)
	self._count = 0
end

-- ---------------------------------------------------------------- course (laps and sectors)

export type CourseEvent = {
	kind: string, -- "sector" | "lap" | "finish" | "wrong_gate" | "wrong_way" | "too_fast"
	body: any,
	zone: string,
	t: number,
	order: number?,
	expected: number?,
	lap: number?,
	split: number?,
	lapTime: number?,
	total: number?,
}
type Racer = {
	startedAt: number,
	lapStartedAt: number,
	lastAt: number,
	lap: number,
	nextOrder: number,
	finished: boolean,
	total: number?,
	laps: { number },
	gates: number,
}

local Course = {}
Course.__index = Course

type CourseFields = {
	set: Set,
	laps: number,
	_env: any,
	_gates: { [number]: Zone },
	_count: number,
	_racers: { [any]: Racer },
	_finishOrder: { any },
	crossed: Signal.Signal,
}
export type Course = typeof(setmetatable({} :: CourseFields, Course))

-- Problems with the set's gates as a course (orders 1..N, no gaps or repeats, exactly one
-- finish gate and it is the last).
function Zones.validateCourse(set: Set, options: any?): { string }
	local problems = {}
	local byOrder: { [number]: string } = {}
	local count, finish = 0, nil
	for _, id in set.ids do
		local zone = set.zones[id]
		if zone.kind == "gate" then
			local gate = zone.gate :: GateDef
			if byOrder[gate.order] then
				table.insert(
					problems,
					string.format("gates %s and %s share order %d", byOrder[gate.order], id, gate.order)
				)
			end
			byOrder[gate.order] = id
			count += 1
			if gate.finish then
				if finish then
					table.insert(problems, "only one gate may be the finish")
				end
				finish = gate.order
			end
		end
	end
	if count == 0 then
		table.insert(problems, "a course needs at least one gate")
	end
	for order = 1, count do
		if byOrder[order] == nil then
			table.insert(
				problems,
				string.format("gate orders must run 1..%d without gaps (missing %d)", count, order)
			)
			break
		end
	end
	if finish == nil then
		table.insert(problems, "one gate must have finish = true")
	elseif finish ~= count then
		table.insert(problems, "the finish gate must have the highest order")
	end
	local laps = options and options.laps
	if laps ~= nil and (not Check.integer(laps) or laps < 1 or laps > 1000) then
		table.insert(problems, "laps must be an integer 1-1000")
	end
	return problems
end

function Zones.course(set: Set, options: { laps: number? }?, env: any): Course
	local problems = Zones.validateCourse(set, options)
	if #problems > 0 then
		error("Zones.course: " .. table.concat(problems, "; "), 2)
	end
	assert(type(env) == "table" and type(env.clock) == "function", "Zones.course needs env.clock")
	local gates = {}
	local count = 0
	for _, id in set.ids do
		local zone = set.zones[id]
		if zone.kind == "gate" then
			gates[(zone.gate :: GateDef).order] = zone
			count += 1
		end
	end
	return setmetatable({
		set = set,
		laps = (options and options.laps) or 1,
		_env = env,
		_gates = gates,
		_count = count,
		_racers = {},
		_finishOrder = {},
		crossed = Signal.new(env),
	}, Course)
end

-- Starts (or restarts) timing a body at the env clock.
function Course.start(self: Course, body: any)
	local now = self._env.clock()
	self._racers[body] = {
		startedAt = now,
		lapStartedAt = now,
		lastAt = now,
		lap = 1,
		nextOrder = 1,
		finished = false,
		total = nil,
		laps = {},
		gates = 0,
	}
	local index = table.find(self._finishOrder, body)
	if index then
		table.remove(self._finishOrder, index)
	end
end

-- A gate crossing (forward = nil when the gate has no direction). Returns the course events.
function Course.cross(self: Course, body: any, zoneId: string, forward: boolean?): { CourseEvent }
	local events: { CourseEvent } = {}
	local racer = self._racers[body]
	local zone = self.set.zones[zoneId]
	if racer == nil or racer.finished or zone == nil or zone.kind ~= "gate" then
		return events
	end
	local now = self._env.clock()
	local gate = zone.gate :: GateDef
	local function push(event: CourseEvent)
		table.insert(events, event)
		self.crossed:Fire(event)
	end
	if forward == false then
		push({ kind = "wrong_way", body = body, zone = zoneId, t = now, order = gate.order })
		return events
	end
	if gate.order ~= racer.nextOrder then
		push({
			kind = "wrong_gate",
			body = body,
			zone = zoneId,
			t = now,
			order = gate.order,
			expected = racer.nextOrder,
		})
		return events
	end
	local split = now - racer.lastAt
	if gate.minTime ~= nil and split < gate.minTime then
		push({ kind = "too_fast", body = body, zone = zoneId, t = now, order = gate.order, split = split })
		return events
	end
	racer.lastAt = now
	racer.gates += 1
	push({
		kind = "sector",
		body = body,
		zone = zoneId,
		t = now,
		order = gate.order,
		lap = racer.lap,
		split = split,
	})
	if gate.order < self._count then
		racer.nextOrder = gate.order + 1
		return events
	end
	local lapTime = now - racer.lapStartedAt
	table.insert(racer.laps, lapTime)
	push({ kind = "lap", body = body, zone = zoneId, t = now, lap = racer.lap, lapTime = lapTime })
	if racer.lap >= self.laps then
		racer.finished = true
		racer.total = now - racer.startedAt
		table.insert(self._finishOrder, body)
		push({ kind = "finish", body = body, zone = zoneId, t = now, lap = racer.lap, total = racer.total })
	else
		racer.lap += 1
		racer.lapStartedAt = now
		racer.nextOrder = 1
	end
	return events
end

-- Feeds tracker events: every gate "enter" becomes a crossing.
function Course.observe(self: Course, events: { Event }): { CourseEvent }
	local out = {}
	for _, event in events do
		if event.kind == "enter" then
			local zone = self.set.zones[event.zone]
			if zone and zone.kind == "gate" then
				for _, courseEvent in self:cross(event.body, event.zone, event.forward) do
					table.insert(out, courseEvent)
				end
			end
		end
	end
	return out
end

function Course.progress(self: Course, body: any): { [string]: any }?
	local racer = self._racers[body]
	if racer == nil then
		return nil
	end
	return {
		lap = racer.lap,
		nextOrder = racer.nextOrder,
		gates = racer.gates,
		finished = racer.finished,
		total = racer.total,
		laps = table.clone(racer.laps),
		lastAt = racer.lastAt,
	}
end

-- Bodies by race position: finishers in finishing order, then by gates passed (more first),
-- then by the earlier last crossing, then by tostring.
function Course.standings(self: Course): { any }
	local list = {}
	for body in self._racers do
		table.insert(list, body)
	end
	local finishRank = {}
	for index, body in self._finishOrder do
		finishRank[body] = index
	end
	table.sort(list, function(a: any, b: any): boolean
		local fa, fb = finishRank[a], finishRank[b]
		if fa or fb then
			if fa and fb then
				return fa < fb
			end
			return fa ~= nil
		end
		local ra, rb = self._racers[a], self._racers[b]
		if ra.gates ~= rb.gates then
			return ra.gates > rb.gates
		end
		if ra.lastAt ~= rb.lastAt then
			return ra.lastAt < rb.lastAt
		end
		return tostring(a) < tostring(b)
	end)
	return list
end

function Course.destroy(self: Course)
	self.crossed:Destroy()
	table.clear(self._racers)
	table.clear(self._finishOrder)
end

return Zones
