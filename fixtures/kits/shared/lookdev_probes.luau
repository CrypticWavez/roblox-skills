--!strict
-- G5 probe registry (prefixes lookdev_, av_, feel_, worldcycle_). Each probe exercises one
-- engine-facing module of the look, sound and feel kits in a play session on the unpublished
-- diagnostic place (fixtures/kits.project.json) and records ENGINE_CHECK lines; runners are
-- tests/engine/<probe>.luau. Client-side probes (audio, feel) need a LocalScript runner: they
-- fail a "client_side" check on the server rather than pretend. Every probe refuses any place but
-- the unpublished diagnostic one first (Env.assertDiagnostic), removes what it builds and restores
-- the Lighting and MaterialService state it changes, also when it raises.
-- No requires: kit modules come from ctx.kit. Lune specs (tests/avkit_probes.spec.luau) run this
-- registry against FakeEnv with env.engineOverrides for the engine methods Lune lacks (Emit,
-- PivotTo, AudioPlayer:Play, LoadAnimation, GetServerTimeNow, MaterialService methods); Studio
-- runs never set it.
local probes = {}

local function overrides(ctx: any): any
	return ctx.env.engineOverrides or {}
end

-- Wraps a probe body: refuses a non-diagnostic place before anything runs, then always runs the
-- body's deferred cleanups (in reverse, each protected), so a probe that raises still removes what
-- it built and restores what it changed. The error is re-raised for Probe.runAll to record as
-- check "error".
local function guarded(body: (ctx: any, defer: (fn: () -> ()) -> ()) -> ...any)
	return function(ctx: any)
		ctx.kit("GameKit/Env").assertDiagnostic(ctx.env, ctx.probe)
		local cleanups = {}
		local ok, err = pcall(body, ctx, function(fn: () -> ())
			table.insert(cleanups, fn)
		end)
		for index = #cleanups, 1, -1 do
			pcall(cleanups[index])
		end
		if not ok then
			error(err, 0)
		end
	end
end

local function read(instance: any, key: string): (boolean, any)
	return pcall(function(): any
		return instance[key]
	end)
end

-- Captures what SceneKit/Lighting.apply writes and returns the function that puts it back: the
-- Lighting properties Lighting.inspect reads, every Lighting attribute, Workspace.GlobalWind, and
-- the SceneKit-owned Atmosphere, Sky, post effects and Clouds. Those are set aside (unparented)
-- for the run, so apply builds its own and the place's instances come back untouched.
local function keepLighting(Lighting: any, lighting: any): () -> ()
	local properties = {}
	for key in Lighting.inspect(lighting).lighting do
		local ok, value = read(lighting, key)
		if ok then
			properties[key] = value
		end
	end
	local attributes = lighting:GetAttributes()
	local root = lighting.Parent
	local workspace = if root then root:FindFirstChildOfClass("Workspace") else nil
	local windRead, wind = false, nil
	if workspace then
		windRead, wind = read(workspace, "GlobalWind")
	end
	local parents = { lighting }
	local terrain = if workspace then workspace:FindFirstChildOfClass("Terrain") else nil
	if terrain then
		table.insert(parents, terrain)
	end
	local function owned(): { { child: any, parent: any } }
		local out = {}
		for _, parent in parents do
			for _, child in parent:GetChildren() do
				if child:GetAttribute(Lighting.OWNED_ATTRIBUTE) == true then
					table.insert(out, { child = child, parent = parent })
				end
			end
		end
		return out
	end
	local setAside = owned()
	for _, entry in setAside do
		entry.child.Parent = nil
	end
	return function()
		for _, entry in owned() do
			entry.child:Destroy()
		end
		for _, entry in setAside do
			entry.child.Parent = entry.parent
		end
		for key, value in properties do
			pcall(function()
				lighting[key] = value
			end)
		end
		for name in lighting:GetAttributes() do
			if attributes[name] == nil then
				lighting:SetAttribute(name, nil)
			end
		end
		for name, value in attributes do
			lighting:SetAttribute(name, value)
		end
		if windRead then
			workspace.GlobalWind = wind
		end
	end
end

local function clientOnly(ctx: any): boolean
	local place = ctx.env.place
	local client = place == nil or place.isClient ~= false
	ctx.check("client_side", client, if client then nil else "run this probe from a LocalScript runner")
	return client
end

local function findPreset(folder: any, id: string): any
	for _, child in folder:GetChildren() do
		if child:GetAttribute("VfxPreset") == id then
			return child
		end
	end
	return nil
end

