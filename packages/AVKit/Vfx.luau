--!strict
-- @tier T1
-- Vfx: the vfx/1 effect format (docs/runtime-kits.md section 9.8; design in
-- docs/research/visual-audio-assets-2026-10.md 3f and 6.3). A preset is plain data: native
-- ParticleEmitter, Beam, Trail and light properties as numbers and sequences, in burst or loop
-- mode, with palette colour roles instead of colours and texture roles instead of asset ids.
--   validate(preset, options?) -> (problems, warnings)  engine limits are problems (rate > 400/s,
--       lifetime > 20 s, flipbook > 30 fps, light range > 120), budgets are warnings (rate > 100/s
--       mobile, peak particles, overdraw, shadow-casting lights)
--   budget(preset, options?)    peak live particles, overdraw score, emission rate, instances
--   plan(preset, options?)      what an activation does after reduced effects, reduced motion
--       and reduce-flashing are applied: emit / enable / light actions (pure, T0)
--   build(preset, env, options?) the template Model (T1: runs on @lune/roblox); the Studio pool is
--       AVKit/VfxPoolRoblox (T3)
--   palette(colorblindMode?)    default role colours, with colour-vision variants (convention)
-- An optional `highlight` (one Highlight, outline/fill roles) is counted against the Highlight
-- budget: 255 simultaneous per client (docs), at most 8 active by convention.
-- Accessibility flags: `motion = true` presets are skipped under reduced motion; emitters and
-- lights with `flash = true` are dropped when flashes are not allowed (settings/1 reduceFlashing).
-- Built-in textures: only sparkles_main.dds and SquareParticle.png are known to ship; a game maps
-- texture roles (soft, smoke, ring, ...) to its approved assets through build options.textures.
local Vfx = {}

Vfx.SCHEMA = "vfx/1"
Vfx.BUILTIN = table.freeze({
	sparkles = "rbxasset://textures/particles/sparkles_main.dds",
	square = "rbxasset://textures/particles/SquareParticle.png",
	none = "",
})
Vfx.ROLES = table.freeze({ "accent", "positive", "negative", "neutral", "bright", "special", "surface" })
-- Preview colours per role; games pass their own palette. Colour-vision variants move the
-- positive/negative pair off red-green (protanopia, deuteranopia) and special off blue-yellow
-- (tritanopia). Convention, not a Roblox rule ("do not rely on colour alone", docs accessibility).
local PALETTES = {
	none = {
		accent = { 255, 196, 64 },
		positive = { 90, 220, 120 },
		negative = { 235, 85, 70 },
		neutral = { 196, 192, 186 },
		bright = { 255, 250, 235 },
		special = { 120, 170, 255 },
		surface = { 170, 200, 220 },
	},
}
PALETTES.protanopia = table.clone(PALETTES.none)
PALETTES.protanopia.positive = { 80, 170, 255 }
PALETTES.protanopia.negative = { 255, 150, 40 }
PALETTES.deuteranopia = table.clone(PALETTES.protanopia)
PALETTES.tritanopia = table.clone(PALETTES.none)
PALETTES.tritanopia.special = { 230, 100, 200 }
PALETTES.tritanopia.accent = { 255, 120, 90 }

local LIMITS = {
	rateMax = 400, -- per emitter, docs effects/particle-emitters
	rateMobile = 100, -- same page: "100 per second on mobile"
	lifetimeMax = 20, -- same page
	flipbookFpsMax = 30, -- same page
	lightRangeMax = 120, -- DevForum 2025-09-23
	lightRangeBudget = 60, -- convention
	burstMax = 100, -- convention
	peakParticles = 200, -- convention per preset
	overdraw = 400, -- convention per preset
	sequenceKeys = 20, -- NumberSequence/ColorSequence keypoint limit
}
Vfx.LIMITS = table.freeze(LIMITS)

local ORIENTATIONS = { "FacingCamera", "FacingCameraWorldUp", "VelocityParallel", "VelocityPerpendicular" }
local SHAPES = { "Box", "Sphere", "Cylinder", "Disc" }
local SHAPE_STYLES = { "Volume", "Surface" }
local SHAPE_IN_OUT = { "Outward", "Inward", "InAndOut" }
local DIRECTIONS = { "Top", "Bottom", "Front", "Back", "Left", "Right" }
local TEXTURE_MODES = { "Wrap", "Stretch", "Static" }
local LAYOUTS = { Grid2x2 = 2, Grid4x4 = 4, Grid8x8 = 8 }
local FLIPBOOK_MODES = { "Loop", "OneShot", "PingPong", "Random" }
local LIGHT_CLASSES = { "PointLight", "SpotLight", "SurfaceLight" }
local DROPPABLE = { "emitters", "beams", "trails", "lights", "highlight" }
local DEPTH_MODES = { "AlwaysOnTop", "Occluded" }

