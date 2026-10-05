--!strict
-- Shared smoke scenes. Lune computes their hashes into tests/golden/studio-smoke.json;
-- fixtures/factory/FactorySmoke.server.luau builds the same scenes in Studio and prints the
-- hashes, proving SceneKit/ProcGen behave identically in both runtimes.
local Dungeon = require("../ProcGen/Dungeon")
local PValidate = require("../ProcGen/Validate")
local Placement = require("../ProcGen/Placement")
local SceneKit = require("../SceneKit/SceneKit")

local FactorySmoke = {}

function FactorySmoke.scenes()
	local building =
		SceneKit.Scene.new({ name = "SETUP_ONLY_SmokeBuilding", seed = 101, style = "neutral-stone" })
	SceneKit.Building.create(building, { footprint = { x = -16, z = -12, w = 32, d = 24 }, storeys = 2 })

	local layout = Dungeon.generate({ seed = 303 })
	local placement = Placement.assign(layout, { encounters = 3, landmarks = 1 })
	local dungeon = SceneKit.Scene.new({ name = "SETUP_ONLY_SmokeDungeon", seed = 303 })
	dungeon:transformed({ x = 80, y = 0, z = 0 }, 0, function()
		SceneKit.Layout.toScene(dungeon, layout, { placement = placement })
	end)
	return {
		building = { scene = building, checks = SceneKit.Validate.scene(building) },
		dungeon = { scene = dungeon, checks = PValidate.rooms(layout, placement) },
	}
end

-- Apply every smoke scene under `parent` and return { name = { pass, parts, hash } }.
function FactorySmoke.run(parent: any, env: any?)
	local out = {}
	for key, entry in FactorySmoke.scenes() do
		local summary, model =
			SceneKit.Apply.scene(entry.scene, parent, { env = env, dryRun = parent == nil })
		local validation = SceneKit.Validate.summary(entry.checks)
		local created = nil
		if model then
			created = 0
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					created += 1
				end
			end
		end
		out[key] = {
			pass = validation.pass,
			failed = validation.failed,
			parts = summary.parts,
			instances = created,
			hash = summary.hash,
		}
	end
	return out
end

return FactorySmoke
