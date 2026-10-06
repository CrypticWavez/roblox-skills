--!strict
-- Studio entry for probe ui_gallery_audit (G4): mounts every UIKit gallery story in PlayerGui
-- and audits it with UIKit/AuditRoblox (engine layout, TextFits, pseudo-localisation and legacy
-- fonts). Run it in a client play session on the unpublished diagnostic place built from
-- fixtures/kits.project.json, once per device in the Device Simulator (phone, tablet, desktop,
-- console); it prints ENGINE_CHECK lines and one ENGINE_DONE (GameKit/Probe). Not run in this
-- container: PENDING.
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

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "ui_gallery_audit" } })
