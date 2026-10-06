--!strict
-- Studio RunScript entry for probe feel_marker_cue (G5): Feel/FeelRoblox: an animation marker fires a cue with hit-stop.
-- Side: client (LocalScript). Loads kits from the built kits place (fixtures/kits.project.json ->
-- ReplicatedStorage.Workbench) and the G5 registry ReplicatedStorage.KitFixtures.lookdev_probes,
-- then runs the probe with GameKit/Probe (ENGINE_CHECK lines and one ENGINE_DONE). Run it only in
-- a play session on the unpublished diagnostic place. Not run in this container: the probe stays
-- pending until its output exists.
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
	ReplicatedStorage:WaitForChild("KitFixtures"):WaitForChild("lookdev_probes")
)

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "feel_marker_cue" } })
