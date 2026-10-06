--!strict
-- G9b kit smoke runner (client). Inert unless Workspace attribute SETUP_ONLY_KitFixture is
-- "kitsmoke". In a play session it runs every shared and client probe registry through
-- Pipeline/KitSmoke (perf_capture_client among them) and prints ENGINE_CHECK lines and one
-- ENGINE_DONE line in the client Output; record it with
-- `python3 tools/studio_run.py --probe kitsmoke_all --from-output <file>`.
local Workspace = game:GetService("Workspace")
if Workspace:GetAttribute("SETUP_ONLY_KitFixture") ~= "kitsmoke" then
	return
end
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workbench = ReplicatedStorage:WaitForChild("Workbench")
local KitSmoke = require(Workbench:WaitForChild("Pipeline"):WaitForChild("KitSmoke")) :: any
local kit = KitSmoke.studioLoader(Workbench)
local EnvRoblox = kit("GameKit/EnvRoblox")

local sources = KitSmoke.collect({
	{ side = "shared", folder = ReplicatedStorage:WaitForChild("KitFixtures") },
	{ side = "client", folder = script.Parent },
})
KitSmoke.run(sources, { env = EnvRoblox.studio(), kit = kit })
