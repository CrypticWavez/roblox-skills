--!strict
-- Studio RunScript entry for probe action_zones_enter_exit (G2):
-- ZonesRoblox reads a kill-zone part; the tracker sees enter, kill and exit.
-- Shape of tests/engine/foundation_env_studio.luau: kits from ReplicatedStorage.Workbench (the
-- place built from fixtures/kits.project.json), the server registry
-- ServerScriptService.KitFixtures.action_probes, GameKit/Probe prints ENGINE_CHECK lines and one
-- ENGINE_DONE. Run it on the server of a play session on the unpublished diagnostic place with
-- Workspace.AuthorityMode = Server. Not run in this container; pending until the owner runs it.
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
	ServerScriptService:WaitForChild("KitFixtures"):WaitForChild("action_probes")
)

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "action_zones_enter_exit" } })
