--!strict
-- Studio RunScript entry for probe lvl_kit_swap (G7, registry fixtures/kits/server/level_probes.luau,
-- mapped to ServerScriptService.KitFixtures by fixtures/kits.project.json). Run it on the server in
-- a play session on the unpublished diagnostic place built from that project; it prints
-- ENGINE_CHECK lines and one ENGINE_DONE (GameKit/Probe). Not run in this container: until the
-- owner's run produces the lines the probe stays pending and its modules stay T3.
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
	ServerScriptService:WaitForChild("KitFixtures"):WaitForChild("level_probes")
)

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "lvl_kit_swap" } })
