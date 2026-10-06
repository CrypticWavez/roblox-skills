--!strict
-- SceneKit/Materials (material-library/1): the committed assets/material-library.json validates
-- and stays upload-free; validate rejects every malformed field (DirectX normals, oversized
-- textures, duplicate overrides, ids without maps); kit/1 references resolve; tier 0 override
-- plans and the tier 1 MaterialVariant builder behave, the Studio-only override call goes through
-- a fake MaterialService.
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Materials = require("../packages/SceneKit/Materials")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function library(): any
	return serde.decode("json", fs.readFile(ROOT .. "/assets/material-library.json"))
end

local function mentions(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function sample(): any
	return {
		name = "sample_a",
		base_material = "Concrete",
		studs_per_tile = 8,
		pattern = "Regular",
		maps = { color = "ambientcg/Sample001/1K-PNG#Color", normal = "ambientcg/Sample001/1K-PNG#NormalGL" },
		resolution = 1024,
		override_base = false,
		provenance = "ambientcg/Sample001/1K-PNG",
		roblox = { color = 0, normal = 0, roughness = 0, metalness = 0 },
	}
end

test("the committed library validates, is named by function and needs no uploads", function(t)
	local lib = library()
	t.eq(Materials.validate(lib), {})
	t.ok(#lib.materials >= 12, "a usable neutral set")
	for _, material in lib.materials do
		t.ok(string.match(material.name, "_a$"), material.name .. " is a neutral variant slot")
		t.eq(material.provenance, "local")
		for slot, id in material.roblox do
			t.eq(id, 0, material.name .. " " .. slot .. " stays 0 until the owner uploads")
		end
		for slot, ref in material.maps do
			t.ok(
				string.sub(ref, 1, 6) == "build:",
				material.name .. " " .. slot .. " is a factory bake output"
			)
		end
		t.ok(material.resolution <= 1024, "no library default above 1024")
		-- Every map is still pending: nothing is uploaded from the factory.
		local pending = Materials.pendingMaps(material)
		local count = 0
		for _ in material.maps do
			count += 1
		end
		t.eq(#pending, count)
	end
	local defined = Materials.define(lib)
	t.ok(table.isfrozen(defined) and table.isfrozen(defined.materials[1].maps))
end)

test("validate rejects malformed materials", function(t)
	local function rejects(needle: string, mutate: (any) -> ())
		local lib = { schema = "material-library/1", materials = { sample() } }
		mutate(lib)
		local problems = Materials.validate(lib)
		t.ok(mentions(problems, needle), needle .. " -> " .. table.concat(problems, "; "))
	end
	rejects("schema must be material-library/1", function(lib)
		lib.schema = "material-library/2"
	end)
	rejects("extra is not a library key", function(lib)
		lib.extra = true
	end)
	rejects("name must be a lower_snake label", function(lib)
		lib.materials[1].name = "Concrete A"
	end)
	rejects("is listed twice", function(lib)
		table.insert(lib.materials, sample())
	end)
	rejects("tint is not a material key", function(lib)
		lib.materials[1].tint = { 1, 2, 3 }
	end)
	rejects("base_material Stone is not an Enum.Material name", function(lib)
		lib.materials[1].base_material = "Stone"
	end)
	rejects("base_material Water cannot carry a MaterialVariant", function(lib)
		lib.materials[1].base_material = "Water"
	end)
	rejects("studs_per_tile must be > 0", function(lib)
		lib.materials[1].studs_per_tile = 0
	end)
	rejects("pattern must be Regular or Organic", function(lib)
		lib.materials[1].pattern = "Tiled"
	end)
	rejects("maps.height is not a map slot", function(lib)
		lib.materials[1].maps.height = "x#y"
	end)
	rejects("maps.color is required", function(lib)
		lib.materials[1].maps.color = nil
	end)
	rejects("DirectX normal map", function(lib)
		lib.materials[1].maps.normal = "ambientcg/Sample001/1K-PNG#NormalDX"
	end)
	rejects("must not contain backslashes or ..", function(lib)
		lib.materials[1].maps.roughness = "build:../outside.png"
	end)
	rejects("must be <source key>#<file> or build:<path>", function(lib)
		lib.materials[1].maps.roughness = "/home/user/roughness.png"
	end)
	rejects("resolution must be a power of two", function(lib)
		lib.materials[1].resolution = 1000
	end)
	rejects("needs a justify sentence", function(lib)
		lib.materials[1].resolution = 2048
	end)
	rejects("4096 is the engine ceiling", function(lib)
		lib.materials[1].resolution = 4096
		lib.materials[1].justify = "Hero asset seen at close range in every shot."
	end)
	rejects("override_base must be a boolean", function(lib)
		lib.materials[1].override_base = "yes"
	end)
	rejects("both override Concrete", function(lib)
		local second = sample()
		second.name = "sample_b"
		lib.materials[1].override_base = true
		second.override_base = true
		table.insert(lib.materials, second)
	end)
	rejects("provenance must be local or an asset-sources key", function(lib)
		lib.materials[1].provenance = "C:\\textures"
	end)
	rejects("roblox.emissive is not an uploadable slot", function(lib)
		lib.materials[1].roblox.emissive = 0
	end)
	rejects("roblox.color must be an integer id >= 0", function(lib)
		lib.materials[1].roblox.color = 1.5
	end)
	rejects("roblox.roughness is set but maps.roughness is null", function(lib)
		lib.materials[1].roblox.roughness = 77
	end)
	t.eq(Materials.validate(5), { "library must be a table" })
	t.throws(function()
		Materials.define({ schema = "material-library/1", materials = { 5 } })
	end)
	-- A justified 2048 hero texture is allowed.
	local hero = { schema = "material-library/1", materials = { sample() } }
	hero.materials[1].resolution = 2048
	hero.materials[1].justify = "Hero surface filling the screen in the lobby shot."
	t.eq(Materials.validate(hero), {})
end)

test("kit/1 material references resolve against the library", function(t)
	local lib = library()
	local resolved = Materials.resolve("library:concrete_a", lib)
	t.eq(resolved.kind, "library")
	t.eq(resolved.material.base_material, "Concrete")
	t.eq(Materials.resolve("builtin:SmoothPlastic"), { kind = "builtin", material = "SmoothPlastic" })
	t.eq(Materials.resolve("atlas:door_atlas.png"), { kind = "atlas", file = "door_atlas.png" })
	t.eq(Materials.resolve("vertex_color"), { kind = "vertex_color" })
	for _, bad in { "library:missing_a", "builtin:Stone", "builtin:Air", "atlas:../x.png", "paint:red" } do
		local value, problem = Materials.resolve(bad, lib)
		t.eq(value, nil, bad)
		t.ok(type(problem) == "string", bad)
	end
	local _, needsLibrary = Materials.resolve("library:concrete_a")
	t.ok(string.find(needsLibrary :: string, "needs a material library", 1, true))
end)

test("Materials.ENUM matches the engine's Enum.Material names", function(t)
	local engine = {}
	for _, item in roblox.Enum.Material:GetEnumItems() do
		table.insert(engine, item.Name)
	end
	table.sort(engine)
	local ours = table.clone(Materials.ENUM)
	table.sort(ours)
	t.eq(ours, engine)
end)

test("tier 0: override plan and the SetBaseMaterialOverride call (fake MaterialService)", function(t)
	local lib = library()
	local plan = Materials.overridePlan(lib)
	t.eq(plan, {
		{ base_material = "Grass", name = "grass_a" },
		{ base_material = "Ground", name = "ground_soil_a" },
		{ base_material = "Rock", name = "rock_a" },
		{ base_material = "Sand", name = "sand_a" },
	})
	-- MaterialService methods are not in Lune's reflection database: record the calls instead.
	local calls = {}
	local variants = {}
	for _, material in lib.materials do
		if material.name ~= "sand_a" then
			variants[material.name] = (Materials.buildVariant(material, roblox))
		end
	end
	local service = {
		FindFirstChild = function(_, name: string)
			return variants[name]
		end,
		SetBaseMaterialOverride = function(_, base: any, name: string)
			if name == "rock_a" then
				error("engine refused")
			end
			table.insert(calls, base.Name .. "=" .. name)
		end,
	}
	local report = Materials.applyOverrides(service, plan, roblox)
	t.eq(calls, { "Grass=grass_a", "Ground=ground_soil_a" })
	t.eq(report.set, { "Grass -> grass_a", "Ground -> ground_soil_a" })
	t.eq(report.missing, { "Sand -> sand_a" }, "no variant, no override")
	t.eq(#report.failed, 1)
	t.ok(string.find(report.failed[1], "Rock: ", 1, true))
	-- A variant with the wrong base material is not used.
	variants.grass_a.BaseMaterial = roblox.Enum.Material.Rock
	local wrong = Materials.applyOverrides(service, { plan[1] }, { roblox = roblox })
	t.eq(wrong.missing, { "Grass -> grass_a" })
end)

test("tier 1: buildVariant sets scriptable properties and lists pending maps", function(t)
	local material = sample()
	local variant, pending = Materials.buildVariant(material, roblox)
	t.eq(variant.ClassName, "MaterialVariant")
	t.eq(variant.Name, "sample_a")
	t.eq(variant.BaseMaterial, roblox.Enum.Material.Concrete)
	t.eq(variant.StudsPerTile, 8)
	t.eq(variant.MaterialPattern, roblox.Enum.MaterialPattern.Regular)
	t.eq(variant:GetAttribute("SceneKitMaterial"), "sample_a")
	t.eq(#pending, 2)
	t.eq(
		pending[1],
		{ slot = "color", property = "ColorMap", reference = "ambientcg/Sample001/1K-PNG#Color" }
	)
	-- Once an id exists (game repo, after upload) the slot is no longer pending.
	material.roblox.normal = 4242
	local _, after = Materials.buildVariant(material, roblox)
	t.eq(#after, 1)
end)

return cases
