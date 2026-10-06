--!strict
-- @tier T0
-- NavAgent: a pure waypoint follower with stuck detection and a repath policy. It never computes
-- paths itself: moveTo() and step() return commands, and a "repath" command asks the caller
-- (NavAgentRoblox with PathfindingService, or a grid search in specs) for a path, handed back
-- with setPath(waypoints, status, request).
--   commands  move (walk to `to`), jump (jump towards `to`), wait (a path is on its way), repath
--             (compute a path to `to`; reason new_target, stuck, blocked, target_moved, retry,
--             interval), arrived (reason partial when the path only got close), failed (reason
--             stuck, no_path), idle
-- Stuck: less than stuckDistance of progress towards the current waypoint in stuckTime seconds.
-- More than maxRepaths repaths in a row without reaching a waypoint fails the move; a path
-- status other than Success / ClosestNoPath is retried after pathRetryDelay (doubling) up to
-- maxPathFailures. Time is the dt passed to step(), so the agent runs inside a simulation step.
local Check = require("./Check")

local NavAgent = {}

export type V3 = { x: number, y: number, z: number }
export type Waypoint = { pos: V3, action: ("walk" | "jump" | "custom")?, label: string? }
export type Command = {
	kind: "move" | "jump" | "wait" | "repath" | "arrived" | "failed" | "idle",
	to: V3?,
	waypoint: number?,
	reason: string?,
	request: number?,
	label: string?,
}
export type Options = {
	arriveRadius: number?, -- horizontal studs that count as reaching a waypoint (default 2)
	verticalTolerance: number?, -- vertical studs allowed on arrival (default 6)
	stuckTime: number?, -- seconds (default 1.5, convention)
	stuckDistance: number?, -- studs of progress expected per stuckTime (default 1, convention)
	maxRepaths: number?, -- default 3
	repathDistance: number?, -- target movement that triggers a repath, studs (default 6)
	repathInterval: number?, -- periodic repath while following, seconds (default off)
	minRepathGap: number?, -- seconds between target_moved / interval repaths (default 0.5)
	pathRetryDelay: number?, -- first wait after a failed path, seconds (default 0.5)
	maxPathFailures: number?, -- default 3
}

NavAgent.DEFAULTS = table.freeze({
	arriveRadius = 2,
	verticalTolerance = 6,
	stuckTime = 1.5,
	stuckDistance = 1,
	maxRepaths = 3,
	repathDistance = 6,
	minRepathGap = 0.5,
	pathRetryDelay = 0.5,
	maxPathFailures = 3,
})
-- PathfindingService statuses that still give a usable path.
NavAgent.USABLE = table.freeze({ Success = "full", ClosestNoPath = "partial", ClosestOutOfRange = "partial" })

local function option(options: Options?, key: string): any
	local value = options and (options :: any)[key]
	if value == nil then
		return (NavAgent.DEFAULTS :: any)[key]
	end
	return value
end

function NavAgent.validate(options: Options?): { string }
	local problems = {}
	for _, key in
		{
			"arriveRadius",
			"verticalTolerance",
			"stuckTime",
			"stuckDistance",
			"repathDistance",
			"minRepathGap",
			"pathRetryDelay",
		}
	do
		local value = option(options, key)
		if not Check.finite(value) or value <= 0 then
			table.insert(problems, key .. " must be a finite number > 0")
		end
	end
	for _, key in { "maxRepaths", "maxPathFailures" } do
		local value = option(options, key)
		if not Check.integer(value) or value < 0 then
			table.insert(problems, key .. " must be an integer >= 0")
		end
	end
	local interval = options and options.repathInterval
	if interval ~= nil and (not Check.finite(interval) or interval <= 0) then
		table.insert(problems, "repathInterval must be a finite number > 0")
	end
	return problems
end

local function horizontal(a: V3, b: V3): number
	local dx, dz = b.x - a.x, b.z - a.z
	return math.sqrt(dx * dx + dz * dz)
end

local function distance(a: V3, b: V3): number
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

export type Agent = {
	state: "idle" | "waiting" | "following" | "arrived" | "failed",
	moveTo: (self: Agent, target: V3) -> Command,
	setPath: (self: Agent, waypoints: { Waypoint }, status: string?, request: number?) -> boolean,
	blocked: (self: Agent, index: number) -> (),
	step: (self: Agent, dt: number, position: V3, target: V3?) -> Command,
	stop: (self: Agent) -> (),
	snapshot: (self: Agent) -> { [string]: any },
}