-- SceneKit/Lighting schema 2: every preset applies without conflicts, inspect reads it back,
-- apply is order-independent and requires (LightingStyle) is reported, not written.
-- The Lighting state the place had is restored afterwards.
probes.av_lighting_presets = guarded(function(ctx: any, defer: (fn: () -> ()) -> ())
	local Lighting = ctx.kit("SceneKit/Lighting")
	local env = ctx.env
	local lighting = env.services.Lighting
	if not ctx.check("lighting_service", lighting ~= nil) then
		return
	end
	defer(keepLighting(Lighting, lighting))
	for _, id in Lighting.list() do
		local ok, report = pcall(Lighting.apply, lighting, id, env)
		if ok then
			local inspected = Lighting.inspect(lighting)
			ctx.check("apply_" .. id, inspected.profile == id and #report.conflicts == 0, {
				conflicts = report.conflicts,
				skipped = report.skipped,
				requires_ok = inspected.requires_ok,
			})
		else
			ctx.check("apply_" .. id, false, tostring(report))
		end
	end
	Lighting.apply(lighting, "overcast", env)
	local direct = Lighting.inspect(lighting)
	Lighting.apply(lighting, "night_clear", env)
	Lighting.apply(lighting, "overcast", env)
	local after = Lighting.inspect(lighting)
	ctx.check(
		"apply_order_independent",
		after.lighting.Brightness == direct.lighting.Brightness
			and after.lighting.FogEnd == direct.lighting.FogEnd,
		{ direct = direct.lighting.Brightness, after = after.lighting.Brightness }
	)
	ctx.check("requires_reported", type(after.requires_ok) == "boolean", after.requires)
end)