local TOP_KEYS = {
	id = true,
	intent = true,
	tags = true,
	mode = true,
	duration = true,
	priority = true,
	sound = true,
	motion = true,
	emitters = true,
	beams = true,
	trails = true,
	lights = true,
	highlight = true,
	reduced = true,
}
local EMITTER_KEYS = {
	name = true,
	texture = true,
	textureRole = true,
	color = true,
	burst = true,
	rate = true,
	delay = true,
	lifetime = true,
	speed = true,
	spread = true,
	size = true,
	transparency = true,
	squash = true,
	lightEmission = true,
	lightInfluence = true,
	brightness = true,
	orientation = true,
	drag = true,
	acceleration = true,
	rotation = true,
	rotSpeed = true,
	zOffset = true,
	shape = true,
	shapeStyle = true,
	shapeInOut = true,
	area = true,
	emissionDirection = true,
	lockedToPart = true,
	velocityInheritance = true,
	timeScale = true,
	windAffectsDrag = true,
	flipbook = true,
	offset = true,
	flash = true,
}
local BEAM_KEYS = {
	name = true,
	from = true,
	to = true,
	width = true,
	segments = true,
	curve = true,
	texture = true,
	textureRole = true,
	textureMode = true,
	textureLength = true,
	textureSpeed = true,
	color = true,
	transparency = true,
	lightEmission = true,
	lightInfluence = true,
	brightness = true,
	faceCamera = true,
	zOffset = true,
	flash = true,
}
local TRAIL_KEYS = {
	name = true,
	from = true,
	to = true,
	lifetime = true,
	minLength = true,
	maxLength = true,
	widthScale = true,
	texture = true,
	textureRole = true,
	textureMode = true,
	textureLength = true,
	color = true,
	transparency = true,
	lightEmission = true,
	lightInfluence = true,
	brightness = true,
	faceCamera = true,
	flash = true,
}
local HIGHLIGHT_KEYS = {
	fill = true,
	outline = true,
	fillTransparency = true,
	outlineTransparency = true,
	depthMode = true,
	flash = true,
}
local LIGHT_KEYS = {
	name = true,
	class = true,
	offset = true,
	range = true,
	brightness = true,
	color = true,
	shadows = true,
	angle = true,
	face = true,
	hold = true,
	fade = true,
	flash = true,
}

-- ---------------------------------------------------------------- helpers

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

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = copy(child)
	end
	return out
end

type Report = { problems: { string }, warnings: { string } }

local function problem(report: Report, text: string)
	table.insert(report.problems, text)
end

local function warn(report: Report, text: string)
	table.insert(report.warnings, text)
end

local function number(report: Report, where: string, value: any, min: number, max: number, required: boolean?)
	if value == nil then
		if required then
			problem(report, where .. " is required")
		end
		return
	end
	if not finite(value) then
		problem(report, where .. " must be a finite number")
	elseif value < min or value > max then
		problem(
			report,
			string.format("%s %s outside %s..%s", where, tostring(value), tostring(min), tostring(max))
		)
	end
end

local function range(report: Report, where: string, value: any, min: number, max: number, required: boolean?)
	if value == nil then
		if required then
			problem(report, where .. " is required")
		end
		return
	end
	if type(value) ~= "table" or #value ~= 2 or not finite(value[1]) or not finite(value[2]) then
		problem(report, where .. " must be { min, max }")
	elseif value[1] > value[2] then
		problem(report, where .. " min is above max")
	elseif value[1] < min or value[2] > max then
		problem(report, string.format("%s outside %s..%s", where, tostring(min), tostring(max)))
	end
end

-- Two independent values (Beam Width0/Width1, CurveSize0/CurveSize1), each within min..max.
local function pair(report: Report, where: string, value: any, min: number, max: number, required: boolean?)
	if value == nil then
		if required then
			problem(report, where .. " is required")
		end
		return
	end
	if type(value) ~= "table" or #value ~= 2 or not finite(value[1]) or not finite(value[2]) then
		problem(report, where .. " must be { start, end }")
	elseif value[1] < min or value[1] > max or value[2] < min or value[2] > max then
		problem(report, string.format("%s values must be within %s..%s", where, tostring(min), tostring(max)))
	end
end

local function vector(report: Report, where: string, value: any, limit: number)
	if value == nil then
		return
	end
	if type(value) ~= "table" then
		problem(report, where .. " must be { x, y, z }")
		return
	end
	for _, key in sortedKeys(value) do
		if key ~= "x" and key ~= "y" and key ~= "z" then
			problem(report, where .. "." .. key .. " is not x, y or z")
		elseif not finite(value[key]) or math.abs(value[key]) > limit then
			problem(report, string.format("%s.%s must be finite within +-%s", where, key, tostring(limit)))
		end
	end
end

local function choice(report: Report, where: string, value: any, choices: { string })
	if value ~= nil and not table.find(choices, value) then
		problem(report, where .. " must be one of " .. table.concat(choices, ", "))
	end
end

local function boolean(report: Report, where: string, value: any)
	if value ~= nil and type(value) ~= "boolean" then
		problem(report, where .. " must be a boolean")
	end
end

