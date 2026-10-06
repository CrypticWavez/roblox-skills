--!strict
-- Studio entry for probe inputmap_contexts (G4): GameKit/InputMapRoblox builds Input Action System
-- contexts, actions and bindings from InputMap.defaults() (priorities, sink, types, key codes, a
-- TouchActionButton bound as UIButton). Run it in a client play session on the unpublished
-- diagnostic place built from fixtures/kits.project.json; it prints ENGINE_CHECK lines and one
-- ENGINE_DONE (GameKit/Probe). Not run in this container: PENDING.
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
local registry = (require :: any)(ReplicatedStorage:WaitForChild("KitFixtures"):WaitForChild("ui_probes"))

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "inputmap_contexts" } })