-- AVKit/VfxPoolRoblox: all 21 presets play on a grid, bursts return to the pool, stopped loops
-- linger then return, clones are reused, and flash items drop when flashes are off.
probes.av_vfx_grid = guarded(function(ctx: any, defer: (fn: () -> ()) -> ())
	local VfxPoolRoblox = ctx.kit("AVKit/VfxPoolRoblox")
	local VfxLibrary = ctx.kit("AVKit/VfxLibrary")
	local env = ctx.env
	local lib = env.roblox
	local folder = lib.Instance.new("Folder")
	folder.Name = "LookdevVfxGrid"
	folder.Parent = env.services.Workspace
	defer(function()
		folder:Destroy()
	end)
	local pool = VfxPoolRoblox.new(env, { parent = folder, engine = overrides(ctx).vfx, capacity = 32 })
	defer(function()
		pool:destroy()
	end)
	local ids = VfxLibrary.list()
	local loops = 0
	local handles = {}
	for index, id in ids do
		local column, row = (index - 1) % 7, (index - 1) // 7
		local handle, reason = pool:play(id, lib.Vector3.new(column * 12 - 36, 6, row * 12 + 40))
		ctx.check("play_" .. id, handle ~= nil, reason)
		if handle then
			table.insert(handles, handle)
			if handle.loop then
				loops += 1
			end
		end
	end
	ctx.check("all_active", pool:stats().active == #ids, pool:stats())
	pool:step(0.05)
	local level = findPreset(folder, "levelup_burst")
	local glow = level and level:FindFirstChild("glow", true)
	ctx.check("light_on", glow ~= nil and glow.Enabled == true and glow.Brightness > 0)
	pool:step(5) -- past every burst (2.5 s at most), inside every loop (10 s at least)
	ctx.check("bursts_returned", pool:stats().active == loops, pool:stats())
	for _, handle in handles do
		if handle.loop then
			handle:stop()
		end
	end
	pool:step(2)
	local stats = pool:stats()
	ctx.check("loops_returned", stats.active == 0, stats)
	ctx.check("no_adapter_errors", stats.adapterErrors == 0 and stats.cleanupErrors == 0, stats)
	pool:play("hit_spark", lib.Vector3.new(0, 6, 30))
	ctx.check("clone_reused", pool:stats().reused >= 1, pool:stats())
	pool:setEffective({ allowFlashes = false, reducedMotion = true })
	pool:play("muzzle_flash", lib.Vector3.new(6, 6, 30))
	local muzzle = findPreset(folder, "muzzle_flash")
	local flash = muzzle and muzzle:FindFirstChild("flash", true)
	ctx.check("flash_light_dropped", flash ~= nil and flash.Enabled == false)
	local _, reason = pool:play("speed_lines", lib.Vector3.new(12, 6, 30))
	ctx.check("motion_skipped", reason == "reduced_motion", reason)
end)

local function audioSetup(ctx: any, options: any, defer: (fn: () -> ()) -> ()): any
	local env = ctx.env
	local lib = env.roblox
	local folder = lib.Instance.new("Folder")
	folder.Name = "LookdevAudioGraph"
	local soundService = env.services.SoundService
	folder.Parent = if typeof(soundService) == "Instance" then soundService else env.services.Workspace
	defer(function()
		folder:Destroy()
	end)
	local AudioGraphRoblox = ctx.kit("AVKit/AudioGraphRoblox")
	options.parent = folder
	options.camera = env.services.Workspace and env.services.Workspace.CurrentCamera
	options.engine = overrides(ctx).audio
	local mix = AudioGraphRoblox.new(env, options)
	defer(function()
		mix:destroy()
	end)
	return mix
end

-- AVKit/AudioGraphRoblox: the default audio-graph/1 builds on the Audio API and every Wire is
-- Connected (all pins exist, no cycle).
probes.av_audiograph_wires = guarded(function(ctx: any, defer: (fn: () -> ()) -> ())
	if not clientOnly(ctx) then
		return
	end
	local mix = audioSetup(ctx, {}, defer)
	ctx.env.wait(0.1)
	local report = mix:inspect()
	ctx.check("wires_connected", report.wires > 0 and report.connected == report.wires, report.broken)
	ctx.check("analyzer_built", mix:graph().nodes.Analyzer_master ~= nil)
	ctx.check(
		"listener_location_read",
		report.defaultListenerLocation ~= nil,
		{ defaultListenerLocation = report.defaultListenerLocation }
	)
end)

-- AVKit/AudioGraphRoblox: a cue played on sfx reaches master: the master AudioAnalyzer peak rises
-- above 0. The content is a built-in path whose AudioPlayer support is UNVERIFIED; a run may set
-- env.lookdevAudioContent to an approved content string instead.
probes.av_audio_master_level = guarded(function(ctx: any, defer: (fn: () -> ()) -> ())
	if not clientOnly(ctx) then
		return
	end
	local env = ctx.env
	local content = env.lookdevAudioContent or "rbxasset://sounds/action_footsteps_plastic.mp3"
	local mix = audioSetup(ctx, {
		cues = {
			probe_tone = { bus = "sfx", slot = "probe_tone", cooldown = 0, maxConcurrent = 1, volume = 0.5 },
		},
		assets = { probe_tone = content },
	}, defer)
	local voice, reason = mix:play("probe_tone")
	ctx.check("cue_admitted", voice ~= nil, reason)
	local peak = 0
	for _ = 1, 20 do
		env.wait(0.1)
		mix:step(0.1)
		peak = math.max(peak, mix:levels().peak)
	end
	ctx.check("master_peak_above_zero", peak > 0, { peak = peak, content = content })
end)

-- Feel/FeelRoblox: an animation marker fires a Feel cue; hit-stop pauses the track with
-- AdjustSpeed(0) and restores it. The animation is a local KeyframeSequence registered with
-- KeyframeSequenceProvider:RegisterKeyframeSequence (a Studio-only temporary id; nothing uploaded).
probes.feel_marker_cue = guarded(function(ctx: any, defer: (fn: () -> ()) -> ())
	if not clientOnly(ctx) then
		return
	end
	local env = ctx.env
	local lib = env.roblox
	local o = overrides(ctx)
	local FeelRoblox = ctx.kit("Feel/FeelRoblox")
	local workspace = env.services.Workspace
	local rig = lib.Instance.new("Model")
	rig.Name = "LookdevFeelRig"
	defer(function()
		rig:Destroy()
	end)
	local root = lib.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Parent = rig
	rig.PrimaryPart = root
	local controller = lib.Instance.new("AnimationController")
	controller.Parent = rig
	local animator = lib.Instance.new("Animator")
	animator.Parent = controller
	rig.Parent = workspace
	local sequence = lib.Instance.new("KeyframeSequence")
	sequence.Loop = false
	for _, time in { 0, 0.2, 0.6 } do
		local keyframe = lib.Instance.new("Keyframe")
		keyframe.Time = time
		if time == 0.2 then
			local marker = lib.Instance.new("KeyframeMarker")
			marker.Name = "Hit"
			marker.Value = "probe"
			marker.Parent = keyframe
		end
		keyframe.Parent = sequence
	end
	local provider = env.services.KeyframeSequenceProvider
	local registered, id = pcall(function()
		return provider:RegisterKeyframeSequence(sequence)
	end)
	if not ctx.check("sequence_registered", registered, if registered then nil else tostring(id)) then
		return
	end
	local animation = lib.Instance.new("Animation")
	animation.AnimationId = id
	local load = o.loadTrack or function(target: any, anim: any): any
		return target:LoadAnimation(anim)
	end
	local track = load(animator, animation)
	local fired = {}
	local feel = FeelRoblox.new(env, {
		camera = workspace.CurrentCamera,
		cues = { probe_hit = { shake = "hit_light", hitStop = 0.1, visual = "animation", priority = 5 } },
		engine = o.feel,
	})
	defer(function()
		feel:destroy()
	end)
	feel:freeze(track)
	feel:bindMarkers(track, { Hit = "probe_hit" }, function(param: any)
		table.insert(fired, tostring(param))
		return {}
	end)
	track:Play()
	local sawFreeze = false
	for _ = 1, 20 do
		env.wait(0.05)
		feel:step(0.05)
		if track.Speed == 0 then
			sawFreeze = true
		end
	end
	ctx.check("marker_fired_once", #fired == 1, fired)
	ctx.check("hit_stop_paused_track", sawFreeze)
	ctx.check("speed_restored", track.Speed == 1, track.Speed)
end)

-- GameKit/WorldCycle: phases computed from Workspace:GetServerTimeNow() apply onto Lighting with
-- ClockTime on the clock, blends between presets, and the apply rate limit. The Lighting state the
-- place had is restored afterwards.
probes.worldcycle_phases = guarded(function(ctx: any, defer: (fn: () -> ()) -> ())
	local WorldCycle = ctx.kit("GameKit/WorldCycle")
	local Lighting = ctx.kit("SceneKit/Lighting")
	local env = ctx.env
	local lighting = env.services.Lighting
	defer(keepLighting(Lighting, lighting))
	local workspace = env.services.Workspace
	local read = overrides(ctx).serverTime or function(): number
		return workspace:GetServerTimeNow()
	end
	local ok, now = pcall(read)
	ctx.check("server_time", ok and type(now) == "number", if ok then nil else tostring(now))
	if not ok then
		return
	end
	local day = WorldCycle.DEFAULT.dayLength
	local midnight = now - (now % day)
	for _, hour in { 3, 6, 12, 16.625, 18, 22 } do
		local state = WorldCycle.state(midnight + hour / 24 * day, WorldCycle.DEFAULT)
		WorldCycle.apply(lighting, state, env)
		local inspected = Lighting.inspect(lighting)
		ctx.check(
			"hour_" .. string.gsub(tostring(hour), "%.", "_"),
			math.abs(lighting.ClockTime - hour) < 1e-3
				and (if state.t > 0 then inspected.blend ~= nil else inspected.profile == state.preset.id),
			{ phase = state.phase, t = state.t, clock = lighting.ClockTime }
		)
	end
	local cycle = WorldCycle.new()
	ctx.check("rate_limited", cycle:step(now) ~= nil and cycle:step(now + 0.1) == nil)
end)

-- SceneKit/Materials tier 0: MaterialService:SetBaseMaterialOverride switches a base material to
-- an existing MaterialVariant and back. Building the variant needs plugin security (BaseMaterial),
-- so run this probe through execute_luau; a play session reports variant_built = false. The Sand
-- override the place had is put back and the variant removed afterwards.
probes.lookdev_material_override = guarded(function(ctx: any, defer: (fn: () -> ()) -> ())
	local Materials = ctx.kit("SceneKit/Materials")
	local env = ctx.env
	local lib = env.roblox
	local service = env.services.MaterialService
	if not ctx.check("material_service", service ~= nil) then
		return
	end
	local library = Materials.define({
		schema = "material-library/1",
		materials = {
			{
				name = "lookdev_probe_sand",
				base_material = "Sand",
				studs_per_tile = 8,
				pattern = "Regular",
				override_base = true,
				resolution = 1024,
				provenance = "local",
				maps = {
					color = "build:materials/lookdev_probe_sand/color.png",
					normal = nil,
					roughness = nil,
					metalness = nil,
					emissive = nil,
				},
				roblox = { color = 0, normal = 0, roughness = 0, metalness = 0 },
			},
		},
	})
	local built, variant = pcall(Materials.buildVariant, library.materials[1], env)
	if not ctx.check("variant_built", built, if built then nil else tostring(variant)) then
		return
	end
	variant.Parent = service
	defer(function()
		variant:Destroy()
	end)
	-- the object that carries the override methods (Lune specs pass a proxy; Studio uses the service)
	local api = overrides(ctx).materialApi or service
	local sand = lib.Enum.Material.Sand
	local readBefore, before = pcall(function(): any
		return api:GetBaseMaterialOverride(sand)
	end)
	defer(function()
		api:SetBaseMaterialOverride(sand, if readBefore and type(before) == "string" then before else "")
	end)
	local report = Materials.applyOverrides(api, Materials.overridePlan(library), env)
	ctx.check("override_set", #report.set == 1 and #report.failed == 0, report)
	ctx.check("override_reads_back", api:GetBaseMaterialOverride(sand) == "lookdev_probe_sand")
end)

return probes
