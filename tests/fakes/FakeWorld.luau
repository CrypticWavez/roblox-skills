--!strict
-- FakeWorld: just enough engine for G2 adapter and probe specs in Lune.
--   * roblox(lune) wraps @lune/roblox and adds RaycastParams/OverlapParams (absent from Lune) as
--     plain tables with the same fields.
--   * new(env, roblox) registers fake services in env: RunService (BindToSimulation records
--     callbacks; world:step(dt, n) advances the env clock and calls them), Workspace (a table:
--     AuthorityMode, Gravity, mount/unmount(instance) instead of parenting, and Raycast, Spherecast,
--     GetPartBoundsInBox, GetPartBoundsInRadius over the mounted parts using the pure Hitbox
--     math), ReplicatedStorage (a real Lune Folder), Players (no players, fake signals) and
--     KeyframeSequenceProvider/AnimationClipProvider (temporary ids "rbxtemp://fake/<n>").
-- It proves wiring and probe logic, not engine behaviour: queries use the same Hitbox maths the
-- cores use, so only a Studio run of the probes is evidence about the engine.
local Hitbox = require("../../packages/GameKit/Hitbox")
local Vec = require("../../packages/SceneKit/Vec")

local FakeWorld = {}

local function signal()
	local handlers = {}
	local sig = {}
	function sig:Connect(fn: any)
		table.insert(handlers, fn)
		local connection = { Connected = true }
		function connection:Disconnect()
			connection.Connected = false
			local index = table.find(handlers, fn)
			if index then
				table.remove(handlers, index)
			end
		end
		return connection
	end
	function sig:Fire(...: any)
		for _, fn in table.clone(handlers) do
			fn(...)
		end
	end
	function sig:Count(): number
		return #handlers
	end
	return sig
end
FakeWorld.signal = signal

local function params(lune: any): any
	local p: any = {
		FilterType = lune.Enum.RaycastFilterType.Exclude,
		FilterDescendantsInstances = {},
		CollisionGroup = "Default",
		IgnoreWater = false,
		RespectCanCollide = false,
		MaxParts = 0,
	}
	function p:AddToFilter(instances: any)
		local list = if type(instances) == "table" then instances else { instances }
		for _, instance in list do
			table.insert(p.FilterDescendantsInstances, instance)
		end
	end
	return p
end

function FakeWorld.roblox(lune: any): any
	local extra = {
		RaycastParams = {
			new = function()
				return params(lune)
			end,
		},
		OverlapParams = {
			new = function()
				return params(lune)
			end,
		},
	}
	return setmetatable(extra, { __index = lune })
end

local function v3(value: any): Vec.V3
	return Vec.new(value.X, value.Y, value.Z)
end

local function shapeOf(part: any): Hitbox.Shape
	local cframe = part.CFrame
	local size = part.Size
	if part.Shape.Name == "Ball" then
		return Hitbox.sphere(v3(cframe.Position), math.min(size.X, size.Y, size.Z) / 2)
	end
	return Hitbox.boxAxes(
		v3(cframe.Position),
		v3(size),
		v3(cframe.RightVector),
		v3(cframe.UpVector),
		Vec.scale(v3(cframe.LookVector), -1)
	)
end
FakeWorld.shapeOf = shapeOf

