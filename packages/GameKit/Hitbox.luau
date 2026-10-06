--!strict
-- @tier T0
-- Hitbox: pure hit geometry and server-side hit validation.
--   * Shapes: sphere, oriented box and capsule (plain { x, y, z } vectors). closestPoint,
--     distance, contains, overlaps (all nine pairs; box-box by the separating-axis test) and
--     segment(): the first contact of a moving point or sphere with a shape, as a fraction of
--     the path. Convex cases without a closed form are solved by ternary search plus bisection on
--     the (convex) distance along the path: deterministic and exact to about 1e-10 of the path.
--   * history(): a ring buffer of timed poses per entity for lag compensation. at(t) interpolates
--     between samples; rewinds are limited to MAX_REWIND (200 ms) by the validator.
--   * activation(): one melee swing; each target is hit at most once, and sweep() samples the
--     poses between two frames so a fast swing cannot tunnel through a thin target.
--   * validator(): checks a client's hit claim against server state: malformed numbers, unknown
--     or self targets, replayed shot ids, fire rate (token bucket), future or stale timestamps,
--     the shooter's origin against where the server had them (teleport shots), range, aim angle,
--     the ray against the target's rewound hitbox, line of sight and liveness (hooks).
-- Engine casts (Spherecast, Blockcast, GetPartBoundsInBox) live in HitboxRoblox.
local Check = require("./Check")
local Vec = require("../SceneKit/Vec")

local Hitbox = {}
Hitbox.MAX_REWIND = 0.2 -- seconds; the hard cap for lag compensation
Hitbox.MAX_EXTENT = 4096 -- studs; sanity bound for shape sizes (convention)
Hitbox.SEARCH_STEPS = 60
Hitbox.EPSILON = 1e-9
Hitbox.MAX_POSES = 64

export type V3 = Vec.V3
export type Shape = {
	kind: string, -- "sphere" | "box" | "capsule"
	center: V3?,
	radius: number?,
	size: V3?,
	axes: { V3 }?, -- box: unit right, up, back (nil = axis-aligned)
	a: V3?,
	b: V3?,
}

local function isVec(value: any): boolean
	return type(value) == "table"
		and Check.finite(value.x)
		and Check.finite(value.y)
		and Check.finite(value.z)
end
Hitbox.isVec = isVec

local function v(x: number, y: number, z: number): V3
	return { x = x, y = y, z = z }
end

local IDENTITY: { V3 } =
	table.freeze({ table.freeze(v(1, 0, 0)), table.freeze(v(0, 1, 0)), table.freeze(v(0, 0, 1)) })

-- ---------------------------------------------------------------- constructors

function Hitbox.sphere(center: V3, radius: number): Shape
	return { kind = "sphere", center = Vec.new(center.x, center.y, center.z), radius = radius }
end

-- A box at center with full size; rotation is an orientation in degrees (SceneKit/Vec.rotate,
-- the CFrame.fromOrientation order).
function Hitbox.box(center: V3, size: V3, rotation: V3?): Shape
	local axes: { V3 }? = nil
	if rotation and (rotation.x ~= 0 or rotation.y ~= 0 or rotation.z ~= 0) then
		axes = {
			Vec.rotate(v(1, 0, 0), rotation),
			Vec.rotate(v(0, 1, 0), rotation),
			Vec.rotate(v(0, 0, 1), rotation),
		}
	end
	return {
		kind = "box",
		center = Vec.new(center.x, center.y, center.z),
		size = Vec.new(size.x, size.y, size.z),
		axes = axes,
	}
end

