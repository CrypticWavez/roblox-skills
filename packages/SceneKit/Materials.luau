--!strict
-- Materials: the material-library/1 format (docs/runtime-kits.md "material-library/1";
-- data in assets/material-library.json, G6 bakes against its names, kit/1 pieces cite them as
-- library:<name>). Two tiers (docs/research/visual-audio-assets-2026-10.md 3d and 6.2):
--   tier 0  built-in Enum.Material plus MaterialService:SetBaseMaterialOverride (security None,
--           any script): overridePlan + applyOverrides switch a base material place-wide to a
--           MaterialVariant that already exists;
--   tier 1  MaterialVariants with uploaded maps (game repo; maps are PluginSecurity to write, so
--           execute_luau builds them after the owner uploads). buildVariant sets the scriptable
--           properties and lists the map slots still pending.
-- validate/define/resolve/overridePlan are pure (T0); buildVariant runs on @lune/roblox (T1);
-- applyOverrides needs Studio (T3, probe lookdev_material_override: MaterialService methods are
-- not in Lune's reflection database). Keys are snake_case (Python tools read the library).
local Budgets = require("./Budgets")

local Materials = {}

Materials.SCHEMA = "material-library/1"
Materials.MAP_KEYS = table.freeze({ "color", "normal", "roughness", "metalness", "emissive" })
Materials.ROBLOX_KEYS = table.freeze({ "color", "normal", "roughness", "metalness" })
Materials.PATTERNS = table.freeze({ "Regular", "Organic" })
-- MaterialVariant properties per map key (color and emissive are sRGB, the rest Non-Color).
Materials.MAP_PROPERTY = table.freeze({
	color = "ColorMap",
	normal = "NormalMap",
	roughness = "RoughnessMap",
	metalness = "MetalnessMap",
	emissive = "EmissiveMaskContent",
})

-- Enum.Material names (Lune 0.10.5 reflection database). Air, Water and ForceField cannot carry
-- a MaterialVariant (UNVERIFIED in the docs; they are terrain water, empty space and an effect).
Materials.ENUM = table.freeze({
	"Asphalt",
	"Basalt",
	"Brick",
	"Cardboard",
	"Carpet",
	"CeramicTiles",
	"ClayRoofTiles",
	"Cobblestone",
	"Concrete",
	"CorrodedMetal",
	"CrackedLava",
	"DiamondPlate",
	"Fabric",
	"Foil",
	"Glacier",
	"Glass",
	"Granite",
	"Grass",
	"Ground",
	"Ice",
	"LeafyGrass",
	"Leather",
	"Limestone",
	"Marble",
	"Metal",
	"Mud",
	"Neon",
	"Pavement",
	"Pebble",
	"Plaster",
	"Plastic",
	"Rock",
	"RoofShingles",
	"Rubber",
	"Salt",
	"Sand",
	"Sandstone",
	"Slate",
	"SmoothPlastic",
	"Snow",
	"Wood",
	"WoodPlanks",
	"Air",
	"Water",
	"ForceField",
})
local NO_VARIANT = { Air = true, Water = true, ForceField = true }

local MATERIAL_KEYS = {
	name = true,
	base_material = true,
	studs_per_tile = true,
	pattern = true,
	maps = true,
	resolution = true,
	justify = true,
	override_base = true,
	provenance = true,
	roblox = true,
}
local STUDS_PER_TILE_MAX = 1024 -- convention

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function label(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function sortedKeys(map: { [any]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	return keys
end

local function powerOfTwo(value: number): boolean
	return value >= 1 and value % 1 == 0 and bit32.band(value, value - 1) == 0
end

-- A map reference: "<asset-sources key>#<file or channel>" or "build:<relative path>".
-- Problems are returned for absolute paths, "..", empty parts and DirectX normal maps.
function Materials.referenceProblem(ref: any, slot: string?): string?
	if type(ref) ~= "string" or #ref == 0 or #ref > 200 then
		return "must be a reference string"
	end
	if string.find(ref, "\\", 1, true) or string.find(ref, "..", 1, true) then
		return "must not contain backslashes or .."
	end
	local ok = string.match(ref, "^build:[%w_%-][%w_./%-]*$") ~= nil
		or string.match(ref, "^[%w][%w_./%-]*#[%w_.%-]+$") ~= nil
	if not ok then
		return "must be <source key>#<file> or build:<path>"
	end
	if slot == "normal" then
		local lower = string.lower(ref)
		if string.find(lower, "normaldx", 1, true) or string.find(lower, "nor_dx", 1, true) then
			return "is a DirectX normal map; Roblox expects OpenGL (NormalGL, nor_gl)"
		end
	end
	return nil
end

local function validateMaterial(
	index: number,
	material: any,
	problems: { string },
	names: { [string]: boolean }
)
	local where = "materials[" .. index .. "]"
	if type(material) ~= "table" then
		table.insert(problems, where .. " must be a table")
		return
	end
	if label(material.name) then
		where = "material " .. material.name
		if names[material.name] then
			table.insert(problems, where .. " is listed twice")
		end
		names[material.name] = true
	else
		table.insert(problems, where .. ".name must be a lower_snake label")
	end
	for _, key in sortedKeys(material) do
		if not MATERIAL_KEYS[key] then
			table.insert(problems, where .. ": " .. key .. " is not a material key")
		end
	end
	local base = material.base_material
	if not table.find(Materials.ENUM, base) then
		table.insert(
			problems,
			where .. ": base_material " .. tostring(base) .. " is not an Enum.Material name"
		)
	elseif NO_VARIANT[base] then
		table.insert(problems, where .. ": base_material " .. base .. " cannot carry a MaterialVariant")
	end
	local spt = material.studs_per_tile
	if not finite(spt) or spt <= 0 or spt > STUDS_PER_TILE_MAX then
		table.insert(
			problems,
			where .. ": studs_per_tile must be > 0 and <= " .. STUDS_PER_TILE_MAX .. " (convention)"
		)
	end
	if not table.find(Materials.PATTERNS, material.pattern) then
		table.insert(problems, where .. ": pattern must be Regular or Organic")
	end
	local maps = material.maps
	if type(maps) ~= "table" then
		table.insert(problems, where .. ": maps must be a table (null for an absent map)")
		maps = {}
	end
	for _, key in sortedKeys(maps) do
		if not table.find(Materials.MAP_KEYS, key) then
			table.insert(problems, where .. ": maps." .. key .. " is not a map slot")
		else
			local problem = Materials.referenceProblem(maps[key], key)
			if problem then
				table.insert(problems, where .. ": maps." .. key .. " " .. problem)
			end
		end
	end
	if maps.color == nil then
		table.insert(
			problems,
			where .. ": maps.color is required (a variant without a colour map is the base material)"
		)
	end
	local resolution = material.resolution
	if not finite(resolution) or not powerOfTwo(resolution) then
		table.insert(problems, where .. ": resolution must be a power of two")
	elseif resolution > Budgets.CONVENTIONS.texture_hero then
		table.insert(
			problems,
			string.format(
				"%s: resolution %d is above %d (4096 is the engine ceiling, never a library default)",
				where,
				resolution,
				Budgets.CONVENTIONS.texture_hero
			)
		)
	elseif resolution > Budgets.CONVENTIONS.texture_default then
		if type(material.justify) ~= "string" or #material.justify < 8 then
			table.insert(problems, where .. ": resolution above 1024 needs a justify sentence")
		end
	elseif resolution < 64 then
		table.insert(problems, where .. ": resolution below 64 (convention)")
	end
	if material.justify ~= nil and type(material.justify) ~= "string" then
		table.insert(problems, where .. ": justify must be a string")
	end
	if type(material.override_base) ~= "boolean" then
		table.insert(problems, where .. ": override_base must be a boolean")
	end
	local provenance = material.provenance
	if
		provenance ~= "local"
		and not (
			type(provenance) == "string"
			and string.match(provenance, "^[%w][%w_./%-]*$")
			and #provenance <= 200
		)
	then
		table.insert(problems, where .. ": provenance must be local or an asset-sources key")
	end
	local roblox = material.roblox
	if type(roblox) ~= "table" then
		table.insert(problems, where .. ": roblox must be a table of uploaded ids (0 until uploaded)")
	else
		for _, key in sortedKeys(roblox) do
			local id = roblox[key]
			if not table.find(Materials.ROBLOX_KEYS, key) then
				table.insert(problems, where .. ": roblox." .. key .. " is not an uploadable slot")
			elseif not (finite(id) and id % 1 == 0 and id >= 0) then
				table.insert(problems, where .. ": roblox." .. key .. " must be an integer id >= 0")
			elseif id > 0 and maps[key] == nil then
				table.insert(
					problems,
					where .. ": roblox." .. key .. " is set but maps." .. key .. " is null"
				)
			end
		end
	end
end

-- Problems with a library (empty when valid). Raises nothing.
function Materials.validate(library: any): { string }
	if type(library) ~= "table" then
		return { "library must be a table" }
	end
	local problems = {}
	if library.schema ~= Materials.SCHEMA then
		table.insert(problems, "schema must be " .. Materials.SCHEMA)
	end
	for _, key in sortedKeys(library) do
		if key ~= "schema" and key ~= "materials" then
			table.insert(problems, key .. " is not a library key")
		end
	end
	if type(library.materials) ~= "table" then
		table.insert(problems, "materials must be a list")
		return problems
	end
	local names = {}
	local overrides: { [string]: string } = {}
	for index, material in library.materials do
		validateMaterial(index, material, problems, names)
		if
			type(material) == "table"
			and material.override_base == true
			and type(material.base_material) == "string"
		then
			local previous = overrides[material.base_material]
			if previous then
				table.insert(
					problems,
					string.format(
						"%s and %s both override %s (one override per base material: terrain materials are global per place)",
						previous,
						tostring(material.name),
						material.base_material
					)
				)
			else
				overrides[material.base_material] = tostring(material.name)
			end
		end
	end
	return problems
end

local function deepFreeze(value: any): any
	if type(value) == "table" and not table.isfrozen(value) then
		for _, child in value do
			deepFreeze(child)
		end
		table.freeze(value)
	end
	return value
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = deepCopy(child)
	end
	return out
end

-- A validated, deep-frozen copy. Raises with every problem joined.
function Materials.define(library: any): any
	local problems = Materials.validate(library)
	if #problems > 0 then
		error("Materials.define: " .. table.concat(problems, "; "), 2)
	end
	return deepFreeze(deepCopy(library))
end

function Materials.find(library: any, name: string): any?
	for _, material in library.materials do
		if material.name == name then
			return material
		end
	end
	return nil
end

-- Resolves a kit/1 material reference: library:<name>, builtin:<Enum.Material>, atlas:<file>
-- or vertex_color. Returns (resolved, problem).
function Materials.resolve(ref: string, library: any?): (any?, string?)
	if type(ref) ~= "string" then
		return nil, "reference must be a string"
	end
	local kind, rest = string.match(ref, "^(%a+):(.+)$")
	if ref == "vertex_color" then
		return { kind = "vertex_color" }, nil
	elseif kind == "library" then
		if library == nil then
			return nil, "library:" .. rest .. " needs a material library"
		end
		local material = Materials.find(library, rest :: string)
		if material == nil then
			return nil, "library has no material " .. tostring(rest)
		end
		return { kind = "library", material = material }, nil
	elseif kind == "builtin" then
		if not table.find(Materials.ENUM, rest) or rest == "Air" then
			return nil, tostring(rest) .. " is not a part material"
		end
		return { kind = "builtin", material = rest }, nil
	elseif kind == "atlas" then
		if string.find(rest :: string, "..", 1, true) or string.find(rest :: string, "/", 1, true) then
			return nil, "atlas file must be a plain file name next to the kit"
		end
		return { kind = "atlas", file = rest }, nil
	end
	return nil, "unknown material reference " .. ref
end

-- Tier 0: { { base_material, name } } for every override_base entry, sorted by base material.
function Materials.overridePlan(library: any): { { base_material: string, name: string } }
	local plan = {}
	for _, material in library.materials do
		if material.override_base == true then
			table.insert(plan, { base_material = material.base_material, name = material.name })
		end
	end
	table.sort(plan, function(a, b)
		return a.base_material < b.base_material
	end)
	return plan
end

-- Map slots still waiting for an uploaded id: { { slot, property, reference } }.
function Materials.pendingMaps(material: any): { { slot: string, property: string, reference: string } }
	local pending = {}
	for _, slot in Materials.MAP_KEYS do
		local ref = material.maps[slot]
		local id = material.roblox and material.roblox[slot]
		if ref ~= nil and not (type(id) == "number" and id > 0) then
			table.insert(pending, { slot = slot, property = Materials.MAP_PROPERTY[slot], reference = ref })
		end
	end
	return pending
end

-- A MaterialVariant with the scriptable properties set (Name, BaseMaterial, StudsPerTile,
-- MaterialPattern) and any uploaded map ids; env is the @lune/roblox library or a GameKit env with
-- .roblox. Returns (variant, pending map slots). Setting BaseMaterial and maps needs plugin
-- security in Studio (execute_luau has it); a runtime script gets an error there.
function Materials.buildVariant(material: any, env: any): (any, { any })
	local lib = if env.roblox then env.roblox else env
	local variant = lib.Instance.new("MaterialVariant")
	variant.Name = material.name
	variant.BaseMaterial = (lib.Enum.Material :: any)[material.base_material]
	variant.StudsPerTile = material.studs_per_tile
	variant.MaterialPattern = (lib.Enum.MaterialPattern :: any)[material.pattern]
	for _, slot in Materials.ROBLOX_KEYS do
		local id = material.roblox and material.roblox[slot]
		if type(id) == "number" and id > 0 then
			variant[Materials.MAP_PROPERTY[slot]] = "rbxassetid://" .. string.format("%d", id)
		end
	end
	variant:SetAttribute("SceneKitMaterial", material.name)
	return variant, Materials.pendingMaps(material)
end

export type OverrideReport = { set: { string }, missing: { string }, failed: { string } }

-- Tier 0 apply (T3): for each plan entry whose MaterialVariant exists under materialService with
-- the same base material, MaterialService:SetBaseMaterialOverride(base, name). Entries without a
-- variant are listed as missing; errors from the engine as failed. Nothing is created here.
function Materials.applyOverrides(materialService: any, plan: { any }, env: any): OverrideReport
	local lib = if env.roblox then env.roblox else env
	local report: OverrideReport = { set = {}, missing = {}, failed = {} }
	for _, entry in plan do
		local variant = materialService:FindFirstChild(entry.name)
		local base = (lib.Enum.Material :: any)[entry.base_material]
		if variant == nil or variant.ClassName ~= "MaterialVariant" or variant.BaseMaterial ~= base then
			table.insert(report.missing, entry.base_material .. " -> " .. entry.name)
		else
			local ok, err = pcall(function()
				materialService:SetBaseMaterialOverride(base, entry.name)
			end)
			if ok then
				table.insert(report.set, entry.base_material .. " -> " .. entry.name)
			else
				table.insert(report.failed, entry.base_material .. ": " .. tostring(err))
			end
		end
	end
	return report
end

return Materials
