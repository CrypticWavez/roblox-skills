--!strict
-- Studio RunScript entry (G2) for probe authority_simulation_bind alone, from the shared registry
-- ReplicatedStorage.KitFixtures.authority_probes: RunService:BindToSimulation binds, steps with a
-- numeric dt and unbinds (settles AuthorityRoblox.bindStep's UNVERIFIED return shape).
-- tests/engine/action_authority_suite.luau runs all four authority_ probes; this entry runs this
-- one, so tools/studio_run.py --probe authority_simulation_bind finds it. Run it on the server of
-- a play session on the unpublished diagnostic place. Not run in this container; pending until
-- the owner runs it.
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
	ReplicatedStorage:WaitForChild("KitFixtures"):WaitForChild("authority_probes")
)

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "authority_simulation_bind" } })
