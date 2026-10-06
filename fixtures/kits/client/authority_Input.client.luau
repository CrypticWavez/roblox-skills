--!strict
-- G2 authority fixture, client side (LocalScript StarterPlayerScripts.KitFixtures.authority_Input).
-- Opt in: runs only when Workspace attribute SETUP_ONLY_KitFixture is "authority".
--   * Builds the raw IAS InputContext from authority_Arena.ACTIONS (AuthorityRoblox.buildActions;
--     G4's InputMap replaces this raw build after merge) and reads it in the simulation step.
--   * Sends input (camera-relative move turned into a world XZ direction, sprint, dash) through
--     the Input remote when it changes, at most 20 times a second plus a 4 Hz keep-alive.
--   * On a primary press, raycasts from its own body marker along the camera look against the
--     body markers and sends a hit claim stamped with the ArenaClock attribute it sees (the
--     server time of the world on screen); the server rewinds to it (at most 200 ms).
-- The client decides nothing: the server validates and applies everything.
local Players = (game :: any):GetService("Players")
local ReplicatedStorage = (game :: any):GetService("ReplicatedStorage")
local RunService = (game :: any):GetService("RunService")
local Workspace = (game :: any):GetService("Workspace")

if Workspace:GetAttribute("SETUP_ONLY_KitFixture") ~= "authority" then
	return
end

local workbench = ReplicatedStorage:WaitForChild("Workbench", 10)
local function kit(path: string): any
	local node = workbench
	for _, part in string.split(path, "/") do
		node = node:WaitForChild(part, 10)
	end
	return (require :: any)(node)
end

local AuthorityRoblox = kit("GameKit/AuthorityRoblox")
local Arena = (require :: any)(ReplicatedStorage:WaitForChild("KitFixtures"):WaitForChild("authority_Arena"))

local holder = ReplicatedStorage:WaitForChild("SETUP_ONLY_Authority", 30)
local arenaFolder = Workspace:WaitForChild("SETUP_ONLY_AuthorityArena", 30)
if holder == nil or arenaFolder == nil then
	warn("authority fixture: the server side did not start (is the place unpublished?)")
	return
end
local inputRemote = holder:WaitForChild("Input")
local claimRemote = holder:WaitForChild("Claim")
local bodies = arenaFolder:WaitForChild("Bodies")
local player = Players.LocalPlayer

local _, actions = AuthorityRoblox.buildActions(Arena.ACTIONS, { Instance = Instance, Enum = Enum }, script)

local SEND_INTERVAL = 1 / 20
local KEEP_ALIVE = 0.25

local function read(name: string): any
	local ok, value = pcall(AuthorityRoblox.readAction, actions[name])
	return if ok then value else nil
end

local function flat(v: Vector3): Vector3
	local h = Vector3.new(v.X, 0, v.Z)
	return if h.Magnitude > 1e-6 then h.Unit else Vector3.zero
end

local function plain(v: Vector3): { x: number, y: number, z: number }
	return { x = v.X, y = v.Y, z = v.Z }
end

local lastSent = { x = 0, z = 0, sprint = false }
local sentAt = -math.huge
local held = { dash = false, primary = false }
local shot = 0
local seq = 0
local followed = false

local function fire(own: any, camera: any)
	local origin = own.CFrame.Position
	local direction = camera.CFrame.LookVector
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { bodies }
	-- A ray that starts inside its own marker does not hit it.
	local result = Workspace:Raycast(origin, direction * Arena.CONFIG.primaryRange, params)
	if result == nil then
		return
	end
	shot += 1
	claimRemote:FireServer({
		target = result.Instance:GetAttribute("BodyId"),
		time = holder:GetAttribute("ArenaClock"),
		origin = plain(origin),
		direction = plain(direction),
		hitPoint = plain(result.Position),
		shotId = shot,
	})
end

AuthorityRoblox.bindStep(RunService, function()
	local camera = Workspace.CurrentCamera
	local own = bodies:FindFirstChild(tostring(player.UserId))
	if camera == nil or own == nil then
		return
	end
	if not followed then
		camera.CameraSubject = own
		followed = true
	end
	local move = read("gameplay.move") or { x = 0, y = 0 }
	local world = flat(camera.CFrame.RightVector) * move.x + flat(camera.CFrame.LookVector) * move.y
	local sprint = read("gameplay.sprint") == true
	local dash = read("gameplay.dash") == true
	local primary = read("gameplay.primary") == true
	local dashPressed = dash and not held.dash
	held.dash = dash
	local now = os.clock()
	local changed = math.abs(world.X - lastSent.x) > 0.01
		or math.abs(world.Z - lastSent.z) > 0.01
		or sprint ~= lastSent.sprint
	if dashPressed or (changed and now - sentAt >= SEND_INTERVAL) or now - sentAt >= KEEP_ALIVE then
		seq += 1
		inputRemote:FireServer({
			move = { x = world.X, z = world.Z },
			sprint = sprint,
			dash = dashPressed,
			seq = seq,
		})
		lastSent = { x = world.X, z = world.Z, sprint = sprint }
		sentAt = now
	end
	if primary and not held.primary then
		fire(own, camera)
	end
	held.primary = primary
end, { allowFallback = true })
