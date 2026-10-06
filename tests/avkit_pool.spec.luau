--!strict
-- AVKit/Pool (opened up from Creator/EffectsPool) and AVKit/VfxPoolRoblox driven on @lune/roblox
-- with the engine calls Lune lacks (PivotTo, Emit, Clear) injected through options.engine. The
-- legacy pool API is covered by tests/creator/effects.luau through the Creator shim.
local roblox = require("@lune/roblox")
local Pool = require("../packages/AVKit/Pool")
local Shim = require("../packages/Creator/EffectsPool")
local VfxLibrary = require("../packages/AVKit/VfxLibrary")
local VfxPoolRoblox = require("../packages/AVKit/VfxPoolRoblox")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(list: { string }, needle: string): boolean
	for _, text in list do
		if string.find(text, needle, 1, true) then
			return true
		end
	end
	return false
end

local function recorder()
	local state = { created = {}, resets = 0, destroyed = 0, updates = 0 }
	local adapter = {}
	function adapter.create(recipe: string, config: any)
		local resource = { recipe = recipe, n = #state.created + 1, config = config }
		table.insert(state.created, resource)
		return resource
	end
	function adapter.activate(resource: any, _recipe: string, config: any, context: any)
		resource.active = true
		resource.lastConfig = config
		resource.context = context
	end
	function adapter.reset(resource: any)
		resource.active = false
		state.resets += 1
	end
	function adapter.destroy(_resource: any)
		state.destroyed += 1
	end
	function adapter.update(_resource: any, _alpha: number, _config: any)
		state.updates += 1
	end
	return adapter, state
end

local FIELDS = {
	duration = { min = 0.05, max = 600 },
	priority = { min = 0, max = 10, integer = true },
	size = { min = 0, max = 4, default = 1 },
}

test("the Creator shim is the same module", function(t)
	t.eq(Shim, Pool)
end)

test("open mode validates recipes against the caller's field schema", function(t)
	t.eq(Pool.validateRecipes({ a = { duration = 1, priority = 2 } }, FIELDS), {})
	local problems = Pool.validateRecipes({
		a = { duration = 0, priority = 2 },
		b = { duration = 1, priority = 2.5 },
		c = { priority = 2 },
		d = { duration = 1, priority = 2, colour = 1 },
		Bad = { duration = 1, priority = 1 },
	}, FIELDS)
	t.ok(has(problems, "recipe a: invalid duration"))
	t.ok(has(problems, "recipe b: invalid priority"))
	t.ok(has(problems, "recipe c: missing duration"))
	t.ok(has(problems, "unknown recipe field colour"))
	t.ok(has(problems, "lower_snake"))
	t.ok(
		has(
			Pool.validateRecipes({ a = { duration = 1 } }, { duration = FIELDS.duration }),
			"duration and priority"
		)
	)
	t.ok(has(Pool.validateRecipes({}, FIELDS), "must not be empty"))
	t.throws(function()
		Pool.new((recorder()), { fields = FIELDS, recipes = { a = { duration = 0, priority = 1 } } })
	end)
end)

test("defaults fill missing fields and overrides are range-checked", function(t)
	local adapter, state = recorder()
	local pool = Pool.new(adapter, { fields = FIELDS, recipes = { a = { duration = 1, priority = 2 } } })
	t.ok(pool:emit("a"))
	t.eq(state.created[1].lastConfig.size, 1)
	t.ok(pool:emit("a", { size = 3 }))
	t.eq(state.created[2].lastConfig.size, 3)
	t.throws(function()
		pool:emit("a", { size = 9 })
	end)
	t.throws(function()
		pool:emit("missing")
	end)
end)

test("keyed pools reuse per recipe and free another recipe's idle resource when full", function(t)
	local adapter, state = recorder()
	local pool = Pool.new(adapter, {
		capacity = 2,
		keyed = true,
		fields = FIELDS,
		recipes = { a = { duration = 1, priority = 2 }, b = { duration = 1, priority = 2 } },
	})
	local a1 = pool:emit("a")
	local b1 = pool:emit("b")
	a1:cancel()
	b1:cancel()
	t.eq(pool:stats().idle, 2)
	local a2 = pool:emit("a")
	t.eq(#state.created, 2, "a reuses its own idle clone")
	t.eq(pool:stats().reused, 1)
	a2:cancel()
	local c = pool:emit("a")
	t.ok(c)
	pool:emit("a") -- second 'a': the pool is full, so b's idle clone is destroyed to make room
	t.eq(#state.created, 3)
	t.eq(state.destroyed, 1)
	t.eq(state.created[3].recipe, "a")
end)

test("expire shortens but never extends; remaining reads the entry", function(t)
	local adapter, state = recorder()
	local pool = Pool.new(adapter, { fields = FIELDS, recipes = { loop = { duration = 30, priority = 5 } } })
	local token = pool:emit("loop")
	t.eq(pool:remaining(token.id), 30)
	t.eq(pool:expire(token.id, 0.5), true)
	t.eq(pool:remaining(token.id), 0.5)
	pool:expire(token.id, 10)
	t.eq(pool:remaining(token.id), 0.5)
	pool:step(0.25)
	t.eq(state.resets, 0)
	pool:step(0.25)
	t.eq(state.resets, 1)
	t.eq(pool:remaining(token.id), nil)
	t.eq(pool:expire(token.id, 1), false)
	t.throws(function()
		pool:expire(token.id, -1)
	end)
end)

test("reduced effects refuse low priorities below a custom threshold and keep the rest", function(t)
	local adapter = recorder()
	local pool = Pool.new(adapter, {
		fields = FIELDS,
		recipes = { low = { duration = 1, priority = 3 }, high = { duration = 1, priority = 4 } },
		reducedEffects = true,
		reducedThreshold = 4,
		reduce = function(config: any)
			config.size = 0
		end,
	})
	local token, reason = pool:emit("low")
	t.eq(token, nil)
	t.eq(reason, "reduced_effects")
	t.ok(pool:emit("high"))
end)

-- ---------------------------------------------------------------- VfxPoolRoblox on @lune/roblox

local function harness(options: any?)
	local calls = { pivots = 0, emits = {}, clears = 0 }
	local engine = {
		pivot = function(model: any, cframe: any)
			calls.pivots += 1
			model:SetAttribute("TestPivot", cframe.Position)
		end,
		emit = function(emitter: any, count: number)
			table.insert(calls.emits, emitter.Name .. "=" .. count)
		end,
		clear = function(_emitter: any)
			calls.clears += 1
		end,
		adorn = function(highlight: any, target: any?)
			-- Lune cannot set a Ref property to nil; record the release on an attribute instead
			if target == nil then
				highlight:SetAttribute("TestReleased", true)
			else
				highlight:SetAttribute("TestReleased", false)
				highlight.Adornee = target
			end
		end,
		cframeOf = function(instance: any): any
			return roblox.CFrame.new(instance:GetAttribute("TestPosition") or roblox.Vector3.zero)
		end,
	}
	local folder = roblox.Instance.new("Folder")
	local reports = {}
	local opts: any = { parent = folder, engine = engine }
	for key, value in options or {} do
		opts[key] = value
	end
	local env = {
		roblox = roblox,
		report = function(message: string)
			table.insert(reports, message)
		end,
	}
	return VfxPoolRoblox.new(env, opts), calls, folder, reports
end

local function find(folder: any, preset: string): any
	for _, child in folder:GetChildren() do
		if child:GetAttribute("VfxPreset") == preset then
			return child
		end
	end
	return nil
end

local function effect(model: any, name: string): any
	for _, item in model:GetDescendants() do
		if item.Name == name and not item:IsA("Attachment") and not item:IsA("BasePart") then
			return item
		end
	end
	return nil
end

test("a burst emits on schedule, fades its light and returns to the idle list", function(t)
	local sounds = {}
	local pool, calls, folder = harness({
		sound = function(cue: string)
			table.insert(sounds, cue)
		end,
	})
	local handle = pool:play("levelup_burst", roblox.Vector3.new(4, 0, 0))
	t.ok(handle, "played")
	t.eq(sounds, { "level_up" })
	local model = find(folder, "levelup_burst")
	t.ok(model, "clone parented")
	t.eq(calls.emits, { "ring=24" }, "the delayed burst waits")
	t.eq(effect(model, "pillar").Enabled, true)
	local glow = effect(model, "glow")
	t.eq(glow.Enabled, true)
	t.eq(glow.Brightness, 3)
	pool:step(0.2)
	t.eq(calls.emits, { "ring=24", "rise=30" })
	pool:step(0.6) -- elapsed 0.8: 0.4 s into a 1.2 s fade
	t.near(glow.Brightness, 3 * (1 - 0.4 / 1.2), 1e-3)
	pool:step(1.3)
	t.eq(model.Parent, nil, "returned after its duration")
	t.eq(glow.Enabled, false)
	t.eq(pool:stats().idle, 1)
	t.ok(calls.clears >= 2, "particles cleared on reset")
	pool:play("levelup_burst", roblox.Vector3.zero)
	t.eq(pool:stats().reused, 1)
	t.eq(pool:stats().templates, 1)
end)

test("a stopped loop lingers for its particle lifetime, then is reclaimed", function(t)
	local pool, _, folder = harness()
	local target = roblox.Instance.new("Part")
	target.Parent = roblox.Instance.new("Folder")
	target:SetAttribute("TestPosition", roblox.Vector3.new(0, 5, 0))
	local handle = pool:play("shield_bubble", target)
	local model = find(folder, "shield_bubble")
	local shell = effect(model, "shell")
	t.eq(shell.Enabled, true)
	t.eq(shell.Rate, 20)
	local highlight = model:FindFirstChildOfClass("Highlight")
	t.eq(highlight.Enabled, true)
	t.eq(highlight.Adornee, target, "highlight on the target")
	pool:step(1)
	t.eq(model:GetAttribute("TestPivot"), roblox.Vector3.new(0, 5, 0), "loops follow their target")
	t.eq(handle:stop(), true)
	t.eq(shell.Enabled, false)
	t.eq(handle:active(), true, "lingering")
	pool:step(0.5)
	t.eq(handle:active(), true)
	pool:step(0.5)
	t.eq(handle:active(), false)
	t.eq(model.Parent, nil)
	t.eq(highlight:GetAttribute("TestReleased"), true, "highlight released")
	t.eq(handle:stop(), false, "a finished handle cannot stop a reused clone")
	t.eq(pool:stats().cleanupErrors, 0)
	t.eq(pool:stats().adapterErrors, 0)
end)

test("a loop whose target is removed stops emitting and fades in place", function(t)
	local pool, _, folder = harness()
	local holder = roblox.Instance.new("Folder")
	local target = roblox.Instance.new("Part")
	target.Parent = holder
	local handle = pool:play("aura_loop", target)
	local motes = effect(find(folder, "aura_loop"), "motes")
	t.eq(motes.Enabled, true)
	target.Parent = nil
	pool:step(0.1)
	t.eq(motes.Enabled, false)
	t.eq(handle:active(), true)
end)

test("reduced motion, flash safety and reduced effects are applied per play", function(t)
	local pool, calls, folder = harness({ effective = { reducedMotion = true, allowFlashes = false } })
	local none, reason = pool:play("speed_lines", roblox.Vector3.zero)
	t.eq(none, nil)
	t.eq(reason, "reduced_motion")
	t.ok(pool:play("muzzle_flash", roblox.Vector3.zero))
	local muzzle = find(folder, "muzzle_flash")
	t.eq(effect(muzzle, "flash").Enabled, false, "flash light dropped")
	t.eq(calls.emits, { "flare=1", "wisp=2" })
	pool:setEffective({ reducedMotion = false, allowFlashes = true })
	t.ok(pool:play("speed_lines", roblox.Vector3.zero))
	pool:setReducedEffects(true)
	local dropped, why = pool:play("confetti", roblox.Vector3.zero)
	t.eq(dropped, nil)
	t.eq(why, "reduced_effects")
	t.eq(find(folder, "speed_lines"), nil, "a low-priority loop is dropped when reduced effects start")
	t.ok(pool:play("hit_spark", roblox.Vector3.zero))
	t.eq(calls.emits[#calls.emits], "core=1")
	t.eq(calls.emits[#calls.emits - 1], "sparks=7", "the preset's reduced burst scale")
end)

test("capacity evicts lower priorities first, sound errors are reported, destroy cleans up", function(t)
	local pool, _, folder, reports = harness({
		capacity = 2,
		sound = function()
			error("no audio here")
		end,
	})
	t.ok(pool:play("smoke_puff", roblox.Vector3.zero))
	t.ok(pool:play("impact_dust", roblox.Vector3.zero))
	t.eq(#reports, 1, "smoke_puff has no sound; impact_dust's failure is reported")
	local low, reason = pool:play("footstep_dust", roblox.Vector3.zero)
	t.eq(low, nil)
	t.eq(reason, "capacity")
	t.ok(pool:play("explosion_small", roblox.Vector3.zero))
	t.eq(find(folder, "smoke_puff"), nil, "the weakest active effect was evicted")
	t.throws(function()
		pool:play("not_a_preset", roblox.Vector3.zero)
	end)
	pool:destroy()
	t.eq(#folder:GetChildren(), 0)
	t.throws(function()
		VfxPoolRoblox.new({ roblox = roblox }, {} :: any)
	end)
	local bad = VfxLibrary.all()
	bad.hit_spark.emitters[1].rate = 999
	t.throws(function()
		VfxPoolRoblox.new({ roblox = roblox }, { parent = roblox.Instance.new("Folder"), presets = bad })
	end)
end)

return cases
