--!strict
-- CaptureSet: named, repeatable capture plans from SceneKit Camera framing. A plan names every shot
-- `<scene>.<profile>.<angle>` and records the scene hash it was framed for, so a later run can tell
-- whether a saved capture still shows the current scene (tools/capture_staleness.py compares the
-- hash with tests/golden/fixture-hashes.json or tests/golden/studio-smoke.json).
--   local plan = CaptureSet.plan({ scene = "dungeon", source = "fixture", sceneHash = "06ace82c",
--       bounds = { min = {...}, max = {...} }, profiles = { "inspection-flat" } })
--   CaptureSet.apply(workspace.CurrentCamera, plan.shots[1], { Vector3 = Vector3, CFrame = CFrame })
-- Written next to the images as manifest.json (schema capture-manifest/1):
--   { schema, scene = { name, hash, source }, commit?, studio_version?, shots = { { id, angle,
--     profile, file, eye, focus, fov } } }
-- Pure Luau: no Roblox globals (apply takes the datatypes), no clock, deterministic order.
local Camera = require("../SceneKit/Camera")

local CaptureSet = {}

CaptureSet.SCHEMA = "capture-manifest/1"
CaptureSet.SOURCES = table.freeze({ "fixture", "studio-smoke" })
CaptureSet.MAX_SHOTS = 64
local LABEL = "^[a-z0-9][a-z0-9_%-]*$"
local HASH = "^%x+$"

export type V3 = { x: number, y: number, z: number }
export type Shot = {
	id: string,
	angle: string,
	profile: string,
	file: string,
	eye: V3,
	focus: V3,
	fov: number,
}
export type Plan = {
	schema: string,
	scene: { name: string, hash: string, source: string },
	commit: string?,
	studio_version: string?,
	shots: { Shot },
}
export type Input = {
	scene: string,
	source: string, -- "fixture" (fixture-hashes.json key) or "studio-smoke" (studio-smoke.json key)
	sceneHash: string,
	bounds: { min: V3, max: V3 },
	angles: { string }?, -- default: every Camera.ANGLES name, sorted
	profiles: { string }?, -- lighting profile names (default { "inspection-flat" })
	fov: number?,
	margin: number?,
	commit: string?,
	studioVersion: string?,
}

local function label(value: any): boolean
	return type(value) == "string" and #value <= 48 and string.match(value, LABEL) ~= nil
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function vector(value: any): boolean
	return type(value) == "table" and finite(value.x) and finite(value.y) and finite(value.z)
end

local function round(value: number): number
	-- Six decimals keep manifests stable across runtimes without losing a visible amount.
	return math.floor(value * 1e6 + 0.5) / 1e6
end

local function roundV(v: V3): V3
	return { x = round(v.x), y = round(v.y), z = round(v.z) }
end

function CaptureSet.angles(): { string }
	local names: { string } = {}
	for name in Camera.ANGLES do
		table.insert(names, tostring(name))
	end
	table.sort(names)
	return names
end

function CaptureSet.shotId(scene: string, profile: string, angle: string): string
	return scene .. "." .. profile .. "." .. angle
end

