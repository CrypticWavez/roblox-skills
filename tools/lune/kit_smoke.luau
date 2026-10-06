--!strict
-- Kit smoke in Lune: Pipeline/KitSmoke over the repository's probe registries with fakes.
--   lune run tools/lune/kit_smoke.luau            check, print the G9b ENGINE lines and the inventory
--   FACTORY_UPDATE_GOLDEN=kit-smoke lune run ...  rewrite tests/golden/kit-smoke.json
-- 1. Inventory: every fixtures/kits/<side>/*_probes registry must load, hold only lower_snake
--    probe names mapped to functions, and register no name twice (across all sides).
-- 2. Golden: the G9b registries (kitsmoke_*) run on a fake server and a fake client
--    (tests/fakes/FakeKitSmoke.luau); their ENGINE lines must match tests/golden/kit-smoke.json.
-- Other groups' probes are loaded, not run: each group runs its own registry against its fakes.
-- This is Lune evidence only; Studio evidence is `python3 tools/studio_run.py --probe kitsmoke_all`.
-- Exit 0 on success, 1 on any problem.
local process = require("@lune/process")
local FakeKitSmoke = require("../../tests/fakes/FakeKitSmoke")
local Golden = require("../../tests/lib/Golden")
local KitSmoke = require("../../packages/Pipeline/KitSmoke")

local failures = 0

local _, problems, inventory = KitSmoke.merge(FakeKitSmoke.sources())
for _, entry in inventory do
	print(
		string.format(
			"REGISTRY %s/%s %s",
			entry.side,
			entry.name,
			if entry.error then "ERROR " .. entry.error else table.concat(entry.probes, " ")
		)
	)
end
for _, problem in problems do
	print("PROBLEM " .. problem)
	failures += 1
end

local value = FakeKitSmoke.golden()
for _, side in { "server", "client" } do
	for _, line in value[side].lines do
		print(line)
	end
	if not value[side].summary.ok then
		print("FAIL " .. side .. " kit smoke run is not ok")
		failures += 1
	end
end
local ok, message = Golden.check("kit-smoke", value)
print((if ok then "GOLDEN " else "FAIL ") .. "kit-smoke: " .. message)
if not ok then
	failures += 1
end

print(string.format("kit_smoke: %d registries, %d problems, %d failures", #inventory, #problems, failures))
process.exit(if failures == 0 then 0 else 1)
