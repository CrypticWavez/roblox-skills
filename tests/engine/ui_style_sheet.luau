--!strict
-- Studio entry for probe ui_style_sheet (G4): UIKit/StyleRoblox builds a native StyleSheet from
-- the token plan; a tagged Frame must take the accent colour from a StyleRule and follow a theme
-- swap (retheme). Run it in a client play session on the unpublished diagnostic place built from
-- fixtures/kits.project.json; it prints ENGINE_CHECK lines and one ENGINE_DONE (GameKit/Probe).
-- Not run in this container: PENDING.
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

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "ui_style_sheet" } })