-- Builds a plan; raises with every problem in the input.
function CaptureSet.plan(input: Input): Plan
	local problems = {}
	if type(input) ~= "table" then
		error("CaptureSet.plan: input must be a table", 2)
	end
	if not label(input.scene) then
		table.insert(problems, "scene must be a lower-case label")
	end
	if not table.find(CaptureSet.SOURCES, input.source) then
		table.insert(problems, "source must be fixture or studio-smoke")
	end
	if
		type(input.sceneHash) ~= "string"
		or #input.sceneHash > 64
		or not string.match(input.sceneHash, HASH)
	then
		table.insert(problems, "sceneHash must be a hex digest")
	end
	local bounds = input.bounds
	if type(bounds) ~= "table" or not vector(bounds.min) or not vector(bounds.max) then
		table.insert(problems, "bounds needs min and max {x, y, z}")
	elseif bounds.min.x > bounds.max.x or bounds.min.y > bounds.max.y or bounds.min.z > bounds.max.z then
		table.insert(problems, "bounds min must not exceed max")
	end
	local angles: { string } = input.angles or CaptureSet.angles()
	for _, angle in angles do
		if Camera.ANGLES[angle] == nil then
			table.insert(problems, "unknown angle " .. tostring(angle))
		end
	end
	local profiles: { string } = input.profiles or { "inspection-flat" }
	for _, profile in profiles do
		if not label(profile) then
			table.insert(problems, "profile " .. tostring(profile) .. " must be a lower-case label")
		end
	end
	if #angles == 0 or #profiles == 0 then
		table.insert(problems, "a plan needs at least one angle and one profile")
	end
	if #angles * #profiles > CaptureSet.MAX_SHOTS then
		table.insert(problems, "more than " .. CaptureSet.MAX_SHOTS .. " shots")
	end
	if input.fov ~= nil and (not finite(input.fov) or input.fov <= 1 or input.fov >= 120) then
		table.insert(problems, "fov must be between 1 and 120 degrees")
	end
	if #problems > 0 then
		error("CaptureSet.plan: " .. table.concat(problems, "; "), 2)
	end
	local seen: { [string]: boolean } = {}
	local shots: { Shot } = {}
	for _, profile in profiles do
		for _, angle in angles do
			local id = CaptureSet.shotId(input.scene, profile, angle)
			if seen[id] then
				error("CaptureSet.plan: duplicate shot " .. id, 2)
			end
			seen[id] = true
			local view = Camera.frame(bounds.min, bounds.max, angle, input.fov, input.margin)
			table.insert(shots, {
				id = id,
				angle = angle,
				profile = profile,
				file = id .. ".png",
				eye = roundV(view.eye),
				focus = roundV(view.focus),
				fov = round(view.fov),
			})
		end
	end
	table.sort(shots, function(a: Shot, b: Shot): boolean
		return a.id < b.id
	end)
	return {
		schema = CaptureSet.SCHEMA,
		scene = { name = input.scene, hash = input.sceneHash, source = input.source },
		commit = input.commit,
		studio_version = input.studioVersion,
		shots = shots,
	}
end

-- Problems with a manifest read back from disk (empty when valid).
function CaptureSet.validate(manifest: any): { string }
	local problems = {}
	if type(manifest) ~= "table" then
		return { "manifest must be a table" }
	end
	if manifest.schema ~= CaptureSet.SCHEMA then
		table.insert(problems, "schema must be " .. CaptureSet.SCHEMA)
	end
	local scene = manifest.scene
	if type(scene) ~= "table" or not label(scene.name) then
		table.insert(problems, "scene.name must be a label")
	elseif type(scene.hash) ~= "string" or not string.match(scene.hash, HASH) then
		table.insert(problems, "scene.hash must be a hex digest")
	elseif not table.find(CaptureSet.SOURCES, scene.source) then
		table.insert(problems, "scene.source must be fixture or studio-smoke")
	end
	if type(manifest.shots) ~= "table" or #manifest.shots == 0 then
		table.insert(problems, "shots must be a non-empty list")
		return problems
	end
	local seen: { [string]: boolean } = {}
	for index, shot in manifest.shots do
		local where = "shots[" .. index .. "]"
		if type(shot) ~= "table" or type(shot.id) ~= "string" then
			table.insert(problems, where .. " needs an id")
			continue
		end
		if seen[shot.id] then
			table.insert(problems, where .. " duplicates " .. shot.id)
		end
		seen[shot.id] = true
		if
			type(scene) == "table"
			and shot.id ~= CaptureSet.shotId(scene.name, tostring(shot.profile), tostring(shot.angle))
		then
			table.insert(problems, where .. " id must be <scene>.<profile>.<angle>")
		end
		if Camera.ANGLES[shot.angle] == nil then
			table.insert(problems, where .. " unknown angle")
		end
		if not vector(shot.eye) or not vector(shot.focus) or not finite(shot.fov) then
			table.insert(problems, where .. " needs eye, focus and fov")
		end
		if
			type(shot.file) ~= "string"
			or string.find(shot.file, "[/\\]")
			or not string.match(shot.file, "%.png$")
		then
			table.insert(problems, where .. " file must be a plain .png name")
		end
	end
	return problems
end

-- Points a Roblox camera at a shot. `roblox` carries the datatypes ({ Vector3, CFrame }).
function CaptureSet.apply(camera: any, shot: Shot, roblox: { Vector3: any, CFrame: any })
	local function v3(v: V3): any
		return roblox.Vector3.new(v.x, v.y, v.z)
	end
	camera.FieldOfView = shot.fov
	camera.CFrame = roblox.CFrame.lookAt(v3(shot.eye), v3(shot.focus))
end

return CaptureSet
