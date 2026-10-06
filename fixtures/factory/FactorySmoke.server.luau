--!strict
-- SETUP_ONLY diagnostic: proves SceneKit/ProcGen load and behave identically in real Roblox
-- (string requires, bit32, Instance creation). Disabled by default; enable it in the
-- unpublished diagnostic place, press Run (F8), and compare the printed hashes with
-- tests/golden/studio-smoke.json.
local HttpService = game:GetService("HttpService")
local Workbench = game:GetService("ReplicatedStorage"):WaitForChild("Workbench")
local FactorySmoke = require(Workbench.Pipeline.FactorySmoke) :: any

print("FACTORY_SMOKE " .. HttpService:JSONEncode(FactorySmoke.run(workspace)))