-- A box from explicit axes (a CFrame's RightVector, UpVector and -LookVector); they are
-- normalised and made orthogonal.
function Hitbox.boxAxes(center: V3, size: V3, right: V3, up: V3, back: V3): Shape
	local x = Vec.unit(right)
	local y = Vec.unit(Vec.sub(up, Vec.scale(x, Vec.dot(up, x))))
	local z = v(x.y * y.z - x.z * y.y, x.z * y.x - x.x * y.z, x.x * y.y - x.y * y.x)
	if Vec.dot(z, back) < 0 then
		z = Vec.scale(z, -1)
	end
	return {
		kind = "box",
		center = Vec.new(center.x, center.y, center.z),
		size = Vec.new(size.x, size.y, size.z),
		axes = { x, y, z },
	}
end

function Hitbox.capsule(a: V3, b: V3, radius: number): Shape
	return { kind = "capsule", a = Vec.new(a.x, a.y, a.z), b = Vec.new(b.x, b.y, b.z), radius = radius }
end

-- Problems with a shape (empty when valid).
function Hitbox.validate(shape: any): { string }
	if type(shape) ~= "table" then
		return { "shape must be a table" }
	end
	local problems = {}
	local function extent(value: any, what: string, allowZero: boolean)
		if
			not Check.finite(value)
			or value < 0
			or (not allowZero and value == 0)
			or value > Hitbox.MAX_EXTENT
		then
			table.insert(
				problems,
				string.format(
					"%s must be finite and in %s0, %d]",
					what,
					if allowZero then "[" else "(",
					Hitbox.MAX_EXTENT
				)
			)
		end
	end
	if shape.kind == "sphere" then
		if not isVec(shape.center) then
			table.insert(problems, "sphere center must be a finite vector")
		end
		extent(shape.radius, "sphere radius", true)
	elseif shape.kind == "box" then
		if not isVec(shape.center) then
			table.insert(problems, "box center must be a finite vector")
		end
		if not isVec(shape.size) then
			table.insert(problems, "box size must be a finite vector")
		else
			extent(shape.size.x, "box size.x", true)
			extent(shape.size.y, "box size.y", true)
			extent(shape.size.z, "box size.z", true)
		end
		if shape.axes ~= nil then
			if type(shape.axes) ~= "table" or #shape.axes ~= 3 then
				table.insert(problems, "box axes must be three unit vectors")
			else
				for index, axis in shape.axes do
					if not isVec(axis) or math.abs(Vec.length(axis) - 1) > 1e-6 then
						table.insert(problems, "box axis " .. index .. " must be a unit vector")
					end
				end
			end
		end
	elseif shape.kind == "capsule" then
		if not isVec(shape.a) or not isVec(shape.b) then
			table.insert(problems, "capsule ends a and b must be finite vectors")
		end
		extent(shape.radius, "capsule radius", true)
	else
		table.insert(
			problems,
			"kind must be sphere, box or capsule (got " .. Check.describe(shape.kind) .. ")"
		)
	end
	return problems
end

function Hitbox.valid(shape: any): boolean
	return #Hitbox.validate(shape) == 0
end

-- ---------------------------------------------------------------- primitives

local function axesOf(box: Shape): { V3 }
	return box.axes or IDENTITY
end

-- Closest point on segment ab to p, and its parameter in [0, 1].
local function closestOnSegment(a: V3, b: V3, p: V3): (V3, number)
	local ab = Vec.sub(b, a)
	local denom = Vec.dot(ab, ab)
	if denom <= Hitbox.EPSILON then
		return a, 0
	end
	local t = math.clamp(Vec.dot(Vec.sub(p, a), ab) / denom, 0, 1)
	return Vec.add(a, Vec.scale(ab, t)), t
end
Hitbox.closestOnSegment = closestOnSegment

-- Squared distance between segments p1q1 and p2q2 with the closest points (Ericson 5.1.9).
local function segmentSegment(p1: V3, q1: V3, p2: V3, q2: V3): (number, V3, V3)
	local d1, d2, r = Vec.sub(q1, p1), Vec.sub(q2, p2), Vec.sub(p1, p2)
	local a, e, f = Vec.dot(d1, d1), Vec.dot(d2, d2), Vec.dot(d2, r)
	local s, t
	if a <= Hitbox.EPSILON and e <= Hitbox.EPSILON then
		s, t = 0, 0
	elseif a <= Hitbox.EPSILON then
		s, t = 0, math.clamp(f / e, 0, 1)
	else
		local c = Vec.dot(d1, r)
		if e <= Hitbox.EPSILON then
			t, s = 0, math.clamp(-c / a, 0, 1)
		else
			local b = Vec.dot(d1, d2)
			local denom = a * e - b * b
			s = if denom ~= 0 then math.clamp((b * f - c * e) / denom, 0, 1) else 0
			t = (b * s + f) / e
			if t < 0 then
				t, s = 0, math.clamp(-c / a, 0, 1)
			elseif t > 1 then
				t, s = 1, math.clamp((b - c) / a, 0, 1)
			end
		end
	end
	local c1, c2 = Vec.add(p1, Vec.scale(d1, s)), Vec.add(p2, Vec.scale(d2, t))
	local diff = Vec.sub(c1, c2)
	return Vec.dot(diff, diff), c1, c2
end
Hitbox.segmentSegment = segmentSegment

-- The point of shape closest to p (p itself when inside).
function Hitbox.closestPoint(shape: Shape, p: V3): V3
	if shape.kind == "sphere" then
		local c = shape.center :: V3
		local r = shape.radius :: number
		local d = Vec.sub(p, c)
		local length = Vec.length(d)
		if length <= r then
			return Vec.new(p.x, p.y, p.z)
		end
		return Vec.add(c, Vec.scale(d, r / length))
	elseif shape.kind == "box" then
		local c = shape.center :: V3
		local half = Vec.scale(shape.size :: V3, 0.5)
		local axes = axesOf(shape)
		local d = Vec.sub(p, c)
		local out = Vec.new(c.x, c.y, c.z)
		local halves = { half.x, half.y, half.z }
		for index = 1, 3 do
			local amount = math.clamp(Vec.dot(d, axes[index]), -halves[index], halves[index])
			out = Vec.add(out, Vec.scale(axes[index], amount))
		end
		return out
	end
	local q = closestOnSegment(shape.a :: V3, shape.b :: V3, p)
	local d = Vec.sub(p, q)
	local length = Vec.length(d)
	local r = shape.radius :: number
	if length <= r then
		return Vec.new(p.x, p.y, p.z)
	end
	return Vec.add(q, Vec.scale(d, r / length))
end

-- Distance from p to the shape's surface; 0 inside.
function Hitbox.distance(shape: Shape, p: V3): number
	if shape.kind == "sphere" then
		return math.max(0, Vec.length(Vec.sub(p, shape.center :: V3)) - (shape.radius :: number))
	elseif shape.kind == "capsule" then
		local q = closestOnSegment(shape.a :: V3, shape.b :: V3, p)
		return math.max(0, Vec.length(Vec.sub(p, q)) - (shape.radius :: number))
	end
	return Vec.length(Vec.sub(p, Hitbox.closestPoint(shape, p)))
end

function Hitbox.contains(shape: Shape, p: V3): boolean
	return Hitbox.distance(shape, p) <= Hitbox.EPSILON
end

-- A representative centre (sphere/box centre, capsule midpoint).
function Hitbox.center(shape: Shape): V3
	if shape.kind == "capsule" then
		return Vec.lerp(shape.a :: V3, shape.b :: V3, 0.5)
	end
	local c = shape.center :: V3
	return Vec.new(c.x, c.y, c.z)
end

-- World-axis bounds (min, max).
function Hitbox.bounds(shape: Shape): (V3, V3)
	if shape.kind == "sphere" then
		local c, r = shape.center :: V3, shape.radius :: number
		return v(c.x - r, c.y - r, c.z - r), v(c.x + r, c.y + r, c.z + r)
	elseif shape.kind == "capsule" then
		local a, b, r = shape.a :: V3, shape.b :: V3, shape.radius :: number
		return v(math.min(a.x, b.x) - r, math.min(a.y, b.y) - r, math.min(a.z, b.z) - r),
			v(math.max(a.x, b.x) + r, math.max(a.y, b.y) + r, math.max(a.z, b.z) + r)
	end
	local c, size, axes = shape.center :: V3, shape.size :: V3, axesOf(shape)
	local h = { size.x / 2, size.y / 2, size.z / 2 }
	local ex = math.abs(axes[1].x) * h[1] + math.abs(axes[2].x) * h[2] + math.abs(axes[3].x) * h[3]
	local ey = math.abs(axes[1].y) * h[1] + math.abs(axes[2].y) * h[2] + math.abs(axes[3].y) * h[3]
	local ez = math.abs(axes[1].z) * h[1] + math.abs(axes[2].z) * h[2] + math.abs(axes[3].z) * h[3]
	return v(c.x - ex, c.y - ey, c.z - ez), v(c.x + ex, c.y + ey, c.z + ez)
end

function Hitbox.translate(shape: Shape, offset: V3): Shape
	local out = table.clone(shape)
	if shape.kind == "capsule" then
		out.a = Vec.add(shape.a :: V3, offset)
		out.b = Vec.add(shape.b :: V3, offset)
	else
		out.center = Vec.add(shape.center :: V3, offset)
	end
	return out
end

-- Interpolates two shapes of the same kind (box axes are re-orthonormalised).
function Hitbox.lerp(from: Shape, to: Shape, t: number): Shape
	assert(from.kind == to.kind, "Hitbox.lerp: shapes must be the same kind")
	if from.kind == "sphere" then
		return {
			kind = "sphere",
			center = Vec.lerp(from.center :: V3, to.center :: V3, t),
			radius = (from.radius :: number) + ((to.radius :: number) - (from.radius :: number)) * t,
		}
	elseif from.kind == "capsule" then
		return {
			kind = "capsule",
			a = Vec.lerp(from.a :: V3, to.a :: V3, t),
			b = Vec.lerp(from.b :: V3, to.b :: V3, t),
			radius = (from.radius :: number) + ((to.radius :: number) - (from.radius :: number)) * t,
		}
	end
	local center = Vec.lerp(from.center :: V3, to.center :: V3, t)
	local size = Vec.lerp(from.size :: V3, to.size :: V3, t)
	if from.axes == nil and to.axes == nil then
		return { kind = "box", center = center, size = size }
	end
	local fa, ta = axesOf(from), axesOf(to)
	return Hitbox.boxAxes(
		center,
		size,
		Vec.lerp(fa[1], ta[1], t),
		Vec.lerp(fa[2], ta[2], t),
		Vec.lerp(fa[3], ta[3], t)
	)
end

-- ---------------------------------------------------------------- convex search

-- Minimum of a convex function on [lo, hi]: (t, f(t)).
local function minimize(f: (number) -> number, lo: number, hi: number): (number, number)
	for _ = 1, Hitbox.SEARCH_STEPS do
		local m1 = lo + (hi - lo) / 3
		local m2 = hi - (hi - lo) / 3
		if f(m1) <= f(m2) then
			hi = m2
		else
			lo = m1
		end
	end
	local t = (lo + hi) / 2
	return t, f(t)
end

-- First t in [0, 1] with f(t) <= threshold for a convex f, or nil.
local function firstBelow(f: (number) -> number, threshold: number): number?
	if f(0) <= threshold then
		return 0
	end
	local tmin, fmin = minimize(f, 0, 1)
	if fmin > threshold then
		return nil
	end
	-- Left of a minimiser a convex function never increases: bisect for the crossing.
	local lo, hi = 0, tmin
	for _ = 1, Hitbox.SEARCH_STEPS do
		local mid = (lo + hi) / 2
		if f(mid) <= threshold then
			hi = mid
		else
			lo = mid
		end
	end
	return hi
end

-- ---------------------------------------------------------------- overlap

local function boxBox(A: Shape, B: Shape): boolean
	local au, bu = axesOf(A), axesOf(B)
	-- Zero-based like the SAT reference formulation (filled by index, not a mixed constructor).
	local sa, sb = A.size :: V3, B.size :: V3
	local ae: { [number]: number } = {}
	ae[0], ae[1], ae[2] = sa.x / 2, sa.y / 2, sa.z / 2
	local be: { [number]: number } = {}
	be[0], be[1], be[2] = sb.x / 2, sb.y / 2, sb.z / 2
	local R: { [number]: { [number]: number } } = {}
	local AbsR: { [number]: { [number]: number } } = {}
	for i = 0, 2 do
		R[i], AbsR[i] = {}, {}
		for j = 0, 2 do
			R[i][j] = Vec.dot(au[i + 1], bu[j + 1])
			AbsR[i][j] = math.abs(R[i][j]) + 1e-9
		end
	end
	local d = Vec.sub(B.center :: V3, A.center :: V3)
	local t: { [number]: number } = {}
	t[0], t[1], t[2] = Vec.dot(d, au[1]), Vec.dot(d, au[2]), Vec.dot(d, au[3])
	for i = 0, 2 do
		local ra = ae[i]
		local rb = be[0] * AbsR[i][0] + be[1] * AbsR[i][1] + be[2] * AbsR[i][2]
		if math.abs(t[i]) > ra + rb then
			return false
		end
	end
	for i = 0, 2 do
		local ra = ae[0] * AbsR[0][i] + ae[1] * AbsR[1][i] + ae[2] * AbsR[2][i]
		local rb = be[i]
		if math.abs(t[0] * R[0][i] + t[1] * R[1][i] + t[2] * R[2][i]) > ra + rb then
			return false
		end
	end
	local function axis(ra: number, rb: number, value: number): boolean
		return math.abs(value) <= ra + rb
	end
	return axis(
		ae[1] * AbsR[2][0] + ae[2] * AbsR[1][0],
		be[1] * AbsR[0][2] + be[2] * AbsR[0][1],
		t[2] * R[1][0] - t[1] * R[2][0]
	) and axis(
		ae[1] * AbsR[2][1] + ae[2] * AbsR[1][1],
		be[0] * AbsR[0][2] + be[2] * AbsR[0][0],
		t[2] * R[1][1] - t[1] * R[2][1]
	) and axis(
		ae[1] * AbsR[2][2] + ae[2] * AbsR[1][2],
		be[0] * AbsR[0][1] + be[1] * AbsR[0][0],
		t[2] * R[1][2] - t[1] * R[2][2]
	) and axis(
		ae[0] * AbsR[2][0] + ae[2] * AbsR[0][0],
		be[1] * AbsR[1][2] + be[2] * AbsR[1][1],
		t[0] * R[2][0] - t[2] * R[0][0]
	) and axis(
		ae[0] * AbsR[2][1] + ae[2] * AbsR[0][1],
		be[0] * AbsR[1][2] + be[2] * AbsR[1][0],
		t[0] * R[2][1] - t[2] * R[0][1]
	) and axis(
		ae[0] * AbsR[2][2] + ae[2] * AbsR[0][2],
		be[0] * AbsR[1][1] + be[1] * AbsR[1][0],
		t[0] * R[2][2] - t[2] * R[0][2]
	) and axis(
		ae[0] * AbsR[1][0] + ae[1] * AbsR[0][0],
		be[1] * AbsR[2][2] + be[2] * AbsR[2][1],
		t[1] * R[0][0] - t[0] * R[1][0]
	) and axis(
		ae[0] * AbsR[1][1] + ae[1] * AbsR[0][1],
		be[0] * AbsR[2][2] + be[2] * AbsR[2][0],
		t[1] * R[0][1] - t[0] * R[1][1]
	) and axis(
		ae[0] * AbsR[1][2] + ae[1] * AbsR[0][2],
		be[0] * AbsR[2][1] + be[1] * AbsR[2][0],
		t[1] * R[0][2] - t[0] * R[1][2]
	)
end

-- Distance between a segment and a shape's surface (0 when they touch).
local function segmentDistance(shape: Shape, a: V3, b: V3): number
	if shape.kind == "sphere" then
		local q = closestOnSegment(a, b, shape.center :: V3)
		return math.max(0, Vec.length(Vec.sub(q, shape.center :: V3)) - (shape.radius :: number))
	elseif shape.kind == "capsule" then
		local d2 = segmentSegment(a, b, shape.a :: V3, shape.b :: V3)
		return math.max(0, math.sqrt(d2) - (shape.radius :: number))
	end
	local ab = Vec.sub(b, a)
	local _, best = minimize(function(t: number): number
		return Hitbox.distance(shape, Vec.add(a, Vec.scale(ab, t)))
	end, 0, 1)
	return best
end

-- Whether two shapes overlap (touching counts).
function Hitbox.overlaps(first: Shape, second: Shape): boolean
	local a, b = first, second
	-- Order the pair so each case below is written once: sphere < capsule < box.
	local rank = { sphere = 1, capsule = 2, box = 3 }
	if rank[a.kind] > rank[b.kind] then
		a, b = b, a
	end
	if a.kind == "sphere" then
		return Hitbox.distance(b, a.center :: V3) <= (a.radius :: number) + Hitbox.EPSILON
	elseif a.kind == "capsule" then
		return segmentDistance(b, a.a :: V3, a.b :: V3) <= (a.radius :: number) + Hitbox.EPSILON
	end
	return boxBox(a, b)
end

-- ---------------------------------------------------------------- swept tests

-- Slab test of a segment against a box: entry fraction or nil.
local function segmentBox(box: Shape, origin: V3, delta: V3): number?
	local axes = axesOf(box)
	local size = box.size :: V3
	local half = { size.x / 2, size.y / 2, size.z / 2 }
	local rel = Vec.sub(origin, box.center :: V3)
	local tmin, tmax = 0, 1
	for index = 1, 3 do
		local p = Vec.dot(rel, axes[index])
		local d = Vec.dot(delta, axes[index])
		if math.abs(d) < Hitbox.EPSILON then
			if p < -half[index] or p > half[index] then
				return nil
			end
		else
			local t1, t2 = (-half[index] - p) / d, (half[index] - p) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin = math.max(tmin, t1)
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin
end

-- First contact of a point (radius 0) or sphere (radius r) moving from origin by delta with
-- shape: (true, fraction 0-1, contact centre on the path) or (false). Starting inside is t = 0.
function Hitbox.segment(shape: Shape, origin: V3, delta: V3, radius: number?): (boolean, number?, V3?)
	local r = radius or 0
	local t: number?
	if shape.kind == "sphere" then
		local R = (shape.radius :: number) + r
		local m = Vec.sub(origin, shape.center :: V3)
		local c = Vec.dot(m, m) - R * R
		if c <= 0 then
			t = 0
		else
			local a = Vec.dot(delta, delta)
			local b = Vec.dot(m, delta)
			if a > Hitbox.EPSILON and b < 0 then
				local disc = b * b - a * c
				if disc >= 0 then
					local root = (-b - math.sqrt(disc)) / a
					if root <= 1 then
						t = math.max(0, root)
					end
				end
			end
		end
	elseif shape.kind == "box" and r == 0 then
		t = segmentBox(shape, origin, delta)
	else
		t = firstBelow(function(s: number): number
			return Hitbox.distance(shape, Vec.add(origin, Vec.scale(delta, s)))
		end, r + Hitbox.EPSILON)
	end
	if t == nil then
		return false, nil, nil
	end
	return true, t, Vec.add(origin, Vec.scale(delta, t :: number))
end

-- Poses between prev and curr (both included) so no part moves more than maxStep between two
-- of them (default: the smaller shape extent). At most MAX_POSES.
function Hitbox.sweepPoses(prev: Shape, curr: Shape, maxStep: number?): { Shape }
	assert(prev.kind == curr.kind, "Hitbox.sweepPoses: shapes must be the same kind")
	local step = maxStep
	if step == nil then
		if prev.kind == "box" then
			local s = prev.size :: V3
			step = math.max(math.min(s.x, s.y, s.z), 0.05)
		else
			step = math.max((prev.radius :: number) * 2, 0.05)
		end
	end
	assert(Check.finite(step) and (step :: number) > 0, "Hitbox.sweepPoses: maxStep must be > 0")
	local moved
	if prev.kind == "capsule" then
		moved = math.max(
			Vec.length(Vec.sub(curr.a :: V3, prev.a :: V3)),
			Vec.length(Vec.sub(curr.b :: V3, prev.b :: V3))
		)
	else
		moved = Vec.length(Vec.sub(curr.center :: V3, prev.center :: V3))
		if prev.kind == "box" then
			-- A rotating box sweeps its corners further than its centre.
			local s = prev.size :: V3
			local radius = Vec.length(Vec.scale(s, 0.5))
			local pa, ca = axesOf(prev), axesOf(curr)
			local turn = 0
			for index = 1, 3 do
				turn = math.max(turn, Vec.length(Vec.sub(ca[index], pa[index])))
			end
			moved += turn * radius
		end
	end
	local count = math.clamp(math.ceil(moved / (step :: number)), 1, Hitbox.MAX_POSES - 1)
	local poses = {}
	for index = 0, count do
		table.insert(poses, Hitbox.lerp(prev, curr, index / count))
	end
	return poses
end

-- ---------------------------------------------------------------- lag-compensation history

local History = {}
History.__index = History

type HistoryFields = {
	_capacity: number,
	_times: { number },
	_shapes: { Shape },
	_head: number,
	_count: number,
}
export type History = typeof(setmetatable({} :: HistoryFields, History))

-- A ring buffer of (time, shape) samples. capacity defaults to 32 (0.53 s at 60 Hz).
function Hitbox.history(options: { capacity: number? }?): History
	local capacity = (options and options.capacity) or 32
	assert(
		Check.integer(capacity) and capacity >= 2 and capacity <= 1024,
		"Hitbox.history: capacity must be 2-1024"
	)
	return setmetatable({ _capacity = capacity, _times = {}, _shapes = {}, _head = 0, _count = 0 }, History)
end

local function slot(self: History, age: number): number
	-- age 0 is the newest sample.
	return (self._head - 1 - age) % self._capacity + 1
end

-- Records a pose at time t (non-decreasing; an equal time replaces the newest sample). Returns
-- false for a time older than the newest sample or an invalid shape.
function History.record(self: History, t: number, shape: Shape): boolean
	if not Check.finite(t) or not Hitbox.valid(shape) then
		return false
	end
	if self._count > 0 then
		local newest = self._times[slot(self, 0)]
		if t < newest then
			return false
		elseif t == newest then
			self._shapes[slot(self, 0)] = shape
			return true
		end
	end
	self._head = self._head % self._capacity + 1
	self._times[self._head] = t
	self._shapes[self._head] = shape
	self._count = math.min(self._count + 1, self._capacity)
	return true
end

-- The pose at time t: interpolated between the samples around it; the newest pose for t at or
-- after it; (nil, "too_old") before the oldest sample; (nil, "empty") with no samples.
function History.at(self: History, t: number): (Shape?, string?)
	if self._count == 0 then
		return nil, "empty"
	end
	local newestT = self._times[slot(self, 0)]
	if t >= newestT then
		return self._shapes[slot(self, 0)], nil
	end
	local oldestT = self._times[slot(self, self._count - 1)]
	if t < oldestT - Hitbox.EPSILON then
		return nil, "too_old"
	end
	for age = 0, self._count - 2 do
		local newer, older = slot(self, age), slot(self, age + 1)
		local t1, t0 = self._times[newer], self._times[older]
		if t >= t0 then
			local s0, s1 = self._shapes[older], self._shapes[newer]
			if s0.kind ~= s1.kind then
				return if t - t0 < t1 - t then s0 else s1, nil
			end
			local alpha = if t1 > t0 then (t - t0) / (t1 - t0) else 1
			return Hitbox.lerp(s0, s1, alpha), nil
		end
	end
	return self._shapes[slot(self, self._count - 1)], nil
end

function History.latest(self: History): (Shape?, number?)
	if self._count == 0 then
		return nil, nil
	end
	return self._shapes[slot(self, 0)], self._times[slot(self, 0)]
end

function History.oldest(self: History): number?
	if self._count == 0 then
		return nil
	end
	return self._times[slot(self, self._count - 1)]
end

function History.size(self: History): number
	return self._count
end

function History.clear(self: History)
	self._times, self._shapes, self._head, self._count = {}, {}, 0, 0
end

-- ---------------------------------------------------------------- melee activations

local Activation = {}
Activation.__index = Activation

type ActivationFields = {
	_hit: { [string]: boolean },
	_order: { string },
	_maxHits: number,
	_ignore: { [string]: boolean },
}
export type Activation = typeof(setmetatable({} :: ActivationFields, Activation))
export type Target = { id: string | number, shape: Shape }

-- One swing or one area pulse: each target id is reported at most once. maxHits caps a swing
-- (cleave limit); ignore lists ids never hit (the attacker).
function Hitbox.activation(options: { maxHits: number?, ignore: { string | number }? }?): Activation
	local maxHits = (options and options.maxHits) or math.huge
	assert(
		maxHits == math.huge or (Check.integer(maxHits) and maxHits >= 1),
		"Hitbox.activation: maxHits must be >= 1"
	)
	local ignore: { [string]: boolean } = {}
	for _, id in (options and options.ignore) or {} do
		ignore[tostring(id)] = true
	end
	return setmetatable({ _hit = {}, _order = {}, _maxHits = maxHits, _ignore = ignore }, Activation)
end

local function sortedTargets(targets: { Target }): { Target }
	local list = table.clone(targets)
	table.sort(list, function(a: Target, b: Target): boolean
		return tostring(a.id) < tostring(b.id)
	end)
	return list
end

-- New hits of shape against targets ({ { id, shape } }), sorted by id.
function Activation.test(self: Activation, shape: Shape, targets: { Target }): { string | number }
	local hits = {}
	for _, target in sortedTargets(targets) do
		local key = tostring(target.id)
		if #self._order >= self._maxHits then
			break
		end
		if not self._hit[key] and not self._ignore[key] and Hitbox.overlaps(shape, target.shape) then
			self._hit[key] = true
			table.insert(self._order, key)
			table.insert(hits, target.id)
		end
	end
	return hits
end

-- New hits along the poses between prev and curr (see sweepPoses), in the order they happen.
function Activation.sweep(
	self: Activation,
	prev: Shape,
	curr: Shape,
	targets: { Target },
	maxStep: number?
): { string | number }
	local hits = {}
	for _, pose in Hitbox.sweepPoses(prev, curr, maxStep) do
		for _, id in self:test(pose, targets) do
			table.insert(hits, id)
		end
	end
	return hits
end

function Activation.hits(self: Activation): { string }
	return table.clone(self._order)
end

function Activation.reset(self: Activation)
	self._hit, self._order = {}, {}
end

-- ---------------------------------------------------------------- server claim validation

export type ValidatorOptions = {
	maxRange: number,
	maxRewind: number?,
	interpolationDelay: number?,
	jitter: number?,
	originTolerance: number?,
	hitTolerance: number?,
	maxAngle: number?,
	fireInterval: number?,
	burst: number?,
	clampOld: boolean?,
	futureTolerance: number?,
	seenLimit: number?,
	capacity: number?,
	lineOfSight: ((origin: V3, point: V3, claim: any) -> boolean)?,
	alive: ((id: any) -> boolean)?,
}
export type Claim = {
	shooter: any,
	target: any,
	time: any,
	origin: any,
	direction: any,
	hitPoint: any?,
	shotId: any?,
}
export type Detail = {
	rewind: number?,
	window: number?,
	distance: number?,
	point: V3?,
	originError: number?,
}

local Validator = {}
Validator.__index = Validator

type Bucket = { tokens: number, at: number }
type ValidatorFields = {
	options: ValidatorOptions,
	_env: any,
	_histories: { [string]: History },
	_latency: { [string]: number },
	_buckets: { [string]: Bucket },
	_seen: { [string]: { order: { string }, set: { [string]: boolean } } },
	_stats: { accepted: number, rejected: { [string]: number } },
}
export type Validator = typeof(setmetatable({} :: ValidatorFields, Validator))

-- Problems with validator options (empty when valid).
function Hitbox.validateOptions(options: any): { string }
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	local problems = {}
	local function positive(key: string, required: boolean, allowZero: boolean)
		local value = options[key]
		if value == nil then
			if required then
				table.insert(problems, key .. " is required")
			end
		elseif not Check.finite(value) or value < 0 or (not allowZero and value == 0) then
			table.insert(
				problems,
				key .. " must be a finite number " .. (if allowZero then ">= 0" else "> 0")
			)
		end
	end
	positive("maxRange", true, false)
	positive("maxRewind", false, true)
	positive("interpolationDelay", false, true)
	positive("jitter", false, true)
	positive("originTolerance", false, true)
	positive("hitTolerance", false, true)
	positive("fireInterval", false, true)
	positive("futureTolerance", false, true)
	if
		options.maxRewind ~= nil
		and Check.finite(options.maxRewind)
		and options.maxRewind > Hitbox.MAX_REWIND
	then
		table.insert(
			problems,
			string.format("maxRewind must be <= %.3f s (Hitbox.MAX_REWIND)", Hitbox.MAX_REWIND)
		)
	end
	if
		options.maxAngle ~= nil
		and (not Check.finite(options.maxAngle) or options.maxAngle <= 0 or options.maxAngle > 180)
	then
		table.insert(problems, "maxAngle must be degrees in (0, 180]")
	end
	if options.burst ~= nil and (not Check.integer(options.burst) or options.burst < 1) then
		table.insert(problems, "burst must be an integer >= 1")
	end
	if options.seenLimit ~= nil and (not Check.integer(options.seenLimit) or options.seenLimit < 1) then
		table.insert(problems, "seenLimit must be an integer >= 1")
	end
	for _, key in { "lineOfSight", "alive" } do
		if options[key] ~= nil and type(options[key]) ~= "function" then
			table.insert(problems, key .. " must be a function")
		end
	end
	return problems
end

-- Server-side hit-claim validator. Record every entity's pose each simulation step with
-- record(id, shape); check(claim) answers (ok, reason, detail).
function Hitbox.validator(options: ValidatorOptions, env: any): Validator
	local problems = Hitbox.validateOptions(options)
	if #problems > 0 then
		error("Hitbox.validator: " .. table.concat(problems, "; "), 2)
	end
	assert(
		type(env) == "table" and type(env.clock) == "function",
		"Hitbox.validator needs an env with clock()"
	)
	local opts = table.clone(options)
	opts.maxRewind = opts.maxRewind or Hitbox.MAX_REWIND
	opts.interpolationDelay = opts.interpolationDelay or 0.1
	opts.jitter = opts.jitter or 0.05
	opts.originTolerance = opts.originTolerance or 4
	opts.hitTolerance = opts.hitTolerance or 0.5
	opts.burst = opts.burst or 2
	opts.futureTolerance = opts.futureTolerance or 0.01
	opts.seenLimit = opts.seenLimit or 256
	return setmetatable({
		options = table.freeze(opts),
		_env = env,
		_histories = {},
		_latency = {},
		_buckets = {},
		_seen = {},
		_stats = { accepted = 0, rejected = {} },
	}, Validator)
end

-- Records id's pose at the current server time (call once per simulation step).
function Validator.record(self: Validator, id: any, shape: Shape): boolean
	local key = tostring(id)
	local history = self._histories[key]
	if history == nil then
		history = Hitbox.history({ capacity = self.options.capacity })
		self._histories[key] = history
	end
	return (history :: History):record(self._env.clock(), shape)
end

function Validator.history(self: Validator, id: any): History?
	return self._histories[tostring(id)]
end

-- Server-measured one-way latency for a shooter (clamped to 0..maxRewind).
function Validator.setLatency(self: Validator, id: any, seconds: number)
	if Check.finite(seconds) then
		self._latency[tostring(id)] = math.clamp(seconds, 0, self.options.maxRewind :: number)
	end
end

function Validator.remove(self: Validator, id: any)
	local key = tostring(id)
	self._histories[key] = nil
	self._latency[key] = nil
	self._buckets[key] = nil
	self._seen[key] = nil
end

-- { accepted, rejected = { [reason] = count } }
function Validator.stats(self: Validator): { accepted: number, rejected: { [string]: number } }
	return Check.copy(self._stats)
end

local function reject(self: Validator, reason: string, detail: Detail?): (boolean, string, Detail)
	self._stats.rejected[reason] = (self._stats.rejected[reason] or 0) + 1
	return false, reason, detail or {}
end

local function validId(id: any): boolean
	return (type(id) == "string" and #id >= 1 and #id <= 64) or Check.finite(id)
end

local function poseAt(history: History, t: number): Shape?
	local shape, reason = history:at(t)
	if shape == nil and reason == "too_old" then
		-- The entity has no sample that old (it just spawned): use its oldest pose.
		local oldest = history:oldest()
		if oldest then
			shape = history:at(oldest)
		end
	end
	return shape
end

-- Checks one hit claim. Returns (true, nil, detail) or (false, reason, detail) where reason is
-- bad_claim, unknown_shooter, unknown_target, self_hit, rate_limited, duplicate_shot,
-- future_time, too_old, origin_mismatch, out_of_range, bad_angle, hitpoint_mismatch, miss,
-- no_line_of_sight or target_dead. Never raises on claim content.
function Validator.check(self: Validator, claim: Claim): (boolean, string?, Detail)
	local opts = self.options
	if type(claim) ~= "table" or not validId(claim.shooter) or not validId(claim.target) then
		return reject(self, "bad_claim")
	end
	local shooterKey, targetKey = tostring(claim.shooter), tostring(claim.target)
	local now = self._env.clock()
	-- Fire rate first, so malformed spam still spends tokens.
	if opts.fireInterval and opts.fireInterval > 0 then
		local bucket = self._buckets[shooterKey]
		local burst = opts.burst :: number
		if bucket == nil then
			bucket = { tokens = burst, at = now }
			self._buckets[shooterKey] = bucket
		end
		local b = bucket :: Bucket
		b.tokens = math.min(burst, b.tokens + math.max(0, now - b.at) / opts.fireInterval)
		b.at = now
		if b.tokens < 1 - Hitbox.EPSILON then
			return reject(self, "rate_limited")
		end
		b.tokens -= 1
	end
	if
		not Check.finite(claim.time)
		or not isVec(claim.origin)
		or not isVec(claim.direction)
		or Vec.length(claim.direction) < 1e-6
		or (claim.hitPoint ~= nil and not isVec(claim.hitPoint))
		or (claim.shotId ~= nil and not validId(claim.shotId))
	then
		return reject(self, "bad_claim")
	end
	if shooterKey == targetKey then
		return reject(self, "self_hit")
	end
	local shooterHistory = self._histories[shooterKey]
	if shooterHistory == nil then
		return reject(self, "unknown_shooter")
	end
	local targetHistory = self._histories[targetKey]
	if targetHistory == nil then
		return reject(self, "unknown_target")
	end
	if claim.shotId ~= nil then
		local seen = self._seen[shooterKey]
		if seen == nil then
			seen = { order = {}, set = {} }
			self._seen[shooterKey] = seen
		end
		local s = seen :: { order: { string }, set: { [string]: boolean } }
		local id = tostring(claim.shotId)
		if s.set[id] then
			return reject(self, "duplicate_shot")
		end
		s.set[id] = true
		table.insert(s.order, id)
		if #s.order > (opts.seenLimit :: number) then
			s.set[table.remove(s.order, 1) :: string] = nil
		end
	end
	local window = math.min(
		opts.maxRewind :: number,
		(self._latency[shooterKey] or 0) + (opts.interpolationDelay :: number) + (opts.jitter :: number)
	)
	local detail: Detail = { window = window }
	local t = claim.time :: number
	if t > now + (opts.futureTolerance :: number) then
		return reject(self, "future_time", detail)
	end
	if t < now - window - Hitbox.EPSILON then
		if not opts.clampOld then
			detail.rewind = now - t
			return reject(self, "too_old", detail)
		end
		t = now - window
	end
	t = math.min(t, now)
	detail.rewind = now - t
	local shooterShape = poseAt(shooterHistory, t)
	local targetShape = poseAt(targetHistory, t)
	if shooterShape == nil then
		return reject(self, "unknown_shooter", detail)
	end
	if targetShape == nil then
		return reject(self, "unknown_target", detail)
	end
	local origin = claim.origin :: V3
	local originError = Hitbox.distance(shooterShape, origin)
	detail.originError = originError
	if originError > (opts.originTolerance :: number) then
		return reject(self, "origin_mismatch", detail)
	end
	local tolerance = opts.hitTolerance :: number
	local nearest = Hitbox.closestPoint(targetShape, origin)
	if Vec.length(Vec.sub(nearest, origin)) > opts.maxRange + tolerance then
		detail.distance = Vec.length(Vec.sub(nearest, origin))
		return reject(self, "out_of_range", detail)
	end
	local direction = Vec.unit(claim.direction :: V3)
	if claim.hitPoint ~= nil then
		local hitPoint = claim.hitPoint :: V3
		local toHit = Vec.sub(hitPoint, origin)
		local hitDistance = Vec.length(toHit)
		detail.distance = hitDistance
		if hitDistance > opts.maxRange + tolerance then
			return reject(self, "out_of_range", detail)
		end
		if opts.maxAngle and hitDistance > 1e-6 then
			local cosine = math.clamp(Vec.dot(direction, Vec.scale(toHit, 1 / hitDistance)), -1, 1)
			if math.deg(math.acos(cosine)) > opts.maxAngle then
				return reject(self, "bad_angle", detail)
			end
		end
		if Hitbox.distance(targetShape, hitPoint) > tolerance then
			return reject(self, "hitpoint_mismatch", detail)
		end
	end
	local hit, fraction, point =
		Hitbox.segment(targetShape, origin, Vec.scale(direction, opts.maxRange), tolerance)
	if not hit then
		return reject(self, "miss", detail)
	end
	detail.point = point
	detail.distance = detail.distance or (fraction :: number) * opts.maxRange
	if opts.lineOfSight then
		local ok, clear = pcall(opts.lineOfSight, origin, claim.hitPoint or point :: V3, claim)
		if not ok then
			self._env.report("Hitbox.validator lineOfSight failed: " .. tostring(clear))
		end
		if not ok or clear ~= true then
			return reject(self, "no_line_of_sight", detail)
		end
	end
	if opts.alive then
		local ok, alive = pcall(opts.alive, claim.target)
		if not ok or alive ~= true then
			return reject(self, "target_dead", detail)
		end
	end
	self._stats.accepted += 1
	return true, nil, detail
end

return Hitbox
