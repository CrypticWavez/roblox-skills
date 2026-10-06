--!strict
-- Studio RunScript entry for probe av_vfx_grid (G5): AVKit/VfxPoolRoblox plays the 21 presets on a grid.
-- Side: server or client. Loads kits from the built kits place (fixtures/kits.project.json ->
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

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "av_vfx_grid" } })
