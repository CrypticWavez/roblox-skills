--!strict
-- G9b kit smoke runner (server). Inert unless Workspace attribute SETUP_ONLY_KitFixture is
-- "kitsmoke". In a play session on the unpublished kits diagnostic place it runs every shared and
-- server probe registry through Pipeline/KitSmoke and prints ENGINE_CHECK lines and one
-- ENGINE_DONE line; save the Output (or the Studio MCP console) and record it with
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
	{ side = "server", folder = script.Parent },
})
KitSmoke.run(sources, { env = EnvRoblox.studio(), kit = kit })
