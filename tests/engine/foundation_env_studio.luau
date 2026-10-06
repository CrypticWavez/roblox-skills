--!strict
-- Studio RunScript entry for probe foundation_env_studio (Stage 0), the shape every
-- tests/engine/<probe>.luau entry follows: load kits from the built kits place
-- (fixtures/kits.project.json -> ReplicatedStorage.Workbench), load the registry that holds the
-- probe, and run it with GameKit/Probe so it prints ENGINE_CHECK lines and one ENGINE_DONE.
-- Run it in a play session on the unpublished diagnostic place. Not run in this container.
local ReplicatedStorage = (game :: any):GetService("ReplicatedStorage")
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
	ReplicatedStorage:WaitForChild("KitFixtures"):WaitForChild("foundation_probes")
)

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "foundation_env_studio" } })
