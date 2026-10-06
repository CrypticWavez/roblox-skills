--!strict
-- Course generators: seeded play spaces whose every jump is sized from the character's real jump
-- physics (SceneKit Measure.profile: gravity, WalkSpeed, JumpHeight), so a layout is playable by
-- construction and ProcGen Validate.course can prove it from the geometry alone.
--   linear      obstacle course: pads linked by gaps, steps, drops, beams, side jumps, hazards
--   tower       spiral of pads around a core, one turn per floor, a checkpoint ending each floor
--   race_loop   closed centripetal Catmull-Rom track with width, grade, banking and gates
--   lanes       parallel paths from a spawn edge to a base with build slots (equal lengths)
--   micro_arena small symmetric arena: spawn ring, cover, hazards for party rounds
-- Every generator takes { seed, length | floors | laps | lanes | players, difficultyCurve,
-- segmentKinds, playerScale } (plus the options listed per generator) and returns a course/1
-- manifest: plain data with segments, checkpoints, spawn, finish and a hash (Manifest.hash of
-- everything but the hash). Same seed, same hash. Difficulty is the share of the safe jump a
-- challenge uses (Course.DIFFICULTY); limits marked "convention" are level-design choices, not
-- Roblox numbers. Course.toScene(course, style) emits the SceneKit plan (ProcGen/CourseScene).
local CourseScene = require("./CourseScene")
local Manifest = require("./Manifest")
local Measure = require("../SceneKit/Measure")
local Rng = require("./Rng")

local Course = {}
Course.SCHEMA = "course/1"
Course.KINDS = table.freeze({ "linear", "tower", "race_loop", "lanes", "micro_arena" })
Course.SEGMENT_KINDS = table.freeze({
	linear = table.freeze({ "gap", "step_up", "step_down", "narrow", "zigzag", "hazard" }),
	tower = table.freeze({ "gap", "narrow" }),
	race_loop = table.freeze({ "straight", "sweeper", "corner", "hill" }),
	lanes = table.freeze({ "straight", "switchback" }),
	micro_arena = table.freeze({ "cover", "hazard", "tiles" }),
})
-- Share of the safe jump (reach x (1 - margin)) a challenge uses at difficulty 0 and 1.
Course.DIFFICULTY = table.freeze({ min = 0.35, max = 0.95 })
-- Beam widths at difficulty 0 and 1, studs (convention: 1.5 is still landable for R15).
Course.NARROW = table.freeze({ wide = 3, narrow = 1.5 })
Course.PAD_THICKNESS = 1
Course.WALK_GAP = 0.05 -- pads closer than this connect by walking
Course.MARGIN = 0.15 -- canJump safety margin (Measure.canJump default)
-- Micro-arena spacing (convention, scaled by body size): studs between spawns, and from a spawn
-- to the nearest cover or hazard.
Course.ARENA = table.freeze({ minSpawnSeparation = 8, spawnClear = 4 })
-- Race gates: at most this many studs apart (convention); the generator adds gates to keep it.
Course.MAX_GATE_SPACING = 400

export type V3 = { x: number, y: number, z: number }
export type Pad = { id: string, role: string, pos: V3, size: V3, yaw: number }
export type Course = { [string]: any }

local function r3(value: number): number
	return math.round(value * 1000) / 1000
end

local function v3(x: number, y: number, z: number): V3
	return { x = r3(x), y = r3(y), z = r3(z) }
end

local function clamp(value: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, value))
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- ---------------------------------------------------------------- difficulty curve

-- Problems with a difficulty curve: nil (0.15 -> 0.85), a number in [0, 1] (flat),
-- { from, to, shape = "linear" | "ease_in" | "ease_out" | "smooth" } or { points = { {t, d}, ... } }
-- with t rising from 0 to 1 and d in [0, 1].
function Course.curveProblems(spec: any): { string }
	local problems = {}
	local function unit(value: any, what: string)
		if type(value) ~= "number" or value ~= value or value < 0 or value > 1 then
			table.insert(problems, what .. " must be a number in [0, 1]")
		end
	end
	if spec == nil then
		return problems
	elseif type(spec) == "number" then
		unit(spec, "difficultyCurve")
	elseif type(spec) ~= "table" then
		table.insert(problems, "difficultyCurve must be nil, a number or a table")
	elseif spec.points ~= nil then
		if type(spec.points) ~= "table" or #spec.points < 2 then
			table.insert(problems, "difficultyCurve.points needs at least 2 { t, d } points")
		else
			local last = -1
			for index, point in spec.points do
				if type(point) ~= "table" then
					table.insert(problems, "difficultyCurve.points[" .. index .. "] must be { t, d }")
					continue
				end
				unit(point[1], "difficultyCurve.points[" .. index .. "][1]")
				unit(point[2], "difficultyCurve.points[" .. index .. "][2]")
				if type(point[1]) == "number" and point[1] <= last then
					table.insert(problems, "difficultyCurve.points must rise in t")
				end
				last = if type(point[1]) == "number" then point[1] else last
			end
			if #problems == 0 and (spec.points[1][1] ~= 0 or spec.points[#spec.points][1] ~= 1) then
				table.insert(problems, "difficultyCurve.points must start at t = 0 and end at t = 1")
			end
		end
	else
		unit(spec.from or 0.15, "difficultyCurve.from")
		unit(spec.to or 0.85, "difficultyCurve.to")
		local shape = spec.shape or "linear"
		if shape ~= "linear" and shape ~= "ease_in" and shape ~= "ease_out" and shape ~= "smooth" then
			table.insert(problems, "difficultyCurve.shape must be linear, ease_in, ease_out or smooth")
		end
	end
	return problems
end

