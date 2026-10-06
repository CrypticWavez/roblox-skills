--!strict
-- @tier T0
-- Checkpoints: ordered checkpoints validated by the server. Each player starts at stage 0; a
-- touch of checkpoint k is accepted only as the next one in order (the course repeats per lap),
-- only near it (the server-side position the adapter passes) and only after enough time to get
-- there at maxSpeed, so skipping, teleporting and replaying a touch are refused with a reason:
--   not_started, finished, unknown_checkpoint, already_reached, skipped, too_far, too_fast
-- Accepted touches record splits (seconds from the start); respawn() gives the last reached
-- checkpoint's respawn point. The last checkpoint of the last lap finishes the run.
-- Checkpoints.fromCourse(course) builds a spec from a ProcGen course/1 manifest (the finish pad
-- or line is the last checkpoint). Time comes from env.clock (or an explicit `now`); nothing
-- yields, so touches can be handled in a simulation step.
local Check = require("./Check")
local Events = require("./Events")
local Signal = require("./Signal")

local Checkpoints = {}

export type V3 = { x: number, y: number, z: number }
export type Point = { pos: V3, radius: number?, respawn: { pos: V3, yaw: number? }? }
export type Spec = {
	checkpoints: { Point },
	start: { pos: V3, yaw: number? },
	laps: number?, -- default 1
	maxSpeed: number?, -- studs per second; touches faster than this are too_fast (default off)
	radius: number?, -- default touch radius, studs (default 8)
}

function Checkpoints.validate(spec: any): { string }
	local problems = {}
	if type(spec) ~= "table" then
		return { "spec must be a table" }
	end
	local function vector(v: any): boolean
		return type(v) == "table" and Check.finite(v.x) and Check.finite(v.y) and Check.finite(v.z)
	end
	if type(spec.checkpoints) ~= "table" or #spec.checkpoints == 0 then
		table.insert(problems, "checkpoints must be a non-empty list")
	else
		for i, point in spec.checkpoints do
			if type(point) ~= "table" or not vector(point.pos) then
				table.insert(problems, string.format("checkpoint %d needs pos { x, y, z }", i))
			elseif point.radius ~= nil and (not Check.finite(point.radius) or point.radius <= 0) then
				table.insert(problems, string.format("checkpoint %d radius must be > 0", i))
			elseif point.respawn ~= nil and not vector(point.respawn.pos) then
				table.insert(problems, string.format("checkpoint %d respawn needs pos", i))
			end
		end
	end
	if type(spec.start) ~= "table" or not vector(spec.start.pos) then
		table.insert(problems, "start needs pos { x, y, z }")
	end
	if spec.laps ~= nil and (not Check.integer(spec.laps) or spec.laps < 1) then
		table.insert(problems, "laps must be an integer >= 1")
	end
	for _, key in { "maxSpeed", "radius" } do
		local value = spec[key]
		if value ~= nil and (not Check.finite(value) or value <= 0) then
			table.insert(problems, key .. " must be a finite number > 0")
		end
	end
	return problems
end

-- Spec from a course/1 manifest: linear and tower courses get their checkpoint pads then the
-- finish pad; race loops get their gates (the last is the finish line) and laps. maxSpeed is the
-- course's walk speed x slack (default 1.25, convention: latency and ping jitter).
function Checkpoints.fromCourse(course: any, slack: number?): Spec
	assert(
		type(course) == "table" and course.schema == "course/1",
		"Checkpoints.fromCourse: not a course/1 manifest"
	)
	local points = {}
	local function size(entry: any): number
		local s = entry.size or {}
		return math.max(s.x or 8, s.z or 8) / 2 + 3
	end
	for _, cp in course.checkpoints do
		local respawn = cp.respawn
		table.insert(points, {
			pos = table.clone(cp.pos),
			radius = size(cp),
			respawn = if respawn then { pos = table.clone(respawn.pos), yaw = respawn.yaw } else nil,
		})
	end
	if course.kind ~= "race_loop" then
		local finish = course.finish
		table.insert(points, { pos = table.clone(finish.pos), radius = size(finish) })
	end
	return {
		checkpoints = points,
		start = { pos = table.clone(course.spawn.pos), yaw = course.spawn.yaw },
		laps = course.laps or 1,
		maxSpeed = course.profile.walkSpeed * (slack or 1.25),
	}
end

export type Progress = {
	stage: number, -- touches accepted (all laps)
	startedAt: number,
	lastAt: number,
	splits: { number },
	finished: boolean,
	time: number?,
}

export type Tracker = {
	spec: Spec,
	reached: any, -- Signal(player, index, lap, split)
	finishedRun: any, -- Signal(player, time)
	rejected: any, -- Signal(player, index, reason)
	start: (self: Tracker, player: string, now: number?) -> (),
	touch: (self: Tracker, player: string, index: number, pos: V3?, now: number?) -> (boolean, string?),
	respawn: (self: Tracker, player: string) -> { pos: V3, yaw: number? },
	progress: (self: Tracker, player: string) -> Progress?,
	resume: (self: Tracker, player: string, progress: Progress) -> (boolean, string?),
	remove: (self: Tracker, player: string) -> (),
}

