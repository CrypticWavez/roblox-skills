--!strict
-- Studio entry for probe platform_playerdata_memory (G1, PlayerData and PlayerDataRoblox).
-- Run on the server of a play session (Play or Server & Clients) on the unpublished diagnostic
-- place built from fixtures/kits.project.json: kits come from ReplicatedStorage.Workbench, the
-- registry from ServerScriptService.KitFixtures.platform_probes. Prints ENGINE_CHECK lines and
-- one ENGINE_DONE. Not run in this container; pending until the owner's run produces the lines.
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
	ServerScriptService:WaitForChild("KitFixtures"):WaitForChild("platform_probes")
)

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "platform_playerdata_memory" } })