-- The curve as a function of progress t in [0, 1] (raises on a bad spec).
function Course.curve(spec: any): (t: number) -> number
	local problems = Course.curveProblems(spec)
	if #problems > 0 then
		error("Course.curve: " .. table.concat(problems, "; "), 2)
	end
	if type(spec) == "number" then
		return function()
			return spec
		end
	end
	local points = spec and spec.points
	if points then
		return function(t: number): number
			t = clamp(t, 0, 1)
			for index = 2, #points do
				local a, b = points[index - 1], points[index]
				if t <= b[1] then
					return lerp(a[2], b[2], (t - a[1]) / (b[1] - a[1]))
				end
			end
			return points[#points][2]
		end
	end
	local from = spec and spec.from or 0.15
	local to = spec and spec.to or 0.85
	local shape = spec and spec.shape or "linear"
	return function(t: number): number
		t = clamp(t, 0, 1)
		local k = if shape == "ease_in"
			then t * t
			elseif shape == "ease_out" then 1 - (1 - t) * (1 - t)
			elseif shape == "smooth" then t * t * (3 - 2 * t)
			else t
		return lerp(from, to, k)
	end
end

-- ---------------------------------------------------------------- pad geometry (shared with Validate)

-- Local axes of a yawed pad in (x, z): local X = (cos, -sin), local Z = (sin, cos) (Vec.rotateY).
local function axes(yaw: number): (number, number, number, number)
	local r = math.rad(yaw)
	local c, s = math.cos(r), math.sin(r)
	return c, -s, s, c
end

-- Distance from a pad's centre to its edge along the unit direction (ux, uz).
function Course.exitDistance(pad: Pad, ux: number, uz: number): number
	local ax, az, bx, bz = axes(pad.yaw)
	local lx = math.abs(ux * ax + uz * az)
	local lz = math.abs(ux * bx + uz * bz)
	local t = math.huge
	if lx > 1e-9 then
		t = math.min(t, pad.size.x / 2 / lx)
	end
	if lz > 1e-9 then
		t = math.min(t, pad.size.z / 2 / lz)
	end
	return t
end

-- Footprint corners in (x, z), counter-clockwise, grown by `grow` studs on every side.
function Course.corners(pad: Pad, grow: number?): { { number } }
	local g = grow or 0
	local ax, az, bx, bz = axes(pad.yaw)
	local a, b = pad.size.x / 2 + g, pad.size.z / 2 + g
	local out = {}
	for _, s in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		table.insert(
			out,
			{ pad.pos.x + ax * a * s[1] + bx * b * s[2], pad.pos.z + az * a * s[1] + bz * b * s[2] }
		)
	end
	return out
end

-- Separating-axis depth of two convex footprints: the smallest overlap of their projections
-- over both rectangles' edge normals (> 0 overlapping, <= 0 apart or touching).
local function overlapDepth(ca: { { number } }, cb: { { number } }): number
	local depth = math.huge
	for _, poly in { ca, cb } do
		for index = 1, 4 do
			local p, q = poly[index], poly[index % 4 + 1]
			local nx, nz = q[2] - p[2], p[1] - q[1]
			local len = math.sqrt(nx * nx + nz * nz)
			nx, nz = nx / len, nz / len
			local amin, amax, bmin, bmax = math.huge, -math.huge, math.huge, -math.huge
			for _, c in ca do
				local d = c[1] * nx + c[2] * nz
				amin, amax = math.min(amin, d), math.max(amax, d)
			end
			for _, c in cb do
				local d = c[1] * nx + c[2] * nz
				bmin, bmax = math.min(bmin, d), math.max(bmax, d)
			end
			depth = math.min(depth, math.min(amax, bmax) - math.max(amin, bmin))
		end
	end
	return depth
end

-- Separating-axis test on two footprints (grown by `grow`): true when they overlap by more than 1e-6.
function Course.footprintsOverlap(a: Pad, b: Pad, grow: number?): boolean
	return overlapDepth(Course.corners(a, grow), Course.corners(b, grow)) > 1e-6
end

local function pointSegment(px: number, pz: number, a: { number }, b: { number }): number
	local dx, dz = b[1] - a[1], b[2] - a[2]
	local len2 = dx * dx + dz * dz
	local t = if len2 > 0 then clamp(((px - a[1]) * dx + (pz - a[2]) * dz) / len2, 0, 1) else 0
	local cx, cz = a[1] + dx * t, a[2] + dz * t
	return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
end

-- Horizontal gap between two pads: the shortest distance between their footprints, i.e. the
-- jump a player makes from the best edge (diagonal pads are measured corner to corner). <= 0 when
-- the footprints touch or overlap (minus the overlap depth).
function Course.padGap(a: Pad, b: Pad): number
	local ca, cb = Course.corners(a), Course.corners(b)
	local depth = overlapDepth(ca, cb)
	if depth > 0 then
		return -depth
	end
	local best = math.huge
	for _, pair in { { ca, cb }, { cb, ca } } do
		local points, poly = pair[1], pair[2]
		for _, point in points do
			for index = 1, 4 do
				best = math.min(best, pointSegment(point[1], point[2], poly[index], poly[index % 4 + 1]))
			end
		end
	end
	return best
end

-- Whether a point (x, z) lies on a pad's footprint (grown by `grow`).
function Course.onPad(pad: Pad, x: number, z: number, grow: number?): boolean
	local ax, az, bx, bz = axes(pad.yaw)
	local dx, dz = x - pad.pos.x, z - pad.pos.z
	local g = grow or 0
	return math.abs(dx * ax + dz * az) <= pad.size.x / 2 + g + 1e-9
		and math.abs(dx * bx + dz * bz) <= pad.size.z / 2 + g + 1e-9
end

-- Horizontal distance from a point (x, z) to a pad's footprint (0 on it).
function Course.footprintDistance(pad: Pad, x: number, z: number): number
	local ax, az, bx, bz = axes(pad.yaw)
	local dx, dz = x - pad.pos.x, z - pad.pos.z
	local ox = math.max(math.abs(dx * ax + dz * az) - pad.size.x / 2, 0)
	local oz = math.max(math.abs(dx * bx + dz * bz) - pad.size.z / 2, 0)
	return math.sqrt(ox * ox + oz * oz)
end

-- Safe horizontal jump for a rise: reach x (1 - margin), or nil when the rise is out of reach.
function Course.safeGap(rise: number, profile: any, margin: number?): number?
	local reach = Measure.jumpReach(rise, profile)
	if reach == nil then
		return nil
	end
	return reach * (1 - (margin or Course.MARGIN))
end

-- ---------------------------------------------------------------- params

local function knownKinds(kind: string, params: any, problems: { string }): { string }
	local all = Course.SEGMENT_KINDS[kind]
	local chosen = params.segmentKinds or all
	if type(chosen) ~= "table" or #chosen == 0 then
		table.insert(problems, "segmentKinds must be a non-empty list")
		return all
	end
	for _, name in chosen do
		if not table.find(all, name) then
			table.insert(
				problems,
				string.format(
					"unknown %s segment kind %s (known: %s)",
					kind,
					tostring(name),
					table.concat(all, ", ")
				)
			)
		end
	end
	return chosen
end

local function positiveInteger(
	params: any,
	key: string,
	default: number,
	lo: number,
	hi: number,
	problems: { string }
)
	local value = params[key]
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value % 1 ~= 0 or value < lo or value > hi then
		table.insert(
			problems,
			string.format("%s must be an integer in [%d, %d] (got %s)", key, lo, hi, tostring(value))
		)
		return default
	end
	return value
end

local function positiveNumber(params: any, key: string, default: number, problems: { string }): number
	local value = params[key]
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		table.insert(problems, string.format("%s must be a finite number > 0 (got %s)", key, tostring(value)))
		return default
	end
	return value
end

local function failOn(kind: string, problems: { string })
	if #problems > 0 then
		error("Course." .. kind .. ": " .. table.concat(problems, "; "), 3)
	end
end

local function begin(kind: string, params: any): (any, { string }, { string })
	local problems = {}
	if type(params) ~= "table" then
		error("Course." .. kind .. ": params must be a table", 3)
	end
	if type(params.seed) ~= "number" and type(params.seed) ~= "string" then
		table.insert(problems, "seed must be a number or a string")
	end
	for _, problem in Course.curveProblems(params.difficultyCurve) do
		table.insert(problems, problem)
	end
	local okProfile, profile = pcall(Measure.profile, params.playerScale)
	if not okProfile then
		table.insert(problems, "playerScale: " .. tostring(profile))
		failOn(kind, problems)
	end
	local kinds = knownKinds(kind, params, problems)
	return profile, kinds, problems
end

local function profileRecord(profile: any): { [string]: number }
	return {
		gravity = profile.gravity,
		walkSpeed = profile.walkSpeed,
		jumpHeight = profile.jumpHeight,
		characterHeight = profile.characterHeight,
		characterWidth = profile.characterWidth,
	}
end

-- Plain-data params as recorded in the manifest (no functions, sorted by Manifest.encode).
local function recordParams(params: any, extra: { [string]: any }): { [string]: any }
	local out: { [string]: any } = {}
	for key, value in params do
		if type(value) ~= "function" then
			out[key] = value
		end
	end
	for key, value in extra do
		out[key] = value
	end
	return out
end

function Course.hash(course: Course): string
	local body = table.clone(course)
	body.hash = nil
	return Manifest.hash(body)
end

local function seal(course: Course): Course
	course.hash = Course.hash(course)
	return course
end

-- ---------------------------------------------------------------- jump courses

local function newPad(
	id: string,
	role: string,
	x: number,
	top: number,
	z: number,
	sx: number,
	sz: number,
	yaw: number
): Pad
	return {
		id = id,
		role = role,
		pos = v3(x, top, z),
		size = v3(sx, Course.PAD_THICKNESS, sz),
		yaw = r3(yaw % 360),
	}
end

-- Places pad `b` (size and yaw set, position ignored) so its centre-line gap from `a` along the
-- unit direction (ux, uz) is exactly `gap`, `rise` higher.
local function placeAlong(a: Pad, b: Pad, ux: number, uz: number, gap: number, rise: number): Pad
	-- The footprint distance grows monotonically as b slides away along (ux, uz) (it is convex in
	-- the slide and 0 at the start), so bisection finds the slide that leaves exactly `gap`.
	local lo = 0
	local hi = gap + math.sqrt(a.size.x ^ 2 + a.size.z ^ 2) + math.sqrt(b.size.x ^ 2 + b.size.z ^ 2) + 1
	for _ = 1, 60 do
		local mid = (lo + hi) / 2
		b.pos = { x = a.pos.x + ux * mid, y = a.pos.y + rise, z = a.pos.z + uz * mid }
		if Course.padGap(a, b) > gap then
			hi = mid
		else
			lo = mid
		end
	end
	local d = (lo + hi) / 2
	b.pos = v3(a.pos.x + ux * d, a.pos.y + rise, a.pos.z + uz * d)
	return b
end

local function headroom(profile: any): number
	return profile.jumpHeight + profile.characterHeight + Course.PAD_THICKNESS
end

-- True when `pad` collides with an earlier pad (other than `except`) in plan and height band.
local function collides(pads: { Pad }, pad: Pad, except: Pad?, clearance: number): boolean
	for _, other in pads do
		if other ~= except and math.abs(other.pos.y - pad.pos.y) < clearance then
			if Course.footprintsOverlap(other, pad, 1) then
				return true
			end
		end
	end
	return false
end

local function pickKind(
	rng: Rng.Rng,
	kinds: { string },
	history: { string },
	allow: (string) -> boolean
): string
	local options = {}
	for _, name in kinds do
		local repeated = #history >= 2 and history[#history] == name and history[#history - 1] == name
		if allow(name) and not repeated then
			table.insert(options, name)
		end
	end
	if #options == 0 then
		for _, name in kinds do
			if allow(name) then
				table.insert(options, name)
			end
		end
	end
	if #options == 0 then
		return "gap"
	end
	return rng:pick(options)
end

-- Linear obstacle course. Options: length (challenge segments, default 24), checkpointEvery
-- (default 5), baseHeight (spawn top, default 6), turnChance (at checkpoints, default 0.6),
-- margin (default 0.15), jitter (difficulty noise, default 0.04).
function Course.linear(params: any): Course
	local profile, kinds, problems = begin("linear", params)
	local length = positiveInteger(params, "length", 24, 2, 400, problems)
	local every = positiveInteger(params, "checkpointEvery", 5, 2, 50, problems)
	local margin = params.margin or Course.MARGIN
	local jitter = params.jitter or 0.04
	local baseY = params.baseHeight or 6
	local turnChance = params.turnChance or 0.6
	failOn("linear", problems)
	local curve = Course.curve(params.difficultyCurve)
	local rng = Rng.new(params.seed)
	local kindRng, sizeRng, turnRng = rng:fork("kinds"), rng:fork("sizes"), rng:fork("turns")
	local maxRise = profile.jumpHeight * 0.75 -- convention: a quarter of the jump height spare
	local clearance = headroom(profile)

	local pads: { Pad } = { newPad("p000", "spawn", 0, baseY, 0, 12, 12, 0) }
	local segments, checkpoints, hazards = {}, {}, {}
	local history: { string } = {}
	local yaw, turnSign = 0, if turnRng:chance(0.5) then 1 else -1
	local pendingTurn = false
	local lastCheckpointPad = 0
	-- Whether a player on pad a reaches pad b with the full jump (no margin): the generator keeps
	-- every pad before a checkpoint out of reach of every pad after it, so none can be skipped.
	local function reaches(a: Pad, b: Pad): boolean
		local gap, rise = Course.padGap(a, b), b.pos.y - a.pos.y
		if gap <= Course.WALK_GAP and math.abs(rise) <= Measure.GUIDE.maxStep then
			return true
		end
		return rise <= profile.jumpHeight and Measure.canJump(math.max(gap, 0), rise, 0, profile)
	end
	for index = 1, length do
		local prev = pads[#pads]
		local t = if length > 1 then (index - 1) / (length - 1) else 1
		local d = clamp(curve(t) + sizeRng:range(-jitter, jitter), 0, 1)
		local s = lerp(Course.DIFFICULTY.min, Course.DIFFICULTY.max, d)
		local isLast = index == length
		local isRest = not isLast and index % every == 0
		local kind = pickKind(kindRng, kinds, history, function(name: string): boolean
			-- A beam is walked onto, so it never follows a turn (the link after a turn leaves
			-- diagonally) and never ends a stretch (checkpoint and finish pads are wide).
			if name == "narrow" and (isRest or isLast or pendingTurn) then
				return false
			end
			if name == "step_down" and prev.pos.y - baseY < 2 then
				return false
			end
			return true
		end)
		table.insert(history, kind)

		local role = if isLast then "finish" elseif isRest then "checkpoint" else "platform"
		local sx, sz = lerp(8, 4, d) + sizeRng:range(0, 1), lerp(8, 4, d) + sizeRng:range(0, 1)
		if role ~= "platform" then
			sx, sz = 12, 12
		elseif kind == "narrow" then
			sx, sz = lerp(10, 16, d), lerp(Course.NARROW.wide, Course.NARROW.narrow, d)
		end
		local rise, gap, lateral = 0, 0, 0
		if kind == "step_up" then
			rise = lerp(1.5, maxRise, d)
		elseif kind == "step_down" then
			rise = -math.min(lerp(2, 6, d), prev.pos.y - baseY)
		end
		if kind == "narrow" then
			gap = 0.01 -- a seam, walked across (Course.WALK_GAP)
		else
			gap = s * (Course.safeGap(rise, profile, margin) :: number)
		end
		if kind == "zigzag" then
			lateral = (if sizeRng:chance(0.5) then 1 else -1) * math.rad(sizeRng:range(25, 40))
		end

		-- Candidate headings: after a checkpoint the course may turn (either way, or not at all);
		-- a zigzag may go either side. The first link after a turn leaves diagonally, away from
		-- the pads before the checkpoint. The first candidate that overlaps nothing and keeps the
		-- checkpoint unskippable wins.
		local options = {}
		local yaws = if pendingTurn
			then { (yaw + 90 * turnSign) % 360, (yaw - 90 * turnSign) % 360, yaw }
			else { yaw }
		for _, candidateYaw in yaws do
			local laterals = if lateral ~= 0 then { lateral, -lateral } else { 0 }
			if candidateYaw ~= yaw then
				local ox, oz = axes(yaw)
				local nx, nz = axes(candidateYaw)
				local beta = math.max(math.abs(lateral), math.rad(30))
				-- Positive beta rotates (nx, nz) towards (-nz, nx); pick the sign facing the old heading.
				local sign = if (-nz * ox + nx * oz) >= 0 then 1 else -1
				laterals = { sign * beta }
			end
			for _, candidateLateral in laterals do
				table.insert(options, { yaw = candidateYaw, lateral = candidateLateral })
			end
		end
		local pad: Pad? = nil
		local chosen = options[1]
		for _, option in options do
			local candidate = newPad(string.format("p%03d", index), role, 0, 0, 0, sx, sz, option.yaw)
			local hx0, hz0 = axes(option.yaw)
			local ux, uz = hx0, hz0
			if option.lateral ~= 0 then
				-- Rotate the heading by `lateral` radians in the (x, z) plane.
				local c, sn = math.cos(option.lateral), math.sin(option.lateral)
				ux, uz = hx0 * c - hz0 * sn, hx0 * sn + hz0 * c
			end
			placeAlong(prev, candidate, ux, uz, gap, rise)
			local ok = not collides(pads, candidate, prev, clearance)
			for p = 1, lastCheckpointPad - 1 do
				if ok and reaches(pads[p], candidate) then
					ok = false
				end
			end
			if ok then
				pad, chosen = candidate, option
				break
			end
		end
		if pad == nil then
			error(
				string.format(
					"Course.linear: segment %d overlaps an earlier pad or skips a checkpoint (seed %s)",
					index,
					tostring(params.seed)
				)
			)
		end
		assert(pad)
		if chosen.yaw ~= yaw then
			turnSign = if (chosen.yaw - yaw) % 360 == 90 then -1 else 1
		end
		yaw = chosen.yaw
		pendingTurn = false
		lateral = chosen.lateral
		local hx, hz = axes(yaw)
		table.insert(pads, pad)
		local segment: { [string]: any } = {
			index = index,
			kind = kind,
			from = #pads - 1,
			to = #pads,
			gap = r3(gap),
			rise = r3(rise),
			difficulty = r3(s),
		}
		if kind == "hazard" then
			-- A kill strip under the gap: missing the jump lands on it. Its top sits 0.6 below the pads.
			local width = math.min(prev.size.z, pad.size.z) - 0.5
			local cx = prev.pos.x + hx * (Course.exitDistance(prev, hx, hz) + gap / 2)
			local cz = prev.pos.z + hz * (Course.exitDistance(prev, hx, hz) + gap / 2)
			local hazard = {
				segment = index,
				pos = v3(cx, prev.pos.y - 0.6, cz),
				size = v3(gap - 0.2, 0.4, width),
				yaw = r3(yaw),
			}
			segment.hazard = hazard
			table.insert(hazards, hazard)
		end
		table.insert(segments, segment)
		if isRest then
			local k = #checkpoints + 1
			table.insert(checkpoints, {
				index = k,
				pad = #pads,
				segment = index,
				pos = pad.pos,
				size = { x = pad.size.x, z = pad.size.z },
				respawn = { pos = v3(pad.pos.x, pad.pos.y + 3, pad.pos.z), yaw = pad.yaw },
			})
			lastCheckpointPad = #pads
			pendingTurn = turnRng:chance(turnChance)
		end
	end
	local spawnPad, finishPad = pads[1], pads[#pads]
	local minY = math.huge
	for _, pad in pads do
		minY = math.min(minY, pad.pos.y)
	end
	return seal({
		schema = Course.SCHEMA,
		kind = "linear",
		params = recordParams(params, { length = length, checkpointEvery = every, margin = margin }),
		profile = profileRecord(profile),
		pads = pads,
		segments = segments,
		checkpoints = checkpoints,
		hazards = hazards,
		spawn = { pad = 1, pos = spawnPad.pos, yaw = spawnPad.yaw, size = { x = 12, z = 12 } },
		finish = {
			pad = #pads,
			pos = finishPad.pos,
			yaw = finishPad.yaw,
			size = { x = finishPad.size.x, z = finishPad.size.z },
		},
		killY = r3(minY - 30),
	})
end

-- Tower: pads spiral around a core, rising floorHeight per full turn, with a checkpoint pad at
-- the end of every floor but the top one (the finish). Options: floors (default 5),
-- floorHeight (default: jump height + character height + pad + 2, rounded up), coreRadius
-- (default 8), margin, jitter.
function Course.tower(params: any): Course
	local profile, kinds, problems = begin("tower", params)
	local floors = positiveInteger(params, "floors", 5, 1, 60, problems)
	local defaultFloor = math.ceil(headroom(profile) + 2)
	local floorHeight = positiveNumber(params, "floorHeight", defaultFloor, problems)
	local coreRadius = positiveNumber(params, "coreRadius", 8, problems)
	if floorHeight < headroom(profile) then
		table.insert(
			problems,
			string.format(
				"floorHeight %.2f leaves no jump headroom (needs >= %.2f)",
				floorHeight,
				headroom(profile)
			)
		)
	end
	local margin = params.margin or Course.MARGIN
	local jitter = params.jitter or 0.04
	local baseY = params.baseHeight or 4
	failOn("tower", problems)
	local curve = Course.curve(params.difficultyCurve)
	local rng = Rng.new(params.seed)
	local kindRng, sizeRng = rng:fork("kinds"), rng:fork("sizes")
	-- Pad centre radius: the square core's corner, 3 studs of air, half of a 12-stud pad.
	local ring = coreRadius * math.sqrt(2) + 3 + 6
	local tau = 2 * math.pi
	local function at(angle: number): (number, number)
		return ring * math.cos(angle), ring * math.sin(angle)
	end
	local function yawAt(angle: number): number
		return -(math.deg(angle) + 90)
	end

	local sx0, sz0 = at(0)
	local pads: { Pad } = { newPad("p000", "spawn", sx0, baseY, sz0, 12, 12, yawAt(0)) }
	local segments, checkpoints = {}, {}
	local angle = 0
	local index = 0
	local history: { string } = {}
	-- Every pad sits on one helix (height = baseY + floorHeight x turns), so pads one turn apart
	-- are exactly floorHeight apart. A floor ends at the first landing that crosses its turn: that
	-- landing becomes the floor's checkpoint pad (the finish on the last floor).
	for floor = 1, floors do
		local floorEnd = floor * tau
		while true do
			index += 1
			if index > floors * 40 then
				error("Course.tower: floor " .. floor .. " did not close")
			end
			local prev = pads[#pads]
			local progress = clamp((angle / tau) / floors, 0, 1)
			local d = clamp(curve(progress) + sizeRng:range(-jitter, jitter), 0, 1)
			local s = lerp(Course.DIFFICULTY.min, Course.DIFFICULTY.max, d)
			local kind = pickKind(kindRng, kinds, history, function()
				return true
			end)
			local sx, sz = lerp(8, 5, d) + sizeRng:range(0, 1), lerp(8, 4, d) + sizeRng:range(0, 1)
			local pad = newPad(string.format("p%03d", index), "platform", 0, 0, 0, sx, sz, 0)
			-- Bisection on the turn angle: the gap grows and the safe gap shrinks as the step widens.
			local function place(step: number): number
				local a2 = angle + step
				local x, z = at(a2)
				pad.pos = { x = x, y = prev.pos.y + floorHeight * step / tau, z = z }
				pad.yaw = yawAt(a2) % 360
				local safe = Course.safeGap(pad.pos.y - prev.pos.y, profile, margin) or 0
				return Course.padGap(prev, pad) - s * safe
			end
			local function solve(): number
				local lo, hi = math.rad(3), math.rad(120)
				for _ = 1, 48 do
					local mid = (lo + hi) / 2
					if place(mid) > 0 then
						hi = mid
					else
						lo = mid
					end
				end
				return (lo + hi) / 2
			end
			local step = solve()
			local closing = angle + step >= floorEnd
			if closing then
				pad.role = if floor == floors then "finish" else "checkpoint"
				pad.size = v3(12, Course.PAD_THICKNESS, 12)
				kind = "gap"
				step = solve()
			elseif kind == "narrow" then
				pad.size = v3(6, Course.PAD_THICKNESS, lerp(Course.NARROW.wide, Course.NARROW.narrow, d))
				step = solve()
			end
			table.insert(history, kind)
			place(step)
			angle += step
			pad.pos = v3(pad.pos.x, pad.pos.y, pad.pos.z)
			pad.yaw = r3(pad.yaw)
			table.insert(pads, pad)
			table.insert(segments, {
				index = index,
				kind = kind,
				from = #pads - 1,
				to = #pads,
				gap = r3(Course.padGap(prev, pad)),
				rise = r3(pad.pos.y - prev.pos.y),
				difficulty = r3(s),
				floor = floor,
			})
			if pad.role == "checkpoint" then
				table.insert(checkpoints, {
					index = #checkpoints + 1,
					pad = #pads,
					segment = index,
					floor = floor,
					pos = pad.pos,
					size = { x = pad.size.x, z = pad.size.z },
					respawn = { pos = v3(pad.pos.x, pad.pos.y + 3, pad.pos.z), yaw = pad.yaw },
				})
			end
			if closing then
				break
			end
		end
	end
	local topY = pads[#pads].pos.y
	local finishPad = pads[#pads]
	return seal({
		schema = Course.SCHEMA,
		kind = "tower",
		params = recordParams(
			params,
			{ floors = floors, floorHeight = floorHeight, coreRadius = coreRadius, margin = margin }
		),
		profile = profileRecord(profile),
		pads = pads,
		segments = segments,
		checkpoints = checkpoints,
		hazards = {},
		structures = {
			{
				role = "core",
				pos = v3(0, (baseY - 2 + topY + 4) / 2, 0),
				size = v3(coreRadius * 2, topY + 4 - (baseY - 2), coreRadius * 2),
			},
		},
		spawn = { pad = 1, pos = pads[1].pos, yaw = pads[1].yaw, size = { x = 12, z = 12 } },
		finish = { pad = #pads, pos = finishPad.pos, yaw = finishPad.yaw, size = { x = 12, z = 12 } },
		killY = r3(baseY - 30),
	})
end

-- ---------------------------------------------------------------- race loop

-- Centripetal Catmull-Rom point between p1 and p2 (alpha 0.5: no cusps or self-loops in a span).
local function catmull(p0: V3, p1: V3, p2: V3, p3: V3, u: number): V3
	local function knot(t: number, a: V3, b: V3): number
		local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
		return t + math.max(math.sqrt(math.sqrt(dx * dx + dy * dy + dz * dz)), 1e-6)
	end
	local t0 = 0
	local t1 = knot(t0, p0, p1)
	local t2 = knot(t1, p1, p2)
	local t3 = knot(t2, p2, p3)
	local t = lerp(t1, t2, u)
	local function mix(a: V3, b: V3, ta: number, tb: number): V3
		local wa, wb = (tb - t) / (tb - ta), (t - ta) / (tb - ta)
		return { x = a.x * wa + b.x * wb, y = a.y * wa + b.y * wb, z = a.z * wa + b.z * wb }
	end
	local a1, a2, a3 = mix(p0, p1, t0, t1), mix(p1, p2, t1, t2), mix(p2, p3, t2, t3)
	local b1, b2 = mix(a1, a2, t0, t2), mix(a2, a3, t1, t3)
	return mix(b1, b2, t1, t2)
end

-- Circumradius of three (x, z) points; math.huge when they are collinear. Positive when the path
-- turns clockwise seen from above (+Y), i.e. towards the track's local -X side.
function Course.turnRadius(a: V3, b: V3, c: V3): number
	local abx, abz = b.x - a.x, b.z - a.z
	local bcx, bcz = c.x - b.x, c.z - b.z
	local acx, acz = c.x - a.x, c.z - a.z
	local cross = abx * bcz - abz * bcx
	if math.abs(cross) < 1e-9 then
		return math.huge
	end
	local ab = math.sqrt(abx * abx + abz * abz)
	local bc = math.sqrt(bcx * bcx + bcz * bcz)
	local ac = math.sqrt(acx * acx + acz * acz)
	return ab * bc * ac / (2 * cross)
end

-- Race loop. Options: laps (default 3), length (lap studs, default 1600), width (default 30),
-- gates (default 8, the last is the start/finish line; raised so no two gates are more than
-- maxGateSpacing studs apart, default Course.MAX_GATE_SPACING), slots (start grid, default 8),
-- minTurnRadius (default 45), maxBank (degrees, default 15), maxGrade (default 0.08),
-- hillHeight (default 8), controlPoints (default 12), spacing (sample studs, default 4).
function Course.raceLoop(params: any): Course
	local profile, kinds, problems = begin("race_loop", params)
	local laps = positiveInteger(params, "laps", 3, 1, 100, problems)
	local length = positiveNumber(params, "length", 1600, problems)
	local width = positiveNumber(params, "width", 30, problems)
	local gates = positiveInteger(params, "gates", 8, 2, 64, problems)
	local maxGateSpacing = positiveNumber(params, "maxGateSpacing", Course.MAX_GATE_SPACING, problems)
	local slotCount = positiveInteger(params, "slots", 8, 1, 32, problems)
	local minTurn = positiveNumber(params, "minTurnRadius", 45, problems)
	local maxBank = positiveNumber(params, "maxBank", 15, problems)
	local maxGrade = positiveNumber(params, "maxGrade", 0.08, problems)
	local hillHeight = positiveNumber(params, "hillHeight", 8, problems)
	local count = positiveInteger(params, "controlPoints", 12, 5, 64, problems)
	local spacing = positiveNumber(params, "spacing", 4, problems)
	if length < 2 * math.pi * minTurn * 1.5 then
		table.insert(
			problems,
			string.format("length %.0f is too short for minTurnRadius %.0f", length, minTurn)
		)
	end
	failOn("race_loop", problems)
	local curve = Course.curve(params.difficultyCurve)
	local rng = Rng.new(params.seed)
	local shapeRng, hillRng = rng:fork("shape"), rng:fork("hills")
	local corners = table.find(kinds, "corner") ~= nil
	local sweepers = table.find(kinds, "sweeper") ~= nil
	local hills = table.find(kinds, "hill") ~= nil
	local noiseMax = if corners then 0.3 elseif sweepers then 0.16 else 0.05
	local radius = length / (2 * math.pi)
	local base = {}
	for k = 0, count - 1 do
		local t = k / count
		local d = curve(t)
		local noise = noiseMax * (0.4 + 0.6 * d)
		local theta = (k + shapeRng:range(-0.25, 0.25)) * 2 * math.pi / count
		local r = radius * (1 + shapeRng:range(-noise, noise))
		local y = if hills then hillRng:range(0, hillHeight) else 0
		table.insert(base, { theta = theta, r = r, y = y })
	end

	local samples
	local function build(relax: number)
		local points = {}
		for _, cp in base do
			local r = radius + (cp.r - radius) * relax
			local theta = cp.theta
			table.insert(points, { x = r * math.cos(theta), y = cp.y * relax, z = r * math.sin(theta) })
		end
		-- Dense polyline, then uniform resampling by arc length.
		local dense = {}
		local n = #points
		for i = 1, n do
			local p0, p1 = points[(i - 2) % n + 1], points[i]
			local p2, p3 = points[i % n + 1], points[(i + 1) % n + 1]
			for step = 0, 63 do
				table.insert(dense, catmull(p0, p1, p2, p3, step / 64))
			end
		end
		local cumulative = { 0 }
		for i = 2, #dense + 1 do
			local a, b = dense[i - 1], dense[(i - 1) % #dense + 1]
			local dx, dz = b.x - a.x, b.z - a.z
			cumulative[i] = cumulative[i - 1] + math.sqrt(dx * dx + dz * dz)
		end
		local total = cumulative[#cumulative]
		local sampleCount = math.max(16, math.round(total / spacing))
		local out = {}
		local j = 1
		for i = 0, sampleCount - 1 do
			local target = total * i / sampleCount
			while cumulative[j + 1] < target do
				j += 1
			end
			local a, b = dense[j], dense[j % #dense + 1]
			local f = (target - cumulative[j]) / math.max(cumulative[j + 1] - cumulative[j], 1e-9)
			table.insert(out, { x = lerp(a.x, b.x, f), y = lerp(a.y, b.y, f), z = lerp(a.z, b.z, f) })
		end
		-- Grade limit: smooth heights (circular moving average) until every step is within it.
		local stepLength = total / sampleCount
		for _ = 1, 200 do
			local worst = 0
			for i = 1, #out do
				local nextY = out[i % #out + 1].y
				worst = math.max(worst, math.abs(nextY - out[i].y) / stepLength)
			end
			if worst <= maxGrade * 0.9 then
				break
			end
			local smoothed = {}
			for i = 1, #out do
				local p, q = out[(i - 2) % #out + 1], out[i % #out + 1]
				smoothed[i] = (p.y + 2 * out[i].y + q.y) / 4
			end
			for i = 1, #out do
				out[i].y = smoothed[i]
			end
		end
		return out, total
	end
	local total = 0
	local relax = 1
	for _ = 1, 8 do
		samples, total = build(relax)
		local tightest = math.huge
		for i = 1, #samples do
			local a, b, c = samples[(i - 2) % #samples + 1], samples[i], samples[i % #samples + 1]
			tightest = math.min(tightest, math.abs(Course.turnRadius(a, b, c)))
		end
		if tightest >= minTurn * 1.05 then
			break
		end
		relax *= 0.6
	end

	-- Per-sample heading, grade, radius and bank (inward, capped).
	local n = #samples
	local track = {}
	for i = 1, n do
		local a, b, c = samples[(i - 2) % n + 1], samples[i], samples[i % n + 1]
		local dx, dz = c.x - a.x, c.z - a.z
		local yaw = math.deg(math.atan2(dx, dz))
		local radiusHere = Course.turnRadius(a, b, c)
		local grade = (c.y - a.y) / math.max(math.sqrt(dx * dx + dz * dz), 1e-9)
		local bankMag = math.min(maxBank, maxBank * minTurn * 1.5 / math.max(math.abs(radiusHere), 1e-9))
		-- Roll raises the outer edge: positive roll lifts local +X, the outside of a clockwise turn.
		local bank = if radiusHere == math.huge then 0 elseif radiusHere > 0 then bankMag else -bankMag
		track[i] = {
			pos = v3(b.x, b.y, b.z),
			yaw = r3(yaw % 360),
			grade = r3(grade),
			radius = if radiusHere == math.huge then 0 else r3(radiusHere),
			bank = r3(bank),
		}
	end
	-- Gates at equal arc length; gate `gates` is the start/finish line at sample 1. Extra gates
	-- keep every stretch within maxGateSpacing (one sample of slack for rounding).
	gates = math.max(gates, math.ceil(total / math.max(maxGateSpacing - 2 * total / n, 1)))
	local checkpoints = {}
	for g = 1, gates do
		local sample = (g * n // gates) % n + 1
		local point = track[sample]
		table.insert(checkpoints, {
			index = g,
			sample = sample,
			pos = point.pos,
			yaw = point.yaw,
			width = r3(width + 2),
			size = { x = r3(width + 2), z = 2 },
		})
	end
	-- Sections between gates, classified by their tightest turn.
	local segments = {}
	local previous = 1
	for g = 1, gates do
		local last = checkpoints[g].sample
		local tight, steep, length = math.huge, 0, 0
		local i = previous
		while true do
			local point = track[i]
			if point.radius ~= 0 then
				tight = math.min(tight, math.abs(point.radius))
			end
			steep = math.max(steep, math.abs(point.grade))
			length += total / n
			if i == last then
				break
			end
			i = i % n + 1
		end
		local kind = if tight < minTurn * 2.5
			then "corner"
			elseif tight < minTurn * 6 then "sweeper"
			else "straight"
		if steep >= maxGrade * 0.5 and hills then
			kind = kind .. "_hill"
		end
		table.insert(segments, {
			index = g,
			kind = kind,
			from = previous,
			to = last,
			length = r3(length),
			minRadius = if tight == math.huge then 0 else r3(tight),
		})
		previous = last % n + 1
	end
	-- Staggered start grid behind the line (two columns), facing the track.
	local slots = {}
	local step = total / n
	for j = 1, slotCount do
		local row, column = (j - 1) // 2, (j - 1) % 2
		local back = 8 + row * 10 + column * 5
		local sample = ((1 - 1 - math.round(back / step)) % n) + 1
		local point = track[sample]
		local side = if column == 0 then -1 else 1
		local ax, az = axes(point.yaw)
		-- Track local X is the lateral axis (track parts are yawed so local Z runs along the track).
		local lateral = side * width / 4
		table.insert(slots, {
			index = j,
			sample = sample,
			pos = v3(point.pos.x + ax * lateral, point.pos.y, point.pos.z + az * lateral),
			yaw = point.yaw,
			lateral = r3(lateral),
		})
	end
	local start = track[1]
	return seal({
		schema = Course.SCHEMA,
		kind = "race_loop",
		params = recordParams(params, {
			laps = laps,
			length = length,
			width = width,
			gates = gates,
			maxGateSpacing = maxGateSpacing,
			slots = slotCount,
			minTurnRadius = minTurn,
			maxBank = maxBank,
			maxGrade = maxGrade,
			relax = r3(relax),
		}),
		profile = profileRecord(profile),
		samples = track,
		lapLength = r3(total),
		segments = segments,
		checkpoints = checkpoints,
		spawn = { pos = slots[1].pos, yaw = slots[1].yaw, slots = slots },
		finish = { pos = start.pos, yaw = start.yaw, gate = gates, width = r3(width + 2) },
		laps = laps,
	})
end

-- ---------------------------------------------------------------- lanes

-- Lanes: parallel paths on a cell grid from the spawn edge (row 1) to the base (last row), one
-- band per lane, with build slots beside each path. Paths bend at switchbacks; their lengths
-- are equalised exactly (every lane has the same number of cells). Options: lanes (default 3),
-- length (rows, default 32), bandWidth (cells, default 9), cellSize (studs, default 6), slots
-- (per lane, default 6), range (slot coverage radius in cells, default 3). Difficulty (its mean)
-- shortens the paths: fewer switchbacks leave less time to defend.
function Course.lanes(params: any): Course
	local profile, kinds, problems = begin("lanes", params)
	local laneCount = positiveInteger(params, "lanes", 3, 1, 8, problems)
	local rows = positiveInteger(params, "length", 32, 8, 200, problems)
	local band = positiveInteger(params, "bandWidth", 9, 5, 40, problems)
	local cellSize = positiveNumber(params, "cellSize", 6, problems)
	local slotTarget = positiveInteger(params, "slots", 6, 0, 64, problems)
	local range = positiveNumber(params, "range", 3, problems)
	if cellSize < profile.characterWidth * 1.6 then
		table.insert(
			problems,
			string.format("cellSize %.2f is narrower than a lane for the character", cellSize)
		)
	end
	failOn("lanes", problems)
	local curve = Course.curve(params.difficultyCurve)
	local mean = (curve(0) + curve(0.5) + curve(1)) / 3
	local switchbacks = table.find(kinds, "switchback") ~= nil
	local bends = if switchbacks then math.max(2, math.round(lerp(6, 2, mean))) else 0
	-- Bend rows need 3 rows each between row 3 and rows - 2.
	bends = math.min(bends, (rows - 4) // 3)
	if bends < 2 then
		bends = 0
	end
	local rng = Rng.new(params.seed)

	local lanes = {}
	for lane = 1, laneCount do
		local laneRng = rng:fork("lane" .. lane)
		local x0 = (lane - 1) * band + 1
		local lo, hi = x0 + 1, x0 + band - 2
		local centre = x0 + band // 2
		local columns = { centre }
		local bendRows = {}
		if bends >= 2 then
			-- Bend rows: spread over [3, rows - 2] with at least 3 rows between them.
			local span = (rows - 4) / bends
			for b = 1, bends do
				local first = math.floor(3 + (b - 1) * span)
				local last = math.max(first, math.floor(3 + b * span) - 2)
				table.insert(bendRows, laneRng:int(first, last))
			end
			for _ = 1, bends - 1 do
				table.insert(columns, laneRng:int(lo, hi))
			end
		end
		table.insert(columns, centre)
		table.insert(lanes, {
			lane = lane,
			x0 = x0,
			lo = lo,
			hi = hi,
			centre = centre,
			columns = columns,
			bendRows = bendRows,
		})
	end
	-- Equalise horizontal travel exactly. Moving the first plateau of the interior maximum up (or
	-- of the minimum down) by one column changes the travel by exactly 2 cells, and every lane's
	-- travel is even (it starts and ends on its centre column), so lanes first grow towards the
	-- longest, then all shrink to the shortest that could not grow.
	local function travel(columns: { number }): number
		local sum = 0
		for i = 2, #columns do
			sum += math.abs(columns[i] - columns[i - 1])
		end
		return sum
	end
	-- First maximal run of interior columns holding the interior maximum (or minimum).
	local function plateau(columns: { number }, wantMax: boolean): (number?, number?, number?)
		local value: number? = nil
		for i = 2, #columns - 1 do
			if value == nil or (wantMax and columns[i] > value) or (not wantMax and columns[i] < value) then
				value = columns[i]
			end
		end
		if value == nil then
			return nil, nil, nil
		end
		local first = nil
		for i = 2, #columns - 1 do
			if columns[i] == value then
				first = first or i
			elseif first then
				return value, first, i - 1
			end
		end
		return value, first, #columns - 1
	end
	local function shift(columns: { number }, from: number, to: number, by: number)
		for i = from, to do
			columns[i] += by
		end
	end
	local function grow(lane: any): boolean
		local cols = lane.columns
		local top, a, b = plateau(cols, true)
		if top and a and b and top + 1 <= lane.hi and top >= cols[a - 1] and top >= cols[b + 1] then
			shift(cols, a, b, 1)
			return true
		end
		local bottom, c, d = plateau(cols, false)
		if
			bottom
			and c
			and d
			and bottom - 1 >= lane.lo
			and bottom <= cols[c - 1]
			and bottom <= cols[d + 1]
		then
			shift(cols, c, d, -1)
			return true
		end
		return false
	end
	local function shrink(lane: any): boolean
		local cols = lane.columns
		local top, a, b = plateau(cols, true)
		if top and a and b and top > cols[a - 1] and top > cols[b + 1] then
			shift(cols, a, b, -1)
			return true
		end
		local bottom, c, d = plateau(cols, false)
		if bottom and c and d and bottom < cols[c - 1] and bottom < cols[d + 1] then
			shift(cols, c, d, 1)
			return true
		end
		return false
	end
	local target = 0
	for _, lane in lanes do
		target = math.max(target, travel(lane.columns))
	end
	for _, lane in lanes do
		for _ = 1, 400 do
			if travel(lane.columns) >= target or not grow(lane) then
				break
			end
		end
		target = math.min(target, travel(lane.columns))
	end
	for _, lane in lanes do
		for _ = 1, 400 do
			if travel(lane.columns) <= target or not shrink(lane) then
				break
			end
		end
	end
	-- Cells, runs and waypoints per lane.
	local segments, checkpoints, slotsOut = {}, {}, {}
	local laneCells = {}
	local occupied: { [number]: number } = {}
	local width = laneCount * band
	local function key(x: number, y: number): number
		return y * 1000 + x
	end
	for _, lane in lanes do
		local cells = {}
		local x, y = lane.columns[1], 1
		table.insert(cells, { x, y })
		local waypoints = { { x, y } }
		local function walk(tx: number, ty: number)
			local runStart = { x, y }
			while x ~= tx or y ~= ty do
				if x ~= tx then
					x += if tx > x then 1 else -1
				else
					y += if ty > y then 1 else -1
				end
				table.insert(cells, { x, y })
			end
			if runStart[1] ~= x or runStart[2] ~= y then
				table.insert(segments, {
					index = #segments + 1,
					kind = "run",
					lane = lane.lane,
					from = runStart,
					to = { x, y },
					length = math.abs(x - runStart[1]) + math.abs(y - runStart[2]),
				})
				table.insert(waypoints, { x, y })
			end
		end
		for b, row in lane.bendRows do
			walk(x, row)
			walk(lane.columns[b + 1], row)
		end
		walk(x, rows)
		walk(lane.centre, rows)
		for _, c in cells do
			occupied[key(c[1], c[2])] = lane.lane
		end
		laneCells[lane.lane] = cells
		for index, w in waypoints do
			table.insert(checkpoints, {
				lane = lane.lane,
				index = index,
				cell = w,
				pos = v3((w[1] - 0.5) * cellSize, 0, (w[2] - 0.5) * cellSize),
			})
		end
	end
	-- Build slots: free cells beside the path, greedy by coverage then path order, 2 cells apart.
	local function coverage(cx: number, cy: number, cells: { { number } }): number
		local covered = 0
		for _, c in cells do
			if (c[1] - cx) ^ 2 + (c[2] - cy) ^ 2 <= range * range then
				covered += 1
			end
		end
		return covered
	end
	local perLane = {}
	for _, lane in lanes do
		local cells = laneCells[lane.lane]
		local candidates, seen = {}, {}
		for order, c in cells do
			for _, o in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local nx, ny = c[1] + o[1], c[2] + o[2]
				local k = key(nx, ny)
				if
					not seen[k]
					and occupied[k] == nil
					and nx >= lane.x0
					and nx <= lane.x0 + band - 1
					and ny >= 2
					and ny <= rows - 1
				then
					seen[k] = true
					table.insert(
						candidates,
						{ x = nx, y = ny, order = order, cover = coverage(nx, ny, cells) }
					)
				end
			end
		end
		table.sort(candidates, function(a, b)
			if a.cover ~= b.cover then
				return a.cover > b.cover
			end
			if a.order ~= b.order then
				return a.order < b.order
			end
			return a.x < b.x
		end)
		local picked = {}
		for _, c in candidates do
			if #picked >= slotTarget then
				break
			end
			local free = true
			for _, p in picked do
				if math.max(math.abs(p.x - c.x), math.abs(p.y - c.y)) < 2 then
					free = false
					break
				end
			end
			if free then
				table.insert(picked, c)
			end
		end
		perLane[lane.lane] = picked
	end
	local fewest = math.huge
	for _, picked in perLane do
		fewest = math.min(fewest, #picked)
	end
	for _, lane in lanes do
		local picked = perLane[lane.lane]
		for i = 1, math.min(#picked, fewest) do
			local c = picked[i]
			table.insert(slotsOut, {
				lane = lane.lane,
				index = i,
				cell = { c.x, c.y },
				cover = c.cover,
				pos = v3((c.x - 0.5) * cellSize, 0, (c.y - 0.5) * cellSize),
			})
		end
	end
	local paths = {}
	for lane = 1, laneCount do
		paths[lane] = laneCells[lane]
	end
	local starts = {}
	for _, lane in lanes do
		table.insert(
			starts,
			{ lane = lane.lane, pos = v3((lane.centre - 0.5) * cellSize, 0, 0.5 * cellSize) }
		)
	end
	return seal({
		schema = Course.SCHEMA,
		kind = "lanes",
		params = recordParams(params, {
			lanes = laneCount,
			length = rows,
			bandWidth = band,
			cellSize = cellSize,
			slots = slotTarget,
			range = range,
			bends = bends,
		}),
		profile = profileRecord(profile),
		grid = { width = width, height = rows, cellSize = cellSize },
		paths = paths,
		slots = slotsOut,
		segments = segments,
		checkpoints = checkpoints,
		spawn = { pos = v3(width * cellSize / 2, 0, -cellSize), yaw = 0, slots = starts },
		finish = {
			pos = v3(width * cellSize / 2, 0, (rows + 1) * cellSize),
			yaw = 0,
			size = { x = r3(width * cellSize), z = r3(cellSize * 2) },
		},
	})
end

-- ---------------------------------------------------------------- micro arena

-- Micro arena: a round or square floor sized by players x areaPerPlayer, a spawn ring facing
-- the centre, and cover and hazards repeated once per spawn sector (rotational symmetry, so
-- every spawn sees the same layout). Options: players (default 8), shape ("round" | "square"),
-- areaPerPlayer (sq studs, default 200, convention), edge ("drop" | "wall"), edgeClearance
-- (studs, default 6, convention). Difficulty (its mean) grows the hazards and shrinks cover.
function Course.microArena(params: any): Course
	local profile, kinds, problems = begin("micro_arena", params)
	local players = positiveInteger(params, "players", 8, 2, 32, problems)
	local shape = params.shape or "round"
	local edge = params.edge or "drop"
	local areaPerPlayer = positiveNumber(params, "areaPerPlayer", 200, problems)
	local edgeClearance = positiveNumber(params, "edgeClearance", 6, problems)
	if shape ~= "round" and shape ~= "square" then
		table.insert(problems, "shape must be round or square")
	end
	if edge ~= "drop" and edge ~= "wall" then
		table.insert(problems, "edge must be drop or wall")
	end
	failOn("micro_arena", problems)
	local curve = Course.curve(params.difficultyCurve)
	local mean = (curve(0) + curve(0.5) + curve(1)) / 3
	local rng = Rng.new(params.seed)
	local scale = profile.characterWidth / Measure.GUIDE.characterWidth
	local area = players * areaPerPlayer * scale * scale
	local half = if shape == "round" then math.sqrt(area / math.pi) else math.sqrt(area) / 2
	-- Spawn ring: 70% out, at least edgeClearance from the edge, and wide enough that neighbours
	-- stand minSpawnSeparation apart; a crowded ring grows the arena instead.
	local separation = Course.ARENA.minSpawnSeparation * scale
	local needed = separation / (2 * math.sin(math.pi / players)) + 0.05
	local spawnRadius = math.max(math.min(half * 0.7, half - edgeClearance - 0.05), needed)
	if spawnRadius > half - edgeClearance - 0.05 then
		half = spawnRadius + edgeClearance + 0.05
		area = if shape == "round" then math.pi * half * half else 4 * half * half
	end
	local offset = rng:range(0, 360 / players)
	local spawns = {}
	for i = 1, players do
		local a = math.rad(offset + (i - 1) * 360 / players)
		local x, z = spawnRadius * math.cos(a), spawnRadius * math.sin(a)
		-- Face the centre: yaw whose local -Z (SceneKit front) points from the spawn to (0, 0).
		local yaw = math.deg(math.atan2(x, z))
		table.insert(spawns, { index = i, pos = v3(x, 0, z), yaw = r3(yaw % 360) })
	end
	local pieces = {}
	local dropped = {}
	local sector = 360 / players
	local clear = Course.ARENA.spawnClear * scale + 0.5
	-- One piece per sector. A ring must keep `clear` from every spawn, stay on the floor and leave a
	-- stud between pieces (its own and earlier rings'). Radii are tried across the band where
	-- neighbours cannot touch (preferred first), then with smaller pieces; a ring that never fits
	-- is dropped and reported in `dropped`.
	local function fits(piece: any, candidate: { any }): boolean
		for _, spawn in spawns do
			if Course.footprintDistance(piece, spawn.pos.x, spawn.pos.z) < clear then
				return false
			end
		end
		for _, list in { pieces, candidate } do
			for _, other in list do
				if Course.footprintsOverlap(other, piece, 0.5) then
					return false
				end
			end
		end
		return true
	end
	local function ring(role: string, preferred: number, angleOffset: number, size: V3): boolean
		for _, shrink in { 1, 0.85, 0.7 } do
			local sx, sz = size.x * shrink, size.z * shrink
			local diag = math.sqrt(sx * sx + sz * sz)
			local rMin = (diag + 1) / (2 * math.sin(math.pi / players))
			local rMax = half - 1 - diag / 2
			if rMin > rMax then
				continue
			end
			for _, t in { preferred, 0, 0.25, 0.5, 0.75, 1 } do
				local r = lerp(rMin, rMax, t)
				local candidate = {}
				local ok = true
				for i = 1, players do
					local angle = offset + (i - 1) * sector + angleOffset
					local a = math.rad(angle)
					local piece = {
						role = role,
						sector = i,
						pos = v3(r * math.cos(a), size.y / 2, r * math.sin(a)),
						size = v3(sx, size.y, sz),
						-- Local X runs tangentially (yaw -(angle + 90)), so cover faces the centre.
						yaw = r3(-(angle + 90) % 360),
					}
					if not fits(piece, candidate) then
						ok = false
						break
					end
					table.insert(candidate, piece)
				end
				if ok then
					for _, piece in candidate do
						table.insert(pieces, piece)
					end
					return true
				end
			end
		end
		return false
	end
	local pieceRng = rng:fork("pieces")
	-- Cover first, between the spawn lines; then hazards in line with the spawns. A hazard ring
	-- that cannot fit becomes one centre hazard (equally far from every spawn).
	if table.find(kinds, "cover") then
		local w = lerp(6, 3, mean)
		if not ring("cover", pieceRng:range(0.2, 0.5), sector / 2, v3(w, 4, 2)) then
			table.insert(dropped, "cover")
		end
	end
	if table.find(kinds, "hazard") then
		local w = lerp(2, 5, mean)
		if not ring("hazard", pieceRng:range(0, 0.3), 0, v3(w, 0.4, w)) then
			local placed = false
			for _, factor in { 1.5, 1, 0.7 } do
				local centre = {
					role = "hazard",
					sector = 0,
					pos = v3(0, 0.2, 0),
					size = v3(w * factor, 0.4, w * factor),
					yaw = 0,
				}
				if fits(centre, {}) then
					table.insert(pieces, centre)
					placed = true
					break
				end
			end
			if not placed then
				table.insert(dropped, "hazard")
			end
		end
	end
	local tiles = {}
	local tileSize = 6
	if table.find(kinds, "tiles") then
		-- Touching tiles that cover the whole disc or square (every point of the outline lies on a
		-- kept tile), so the floor edge is never closer than `half` to the centre.
		local n = math.ceil(half / tileSize) + 1
		for gx = -n, n - 1 do
			for gz = -n, n - 1 do
				local cx, cz = (gx + 0.5) * tileSize, (gz + 0.5) * tileSize
				local nx = math.max(math.abs(cx) - tileSize / 2, 0)
				local nz = math.max(math.abs(cz) - tileSize / 2, 0)
				local inside = if shape == "round"
					then nx * nx + nz * nz < half * half
					else nx < half and nz < half
				if inside then
					table.insert(tiles, { pos = v3(cx, -0.5, cz), size = v3(tileSize, 1, tileSize) })
				end
			end
		end
	end
	return seal({
		schema = Course.SCHEMA,
		kind = "micro_arena",
		params = recordParams(params, {
			players = players,
			shape = shape,
			edge = edge,
			areaPerPlayer = areaPerPlayer,
			edgeClearance = edgeClearance,
		}),
		profile = profileRecord(profile),
		arena = { shape = shape, half = r3(half), area = r3(area), edge = edge, tileSize = tileSize },
		tiles = tiles,
		segments = pieces,
		dropped = dropped,
		checkpoints = {},
		spawn = { pos = spawns[1].pos, yaw = spawns[1].yaw, slots = spawns },
		finish = { pos = v3(0, 0, 0), yaw = 0, size = { x = 6, z = 6 } },
		killY = -30,
	})
end

-- ---------------------------------------------------------------- dispatch

local GENERATORS = {
	linear = Course.linear,
	tower = Course.tower,
	race_loop = Course.raceLoop,
	lanes = Course.lanes,
	micro_arena = Course.microArena,
}

-- Course.generate({ kind = "linear" | "tower" | "race_loop" | "lanes" | "micro_arena", ... }).
function Course.generate(params: any): Course
	assert(type(params) == "table", "Course.generate: params must be a table")
	local generator = GENERATORS[params.kind]
	if generator == nil then
		error(
			"Course.generate: unknown kind "
				.. tostring(params.kind)
				.. " (known: "
				.. table.concat(Course.KINDS, ", ")
				.. ")",
			2
		)
	end
	local body = table.clone(params)
	body.kind = nil
	return generator(body)
end

-- SceneKit plan for a course: a new Scene named "Course_<kind>" in style `style` (default
-- greybox); see ProcGen/CourseScene for the parts and attributes. CourseScene.into adds a course
-- to an existing scene.
function Course.toScene(course: Course, style: string?, options: { name: string? }?): any
	return CourseScene.toScene(course, style, options)
end

return Course