function NavAgent.new(options: Options?, _env: any?): Agent
	local problems = NavAgent.validate(options)
	if #problems > 0 then
		error("NavAgent.new: " .. table.concat(problems, "; "), 2)
	end
	local arrive = option(options, "arriveRadius")
	local vertical = option(options, "verticalTolerance")
	local stuckTime, stuckDistance = option(options, "stuckTime"), option(options, "stuckDistance")
	local maxRepaths, maxFailures = option(options, "maxRepaths"), option(options, "maxPathFailures")
	local repathDistance, minGap = option(options, "repathDistance"), option(options, "minRepathGap")
	local retryDelay = option(options, "pathRetryDelay")
	local interval = options and options.repathInterval

	local self: any = { state = "idle" }
	local now = 0
	local target: V3? = nil
	local waypoints: { Waypoint } = {}
	local index = 1
	local partial = false
	local request = 0
	local repaths = 0
	local failures = 0
	local retryAt: number? = nil
	local lastRequestAt = -math.huge
	local windowStart, windowBest = 0, math.huge
	local blockedFlag = false

	local function ask(reason: string): Command
		request += 1
		lastRequestAt = now
		self.state = "waiting"
		return { kind = "repath", to = target, reason = reason, request = request }
	end

	local function fail(reason: string): Command
		self.state = "failed"
		return { kind = "failed", reason = reason }
	end

	function self.moveTo(_, goal: V3): Command
		target = table.clone(goal)
		repaths, failures, retryAt = 0, 0, nil
		return ask("new_target")
	end

	-- Hands a computed path back. Returns false for a stale request or an unusable path (the
	-- agent then retries or fails on its next step).
	function self.setPath(_, points: { Waypoint }, status: string?, forRequest: number?): boolean
		if forRequest ~= nil and forRequest ~= request then
			return false
		end
		if self.state ~= "waiting" then
			return false
		end
		local usable = NavAgent.USABLE[status or "Success"]
		if usable == nil or #points == 0 then
			failures += 1
			if failures > maxFailures then
				retryAt = nil
				self.state = "failed"
				self.failReason = "no_path"
			else
				retryAt = now + retryDelay * 2 ^ (failures - 1)
			end
			return false
		end
		failures, retryAt = 0, nil
		waypoints = table.clone(points)
		partial = usable == "partial"
		-- The first waypoint is where the agent stands (PathfindingService puts it there).
		index = if #waypoints > 1 then 2 else 1
		windowStart, windowBest = now, math.huge
		blockedFlag = false
		self.state = "following"
		return true
	end

	-- PathfindingService Path.Blocked: a waypoint at or ahead of the current one forces a repath.
	function self.blocked(_, blockedIndex: number)
		if self.state == "following" and blockedIndex >= index then
			blockedFlag = true
		end
	end

	function self.stop(_)
		self.state = "idle"
		target, waypoints = nil, {}
	end

	function self.step(_, dt: number, position: V3, movingTarget: V3?): Command
		now += math.max(dt, 0)
		local state = self.state
		if state == "idle" then
			return { kind = "idle" }
		elseif state == "arrived" then
			return { kind = "arrived", reason = if partial then "partial" else nil }
		elseif state == "failed" then
			return { kind = "failed", reason = self.failReason or "stuck" }
		elseif state == "waiting" then
			if retryAt and now >= retryAt then
				retryAt = nil
				return ask("retry")
			end
			return { kind = "wait", request = request }
		end

		-- Following.
		if movingTarget and target then
			local moved = distance(movingTarget, target :: V3)
			if moved > repathDistance and now - lastRequestAt >= minGap then
				target = table.clone(movingTarget)
				return ask("target_moved")
			end
		end
		if blockedFlag then
			blockedFlag = false
			return ask("blocked")
		end
		if interval and now - lastRequestAt >= interval then
			return ask("interval")
		end
		while index <= #waypoints do
			local wp = waypoints[index]
			if horizontal(position, wp.pos) <= arrive and math.abs(position.y - wp.pos.y) <= vertical then
				index += 1
				repaths = 0
				windowStart, windowBest = now, math.huge
			else
				break
			end
		end
		if index > #waypoints then
			self.state = "arrived"
			return { kind = "arrived", reason = if partial then "partial" else nil }
		end
		local wp = waypoints[index]
		local d = horizontal(position, wp.pos)
		if d < windowBest - stuckDistance or windowBest == math.huge then
			windowBest = d
			windowStart = now
		elseif now - windowStart >= stuckTime then
			repaths += 1
			if repaths > maxRepaths then
				self.failReason = "stuck"
				return fail("stuck")
			end
			windowStart, windowBest = now, math.huge
			return ask("stuck")
		end
		return {
			kind = if wp.action == "jump" then "jump" else "move",
			to = wp.pos,
			waypoint = index,
			label = wp.label,
		}
	end

	function self.snapshot(_): { [string]: any }
		return {
			state = self.state,
			waypoint = index,
			waypoints = #waypoints,
			repaths = repaths,
			failures = failures,
			request = request,
			partial = partial,
		}
	end

	return self
end

return NavAgent
