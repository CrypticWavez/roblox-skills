--!strict
-- Studio RunScript entry for probe lookdev_material_override (G5): SceneKit/Materials tier 0, a
-- MaterialVariant base material override sets and reads back. Side: server or command bar. Loads kits from the built kits place (fixtures/kits.project.json ->
-- ReplicatedStorage.Workbench) and the G5 registry ReplicatedStorage.KitFixtures.lookdev_probes,
-- then runs the probe with GameKit/Probe (ENGINE_CHECK lines and one ENGINE_DONE). Building the
-- variant needs plugin security (BaseMaterial), so run it at command-bar level (RunScript or
-- execute_luau); a play session reports variant_built = false. Run it only on the unpublished
-- diagnostic place. Not run in this container: the probe stays pending until its output exists.
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

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "lookdev_material_override" } })
