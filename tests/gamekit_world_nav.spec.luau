-- GameKit NavAgent (pure follower: arrival, jump waypoints, stuck detection and repath limits,
-- path failures with retry backoff, stale results, moving targets, blocked waypoints, partial
-- paths) and NavAgentRoblox against FakePathfinding (agent parameters, waypoint mapping,
-- modifiers and links on Lune instances, a controller that walks, retries a failed path, repaths
-- on Path.Blocked and fails when stuck).
local roblox = require("@lune/roblox")
local FakeEnv = require("./fakes/FakeEnv")
local FakePathfinding = require("./fakes/FakePathfinding")
local NavAgent = require("../packages/GameKit/NavAgent")
local NavAgentRoblox = require("../packages/GameKit/NavAgentRoblox")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local function v(x, y, z)
	return { x = x, y = y or 0, z = z or 0 }
end

local function line(n, step)
	local out = {}
	for i = 0, n do
		table.insert(out, { pos = v(i * step), action = "walk" })
	end
	return out
end

test("follows waypoints to arrival; jump waypoints ask for a jump", function(t)
	local agent = NavAgent.new()
	local first = agent:moveTo(v(12))
	t.eq(first, { kind = "repath", to = v(12), reason = "new_target", request = 1 })
	t.eq(agent:step(0.1, v(0)), { kind = "wait", request = 1 })
	local points = line(3, 4)
	points[3].action = "jump"
	t.eq(agent:setPath(points, "Success", 1), true)
	local pos = v(0)
	local kinds = {}
	for _ = 1, 20 do
		local command = agent:step(0.1, pos)
		table.insert(kinds, command.kind .. (if command.waypoint then command.waypoint else ""))
		if command.kind == "arrived" then
			break
		end
		pos = command.to :: any
	end
	t.eq(kinds, { "move2", "jump3", "move4", "arrived" })
	t.eq(agent.state, "arrived")
end)

test("stuck: no progress for stuckTime repaths; too many repaths fail", function(t)
	local agent = NavAgent.new({ stuckTime = 1, maxRepaths = 2 })
	agent:moveTo(v(20))
	agent:setPath(line(5, 4), "Success", 1)
	local reasons = {}
	for _ = 1, 100 do
		local command = agent:step(0.25, v(0, 0, 3)) -- pinned against something
		if command.kind == "repath" then
			table.insert(reasons, command.reason .. ":" .. command.request)
			agent:setPath(line(5, 4), "Success", command.request)
		elseif command.kind == "failed" then
			table.insert(reasons, "failed:" .. command.reason)
			break
		end
	end
	t.eq(reasons, { "stuck:2", "stuck:3", "failed:stuck" })
	t.eq(agent:step(0.1, v(0)).kind, "failed", "stays failed")
end)

test("path failures retry with backoff, then fail with no_path; stale results are ignored", function(t)
	local agent = NavAgent.new({ pathRetryDelay = 1, maxPathFailures = 2 })
	agent:moveTo(v(10))
	t.eq(agent:setPath({}, "NoPath", 1), false)
	t.eq(agent:step(0.5, v(0)).kind, "wait")
	local retry = agent:step(0.5, v(0))
	t.eq({ retry.kind, retry.reason, retry.request }, { "repath", "retry", 2 })
	t.eq(agent:setPath(line(2, 5), "Success", 1), false, "request 1 is stale")
	t.eq(agent:setPath({}, "NoPath", 2), false)
	t.eq(agent:step(1.5, v(0)).kind, "wait", "second retry waits 2 s")
	t.eq(agent:step(0.5, v(0)).reason, "retry")
	agent:setPath({}, "FailStartNotEmpty", 3)
	t.eq(agent:step(0.1, v(0)), { kind = "failed", reason = "no_path" })
end)

test("moving targets, blocked waypoints and partial paths", function(t)
	local agent = NavAgent.new({ repathDistance = 5, minRepathGap = 0.5 })
	agent:moveTo(v(20))
	agent:setPath(line(5, 4), "Success", 1)
	t.eq(agent:step(0.1, v(0), v(22)).kind, "move", "moved 2 studs: keep going")
	t.eq(agent:step(0.5, v(0), v(30)).reason, "target_moved")
	agent:setPath(line(5, 6), "Success", 2)
	agent:blocked(1)
	t.eq(agent:step(0.1, v(0)).kind, "move", "a waypoint behind does not matter")
	agent:blocked(4)
	t.eq(agent:step(0.1, v(0)).reason, "blocked")
	agent:setPath(line(2, 4), "ClosestNoPath", 3)
	local pos = v(0)
	local last
	for _ = 1, 10 do
		last = agent:step(0.1, pos)
		if last.kind ~= "move" then
			break
		end
		pos = last.to
	end
	t.eq(last, { kind = "arrived", reason = "partial" })
	t.eq(NavAgent.validate({ stuckTime = 0, maxRepaths = -1, repathInterval = 0 }), {
		"stuckTime must be a finite number > 0",
		"maxRepaths must be an integer >= 0",
		"repathInterval must be a finite number > 0",
	})
end)

