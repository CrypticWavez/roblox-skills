--!strict
-- @tier T3
-- probe: lvl_pathfinding_probe
-- NavAgentRoblox: drives a Humanoid with GameKit/NavAgent and PathfindingService. Paths come from
-- PathfindingService:CreatePath(agent parameters) and Path:ComputeAsync (it yields, so it runs on
-- env.spawn, never inside the step); Path.Blocked feeds NavAgent:blocked. Waypoint actions map to
-- Humanoid:MoveTo and Humanoid.Jump. modifier() tags a part with a PathfindingModifier (a label
-- with a cost in the agent parameters, or PassThrough for doors), link() joins two attachments
-- with a PathfindingLink (a labelled shortcut such as a ladder or a jump pad). The mappings
-- (parameters, waypoints, statuses) are pure and tested in Lune with tests/fakes/FakePathfinding;
-- the engine behaviour is T3 (probes lvl_pathfinding_probe and lvl_navagent_door).
local Env = require("./Env")
local NavAgent = require("./NavAgent")
local Signal = require("./Signal")

local NavAgentRoblox = {}

export type Options = NavAgent.Options & {
	radius: number?, -- AgentRadius (default 2)
	height: number?, -- AgentHeight (default 5)
	canJump: boolean?, -- AgentCanJump (default true)
	canClimb: boolean?, -- AgentCanClimb (default false)
	spacing: number?, -- WaypointSpacing (default 4)
	costs: { [string]: number }?, -- material names and modifier labels -> cost (math.huge avoids)
	moveRefresh: number?, -- seconds between repeated MoveTo calls (default 4; MoveTo gives up at 8)
}

-- The CreatePath agent parameters table.
function NavAgentRoblox.parameters(options: Options?): { [string]: any }
	local o: any = options or {}
	return {
		AgentRadius = o.radius or 2,
		AgentHeight = o.height or 5,
		AgentCanJump = if o.canJump == nil then true else o.canJump,
		AgentCanClimb = o.canClimb == true,
		WaypointSpacing = o.spacing or 4,
		Costs = table.clone(o.costs or {}),
	}
end

-- PathWaypoints to NavAgent waypoints ({ x, y, z } positions; Jump -> jump, Custom -> custom).
function NavAgentRoblox.waypoints(list: { any }): { NavAgent.Waypoint }
	local out = {}
	for _, waypoint in list do
		local action = waypoint.Action and waypoint.Action.Name
		local p = waypoint.Position
		table.insert(out, {
			pos = { x = p.X, y = p.Y, z = p.Z },
			action = if action == "Jump" then "jump" elseif action == "Custom" then "custom" else "walk",
			label = if waypoint.Label ~= nil and waypoint.Label ~= "" then waypoint.Label else nil,
		})
	end
	return out
end

-- PathfindingModifier under `parent` (Label, PassThrough).
function NavAgentRoblox.modifier(parent: any, label: string, passThrough: boolean?, env: any): any
	local modifier = env.roblox.Instance.new("PathfindingModifier")
	modifier.Label = label
	modifier.PassThrough = passThrough == true
	modifier.Parent = parent
	return modifier
end

-- PathfindingLink between two attachments (Label, IsBidirectional), parented to `parent`.
function NavAgentRoblox.link(
	parent: any,
	a0: any,
	a1: any,
	label: string,
	bidirectional: boolean?,
	env: any
): any
	local link = env.roblox.Instance.new("PathfindingLink")
	link.Attachment0 = a0
	link.Attachment1 = a1
	link.Label = label
	link.IsBidirectional = bidirectional ~= false
	link.Parent = parent
	return link
end

export type Controller = {
	agent: NavAgent.Agent,
	finished: any, -- Signal(kind: "arrived" | "failed", reason?)
	moveTo: (self: Controller, goal: any) -> (),
	step: (self: Controller, dt: number, target: any?) -> NavAgent.Command,
	stop: (self: Controller) -> (),
	destroy: (self: Controller) -> (),
}

-- A controller for one Humanoid and its root part. Call step(dt, movingTarget?) from the
-- simulation loop; moveTo(goal) with a Vector3.
function NavAgentRoblox.new(humanoid: any, root: any, options: Options?, env: any): Controller
	local service = Env.service(env, "PathfindingService")
	local Vector3 = env.roblox.Vector3
	local agent = NavAgent.new(options, env)
	local params = NavAgentRoblox.parameters(options)
	local refresh = (options and options.moveRefresh) or 4
	local blockedConnection: any = nil
	local lastWaypoint, lastMoveAt, clock = -1, -math.huge, 0
	local finished = Signal.new(env)
	local announced = false

	local function toVector(p: NavAgent.V3): any
		return Vector3.new(p.x, p.y, p.z)
	end
	local function fromVector(v: any): NavAgent.V3
		return { x = v.X, y = v.Y, z = v.Z }
	end

	local function compute(command: NavAgent.Command)
		env.spawn(function()
			local path = service:CreatePath(params)
			local ok = pcall(function()
				path:ComputeAsync(root.CFrame.Position, toVector(command.to :: NavAgent.V3))
			end)
			local status = if ok then path.Status.Name else "ComputeFailed"
			local points = if ok then NavAgentRoblox.waypoints(path:GetWaypoints()) else {}
			if agent:setPath(points, status, command.request) then
				if blockedConnection then
					blockedConnection:Disconnect()
				end
				blockedConnection = path.Blocked:Connect(function(index: number)
					agent:blocked(index)
				end)
			end
		end)
	end

	local controller: any = { agent = agent, finished = finished }

	function controller.moveTo(_, goal: any)
		announced = false
		lastWaypoint = -1
		compute(agent:moveTo(fromVector(goal)))
	end

	function controller.step(_, dt: number, target: any?): NavAgent.Command
		clock += dt
		local command =
			agent:step(dt, fromVector(root.CFrame.Position), if target then fromVector(target) else nil)
		if command.kind == "repath" then
			compute(command)
		elseif command.kind == "move" or command.kind == "jump" then
			if command.waypoint ~= lastWaypoint or clock - lastMoveAt >= refresh then
				humanoid:MoveTo(toVector(command.to :: NavAgent.V3))
				lastWaypoint, lastMoveAt = command.waypoint :: number, clock
				if command.kind == "jump" then
					humanoid.Jump = true
				end
			end
		elseif (command.kind == "arrived" or command.kind == "failed") and not announced then
			announced = true
			finished:Fire(command.kind, command.reason)
		end
		return command
	end

	function controller.stop(_)
		agent:stop()
		humanoid:MoveTo(root.CFrame.Position)
	end

	function controller.destroy(_)
		if blockedConnection then
			blockedConnection:Disconnect()
		end
		finished:Destroy()
	end

	return controller
end

return NavAgentRoblox
