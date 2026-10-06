--!strict
-- Studio RunScript entry (G2) for the four authority_ probes in the shared registry
-- ReplicatedStorage.KitFixtures.authority_probes: authority_simulation_bind (BindToSimulation
-- binds, steps with a numeric dt and unbinds; settles AuthorityRoblox.bindStep's UNVERIFIED
-- return shape), authority_mode (Workspace.AuthorityMode reads Server; the owner sets it in
-- Studio), authority_attribute_budget (64 attributes per Instance) and authority_input_actions
-- (raw IAS build). A runner, not a probe: Pipeline/KitSmoke runs the same registry with the
-- others. Run it on the server of a play session on the unpublished diagnostic place. Not run
-- in this container; pending until the owner runs it.
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

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit })
