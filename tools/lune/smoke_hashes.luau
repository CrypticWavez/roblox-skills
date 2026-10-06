--!strict
-- Writes tests/golden/studio-smoke.json: the hashes Studio must reproduce when running
-- fixtures/factory/FactorySmoke.server.luau. The repo root comes from this file's own path
-- (debug.info gives ".../tools/lune/smoke_hashes"), so it runs from any working directory.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local FactorySmoke = require("../../packages/Pipeline/FactorySmoke")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tools[/\\]lune[/\\][^/\\]*$") or "."

local result = FactorySmoke.run(nil)
fs.writeFile(ROOT .. "/tests/golden/studio-smoke.json", serde.encode("json", result, true) .. "\n")
print(serde.encode("json", result, false))
