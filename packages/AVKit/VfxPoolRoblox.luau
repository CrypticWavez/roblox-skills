--!strict
-- @tier T3
-- probe: av_vfx_grid
-- VfxPoolRoblox: plays vfx/1 presets in Studio through a keyed AVKit/Pool. Templates come from
-- Vfx.build once per preset (palette and textures fixed at creation); activations clone them,
-- pivot to the target, run Vfx.plan (emit bursts at their delays, enable loops, beams and trails,
-- fade lights, enable the Highlight on its adornee) and return the clone to the idle list.
--   VfxPoolRoblox.new(env, options) -> pool
--   pool:play(id, where, playOptions?) -> (handle?, reason?)  where = CFrame | Vector3 | BasePart |
--       Attachment | Model. reason: reduced_motion, reduced, reduced_effects, capacity, ...
--   handle:stop()     loops: stop emitting, keep the clone while its particles fade (plan.linger)
--   handle:cancel()   end now
--   pool:step(dt)     call every frame (RenderStepped on the client); never yields
--   pool:setEffective(effective)  settings/1 Settings.effective: reducedMotion, allowFlashes
--   pool:setReducedEffects(on)    performance mode: presets below reducedThreshold (4, convention)
--       are refused, the rest use their `reduced` rules
--   pool:stats(), pool:destroy()
-- Accessibility: motion presets are skipped under reduced motion and flash items are dropped
-- when flashes are off; both are read per play. The colour-vision palette is read at creation:
-- recreate the pool when colorblindMode changes. Sounds: options.sound(cueId, cframe, follow) is
-- called for presets with a `sound` (route it to AudioGraphRoblox); its errors go to env.report.
-- options.engine overrides the engine calls (pivot, emit, clear, adorn, cframeOf) for Lune specs
-- (Lune has no PivotTo, Emit or Clear and cannot set a Ref to nil); in Studio the defaults call
-- PivotTo, Emit, Clear, Highlight.Adornee and GetPivot/WorldCFrame/CFrame.
local Pool = require("./Pool")
local Vfx = require("./Vfx")
local VfxLibrary = require("./VfxLibrary")

local VfxPoolRoblox = {}

VfxPoolRoblox.REDUCED_THRESHOLD = 4 -- convention: decorative presets (priority 0-3) go first
VfxPoolRoblox.CAPACITY = 32 -- convention: concurrent effects per client
VfxPoolRoblox.FIELDS = table.freeze({
	duration = table.freeze({ min = 0.05, max = 600 }),
	priority = table.freeze({ min = 0, max = 10, integer = true }),
})

export type Options = {
	parent: any,
	presets: { [string]: any }?,
	capacity: number?,
	reducedEffects: boolean?,
	reducedThreshold: number?,
	effective: any?,
	palette: { [string]: { number } }?,
	textures: { [string]: string }?,
	textureSizes: { [string]: number }?,
	sound: ((cue: string, cframe: any, follow: any?) -> ())?,
	engine: any?,
}

