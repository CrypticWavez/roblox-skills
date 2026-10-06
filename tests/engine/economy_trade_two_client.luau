--!strict
-- Studio RunScript entry for probe economy_trade_two_client (G3), following
-- tests/engine/foundation_env_studio.luau: load kits from ReplicatedStorage.Workbench, load the
-- server registry ServerScriptService.KitFixtures.economy_probes and run the probe with
-- GameKit/Probe (ENGINE_CHECK lines, one ENGINE_DONE). Run it on the server in a Server and Clients test with two clients
-- on the unpublished diagnostic place built from fixtures/kits.project.json. Not run in this
-- container.
local ReplicatedStorage = (game :: any):GetService("ReplicatedStorage")
local ServerScriptService = (game :: any):GetService("ServerScriptService")
local workbench = ReplicatedStorage:WaitForChild("Workbench", 10)

local function kit(path: string): any
	local node = workbench
	for _, part in string.split(path, "/") do
		node = node:WaitForChild(part, 10)
	end
	return (require :: any)(node)
end

local Probe = kit("GameKit/Probe")
local EnvRoblox = kit("GameKit/EnvRoblox")
local registry = (require :: any)(
	ServerScriptService:WaitForChild("KitFixtures"):WaitForChild("economy_probes")
)

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "economy_trade_two_client" } })
