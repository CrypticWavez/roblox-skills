--!strict
-- Neutral native recipes: no damage, camera control, sounds or external asset IDs. Superseded by
-- the vfx/1 library (AVKit/Vfx, AVKit/VfxLibrary, AVKit/VfxPoolRoblox); kept for the inherited
-- creator fixture. String requires, so tools/new_project.py dependency scans follow them.
local Pool = require("./EffectsPool")
local Effects = {}
local particleStyles = {
	none = "",
	sparkles = "rbxasset://textures/particles/sparkles_main.dds",
	square = "rbxasset://textures/particles/SquareParticle.png",
}
local colors = {
	telegraph = Color3.fromRGB(235, 197, 92),
	impact = Color3.fromRGB(186, 209, 218),
	reward = Color3.fromRGB(151, 210, 163),
}
local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function attachment(parent, name)
	local value = Instance.new("Attachment")
	value.Name, value.Parent = name, parent
	return value
end

function Effects.new(parent, options)
	assert(typeof(parent) == "Instance", "native parent required")
	assert(options == nil or type(options) == "table", "invalid native options")
	options = options or {}
	local allowedOptions =
		{ capacity = true, reducedEffects = true, recipes = true, autoStep = true, particleStyle = true }
	for key in options do
		assert(allowedOptions[key] == true, "unknown native option")
	end
	assert(options.autoStep == nil or type(options.autoStep) == "boolean", "invalid autoStep")
	local particleStyle = if options.particleStyle == nil then "none" else options.particleStyle
	assert(particleStyles[particleStyle] ~= nil, "invalid built-in particle style")
	local owner = Instance.new("Folder")
	owner.Name, owner.Parent = "CreatorEffectsOwned", parent
	local connection, ownerConnection
	local destroyed = false
	local adapter = {}
	function adapter.create()
		local part = Instance.new("Part")
		part.Parent = owner -- Contains partial creation if a native property assignment fails.
		part.Name, part.Size, part.Transparency = "PooledEffect", Vector3.one * 0.1, 1
		part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow =
			true, false, false, false, false
		local ends = {}
		for index = 1, 6 do
			ends[index] = attachment(part, "Endpoint" .. index)
		end
		local beams = {}
		for index = 1, 2 do
			local beam = Instance.new("Beam")
			beam.Name, beam.Attachment0, beam.Attachment1 =
				"Cue" .. index, ends[index * 2 - 1], ends[index * 2]
			beam.Texture, beam.FaceCamera, beam.LightEmission, beam.Enabled = "", true, 0, false
			beam.Parent = part
			beams[index] = beam
		end
		local trail = Instance.new("Trail")
		trail.Name, trail.Attachment0, trail.Attachment1 = "MotionTrail", ends[5], ends[6]
		trail.Texture, trail.Enabled, trail.FaceCamera, trail.MinLength = "", false, true, 0.02
		trail.Parent = part
		local particles = Instance.new("ParticleEmitter")
		particles.Name, particles.Texture, particles.Rate, particles.Enabled =
			"Burst", particleStyles[particleStyle], 0, false
		particles.LightEmission, particles.LightInfluence = 0.15, 0.75
		particles.Parent = ends[1]
		return { root = part, ends = ends, beams = beams, trail = trail, particles = particles }
	end
	function adapter.activate(resource, recipe, config, context)
		local color = context.color or colors[recipe]
		resource.origin, resource.recipe = context.cframe, recipe
		local r = config.radius
		resource.ends[1].Position, resource.ends[2].Position = Vector3.new(-r, 0, 0), Vector3.new(r, 0, 0)
		resource.ends[3].Position, resource.ends[4].Position = Vector3.new(0, 0, -r), Vector3.new(0, 0, r)
		resource.ends[5].Position, resource.ends[6].Position =
			Vector3.new(-r * 0.2, 0, 0), Vector3.new(r * 0.2, 0, 0)
		if recipe == "impact" then
			resource.ends[3].Position, resource.ends[4].Position = Vector3.new(0, -r, 0), Vector3.new(0, r, 0)
		end
		for _, beam in resource.beams do
			beam.Color, beam.Transparency = ColorSequence.new(color), NumberSequence.new(0.15)
			beam.Width0, beam.Width1, beam.Enabled = config.width, config.width, true
		end
		resource.trail.Color, resource.trail.Transparency =
			ColorSequence.new(color), NumberSequence.new(0.25, 1)
		resource.trail.Lifetime = math.min(config.duration, 0.3)
		resource.trail.Enabled = recipe == "reward" and not config.reducedEffects
		resource.particles.Color, resource.particles.Lifetime =
			ColorSequence.new(color), NumberRange.new(0.1, 0.25)
		resource.particles.Speed, resource.particles.SpreadAngle =
			NumberRange.new(r, r * 3), Vector2.new(30, 30)
		resource.particles.Size, resource.particles.Transparency =
			NumberSequence.new(config.width), NumberSequence.new(0, 1)
		resource.root.CFrame, resource.root.Parent = context.cframe, owner
		resource.root:SetAttribute("Recipe", recipe)
		resource.particles:Emit(config.particleCount)
	end
	function adapter.update(resource, alpha, config)
		for _, beam in resource.beams do
			beam.Transparency = NumberSequence.new(0.15 + 0.85 * alpha)
		end
		if config.reducedEffects then
			resource.particles:Clear()
			resource.trail.Enabled = false
			resource.trail:Clear()
		end
		if resource.recipe == "reward" and not config.reducedEffects then
			resource.root.CFrame = resource.origin + Vector3.new(0, config.radius * alpha * 2, 0)
		end
	end
	function adapter.reset(resource)
		for _, beam in resource.beams do
			beam.Enabled = false
		end
		resource.trail.Enabled = false
		resource.trail:Clear()
		resource.particles.Enabled = false
		resource.particles:Clear()
		resource.root.Parent = nil
		resource.root:SetAttribute("Recipe", nil)
	end
	function adapter.destroy(resource)
		resource.root:Destroy()
	end
	local ok, pool = pcall(Pool.new, adapter, {
		capacity = options.capacity,
		reducedEffects = options.reducedEffects,
		recipes = options.recipes,
	})
	if not ok then
		owner:Destroy()
		error(pool)
	end
	local api = {}
	function api:emit(recipe, context, overrides)
		assert(type(context) == "table" and typeof(context.cframe) == "CFrame", "CFrame context required")
		for _, value in { context.cframe:GetComponents() } do
			assert(finite(value), "invalid CFrame")
		end
		if context.color ~= nil then
			assert(typeof(context.color) == "Color3", "invalid color")
			for _, value in { context.color.R, context.color.G, context.color.B } do
				assert(finite(value) and value >= 0 and value <= 1, "invalid color")
			end
		end
		return pool:emit(recipe, overrides, { cframe = context.cframe, color = context.color })
	end
	function api:step(dt)
		return pool:step(dt)
	end
	function api:stats()
		return pool:stats()
	end
	function api:setReducedEffects(enabled)
		pool:setReducedEffects(enabled)
	end
	function api:destroy()
		if destroyed then
			return
		end
		destroyed = true
		if ownerConnection then
			ownerConnection:Disconnect()
			ownerConnection = nil
		end
		if connection then
			connection:Disconnect()
			connection = nil
		end
		pool:destroy()
		owner:Destroy()
	end
	ownerConnection = owner.Destroying:Connect(function()
		api:destroy()
	end)
	if options.autoStep ~= false then
		connection = game:GetService("RunService").Heartbeat:Connect(function(dt)
			pool:step(dt)
		end)
	end
	return api
end

return Effects
