--!strict
-- @tier T3
-- probe: economy_followers_formation
-- FollowersRoblox: drives GameKit/Followers with physics constraints. attach(part) adds an
-- Attachment, an AlignPosition and an AlignOrientation (both OneAttachment mode) to an
-- unanchored follower part; apply() writes step frames to them (Position, CFrame) and snaps
-- teleported followers with PivotTo; start() reads parts back into the core, steps it and
-- applies the frames every simulation step through RunService:BindToSimulation, falling back to
-- RunService.PreSimulation (reported) where BindToSimulation is missing. Followers are usually
-- cosmetic and created on the client that sees them; this adapter does not set network owners.
-- Engine types come from env.roblox (EnvRoblox.studio()); leaderFrom and frameCFrame are pure
-- mappings. Responsiveness and force defaults are conventions.
local Followers = require("./Followers")

local FollowersRoblox = {}
FollowersRoblox.DEFAULTS = table.freeze({
	responsiveness = 25, -- AlignPosition/AlignOrientation Responsiveness (convention)
	maxForce = 100000, -- AlignPosition.MaxForce (convention)
	maxTorque = 100000, -- AlignOrientation.MaxTorque (convention)
})

export type Handle = { part: any, attachment: any, align: any, orient: any }

local function roblox(env: any): any
	assert(env and env.roblox, "FollowersRoblox needs env.roblox (EnvRoblox.studio())")
	return env.roblox
end

-- A Followers leader from a CFrame (or anything with Position and LookVector).
function FollowersRoblox.leaderFrom(cframe: any): Followers.Leader
	local p, look = cframe.Position, cframe.LookVector
	return { position = { x = p.X, y = p.Y, z = p.Z }, lookVector = { x = look.X, y = look.Y, z = look.Z } }
end

-- The CFrame for a step frame: its position, turned to its yaw.
function FollowersRoblox.frameCFrame(frame: Followers.Frame, env: any): any
	local r = roblox(env)
	local p = frame.position
	return r.CFrame.new(p.x, p.y, p.z) * r.CFrame.Angles(0, math.rad(frame.yaw), 0)
end

-- Adds the constraints to an unanchored follower part and returns the handle.
function FollowersRoblox.attach(part: any, options: { [string]: number }?, env: any): Handle
	local r = roblox(env)
	local o = options or {}
	local attachment = r.Instance.new("Attachment")
	attachment.Name = "FollowerAttachment"
	attachment.Parent = part
	local align = r.Instance.new("AlignPosition")
	align.Name = "FollowerAlignPosition"
	align.Mode = r.Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.Responsiveness = o.responsiveness or FollowersRoblox.DEFAULTS.responsiveness
	align.MaxForce = o.maxForce or FollowersRoblox.DEFAULTS.maxForce
	align.Position = part.Position
	align.Parent = part
	local orient = r.Instance.new("AlignOrientation")
	orient.Name = "FollowerAlignOrientation"
	orient.Mode = r.Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.Responsiveness = o.responsiveness or FollowersRoblox.DEFAULTS.responsiveness
	orient.MaxTorque = o.maxTorque or FollowersRoblox.DEFAULTS.maxTorque
	orient.Parent = part
	return { part = part, attachment = attachment, align = align, orient = orient }
end

-- Writes frames to their handles. Teleported followers are moved with PivotTo.
function FollowersRoblox.apply(handles: { [string]: Handle }, frames: { Followers.Frame }, env: any)
	local r = roblox(env)
	for _, frame in frames do
		local handle = handles[frame.id]
		if handle then
			local p = frame.position
			handle.align.Position = r.Vector3.new(p.x, p.y, p.z)
			handle.orient.CFrame = r.CFrame.Angles(0, math.rad(frame.yaw), 0)
			if frame.teleported then
				handle.part:PivotTo(FollowersRoblox.frameCFrame(frame, env))
			end
		end
	end
end

-- Copies each part's physical position into the core before a step.
function FollowersRoblox.readBack(core: Followers.Followers, handles: { [string]: Handle })
	for id, handle in handles do
		if core:slotOf(id) ~= nil and core:positionOf(id) ~= nil then
			local p = handle.part.Position
			core:place(id, { x = p.X, y = p.Y, z = p.Z })
		end
	end
end

-- One step: read back, step the core toward leaderCFrame, apply. Returns the frames.
function FollowersRoblox.stepOnce(
	core: Followers.Followers,
	handles: { [string]: Handle },
	dt: number,
	leaderCFrame: any,
	env: any
): { Followers.Frame }
	FollowersRoblox.readBack(core, handles)
	local frames = core:step(dt, FollowersRoblox.leaderFrom(leaderCFrame))
	FollowersRoblox.apply(handles, frames, env)
	return frames
end

-- Steps every simulation frame while getLeader() returns a CFrame. Returns stop().
function FollowersRoblox.start(
	core: Followers.Followers,
	handles: { [string]: Handle },
	getLeader: () -> any,
	env: any
): () -> ()
	local runService = env.services.RunService
	local running = true
	local last = env.clock()
	local function onStep(dt: any)
		if not running then
			return
		end
		local now = env.clock()
		local seconds = if type(dt) == "number" then dt else now - last
		last = now
		local leader = getLeader()
		if leader ~= nil then
			FollowersRoblox.stepOnce(core, handles, seconds, leader, env)
		end
	end
	local connection: any = nil
	local bound = false
	-- Indexing a member the engine lacks raises, so look it up inside pcall.
	local indexed, bind = pcall(function(): any
		return runService.BindToSimulation
	end)
	if indexed and type(bind) == "function" then
		bound, connection = pcall(bind, runService, onStep)
	end
	if not bound then
		if env.report then
			env.report("FollowersRoblox: BindToSimulation unavailable; stepping on RunService.PreSimulation")
		end
		connection = runService.PreSimulation:Connect(onStep)
	end
	return function()
		running = false -- also stops a binding that returned nothing to disconnect
		if connection ~= nil then
			pcall(function()
				connection:Disconnect()
			end)
		end
	end
end

return FollowersRoblox
