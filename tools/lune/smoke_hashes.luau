--!strict
-- Writes tests/golden/studio-smoke.json: the hashes Studio must reproduce when running
-- fixtures/factory/FactorySmoke.server.luau.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local FactorySmoke = require("../../packages/Pipeline/FactorySmoke")

local result = FactorySmoke.run(nil)
fs.writeFile("tests/golden/studio-smoke.json", serde.encode("json", result, true) .. "\n")
print(serde.encode("json", result, false))