function FakeWorld.new(env: any, roblox: any): any
	local world: any = { bound = {}, mounted = {}, steps = 0, errors = {} }
	local Vector3 = roblox.Vector3

	-- RunService
	local runService: any = { PostSimulation = signal(), Heartbeat = signal() }
	function runService:BindToSimulation(fn: (dt: number) -> ())
		local entry = { fn = fn, connected = true }
		table.insert(world.bound, entry)
		return {
			Disconnect = function()
				entry.connected = false
			end,
		}
	end
	function world:step(dt: number, count: number?)
		for _ = 1, count or 1 do
			env:advance(dt)
			world.steps += 1
			for _, entry in table.clone(world.bound) do
				if entry.connected then
					-- Like the engine, a callback error is reported and the step goes on.
					local ok, err = pcall(entry.fn, dt)
					if not ok then
						table.insert(world.errors, tostring(err))
					end
				end
			end
		end
	end
	function world:boundCount(): number
		local n = 0
		for _, entry in world.bound do
			n += if entry.connected then 1 else 0
		end
		return n
	end

	-- Workspace
	local workspace: any = {
		Name = "Workspace",
		AuthorityMode = roblox.Enum.AuthorityMode.Automatic,
		Gravity = 196.2,
	}
	function workspace:mount(instance: any)
		table.insert(world.mounted, instance)
	end
	function workspace:unmount(instance: any)
		local index = table.find(world.mounted, instance)
		if index then
			table.remove(world.mounted, index)
		end
	end
	local function parts(): { any }
		local out = {}
		for _, root in world.mounted do
			if root:IsA("BasePart") then
				table.insert(out, root)
			end
			for _, descendant in root:GetDescendants() do
				if descendant:IsA("BasePart") then
					table.insert(out, descendant)
				end
			end
		end
		return out
	end
	world.parts = parts
	local function allowed(part: any, p: any?): boolean
		if p == nil then
			return true
		end
		local listed = false
		for _, instance in p.FilterDescendantsInstances or {} do
			if instance == part or part:IsDescendantOf(instance) then
				listed = true
				break
			end
		end
		if p.FilterType == roblox.Enum.RaycastFilterType.Include then
			return listed
		end
		return not listed
	end
	local function cast(origin: any, radius: number, direction: any, p: any?): any
		local o, d = v3(origin), v3(direction)
		local length = Vec.length(d)
		local best, bestFraction, bestPoint = nil, math.huge, nil
		for _, part in parts() do
			if allowed(part, p) then
				local hit, fraction, point = Hitbox.segment(shapeOf(part), o, d, radius)
				-- Engine casts ignore parts the shape starts inside (WorldRoot docs).
				if hit and (fraction :: number) > 0 and (fraction :: number) < bestFraction then
					best, bestFraction, bestPoint = part, fraction :: number, point
				end
			end
		end
		if best == nil then
			return nil
		end
		local point = bestPoint :: Vec.V3
		local normal = Vec.scale(Vec.unit(d), -1)
		return {
			Instance = best,
			Position = Vector3.new(point.x, point.y, point.z),
			Normal = Vector3.new(normal.x, normal.y, normal.z),
			Distance = bestFraction * length,
			Material = roblox.Enum.Material.Plastic,
		}
	end
	function workspace:Raycast(origin: any, direction: any, p: any?)
		return cast(origin, 0, direction, p)
	end
	function workspace:Spherecast(origin: any, radius: number, direction: any, p: any?)
		return cast(origin, radius, direction, p)
	end
	function workspace:GetPartBoundsInBox(cframe: any, size: any, p: any?): { any }
		local query = Hitbox.boxAxes(
			v3(cframe.Position),
			v3(size),
			v3(cframe.RightVector),
			v3(cframe.UpVector),
			Vec.scale(v3(cframe.LookVector), -1)
		)
		local lo, hi = Hitbox.bounds(query)
		local out = {}
		for _, part in parts() do
			if allowed(part, p) then
				local plo, phi = Hitbox.bounds(shapeOf(part))
				if
					plo.x <= hi.x
					and phi.x >= lo.x
					and plo.y <= hi.y
					and phi.y >= lo.y
					and plo.z <= hi.z
					and phi.z >= lo.z
				then
					table.insert(out, part)
				end
			end
		end
		return out
	end
	function workspace:GetPartBoundsInRadius(position: any, radius: number, p: any?): { any }
		local center = v3(position)
		local out = {}
		for _, part in parts() do
			if allowed(part, p) then
				local plo, phi = Hitbox.bounds(shapeOf(part))
				local box = Hitbox.box(Vec.scale(Vec.add(plo, phi), 0.5), Vec.sub(phi, plo))
				if Hitbox.distance(box, center) <= radius then
					table.insert(out, part)
				end
			end
		end
		return out
	end

	-- Players (none; signals for wiring)
	local players: any = { PlayerAdded = signal(), PlayerRemoving = signal(), list = {} }
	function players:GetPlayers()
		return table.clone(players.list)
	end
	function players:GetPlayerFromCharacter(character: any)
		for _, player in players.list do
			if player.Character == character then
				return player
			end
		end
		return nil
	end

	local temp = 0
	local function register(_self: any, _source: any): string
		temp += 1
		return "rbxtemp://fake/" .. temp
	end

	local replicated = roblox.Instance.new("Folder")
	replicated.Name = "ReplicatedStorage"

	env:register("RunService", runService)
	env:register("Workspace", workspace)
	env:register("ReplicatedStorage", replicated)
	env:register("Players", players)
	env:register("KeyframeSequenceProvider", { RegisterKeyframeSequence = register })
	env:register("AnimationClipProvider", { RegisterAnimationClip = register })
	world.runService = runService
	world.workspace = workspace
	world.players = players
	world.replicatedStorage = replicated
	return world
end

return FakeWorld