export type PlayOptions = {
	follow: boolean?, -- keep the effect on a moving Instance target (default: loops and trails)
	adornee: any?, -- Highlight target (default: the Instance target, or an Attachment's parent)
	duration: number?, -- override (loops: auto-stop time)
	priority: number?,
	silent: boolean?, -- do not call options.sound
}

local function defaultEngine(): any
	return {
		pivot = function(model: any, cframe: any)
			model:PivotTo(cframe)
		end,
		emit = function(emitter: any, count: number)
			emitter:Emit(count)
		end,
		clear = function(emitter: any)
			emitter:Clear()
		end,
		adorn = function(highlight: any, target: any?)
			highlight.Adornee = target
		end,
		cframeOf = function(instance: any): any
			if instance:IsA("Attachment") then
				return instance.WorldCFrame
			elseif instance:IsA("BasePart") then
				return instance.CFrame
			end
			return instance:GetPivot()
		end,
	}
end

local EFFECT_CLASSES = { "ParticleEmitter", "Beam", "Trail", "Light", "Highlight" }

local function isEffect(instance: any): boolean
	for _, class in EFFECT_CLASSES do
		if instance:IsA(class) then
			return true
		end
	end
	return false
end

function VfxPoolRoblox.new(env: any, options: Options)
	assert(type(options) == "table" and options.parent ~= nil, "VfxPoolRoblox: options.parent is required")
	local lib = if env.roblox then env.roblox else env
	local engine = defaultEngine()
	for key, fn in options.engine or {} do
		engine[key] = fn
	end
	local presets = options.presets or VfxLibrary.all()
	local recipes = {}
	local problems = {}
	for id, preset in presets do
		for _, text in (Vfx.validate(preset, { textureSizes = options.textureSizes })) do
			table.insert(problems, id .. ": " .. text)
		end
		recipes[id] = { duration = preset.duration, priority = preset.priority }
	end
	table.sort(problems)
	assert(#problems == 0, "VfxPoolRoblox: " .. table.concat(problems, "; "))

	local effective: any = options.effective or {}
	local reduced = options.reducedEffects == true
	local palette = options.palette or Vfx.palette(effective.colorblindMode)
	local templates: { [string]: any } = {}
	local report = env.report or function(_message: string) end

	local function template(id: string): any
		local model = templates[id]
		if model == nil then
			model = Vfx.build(presets[id], env, { palette = palette, textures = options.textures })
			templates[id] = model
		end
		return model
	end

	local function stopResource(resource: any)
		if resource.stopped then
			return
		end
		resource.stopped = true
		for _, item in resource.byName do
			item.Enabled = false
		end
	end

	-- Runs the plan's actions due at `elapsed` (emits once at their delay, enables once, lights
	-- follow Vfx.lightAt).
	local function run(resource: any, elapsed: number)
		for index, action in resource.plan.actions do
			local target = resource.byName[action.target]
			if target == nil then
				continue
			end
			if action.kind == "emit" then
				if not resource.fired[index] and elapsed >= (action.at or 0) then
					resource.fired[index] = true
					engine.emit(target, action.count)
				end
			elseif not resource.fired[index] then
				resource.fired[index] = true
				if action.kind == "enable" then
					if action.rate then
						target.Rate = action.rate
					end
					target.Enabled = true
				elseif action.kind == "highlight" then
					engine.adorn(target, resource.adornee)
					target.Enabled = true
				else
					target.Enabled = true
				end
			end
			if action.kind == "light" then
				target.Brightness = Vfx.lightAt(action, elapsed)
			end
		end
	end

	local adapter = {}
	function adapter.create(recipe: string, _config: any): any
		local model = template(recipe):Clone()
		local byName = {}
		for _, item in model:GetDescendants() do
			if isEffect(item) then
				byName[item.Name] = item
			end
		end
		return { model = model, byName = byName }
	end
	function adapter.activate(resource: any, _recipe: string, config: any, context: any)
		context.record.resource = resource
		resource.plan = context.plan
		resource.follow = context.follow
		resource.adornee = context.adornee
		resource.fired = {}
		resource.stopped = false
		resource.duration = config.duration
		engine.pivot(resource.model, context.cframe)
		resource.model.Parent = options.parent
		run(resource, 0)
	end
	function adapter.update(resource: any, alpha: number, config: any)
		local follow = resource.follow
		if follow ~= nil then
			if follow.Parent == nil then
				stopResource(resource) -- the target is gone; let the particles fade where they are
				resource.follow = nil
			else
				engine.pivot(resource.model, engine.cframeOf(follow))
			end
		end
		if resource.stopped then
			return
		end
		local elapsed = alpha * config.duration
		-- A loop that reaches its duration stops early enough for its particles to fade.
		if resource.plan.loop and elapsed >= config.duration - resource.plan.linger then
			stopResource(resource)
			return
		end
		run(resource, elapsed)
	end
	function adapter.reset(resource: any)
		for _, item in resource.byName do
			item.Enabled = false
			if item:IsA("ParticleEmitter") then
				engine.clear(item)
			elseif item:IsA("Highlight") then
				engine.adorn(item, nil)
			end
		end
		resource.model.Parent = nil
		resource.plan, resource.follow, resource.adornee = nil, nil, nil
	end
	function adapter.destroy(resource: any)
		resource.model:Destroy()
	end

	local pool = Pool.new(adapter, {
		capacity = options.capacity or VfxPoolRoblox.CAPACITY,
		reducedEffects = reduced,
		reducedThreshold = options.reducedThreshold or VfxPoolRoblox.REDUCED_THRESHOLD,
		recipes = recipes,
		fields = VfxPoolRoblox.FIELDS,
		keyed = true,
		reduce = function(_config: any) end, -- Vfx.plan applies each preset's own reduced rules
	})

	local function placement(preset: any, where: any, playOptions: PlayOptions): (any, any?, any?)
		local kind = typeof(where)
		if kind == "CFrame" then
			return where, nil, playOptions.adornee
		elseif kind == "Vector3" then
			return lib.CFrame.new(where), nil, playOptions.adornee
		end
		assert(kind == "Instance", "VfxPoolRoblox: where must be a CFrame, Vector3 or Instance")
		local followDefault = preset.mode == "loop" or preset.trails ~= nil
		local follow = if playOptions.follow == nil then followDefault else playOptions.follow
		local adornee = playOptions.adornee or (if where:IsA("Attachment") then where.Parent else where)
		return engine.cframeOf(where), if follow then where else nil, adornee
	end

	local api: any = {}

	function api:play(id: string, where: any, playOptions: PlayOptions?): (any?, string?)
		local preset = presets[id]
		assert(preset ~= nil, "VfxPoolRoblox: unknown preset " .. tostring(id))
		local opts: PlayOptions = playOptions or {}
		local plan = Vfx.plan(preset, {
			reduced = reduced,
			reducedMotion = effective.reducedMotion == true,
			reduceFlashing = effective.allowFlashes == false,
		})
		if plan.skip then
			return nil, plan.skip
		end
		local cframe, follow, adornee = placement(preset, where, opts)
		local overrides = nil
		if opts.duration ~= nil or opts.priority ~= nil then
			overrides = { duration = opts.duration, priority = opts.priority }
		end
		local record: any = {}
		local token, reason = pool:emit(
			id,
			overrides,
			{ plan = plan, cframe = cframe, follow = follow, adornee = adornee, record = record }
		)
		if token == nil then
			return nil, reason
		end
		if preset.sound and options.sound and opts.silent ~= true then
			local ok: boolean, err: any = pcall(options.sound, preset.sound, cframe, follow)
			if not ok then
				report("VfxPoolRoblox: sound " .. preset.sound .. " failed: " .. tostring(err))
			end
		end
		local handle: any = { id = token.id, preset = id, loop = plan.loop }
		function handle.stop(_self: any?): boolean
			if record.resource == nil or pool:remaining(token.id) == nil then
				return false
			end
			stopResource(record.resource)
			return pool:expire(token.id, plan.linger)
		end
		function handle.cancel(_self: any?): boolean
			return pool:cancel(token.id)
		end
		function handle.active(_self: any?): boolean
			return pool:remaining(token.id) ~= nil
		end
		return handle, nil
	end

	function api:step(dt: number): (boolean, string?)
		return pool:step(dt)
	end

	function api:setEffective(value: any)
		assert(type(value) == "table", "VfxPoolRoblox: effective settings table required")
		effective = value
	end

	function api:setReducedEffects(enabled: boolean)
		reduced = enabled
		pool:setReducedEffects(enabled)
	end

	function api:presets(): { string }
		return pool:recipes()
	end

	function api:stats(): any
		local stats = pool:stats()
		local count = 0
		for _ in templates do
			count += 1
		end
		stats.templates = count
		return stats
	end

	function api:destroy()
		pool:destroy()
		for _, model in templates do
			model:Destroy()
		end
		table.clear(templates)
	end

	return api
end

return VfxPoolRoblox