test("NavAgentRoblox maps parameters, waypoints, modifiers and links", function(t)
	t.eq(NavAgentRoblox.parameters({ radius = 3, costs = { avoid = math.huge } }), {
		AgentRadius = 3,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = false,
		WaypointSpacing = 4,
		Costs = { avoid = math.huge },
	})
	local mapped = NavAgentRoblox.waypoints({
		{ Position = roblox.Vector3.new(1, 2, 3), Action = { Name = "Walk" }, Label = "" },
		{ Position = roblox.Vector3.new(4, 5, 6), Action = { Name = "Jump" }, Label = "" },
		{ Position = roblox.Vector3.new(7, 8, 9), Action = { Name = "Custom" }, Label = "ladder" },
	})
	t.eq(mapped, {
		{ pos = v(1, 2, 3), action = "walk" },
		{ pos = v(4, 5, 6), action = "jump" },
		{ pos = v(7, 8, 9), action = "custom", label = "ladder" },
	})
	local env = FakeEnv.new({ roblox = roblox })
	local part = roblox.Instance.new("Part")
	local modifier = NavAgentRoblox.modifier(part, "door", true, env)
	t.eq({ modifier.ClassName, modifier.Label, modifier.PassThrough, modifier.Parent == part }, {
		"PathfindingModifier",
		"door",
		true,
		true,
	})
	local a0, a1 = roblox.Instance.new("Attachment"), roblox.Instance.new("Attachment")
	local link = NavAgentRoblox.link(part, a0, a1, "ladder", false, env)
	t.eq({ link.ClassName, link.Label, link.IsBidirectional }, { "PathfindingLink", "ladder", false })
end)

local function rig(env)
	local root = roblox.Instance.new("Part")
	root.CFrame = roblox.CFrame.new(0, 3, 0)
	local moves = {}
	local humanoid = {
		Jump = false,
		MoveTo = function(_, target)
			table.insert(moves, target)
		end,
	}
	return root, humanoid, moves
end

test("NavAgentRoblox controller walks a fake path, retrying a failed compute", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local service = FakePathfinding.new({ roblox = roblox, statuses = { "NoPath" }, spacing = 4 })
	env:register("PathfindingService", service)
	local root, humanoid, moves = rig(env)
	local controller =
		NavAgentRoblox.new(humanoid, root, { pathRetryDelay = 0.2, costs = { lava = math.huge } }, env)
	local finished = {}
	controller.finished:Connect(function(kind, reason)
		table.insert(finished, kind .. ":" .. tostring(reason))
	end)
	controller:moveTo(roblox.Vector3.new(16, 3, 0))
	t.eq(service.created[1].Costs, { lava = math.huge })
	for _ = 1, 50 do
		local command = controller:step(0.1)
		if command.kind == "move" or command.kind == "jump" then
			root.CFrame = roblox.CFrame.new(command.to.x, command.to.y, command.to.z)
		elseif command.kind == "arrived" then
			break
		end
	end
	t.eq(#service.computed, 2, "NoPath, then a retry that succeeds")
	t.eq(finished, { "arrived:nil" })
	t.eq(#moves, 4, "one MoveTo per waypoint after the start")
	t.eq(moves[#moves], roblox.Vector3.new(16, 3, 0))
	controller:destroy()
end)

test("NavAgentRoblox repaths on Path.Blocked and fails when the body never moves", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local service = FakePathfinding.new({ roblox = roblox })
	env:register("PathfindingService", service)
	local root, humanoid = rig(env)
	local controller = NavAgentRoblox.new(humanoid, root, { stuckTime = 0.5, maxRepaths = 1 }, env)
	local finished = nil
	controller.finished:Connect(function(kind, reason)
		finished = kind .. ":" .. reason
	end)
	controller:moveTo(roblox.Vector3.new(40, 3, 0))
	t.eq(controller:step(0.1).kind, "move")
	service.lastPath:fireBlocked(5)
	t.eq(controller:step(0.1).reason, "blocked")
	t.eq(#service.computed, 2)
	local last
	for _ = 1, 40 do
		last = controller:step(0.1)
		if last.kind == "failed" then
			break
		end
	end
	t.eq(last.kind, "failed")
	t.eq(finished, "failed:stuck")
	controller:destroy()
end)

return cases