-- A number or { { t, v, envelope? }, ... } with t from 0 to 1 ascending (NumberSequence rules).
local function sequence(report: Report, where: string, value: any, min: number, max: number)
	if value == nil then
		return
	end
	if finite(value) then
		number(report, where, value, min, max)
		return
	end
	if type(value) ~= "table" or #value < 2 or #value > LIMITS.sequenceKeys then
		problem(report, where .. " must be a number or 2-20 keypoints { t, value }")
		return
	end
	local last = -1
	for index, key in value do
		if type(key) ~= "table" or not finite(key[1]) or not finite(key[2]) then
			problem(report, where .. " keypoint " .. index .. " must be { t, value }")
			return
		end
		if key[1] <= last then
			problem(report, where .. " keypoint times must increase")
			return
		end
		last = key[1]
		if key[2] < min or key[2] > max then
			problem(
				report,
				string.format(
					"%s keypoint %d value outside %s..%s",
					where,
					index,
					tostring(min),
					tostring(max)
				)
			)
		end
		if key[3] ~= nil and (not finite(key[3]) or key[3] < 0) then
			problem(report, where .. " keypoint " .. index .. " envelope must be >= 0")
		end
	end
	if value[1][1] ~= 0 or value[#value][1] ~= 1 then
		problem(report, where .. " must start at t = 0 and end at t = 1")
	end
end

-- A role name, or { { t, role }, ... } from t = 0 to t = 1.
local function colorRoles(report: Report, where: string, value: any)
	if value == nil then
		return
	end
	if type(value) == "string" then
		if not label(value) then
			problem(report, where .. " role must be a label")
		end
		return
	end
	if type(value) ~= "table" or #value < 2 or #value > LIMITS.sequenceKeys then
		problem(report, where .. " must be a role or 2-20 keypoints { t, role }")
		return
	end
	local last = -1
	for index, key in value do
		if type(key) ~= "table" or not finite(key[1]) or not label(key[2]) then
			problem(report, where .. " keypoint " .. index .. " must be { t, role }")
			return
		end
		if key[1] <= last then
			problem(report, where .. " keypoint times must increase")
			return
		end
		last = key[1]
	end
	if value[1][1] ~= 0 or value[#value][1] ~= 1 then
		problem(report, where .. " must start at t = 0 and end at t = 1")
	end
end

local function texture(report: Report, where: string, value: any)
	if value == nil then
		return
	end
	if type(value) ~= "string" then
		problem(report, where .. " must be builtin:<name> or asset:<key>")
		return
	end
	local builtin = string.match(value, "^builtin:(%a+)$")
	local asset = string.match(value, "^asset:([%w_%-%./]+)$")
	if builtin then
		if Vfx.BUILTIN[builtin] == nil then
			problem(report, where .. " builtin " .. builtin .. " is not a known built-in texture")
		end
	elseif asset == nil then
		problem(report, where .. " must be builtin:<name> or asset:<key> (no raw asset ids)")
	end
end

local function sequenceMax(value: any, default: number): number
	if value == nil then
		return default
	end
	if finite(value) then
		return value
	end
	local best = -math.huge
	for _, key in value do
		best = math.max(best, key[2] + (key[3] or 0))
	end
	return best
end

local function checkKeys(report: Report, where: string, item: any, keys: { [string]: boolean })
	for _, key in sortedKeys(item) do
		if not keys[key] then
			problem(report, where .. ": " .. key .. " is not a field")
		end
	end
end

local function validateEmitter(report: Report, preset: any, emitter: any, where: string, options: any)
	checkKeys(report, where, emitter, EMITTER_KEYS)
	texture(report, where .. ".texture", emitter.texture)
	if emitter.textureRole ~= nil and not label(emitter.textureRole) then
		problem(report, where .. ".textureRole must be a label")
	end
	colorRoles(report, where .. ".color", emitter.color)
	local burst = emitter.burst or 0
	if not (finite(burst) and burst >= 0 and burst % 1 == 0) then
		problem(report, where .. ".burst must be a whole number >= 0")
	elseif burst > LIMITS.burstMax then
		problem(report, string.format("%s.burst %d above %d (convention)", where, burst, LIMITS.burstMax))
	end
	local rate = emitter.rate or 0
	if not (finite(rate) and rate >= 0) then
		problem(report, where .. ".rate must be a finite number >= 0")
	elseif rate > LIMITS.rateMax then
		problem(
			report,
			string.format("%s.rate %s above the engine's %d/s", where, tostring(rate), LIMITS.rateMax)
		)
	elseif rate > LIMITS.rateMobile then
		warn(
			report,
			string.format("%s.rate %s above the mobile %d/s", where, tostring(rate), LIMITS.rateMobile)
		)
	end
	if finite(burst) and finite(rate) and burst == 0 and rate == 0 then
		problem(report, where .. " emits nothing (burst and rate are 0)")
	end
	if preset.mode == "burst" and finite(rate) and rate > 0 then
		problem(report, where .. ".rate must be 0 in burst mode (bursts use burst)")
	end
	number(
		report,
		where .. ".delay",
		emitter.delay,
		0,
		if finite(preset.duration) then preset.duration else 600
	)
	range(report, where .. ".lifetime", emitter.lifetime, 0, LIMITS.lifetimeMax, true)
	if type(emitter.lifetime) == "table" and finite(emitter.lifetime[2]) and emitter.lifetime[2] <= 0 then
		problem(report, where .. ".lifetime of 0 emits nothing")
	end
	range(report, where .. ".speed", emitter.speed, 0, 500)
	-- SpreadAngle is a Vector2 of two independent cone angles (x, y), not a min/max range.
	if emitter.spread ~= nil then
		local spread = emitter.spread
		if type(spread) ~= "table" or #spread ~= 2 or not finite(spread[1]) or not finite(spread[2]) then
			problem(report, where .. ".spread must be { x angle, y angle }")
		elseif spread[1] < 0 or spread[1] > 180 or spread[2] < 0 or spread[2] > 180 then
			problem(report, where .. ".spread angles must be within 0..180")
		end
	end
	sequence(report, where .. ".size", emitter.size, 0, 100)
	sequence(report, where .. ".transparency", emitter.transparency, 0, 1)
	sequence(report, where .. ".squash", emitter.squash, -3, 3)
	number(report, where .. ".lightEmission", emitter.lightEmission, 0, 1)
	number(report, where .. ".lightInfluence", emitter.lightInfluence, 0, 1)
	number(report, where .. ".brightness", emitter.brightness, 0, 10)
	choice(report, where .. ".orientation", emitter.orientation, ORIENTATIONS)
	number(report, where .. ".drag", emitter.drag, 0, 50)
	vector(report, where .. ".acceleration", emitter.acceleration, 200)
	range(report, where .. ".rotation", emitter.rotation, -360, 360)
	range(report, where .. ".rotSpeed", emitter.rotSpeed, -1440, 1440)
	number(report, where .. ".zOffset", emitter.zOffset, -10, 10)
	choice(report, where .. ".shape", emitter.shape, SHAPES)
	choice(report, where .. ".shapeStyle", emitter.shapeStyle, SHAPE_STYLES)
	choice(report, where .. ".shapeInOut", emitter.shapeInOut, SHAPE_IN_OUT)
	choice(report, where .. ".emissionDirection", emitter.emissionDirection, DIRECTIONS)
	vector(report, where .. ".area", emitter.area, 64)
	if emitter.shape ~= nil and emitter.area == nil then
		problem(report, where .. ".shape needs area { x, y, z } (shapes emit from a part, not an Attachment)")
	end
	boolean(report, where .. ".lockedToPart", emitter.lockedToPart)
	number(report, where .. ".velocityInheritance", emitter.velocityInheritance, 0, 1)
	number(report, where .. ".timeScale", emitter.timeScale, 0, 1)
	boolean(report, where .. ".windAffectsDrag", emitter.windAffectsDrag)
	boolean(report, where .. ".flash", emitter.flash)
	vector(report, where .. ".offset", emitter.offset, 64)
	local flipbook = emitter.flipbook
	if flipbook ~= nil then
		if type(flipbook) ~= "table" then
			problem(report, where .. ".flipbook must be a table")
		else
			if LAYOUTS[flipbook.layout] == nil then
				problem(report, where .. ".flipbook.layout must be Grid2x2, Grid4x4 or Grid8x8")
			end
			choice(report, where .. ".flipbook.mode", flipbook.mode, FLIPBOOK_MODES)
			number(report, where .. ".flipbook.fps", flipbook.fps, 1, LIMITS.flipbookFpsMax, true)
			boolean(report, where .. ".flipbook.startRandom", flipbook.startRandom)
			local key = if type(emitter.texture) == "string"
				then string.match(emitter.texture, "^asset:(.+)$")
				else nil
			local size = key and options.textureSizes and options.textureSizes[key]
			if not key then
				problem(
					report,
					where .. ".flipbook needs an asset texture (built-in textures are not flipbooks)"
				)
			elseif size == nil then
				problem(
					report,
					where .. ".flipbook texture " .. key .. " has no known size (options.textureSizes)"
				)
			elseif LAYOUTS[flipbook.layout] and size % LAYOUTS[flipbook.layout] ~= 0 then
				problem(
					report,
					string.format(
						"%s.flipbook texture size %d is not a multiple of %s",
						where,
						size,
						tostring(flipbook.layout)
					)
				)
			end
		end
	end
end

local function attachmentPair(report: Report, where: string, item: any)
	vector(report, where .. ".from", item.from, 64)
	vector(report, where .. ".to", item.to, 64)
	if type(item.from) ~= "table" or type(item.to) ~= "table" then
		problem(report, where .. " needs from and to attachment offsets")
		return
	end
	local dx = (item.from.x or 0) - (item.to.x or 0)
	local dy = (item.from.y or 0) - (item.to.y or 0)
	local dz = (item.from.z or 0) - (item.to.z or 0)
	if dx * dx + dy * dy + dz * dz < 1e-6 then
		problem(report, where .. " from and to must differ (two attachments)")
	end
end

local function validateList(report: Report, preset: any, key: string, check: (any, string) -> ())
	local list = preset[key]
	if list == nil then
		return
	end
	if type(list) ~= "table" then
		problem(report, key .. " must be a list")
		return
	end
	for index, item in list do
		local where = key .. "[" .. index .. "]"
		if type(item) ~= "table" then
			problem(report, where .. " must be a table")
		else
			if label(item.name) then
				where = key .. "." .. item.name
			else
				problem(report, where .. ".name must be a label")
			end
			check(item, where)
		end
	end
end

-- (problems, warnings) for one preset. options.textureSizes maps asset keys to pixel sizes for
-- flipbook checks.
function Vfx.validate(
	preset: any,
	options: { textureSizes: { [string]: number }? }?
): ({ string }, { string })
	local report: Report = { problems = {}, warnings = {} }
	local opts = options or {}
	if type(preset) ~= "table" then
		return { "preset must be a table" }, {}
	end
	for _, key in sortedKeys(preset) do
		if not TOP_KEYS[key] then
			problem(report, key .. " is not a preset key")
		end
	end
	if preset.id ~= nil and not label(preset.id) then
		problem(report, "id must be a label")
	end
	if preset.intent ~= nil and (type(preset.intent) ~= "string" or #preset.intent == 0) then
		problem(report, "intent must be a non-empty string")
	end
	if preset.mode ~= "burst" and preset.mode ~= "loop" then
		problem(report, "mode must be burst or loop")
	end
	if preset.mode == "burst" then
		number(report, "duration", preset.duration, 0.05, 10, true)
	else
		number(report, "duration", preset.duration, 0.05, 600, true)
	end
	if
		not (
			finite(preset.priority)
			and preset.priority % 1 == 0
			and preset.priority >= 0
			and preset.priority <= 10
		)
	then
		problem(report, "priority must be a whole number 0..10")
	end
	if preset.sound ~= nil and not label(preset.sound) then
		problem(report, "sound must be an AudioCues cue id")
	end
	boolean(report, "motion", preset.motion)
	local names = {}
	local count = 0
	for _, key in DROPPABLE do
		for _, item in (if type(preset[key]) == "table" then preset[key] else {}) do
			count += 1
			if type(item) == "table" and type(item.name) == "string" then
				if names[item.name] then
					problem(report, "name " .. item.name .. " is used twice (names address instances)")
				end
				names[item.name] = true
			end
		end
	end
	if count == 0 and preset.highlight == nil then
		problem(report, "preset has no emitters, beams, trails, lights or highlight")
	end
	validateList(report, preset, "emitters", function(emitter, where)
		validateEmitter(report, preset, emitter, where, opts)
	end)
	validateList(report, preset, "beams", function(beam, where)
		checkKeys(report, where, beam, BEAM_KEYS)
		attachmentPair(report, where, beam)
		pair(report, where .. ".width", beam.width, 0, 64, true)
		number(report, where .. ".segments", beam.segments, 1, 100)
		pair(report, where .. ".curve", beam.curve, -100, 100)
		texture(report, where .. ".texture", beam.texture)
		choice(report, where .. ".textureMode", beam.textureMode, TEXTURE_MODES)
		number(report, where .. ".textureLength", beam.textureLength, 0.01, 100)
		number(report, where .. ".textureSpeed", beam.textureSpeed, -50, 50)
		colorRoles(report, where .. ".color", beam.color)
		sequence(report, where .. ".transparency", beam.transparency, 0, 1)
		number(report, where .. ".lightEmission", beam.lightEmission, 0, 1)
		number(report, where .. ".lightInfluence", beam.lightInfluence, 0, 1)
		number(report, where .. ".brightness", beam.brightness, 0, 10000)
		boolean(report, where .. ".faceCamera", beam.faceCamera)
		number(report, where .. ".zOffset", beam.zOffset, -10, 10)
		boolean(report, where .. ".flash", beam.flash)
	end)
	validateList(report, preset, "trails", function(trail, where)
		checkKeys(report, where, trail, TRAIL_KEYS)
		attachmentPair(report, where, trail)
		number(report, where .. ".lifetime", trail.lifetime, 0.01, LIMITS.lifetimeMax, true)
		number(report, where .. ".minLength", trail.minLength, 0, 100)
		number(report, where .. ".maxLength", trail.maxLength, 0, 1000)
		sequence(report, where .. ".widthScale", trail.widthScale, 0, 10)
		texture(report, where .. ".texture", trail.texture)
		choice(report, where .. ".textureMode", trail.textureMode, TEXTURE_MODES)
		number(report, where .. ".textureLength", trail.textureLength, 0.01, 100)
		colorRoles(report, where .. ".color", trail.color)
		sequence(report, where .. ".transparency", trail.transparency, 0, 1)
		number(report, where .. ".lightEmission", trail.lightEmission, 0, 1)
		number(report, where .. ".lightInfluence", trail.lightInfluence, 0, 1)
		number(report, where .. ".brightness", trail.brightness, 0, 10000)
		boolean(report, where .. ".faceCamera", trail.faceCamera)
		boolean(report, where .. ".flash", trail.flash)
	end)
	validateList(report, preset, "lights", function(light, where)
		checkKeys(report, where, light, LIGHT_KEYS)
		choice(report, where .. ".class", light.class, LIGHT_CLASSES)
		if light.class == nil then
			problem(report, where .. ".class is required")
		end
		vector(report, where .. ".offset", light.offset, 64)
		if not (finite(light.range) and light.range > 0 and light.range <= LIMITS.lightRangeMax) then
			problem(
				report,
				string.format("%s.range must be > 0 and <= %d (engine cap)", where, LIMITS.lightRangeMax)
			)
		elseif light.range > LIMITS.lightRangeBudget then
			warn(
				report,
				string.format(
					"%s.range above the %d-stud budget (convention)",
					where,
					LIMITS.lightRangeBudget
				)
			)
		end
		number(report, where .. ".brightness", light.brightness, 0, 40, true)
		if light.color ~= nil and not label(light.color) then
			problem(report, where .. ".color must be one role (lights have one colour)")
		end
		boolean(report, where .. ".shadows", light.shadows)
		if light.shadows == true then
			warn(report, where .. " casts shadows (budget: at most one shadow-casting light per room)")
		end
		number(report, where .. ".angle", light.angle, 0, 180)
		choice(report, where .. ".face", light.face, DIRECTIONS)
		local limit = if finite(preset.duration) then preset.duration else 600
		number(report, where .. ".hold", light.hold, 0, limit)
		number(report, where .. ".fade", light.fade, 0.01, limit)
		if finite(light.hold) and finite(light.fade) and light.hold + light.fade > limit + 1e-9 then
			problem(report, where .. " hold + fade is longer than the duration")
		end
		if light.hold ~= nil and light.fade == nil then
			problem(report, where .. ".hold needs fade (without fade the light stays on for the duration)")
		end
		boolean(report, where .. ".flash", light.flash)
	end)
	local highlight = preset.highlight
	if highlight ~= nil then
		if type(highlight) ~= "table" then
			problem(report, "highlight must be a table")
		else
			checkKeys(report, "highlight", highlight, HIGHLIGHT_KEYS)
			for _, key in { "fill", "outline" } do
				if highlight[key] ~= nil and not label(highlight[key]) then
					problem(report, "highlight." .. key .. " must be a role")
				end
			end
			number(report, "highlight.fillTransparency", highlight.fillTransparency, 0, 1)
			number(report, "highlight.outlineTransparency", highlight.outlineTransparency, 0, 1)
			choice(report, "highlight.depthMode", highlight.depthMode, DEPTH_MODES)
			boolean(report, "highlight.flash", highlight.flash)
			warn(
				report,
				"highlight: the first active Highlight costs about 1 ms on mobile (keep <= 8 active)"
			)
		end
	end
	local reduced = preset.reduced
	if reduced ~= nil then
		if type(reduced) ~= "table" then
			problem(report, "reduced must be a table")
		else
			for _, key in sortedKeys(reduced) do
				if key ~= "drop" and key ~= "burstScale" and key ~= "rateScale" and key ~= "skip" then
					problem(report, "reduced." .. key .. " is not a field")
				end
			end
			number(report, "reduced.burstScale", reduced.burstScale, 0, 1)
			number(report, "reduced.rateScale", reduced.rateScale, 0, 1)
			boolean(report, "reduced.skip", reduced.skip)
			for _, entry in (if type(reduced.drop) == "table" then reduced.drop else {}) do
				if not (table.find(DROPPABLE, entry) or (type(entry) == "string" and names[entry])) then
					problem(
						report,
						"reduced.drop " .. tostring(entry) .. " is not a list kind or an item name"
					)
				end
			end
		end
	end
	-- A burst is reclaimed by the pool at `duration`; particles still alive then are cut off.
	if preset.mode == "burst" and finite(preset.duration) then
		for _, emitter in (if type(preset.emitters) == "table" then preset.emitters else {}) do
			local life = type(emitter) == "table"
				and type(emitter.lifetime) == "table"
				and emitter.lifetime[2]
			local delay = if type(emitter) == "table" and finite(emitter.delay) then emitter.delay else 0
			if finite(life) and delay + life > preset.duration + 1e-9 then
				problem(
					report,
					string.format(
						"emitters.%s delay + lifetime %.2f s outlives duration %.2f s (particles cut off)",
						tostring(emitter.name),
						delay + life,
						preset.duration
					)
				)
			end
		end
	end
	if #report.problems == 0 then
		local cost = Vfx.budget(preset)
		if cost.peakParticles > LIMITS.peakParticles then
			warn(
				report,
				string.format(
					"peak particles %d above %d (convention)",
					cost.peakParticles,
					LIMITS.peakParticles
				)
			)
		end
		if cost.overdraw > LIMITS.overdraw then
			warn(
				report,
				string.format("overdraw score %.0f above %d (convention)", cost.overdraw, LIMITS.overdraw)
			)
		end
	end
	return report.problems, report.warnings
end

-- ---------------------------------------------------------------- budget and plan

local function dropped(preset: any, kind: string, item: any, options: any): boolean
	if options.reduceFlashing and item.flash == true then
		return true
	end
	if options.reduced and preset.reduced and type(preset.reduced.drop) == "table" then
		return table.find(preset.reduced.drop, kind) ~= nil
			or (item.name ~= nil and table.find(preset.reduced.drop, item.name) ~= nil)
	end
	return false
end

local function scales(preset: any, options: any): (number, number)
	if options.reduced and preset.reduced then
		return preset.reduced.burstScale or 1, preset.reduced.rateScale or 1
	end
	return 1, 1
end

export type Budget = {
	peakParticles: number,
	overdraw: number,
	rate: number,
	emitters: number,
	beams: number,
	trails: number,
	lights: number,
	shadowedLights: number,
	highlights: number,
	instances: number,
}

export type PlanOptions = { reduced: boolean?, reducedMotion: boolean?, reduceFlashing: boolean? }

-- Cost estimate (after the reduced rules when options.reduced): peak live particles
-- = sum(burst + rate x lifetime.max), overdraw = sum(peak x largest size^2), instances in the template.
function Vfx.budget(preset: any, options: PlanOptions?): Budget
	local opts: any = options or {}
	local burstScale, rateScale = scales(preset, opts)
	local result: Budget = {
		peakParticles = 0,
		overdraw = 0,
		rate = 0,
		emitters = 0,
		beams = 0,
		trails = 0,
		lights = 0,
		shadowedLights = 0,
		highlights = 0,
		instances = 2, -- Model and its Origin part
	}
	if preset.highlight then
		result.instances += 1
		if not dropped(preset, "highlight", preset.highlight, opts) then
			result.highlights = 1
		end
	end
	for _, emitter in preset.emitters or {} do
		result.instances += 2 -- a shape part or an attachment, plus the emitter
		if not dropped(preset, "emitters", emitter, opts) then
			result.emitters += 1
			local burst = math.floor((emitter.burst or 0) * burstScale + 0.5)
			local rate = (emitter.rate or 0) * rateScale
			local peak = burst + rate * emitter.lifetime[2]
			local size = sequenceMax(emitter.size, 1)
			result.peakParticles += peak
			result.overdraw += peak * size * size
			result.rate += rate
		end
	end
	for _, beam in preset.beams or {} do
		result.instances += 3
		if not dropped(preset, "beams", beam, opts) then
			result.beams += 1
		end
	end
	for _, trail in preset.trails or {} do
		result.instances += 3
		if not dropped(preset, "trails", trail, opts) then
			result.trails += 1
		end
	end
	for _, light in preset.lights or {} do
		result.instances += 2
		if not dropped(preset, "lights", light, opts) then
			result.lights += 1
			if light.shadows == true then
				result.shadowedLights += 1
			end
		end
	end
	result.peakParticles = math.ceil(result.peakParticles)
	result.overdraw = math.round(result.overdraw * 100) / 100
	return result
end

export type Action = {
	kind: "emit" | "enable" | "light" | "highlight",
	target: string,
	count: number?,
	rate: number?,
	at: number?,
	brightness: number?,
	hold: number?,
	fade: number?,
}
export type Plan = { skip: string?, actions: { Action }, duration: number, loop: boolean, linger: number }

-- Longest particle or trail lifetime: how long a stopped loop must stay alive before the pool
-- reclaims it, so live particles are not cut off.
local function lingerOf(preset: any): number
	local linger = 0
	for _, emitter in preset.emitters or {} do
		if type(emitter.lifetime) == "table" and finite(emitter.lifetime[2]) then
			linger = math.max(linger, emitter.lifetime[2])
		end
	end
	for _, trail in preset.trails or {} do
		if finite(trail.lifetime) then
			linger = math.max(linger, trail.lifetime)
		end
	end
	return linger
end

-- What one activation does once the accessibility and reduced rules apply. skip is
-- "reduced_motion" for motion presets under reduced motion, or "reduced" when reduced.skip.
-- Actions: emit (burst count at a delay), enable (loop emitters at a rate, beams, trails), light
-- (brightness; with fade it holds for `hold` seconds then fades linearly over `fade`) and highlight.
function Vfx.plan(preset: any, options: PlanOptions?): Plan
	local opts: any = options or {}
	local plan: Plan = {
		actions = {},
		duration = preset.duration,
		loop = preset.mode == "loop",
		linger = lingerOf(preset),
	}
	if opts.reducedMotion and preset.motion == true then
		plan.skip = "reduced_motion"
		return plan
	end
	if opts.reduced and preset.reduced and preset.reduced.skip == true then
		plan.skip = "reduced"
		return plan
	end
	local burstScale, rateScale = scales(preset, opts)
	for _, emitter in preset.emitters or {} do
		if not dropped(preset, "emitters", emitter, opts) then
			local burst = math.floor((emitter.burst or 0) * burstScale + 0.5)
			if burst > 0 then
				table.insert(
					plan.actions,
					{ kind = "emit", target = emitter.name, count = burst, at = emitter.delay or 0 }
				)
			end
			local rate = (emitter.rate or 0) * rateScale
			if rate > 0 then
				table.insert(plan.actions, { kind = "enable", target = emitter.name, rate = rate })
			end
		end
	end
	for _, kind in { "beams", "trails" } do
		for _, item in preset[kind] or {} do
			if not dropped(preset, kind, item, opts) then
				table.insert(plan.actions, { kind = "enable", target = item.name })
			end
		end
	end
	for _, light in preset.lights or {} do
		if not dropped(preset, "lights", light, opts) then
			table.insert(plan.actions, {
				kind = "light",
				target = light.name,
				brightness = light.brightness,
				hold = if light.fade then light.hold or 0 else nil,
				fade = light.fade,
			})
		end
	end
	if preset.highlight and not dropped(preset, "highlight", preset.highlight, opts) then
		table.insert(plan.actions, { kind = "highlight", target = "Highlight" })
	end
	return plan
end

-- Light brightness at elapsed seconds for a light action: constant without fade, else full for
-- hold seconds and then a linear fade to 0 over fade seconds.
function Vfx.lightAt(action: Action, elapsed: number): number
	local brightness = action.brightness or 0
	local fade = action.fade
	if fade == nil then
		return brightness
	end
	local hold = action.hold or 0
	if elapsed <= hold then
		return brightness
	end
	return brightness * math.clamp(1 - (elapsed - hold) / fade, 0, 1)
end

-- ---------------------------------------------------------------- palette and build

function Vfx.palette(colorblindMode: string?): { [string]: { number } }
	return copy(PALETTES[colorblindMode or "none"] or PALETTES.none)
end

local function roleColor(palette: any, role: string): { number }
	return palette[role] or PALETTES.none[role] or PALETTES.none.neutral
end

local function colorSequence(lib: any, palette: any, value: any): any
	local roles = if value == nil then "bright" else value
	if type(roles) == "string" then
		local c = roleColor(palette, roles)
		return lib.ColorSequence.new(lib.Color3.fromRGB(c[1], c[2], c[3]))
	end
	local keys = {}
	for _, key in roles do
		local c = roleColor(palette, key[2])
		table.insert(keys, lib.ColorSequenceKeypoint.new(key[1], lib.Color3.fromRGB(c[1], c[2], c[3])))
	end
	return lib.ColorSequence.new(keys)
end

local function numberSequence(lib: any, value: any): any
	if finite(value) then
		return lib.NumberSequence.new(value)
	end
	local keys = {}
	for _, key in value do
		table.insert(keys, lib.NumberSequenceKeypoint.new(key[1], key[2], key[3] or 0))
	end
	return lib.NumberSequence.new(keys)
end

local function v3(lib: any, value: any): any
	value = value or {}
	return lib.Vector3.new(value.x or 0, value.y or 0, value.z or 0)
end

local function resolveTexture(item: any, options: any): string
	local role = item.textureRole
	if role and options.textures and options.textures[role] then
		return options.textures[role]
	end
	local tex = item.texture
	if type(tex) == "string" then
		local builtin = string.match(tex, "^builtin:(%a+)$")
		if builtin then
			return Vfx.BUILTIN[builtin]
		end
		local key = string.match(tex, "^asset:(.+)$")
		if key and options.textures and options.textures[key] then
			return options.textures[key]
		end
	end
	return Vfx.BUILTIN.sparkles
end

local function attachment(lib: any, parent: any, name: string, offset: any): any
	local a = lib.Instance.new("Attachment")
	a.Name = name
	a.Position = v3(lib, offset)
	a.Parent = parent
	return a
end

export type BuildOptions = {
	palette: { [string]: { number } }?,
	textures: { [string]: string }?, -- texture role or asset key -> content string (game-supplied)
}

-- The template Model for a preset: an invisible anchored Origin part (PrimaryPart) holding an
-- Attachment per emitter (or a shape part sized `area`), two per beam or trail, and one per light.
-- Everything starts disabled; AVKit/VfxPoolRoblox clones it, pivots it and runs Vfx.plan.
-- env is the @lune/roblox library or a GameKit env with .roblox. Raises on an invalid preset.
function Vfx.build(preset: any, env: any, options: BuildOptions?): any
	local problems = Vfx.validate(preset)
	assert(#problems == 0, "Vfx.build: " .. table.concat(problems, "; "))
	local lib = if env.roblox then env.roblox else env
	local opts: any = options or {}
	local palette = opts.palette or PALETTES.none
	local model = lib.Instance.new("Model")
	model.Name = "Vfx_" .. (preset.id or "custom")
	model:SetAttribute("VfxPreset", preset.id or "custom")
	model:SetAttribute("VfxMode", preset.mode)
	local origin = lib.Instance.new("Part")
	origin.Name = "Origin"
	origin.Size = lib.Vector3.new(0.2, 0.2, 0.2)
	origin.Transparency = 1
	origin.Anchored = true
	origin.CanCollide = false
	origin.CanTouch = false
	origin.CanQuery = false
	origin.CastShadow = false
	origin.Parent = model
	model.PrimaryPart = origin
	for _, emitter in preset.emitters or {} do
		local holder
		if emitter.shape then
			holder = lib.Instance.new("Part")
			holder.Name = emitter.name .. "Area"
			holder.Size = v3(lib, emitter.area)
			holder.Position = v3(lib, emitter.offset)
			holder.Transparency = 1
			holder.Anchored = true
			holder.CanCollide = false
			holder.CanTouch = false
			holder.CanQuery = false
			holder.CastShadow = false
			holder.Parent = model
		else
			holder = attachment(lib, origin, emitter.name .. "Point", emitter.offset)
		end
		local p = lib.Instance.new("ParticleEmitter")
		p.Name = emitter.name
		p.Enabled = false
		p.Rate = emitter.rate or 0
		p.Texture = resolveTexture(emitter, opts)
		p.Color = colorSequence(lib, palette, emitter.color)
		p.Lifetime = lib.NumberRange.new(emitter.lifetime[1], emitter.lifetime[2])
		local speed = emitter.speed or { 0, 0 }
		p.Speed = lib.NumberRange.new(speed[1], speed[2])
		local spread = emitter.spread or { 0, 0 }
		p.SpreadAngle = lib.Vector2.new(spread[1], spread[2])
		p.Size = numberSequence(lib, emitter.size or 1)
		p.Transparency = numberSequence(lib, emitter.transparency or 0)
		p.Squash = numberSequence(lib, emitter.squash or 0)
		p.LightEmission = emitter.lightEmission or 0
		p.LightInfluence = emitter.lightInfluence or 0
		p.Brightness = emitter.brightness or 1
		p.Orientation = (lib.Enum.ParticleOrientation :: any)[emitter.orientation or "FacingCamera"]
		p.Drag = emitter.drag or 0
		p.Acceleration = v3(lib, emitter.acceleration)
		local rotation = emitter.rotation or { 0, 0 }
		p.Rotation = lib.NumberRange.new(rotation[1], rotation[2])
		local rotSpeed = emitter.rotSpeed or { 0, 0 }
		p.RotSpeed = lib.NumberRange.new(rotSpeed[1], rotSpeed[2])
		p.ZOffset = emitter.zOffset or 0
		p.EmissionDirection = (lib.Enum.NormalId :: any)[emitter.emissionDirection or "Top"]
		if emitter.shape then
			p.Shape = (lib.Enum.ParticleEmitterShape :: any)[emitter.shape]
			p.ShapeStyle = (lib.Enum.ParticleEmitterShapeStyle :: any)[emitter.shapeStyle or "Volume"]
			p.ShapeInOut = (lib.Enum.ParticleEmitterShapeInOut :: any)[emitter.shapeInOut or "Outward"]
		end
		p.LockedToPart = emitter.lockedToPart == true
		p.VelocityInheritance = emitter.velocityInheritance or 0
		p.TimeScale = emitter.timeScale or 1
		p.WindAffectsDrag = emitter.windAffectsDrag == true
		if emitter.flipbook then
			p.FlipbookLayout = (lib.Enum.ParticleFlipbookLayout :: any)[emitter.flipbook.layout]
			p.FlipbookMode = (lib.Enum.ParticleFlipbookMode :: any)[emitter.flipbook.mode or "Loop"]
			p.FlipbookFramerate = lib.NumberRange.new(emitter.flipbook.fps)
			p.FlipbookStartRandom = emitter.flipbook.startRandom == true
		end
		p:SetAttribute("VfxBurst", emitter.burst or 0)
		p:SetAttribute("VfxRate", emitter.rate or 0)
		p.Parent = holder
	end
	for _, kind in { "beams", "trails" } do
		for _, item in preset[kind] or {} do
			local a0 = attachment(lib, origin, item.name .. "0", item.from)
			local a1 = attachment(lib, origin, item.name .. "1", item.to)
			local instance = lib.Instance.new(if kind == "beams" then "Beam" else "Trail")
			instance.Name = item.name
			instance.Enabled = false
			instance.Attachment0 = a0
			instance.Attachment1 = a1
			instance.Texture = if item.texture or item.textureRole then resolveTexture(item, opts) else ""
			instance.TextureMode = (lib.Enum.TextureMode :: any)[item.textureMode or "Stretch"]
			instance.TextureLength = item.textureLength or 1
			instance.Color = colorSequence(lib, palette, item.color)
			instance.Transparency = numberSequence(lib, item.transparency or 0)
			instance.LightEmission = item.lightEmission or 0
			instance.LightInfluence = item.lightInfluence or 0
			instance.Brightness = item.brightness or 1
			instance.FaceCamera = item.faceCamera == true
			if kind == "beams" then
				instance.Width0 = item.width[1]
				instance.Width1 = item.width[2]
				instance.Segments = item.segments or 10
				local curve = item.curve or { 0, 0 }
				instance.CurveSize0 = curve[1]
				instance.CurveSize1 = curve[2]
				instance.TextureSpeed = item.textureSpeed or 0
				instance.ZOffset = item.zOffset or 0
			else
				instance.Lifetime = item.lifetime
				instance.MinLength = item.minLength or 0.1
				instance.MaxLength = item.maxLength or 0
				instance.WidthScale = numberSequence(lib, item.widthScale or 1)
			end
			instance.Parent = origin
		end
	end
	for _, light in preset.lights or {} do
		local holder = attachment(lib, origin, light.name .. "Point", light.offset)
		local instance = lib.Instance.new(light.class)
		instance.Name = light.name
		instance.Enabled = false
		instance.Range = light.range
		instance.Brightness = light.brightness
		local c = roleColor(palette, if type(light.color) == "string" then light.color else "bright")
		instance.Color = lib.Color3.fromRGB(c[1], c[2], c[3])
		instance.Shadows = light.shadows == true
		if light.class ~= "PointLight" then
			instance.Angle = light.angle or 90
			instance.Face = (lib.Enum.NormalId :: any)[light.face or "Front"]
		end
		instance:SetAttribute("VfxBrightness", light.brightness)
		instance.Parent = holder
	end
	local highlight = preset.highlight
	if highlight then
		-- Adornee is set by the pool when an activation targets an instance; nil means the model.
		local instance = lib.Instance.new("Highlight")
		instance.Name = "Highlight"
		instance.Enabled = false
		local fill = roleColor(palette, highlight.fill or "bright")
		local outline = roleColor(palette, highlight.outline or "bright")
		instance.FillColor = lib.Color3.fromRGB(fill[1], fill[2], fill[3])
		instance.OutlineColor = lib.Color3.fromRGB(outline[1], outline[2], outline[3])
		instance.FillTransparency = highlight.fillTransparency or 0.75
		instance.OutlineTransparency = highlight.outlineTransparency or 0
		instance.DepthMode = (lib.Enum.HighlightDepthMode :: any)[highlight.depthMode or "Occluded"]
		instance.Parent = model
	end
	return model
end

return Vfx
