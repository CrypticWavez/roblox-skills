--!strict
-- Studio entry for probe cin_play_sample (G4): Cinematics/CinematicsRoblox plays a short pan on
-- Workspace.CurrentCamera; the camera must match Cinematics.sample, events fire once in order,
-- and finishing or skipping restores the camera. Run it in a client play session on the
-- unpublished diagnostic place built from fixtures/kits.project.json; it prints ENGINE_CHECK
-- lines and one ENGINE_DONE (GameKit/Probe). Not run in this container: PENDING.
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
local registry = (require :: any)(ReplicatedStorage:WaitForChild("KitFixtures"):WaitForChild("cin_probes"))

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "cin_play_sample" } })
