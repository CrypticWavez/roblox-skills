--!strict
-- G2 authority fixture, server side (Script ServerScriptService.KitFixtures.authority_Sim). Opt
-- in: runs only when Workspace attribute SETUP_ONLY_KitFixture is "authority", and only in an
-- unpublished Studio place (Env.assertDiagnostic raises elsewhere). Nothing here is game content.
--   * One simulation step bound through AuthorityRoblox.bindStep (RunService:BindToSimulation;
--     the PostSimulation fallback only where the engine lacks it, reported in the holder's
--     ArenaStep attribute) drives the shared core authority_Arena with time().
--   * Clients send IAS input and hit claims (client/authority_Input.client.luau) through two
--     remotes in ReplicatedStorage.SETUP_ONLY_Authority; the arena validates both. Under
--     AuthorityMode Server the engine may also replicate InputAction state itself (UNVERIFIED
--     until probe authority_input_actions runs); the validated remote works in either mode.
--   * State replicates as attributes, at most 64 per Instance (AuthorityRoblox.writeAttributes):
--     round state and ArenaClock on the holder, health/stamina/mode on each body marker.
--   * Latency per player comes from Player:GetNetworkPing() (UNVERIFIED whether it is one-way or
--     round trip; the validator clamps it to the 200 ms rewind cap either way).
-- Built at y = 800 (a convention: clear of the place's content). Prints AUTHORITY_EVENT lines
-- (canonical JSON) for phases, hits and outs so a Studio run leaves a readable log.
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

local Env = kit("GameKit/Env")
local EnvRoblox = kit("GameKit/EnvRoblox")
local AuthorityRoblox = kit("GameKit/AuthorityRoblox")
local Json = kit("GameKit/Json")
local Zones = kit("GameKit/Zones")
local Arena = (require :: any)(ReplicatedStorage:WaitForChild("KitFixtures"):WaitForChild("authority_Arena"))

local env = EnvRoblox.studio()
Env.assertDiagnostic(env, "authority fixture")

local ORIGIN = Vector3.new(0, 800, 0)
local arena = Arena.new(kit, env, { seed = 1, origin = { x = ORIGIN.X, y = ORIGIN.Y, z = ORIGIN.Z } })
local config = Arena.CONFIG

-- World: a floor, translucent zone volumes and one marker per body.
local world = Instance.new("Folder")
world.Name = "SETUP_ONLY_AuthorityArena"
local floor = Instance.new("Part")
floor.Name = "Floor"
floor.Anchored = true
floor.Size = Vector3.new(config.half * 2, 1, config.half * 2)
floor.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0))
floor.Parent = world
for _, id in arena.zones.ids do
	local zone = arena.zones.zones[id]
	local lo, hi = Zones.bounds(zone.shape)
	local volume = Instance.new("Part")
	volume.Name = id
	volume.Anchored = true
	volume.CanCollide = false
	volume.CanQuery = false
	volume.Transparency = 0.8
	volume.Size = Vector3.new(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
	volume.CFrame = CFrame.new((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
	if zone.shape.kind == "sphere" then
		volume.Shape = Enum.PartType.Ball
	end
	volume:SetAttribute("ZoneKind", zone.kind)
	volume.Parent = world
end
local bodies = Instance.new("Folder")
bodies.Name = "Bodies"
bodies.Parent = world

-- Replication holder and the two client -> server remotes.
local holder = Instance.new("Folder")
holder.Name = "SETUP_ONLY_Authority"
local function remote(name: string, unreliable: boolean): any
	local ok, instance = pcall(Instance.new, if unreliable then "UnreliableRemoteEvent" else "RemoteEvent")
	local event: Instance = if ok then instance else Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = holder
	return event
end
local inputRemote = remote("Input", true)
local claimRemote = remote("Claim", false)
holder.Parent = ReplicatedStorage
world.Parent = Workspace

local markers: { [number]: any } = {}

local function added(player: any)
	local ok = arena:join(player.UserId)
	if not ok then
		return
	end
	local marker = Instance.new("Part")
	marker.Name = tostring(player.UserId)
	marker.Anchored = true
	marker.CanCollide = false
	marker.Size =
		Vector3.new(config.bodyRadius * 2, (config.bodyHalf + config.bodyRadius) * 2, config.bodyRadius * 2)
	marker.CFrame = CFrame.new(ORIGIN + Vector3.new(0, config.bodyHeight, 0))
	marker.Parent = bodies
	markers[player.UserId] = marker
end

Players.PlayerAdded:Connect(added)
for _, player in Players:GetPlayers() do
	added(player)
end
Players.PlayerRemoving:Connect(function(player: any)
	arena:leave(player.UserId)
	local marker = markers[player.UserId]
	if marker then
		marker:Destroy()
		markers[player.UserId] = nil
	end
end)

inputRemote.OnServerEvent:Connect(function(player: any, payload: any)
	arena:input(player.UserId, payload)
end)
claimRemote.OnServerEvent:Connect(function(player: any, payload: any)
	arena:claim(player.UserId, payload)
end)

local REPORTED = { phase = true, hit = true, out = true, spawn = true }

local _, how = AuthorityRoblox.bindStep(RunService, function()
	for _, player in Players:GetPlayers() do
		local ok, ping = pcall(function()
			return player:GetNetworkPing()
		end)
		if ok and type(ping) == "number" then
			arena:setLatency(player.UserId, ping)
		end
	end
	for _, event in arena:step() do
		if REPORTED[event.kind] then
			print("AUTHORITY_EVENT " .. Json.encode(event))
		end
	end
	local values = arena:roundAttributes()
	local stats = arena:stats()
	local rejected = 0
	for _, n in stats.claimRejected do
		rejected += n
	end
	values.ArenaAccepted = stats.accepted
	values.ArenaRejected = rejected
	AuthorityRoblox.writeAttributes(holder, values)
	for userId, marker in markers do
		local position = arena:position(userId)
		if position then
			marker.CFrame = CFrame.new(position.x, position.y, position.z)
			AuthorityRoblox.writeAttributes(marker, arena:bodyAttributes(userId) or {})
		end
	end
end, { allowFallback = true })
holder:SetAttribute("ArenaStep", how)
holder:SetAttribute("ArenaAuthorityMode", AuthorityRoblox.mode(Workspace))
print(
	"AUTHORITY_EVENT "
		.. Json.encode({ kind = "started", step = how, mode = AuthorityRoblox.mode(Workspace) })
)
