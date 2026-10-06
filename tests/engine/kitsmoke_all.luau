--!strict
-- Studio RunScript entry for kitsmoke_all: every shared and server probe registry of the kits
-- diagnostic place (fixtures/kits.project.json), merged and run by Pipeline/KitSmoke, which prints
-- ENGINE_CHECK lines and one ENGINE_DONE line (docs/runtime-kits.md section 7). Run it with
--   python3 tools/studio_run.py --probe kitsmoke_all --build
-- on the owner's PC (unpublished place only). Client registries run in a play session through
-- fixtures/kits/client/kitsmoke_Runner.client.luau instead. Not run in this container.
local ReplicatedStorage = (game :: any):GetService("ReplicatedStorage")
local ServerScriptService = (game :: any):GetService("ServerScriptService")
local Workbench = ReplicatedStorage:WaitForChild("Workbench", 10)
local KitSmoke = (require :: any)(Workbench:WaitForChild("Pipeline", 10):WaitForChild("KitSmoke", 10))
local kit = KitSmoke.studioLoader(Workbench)
local EnvRoblox = kit("GameKit/EnvRoblox")

local sources = KitSmoke.collect({
	{ side = "shared", folder = ReplicatedStorage:WaitForChild("KitFixtures", 10) },
	{ side = "server", folder = ServerScriptService:WaitForChild("KitFixtures", 10) },
})
KitSmoke.run(sources, { env = EnvRoblox.studio(), kit = kit })
