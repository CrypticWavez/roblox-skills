--!strict
-- @tier T0
-- Spline: curves for camera paths (docs/uikit.md "Cinematics"). Points are arrays of numbers
-- ({ x, y, z } or any dimension), so the maths is plain Luau that runs the same in Lune and
-- Roblox. Centripetal Catmull-Rom (alpha 0.5, the Barry-Goldman form) passes exactly through
-- every point, has no cusps or self-intersections inside a segment and stays close to the
-- control polygon; alpha 0 is uniform and 1 chordal. Paths get phantom end points by
-- reflection (p[0] = 2 p[1] - p[2]). Cubic Bezier is there for hand-shaped segments. Arc length
-- comes from a sampled table (arcTable) so a path can be walked at constant speed (atDistance).
local Spline = {}

export type Point = { number }
export type ArcEntry = { s: number, segment: number, u: number }
export type ArcTable = { total: number, entries: { ArcEntry }, segments: number }

local EPSILON = 1e-9

local function lerp(a: Point, b: Point, t: number): Point
	local out = table.create(#a)
	for index, value in a do
		out[index] = value + (b[index] - value) * t
	end
	return out
end

local function distance(a: Point, b: Point): number
	local sum = 0
	for index, value in a do
		local d = b[index] - value
		sum += d * d
	end
	return math.sqrt(sum)
end
Spline.distance = distance

-- Weighted sum (wa * a + wb * b) / (wa + wb) with a zero-span guard.
local function blend(a: Point, b: Point, ta: number, tb: number, t: number): Point
	local span = tb - ta
	if math.abs(span) < EPSILON then
		return table.clone(a)
	end
	return lerp(a, b, (t - ta) / span)
end

-- A point on the centripetal (alpha 0.5) Catmull-Rom segment from p1 (u = 0) to p2 (u = 1).
function Spline.catmullRom(p0: Point, p1: Point, p2: Point, p3: Point, u: number, alpha: number?): Point
	if u <= 0 then
		return table.clone(p1)
	elseif u >= 1 then
		return table.clone(p2)
	end
	local a = alpha or 0.5
	-- Knot intervals |p(i+1) - p(i)|^alpha, floored so repeated points do not divide by zero.
	local t0 = 0
	local t1 = t0 + math.max(distance(p0, p1) ^ a, 1e-4)
	local t2 = t1 + math.max(distance(p1, p2) ^ a, 1e-4)
	local t3 = t2 + math.max(distance(p2, p3) ^ a, 1e-4)
	local t = t1 + (t2 - t1) * u
	local a1 = blend(p0, p1, t0, t1, t)
	local a2 = blend(p1, p2, t1, t2, t)
	local a3 = blend(p2, p3, t2, t3, t)
	local b1 = blend(a1, a2, t0, t2, t)
	local b2 = blend(a2, a3, t1, t3, t)
	return blend(b1, b2, t1, t2, t)
end

-- A point on a cubic Bezier.
function Spline.bezier(p0: Point, p1: Point, p2: Point, p3: Point, u: number): Point
	local t = math.clamp(u, 0, 1)
	local s = 1 - t
	local out = table.create(#p0)
	for index = 1, #p0 do
		out[index] = s * s * s * p0[index]
			+ 3 * s * s * t * p1[index]
			+ 3 * s * t * t * p2[index]
			+ t * t * t * p3[index]
	end
	return out
end

local function reflect(a: Point, b: Point): Point
	local out = table.create(#a)
	for index, value in a do
		out[index] = 2 * value - b[index]
	end
	return out
end

-- The four control points of segment i (1-based, from points[i] to points[i + 1]) with
-- reflected phantom points at the ends.
function Spline.controls(points: { Point }, segment: number): (Point, Point, Point, Point)
	local n = #points
	assert(n >= 2, "Spline.controls: needs at least two points")
	assert(segment >= 1 and segment <= n - 1, "Spline.controls: segment out of range")
	local p1, p2 = points[segment], points[segment + 1]
	local p0 = if segment > 1 then points[segment - 1] else reflect(p1, p2)
	local p3 = if segment + 2 <= n then points[segment + 2] else reflect(p2, p1)
	return p0, p1, p2, p3
end

-- A point on the path through points: segment (1-based) and u in 0-1.
function Spline.point(points: { Point }, segment: number, u: number, alpha: number?): Point
	local p0, p1, p2, p3 = Spline.controls(points, segment)
	return Spline.catmullRom(p0, p1, p2, p3, u, alpha)
end

-- A cumulative arc-length table with samples entries per segment.
function Spline.arcTable(points: { Point }, samples: number?, alpha: number?): ArcTable
	local per = samples or 32
	assert(per >= 2 and per <= 1024, "Spline.arcTable: samples must be 2-1024")
	local entries: { ArcEntry } = { { s = 0, segment = 1, u = 0 } }
	local total = 0
	local previous = points[1]
	for segment = 1, #points - 1 do
		for step = 1, per do
			local u = step / per
			local point = Spline.point(points, segment, u, alpha)
			total += distance(previous, point)
			table.insert(entries, { s = total, segment = segment, u = u })
			previous = point
		end
	end
	return { total = total, entries = entries, segments = #points - 1 }
end

-- (segment, u) at arc length s along a table (clamped to the path).
function Spline.atDistance(arc: ArcTable, s: number): (number, number)
	local entries = arc.entries
	if s <= 0 or arc.total <= EPSILON then
		return 1, 0
	end
	if s >= arc.total then
		return arc.segments, 1
	end
	local lo, hi = 1, #entries
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if entries[mid].s < s then
			lo = mid
		else
			hi = mid
		end
	end
	local a, b = entries[lo], entries[hi]
	local span = b.s - a.s
	local f = if span > EPSILON then (s - a.s) / span else 0
	if a.segment ~= b.segment then
		-- a closes the previous segment (u = 1): b's segment starts at u = 0.
		return b.segment, f * b.u
	end
	return b.segment, a.u + (b.u - a.u) * f
end

Spline.lerp = lerp

return Spline
