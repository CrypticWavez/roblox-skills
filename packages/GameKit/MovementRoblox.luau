--!strict
-- @tier T3
-- probe: action_movement_humanoid
-- MovementRoblox: applies a Movement controller to a Humanoid character under Server Authority.
--   * apply(humanoid, root, output) sets Humanoid.WalkSpeed, gives jumps their launch speed
--     (root AssemblyLinearVelocity.Y, so air jumps work) and holds the horizontal velocity
--     during dashes and slides. Climb events are left to the game (a tween or AlignPosition to
--     the ledge top it chose).
--   * grounded(humanoid) is FloorMaterial ~= Air.
--   * ledgeProbe(worldRoot, root, roblox, params, reach, maxHeight) casts forward and then down
--     to build the { height, distance, normal } a "ledge" request needs.
--   * readInput(actions) maps IAS actions (AuthorityRoblox.buildActions) to setInput and the
--     pressed edges of jump/dash/slide; start(controller, options, env) runs all of it from one
--     non-yielding simulation step on the side that simulates the character.
-- No Instance work happens at require time; apply/grounded need a real Humanoid (the probe).
local AuthorityRoblox = require("./AuthorityRoblox")

local MovementRoblox = {}
MovementRoblox.ACTIONS = table.freeze({
	move = "gameplay.move",
	sprint = "gameplay.sprint",
	jump = "gameplay.jump",
	dash = "gameplay.dash",
	slide = "gameplay.slide",
})

function MovementRoblox.grounded(humanoid: any): boolean
	return humanoid.FloorMaterial.Name ~= "Air"
end

-- Applies one step's output to the character.
function MovementRoblox.apply(humanoid: any, root: any, output: any, roblox: any)
	humanoid.WalkSpeed = output.walkSpeed
	local velocity = root.AssemblyLinearVelocity
	local x, y, z = velocity.X, velocity.Y, velocity.Z
	for _, event in output.events do
		if event.kind == "jump" then
			y = event.velocity
			humanoid:ChangeState(roblox.Enum.HumanoidStateType.Jumping)
		end
	end
	if output.velocity then
		x, z = output.velocity.x, output.velocity.z
	end
	if x ~= velocity.X or y ~= velocity.Y or z ~= velocity.Z then
		root.AssemblyLinearVelocity = roblox.Vector3.new(x, y, z)
	end
end

-- A ledge probe in front of the root: a forward ray finds the wall (distance, normal), a ray down
-- from above the wall finds the top (height above the feet). nil when there is no ledge.
function MovementRoblox.ledgeProbe(
	worldRoot: any,
	root: any,
	roblox: any,
	params: any,
	reach: number,
	maxHeight: number
): any?
	local Vector3 = roblox.Vector3
	local cframe = root.CFrame
	local forward = cframe.LookVector
	local feet = cframe.Position - Vector3.new(0, root.Size.Y / 2 + 2, 0) -- hip height (convention)
	local wall = worldRoot:Raycast(cframe.Position, forward * reach, params)
	if wall == nil then
		return nil
	end
	local above = wall.Position + forward * 0.5 + Vector3.new(0, maxHeight + 1, 0)
	local top = worldRoot:Raycast(above, Vector3.new(0, -(maxHeight + 1), 0), params)
	if top == nil then
		return nil
	end
	return {
		height = top.Position.Y - feet.Y,
		distance = wall.Distance,
		normal = { x = wall.Normal.X, y = wall.Normal.Y, z = wall.Normal.Z },
	}
end

-- Reads IAS actions into controller input; returns the requests whose action was pressed this
-- step (edge-triggered with last, a table the caller keeps between steps).
function MovementRoblox.readInput(
	controller: any,
	actions: { [string]: any },
	last: { [string]: boolean },
	names: { [string]: string }?
): { string }
	local map = names or MovementRoblox.ACTIONS
	local move = actions[map.move]
	local direction = if move then AuthorityRoblox.readAction(move) else { x = 0, y = 0 }
	local sprintAction = actions[map.sprint]
	local sprint = sprintAction ~= nil and AuthorityRoblox.readAction(sprintAction) == true
	-- Direction2D: x is right, y is forward; the character moves on X/Z with forward = -Z.
	controller:setInput({ x = direction.x, y = 0, z = -direction.y }, sprint)
	local pressed = {}
	for _, request in { "jump", "dash", "slide" } do
		local action = actions[map[request]]
		local down = action ~= nil and AuthorityRoblox.readAction(action) == true
		if down and not last[request] then
			table.insert(pressed, request)
		end
		last[request] = down
	end
	return pressed
end

export type Options = {
	humanoid: any,
	root: any,
	runService: any,
	roblox: any,
	actions: { [string]: any }?,
	names: { [string]: string }?,
	ledge: { worldRoot: any, params: any, reach: number, maxHeight: number }?,
	allowFallback: boolean?,
	onOutput: ((output: any) -> ())?,
}

-- Steps the controller each simulation step: input, grounded, requests, step, apply.
-- Returns (stop, how).
function MovementRoblox.start(controller: any, options: Options, _env: any): (() -> (), string)
	local last = {}
	local unbind, how = AuthorityRoblox.bindStep(options.runService, function()
		controller:setGrounded(MovementRoblox.grounded(options.humanoid))
		if options.actions then
			for _, request in MovementRoblox.readInput(controller, options.actions, last, options.names) do
				local ok = controller:request(request)
				if not ok and request == "jump" and options.ledge then
					local l = options.ledge
					local probe = MovementRoblox.ledgeProbe(
						l.worldRoot,
						options.root,
						options.roblox,
						l.params,
						l.reach,
						l.maxHeight
					)
					if probe then
						controller:request("ledge", probe)
					end
				end
			end
		end
		local output = controller:step()
		MovementRoblox.apply(options.humanoid, options.root, output, options.roblox)
		if options.onOutput then
			options.onOutput(output)
		end
	end, { allowFallback = options.allowFallback })
	if unbind == nil then
		error("MovementRoblox.start: " .. how, 2)
	end
	return unbind :: () -> (), how
end

return MovementRoblox