-- options.sink: kit-event/1 progression events (path "course", level = stage).
function Checkpoints.new(spec: Spec, options: { sink: any? }?, env: any?): Tracker
	local problems = Checkpoints.validate(spec)
	if #problems > 0 then
		error("Checkpoints.new: " .. table.concat(problems, "; "), 2)
	end
	local points = spec.checkpoints
	local count = #points
	local laps = spec.laps or 1
	local total = count * laps
	local players: { [string]: Progress } = {}
	local self: any = {
		spec = spec,
		reached = Signal.new(env),
		finishedRun = Signal.new(env),
		rejected = Signal.new(env),
	}

	local function clock(now: number?): number
		if now ~= nil then
			return now
		end
		assert(env and type(env.clock) == "function", "Checkpoints: pass now or an env with clock")
		return env.clock()
	end
	local function emit(player: string, status: string, level: number)
		if options and options.sink then
			local event =
				Events.progression("checkpoint", { path = "course", status = status :: any, level = level })
			event.player = player
			options.sink:emit(event)
		end
	end
	local function positionOf(stage: number): V3
		if stage == 0 then
			return spec.start.pos
		end
		return points[(stage - 1) % count + 1].pos
	end
	local function reject(player: string, index: number, reason: string): (boolean, string?)
		self.rejected:Fire(player, index, reason)
		return false, reason
	end

	function self.start(_, player: string, now: number?)
		local t = clock(now)
		players[player] = { stage = 0, startedAt = t, lastAt = t, splits = {}, finished = false }
		emit(player, "start", 0)
	end

	function self.touch(_, player: string, index: number, pos: V3?, now: number?): (boolean, string?)
		local p = players[player]
		if p == nil then
			return reject(player, index, "not_started")
		end
		if p.finished then
			return reject(player, index, "finished")
		end
		if not Check.integer(index) or index < 1 or index > count then
			return reject(player, index, "unknown_checkpoint")
		end
		local expected = p.stage % count + 1
		if index ~= expected then
			-- Behind (or the same one again) in this lap, or the line just crossed to finish a lap:
			-- a replay. Ahead: a skip.
			local lapStage = p.stage % count
			if index <= lapStage or (lapStage == 0 and p.stage > 0 and index == count) then
				return reject(player, index, "already_reached")
			end
			return reject(player, index, "skipped")
		end
		local point = points[index]
		if pos ~= nil then
			local dx, dy, dz = pos.x - point.pos.x, pos.y - point.pos.y, pos.z - point.pos.z
			if math.sqrt(dx * dx + dy * dy + dz * dz) > (point.radius or spec.radius or 8) then
				return reject(player, index, "too_far")
			end
		end
		local t = clock(now)
		if spec.maxSpeed then
			local from = positionOf(p.stage)
			local dx, dz = point.pos.x - from.x, point.pos.z - from.z
			-- Straight-line plan distance less both touch radii: the least anyone must travel.
			local least = math.max(0, math.sqrt(dx * dx + dz * dz) - (point.radius or spec.radius or 8) * 2)
			if t - p.lastAt < least / spec.maxSpeed then
				return reject(player, index, "too_fast")
			end
		end
		p.stage += 1
		p.lastAt = t
		local split = t - p.startedAt
		table.insert(p.splits, split)
		local lap = (p.stage - 1) // count + 1
		self.reached:Fire(player, index, lap, split)
		emit(player, "custom", p.stage)
		if p.stage >= total then
			p.finished = true
			p.time = split
			emit(player, "complete", p.stage)
			self.finishedRun:Fire(player, split)
		end
		return true, nil
	end

	function self.respawn(_, player: string): { pos: V3, yaw: number? }
		local p = players[player]
		if p == nil or p.stage == 0 then
			return { pos = table.clone(spec.start.pos), yaw = spec.start.yaw }
		end
		local point = points[(p.stage - 1) % count + 1]
		if point.respawn then
			return { pos = table.clone(point.respawn.pos), yaw = point.respawn.yaw }
		end
		return { pos = { x = point.pos.x, y = point.pos.y + 3, z = point.pos.z } }
	end

	function self.progress(_, player: string): Progress?
		local p = players[player]
		return if p then Check.copy(p) else nil
	end

	-- Restores saved progress (validated: a stage within the course and one split per stage).
	function self.resume(_, player: string, progress: any): (boolean, string?)
		if
			type(progress) ~= "table"
			or not Check.integer(progress.stage)
			or progress.stage < 0
			or progress.stage > total
			or type(progress.splits) ~= "table"
			or #progress.splits ~= progress.stage
			or not Check.finite(progress.startedAt)
			or not Check.finite(progress.lastAt)
		then
			return false, "bad_progress"
		end
		players[player] = Check.copy(progress)
		return true, nil
	end

	function self.remove(_, player: string)
		players[player] = nil
	end

	return self
end

return Checkpoints
