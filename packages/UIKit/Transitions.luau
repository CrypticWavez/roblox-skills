--!strict
-- @tier T1
-- Transitions: UI motion as data plus a runner (docs/uikit.md "Transitions"). A plan is a list of
-- tracks { node, property, from?, to, delay, duration, ease | spring }; presets build the
-- common ones (fade, slide, scalePop, wipe, iris) and sequence/parallel/stagger compose them.
-- Values are numbers or arrays of numbers (UDim2 { xs, xo, ys, yo }, Vector2 { x, y },
-- Color3 { r, g, b } 0-1), so plans are plain data that Lune checks exactly.
-- reduce(plan) is the reduced-motion form (Settings.effective().reducedMotion, which already
-- folds in GuiService.ReducedMotionEnabled): opacity tracks become short linear fades (at most
-- tokens.motion.reducedFade s), every other track jumps to its end state, and a plan with no
-- opacity track uses its reducedFade fallback. Styling transitions are not used: the runner
-- owns motion so it is interruptible.
-- The runner is steppable and never yields: runner:step(dt) advances every track and writes
-- values through an apply(target, property, value) function. A new track on a target+property
-- that is already animating interrupts the old one and starts from its current value (springs
-- also inherit its velocity), so rapid open/close never jumps. runner:attach(env) drives it from
-- RunService.PreRender (env.services); instanceApply(env) writes Roblox datatypes (T1 in Lune).
local Check = require("../GameKit/Check")
local Ease = require("./Ease")
local Env = require("../GameKit/Env")

local Transitions = {}

export type Value = number | { number }
export type Track = {
	node: string,
	property: string,
	from: Value?,
	to: Value,
	delay: number,
	duration: number,
	ease: string?,
	spring: Ease.SpringParams?,
}
export type Fallback = { node: string, property: string }
export type Plan = {
	kind: "transition",
	name: string,
	phase: string,
	duration: number,
	tracks: { Track },
	reduced: boolean,
	reducedFade: Fallback?,
}

-- Properties that only change opacity (kept under reduced motion).
Transitions.OPACITY = table.freeze({
	GroupTransparency = true,
	BackgroundTransparency = true,
	TextTransparency = true,
	TextStrokeTransparency = true,
	ImageTransparency = true,
	Transparency = true,
})

-- Roblox type per animatable property, used by instanceApply/instanceRead.
Transitions.TYPES = table.freeze({
	GroupTransparency = "number",
	BackgroundTransparency = "number",
	TextTransparency = "number",
	TextStrokeTransparency = "number",
	ImageTransparency = "number",
	Transparency = "number",
	Scale = "number",
	Rotation = "number",
	Thickness = "number",
	LineHeight = "number",
	MaxVisibleGraphemes = "integer",
	Value = "number", -- NumberValue, or a component's proxy table (RollingCounter)
	Position = "UDim2",
	Size = "UDim2",
	AnchorPoint = "Vector2",
	Offset = "Vector2",
	CanvasPosition = "Vector2",
	BackgroundColor3 = "Color3",
	TextColor3 = "Color3",
	GroupColor3 = "Color3",
	ImageColor3 = "Color3",
	Color = "Color3",
})

local DEFAULT_DURATION = 0.2
local DEFAULT_REDUCED_FADE = 0.15
local MAX_TRACKS = 256

local function isValue(value: any): boolean
	if Check.finite(value) then
		return true
	end
	if type(value) ~= "table" or #value == 0 or #value > 4 then
		return false
	end
	for _, item in value do
		if not Check.finite(item) then
			return false
		end
	end
	return true
end

local function sameShape(a: Value, b: Value): boolean
	if type(a) == "number" then
		return type(b) == "number"
	end
	return type(b) == "table" and #(a :: { number }) == #(b :: { number })
end

-- Problems with a plan (empty when valid).
function Transitions.validate(plan: any): { string }
	if type(plan) ~= "table" or plan.kind ~= "transition" then
		return { "plan must be a transition table" }
	end
	local problems = {}
	if type(plan.tracks) ~= "table" then
		return { "plan.tracks must be a list" }
	end
	if #plan.tracks > MAX_TRACKS then
		table.insert(problems, "more than " .. MAX_TRACKS .. " tracks")
	end
	local longest = 0
	for index, track in plan.tracks do
		local where = "tracks[" .. index .. "]"
		if type(track.node) ~= "string" or track.node == "" then
			table.insert(problems, where .. ".node must be a binding name")
		end
		if type(track.property) ~= "string" or track.property == "" then
			table.insert(problems, where .. ".property must be a property name")
		end
		if not isValue(track.to) then
			table.insert(problems, where .. ".to must be a number or a list of 1-4 numbers")
		elseif track.from ~= nil and (not isValue(track.from) or not sameShape(track.from, track.to)) then
			table.insert(problems, where .. ".from must match the shape of .to")
		end
		if not (Check.finite(track.delay) and track.delay >= 0) then
			table.insert(problems, where .. ".delay must be >= 0")
		end
		if not (Check.finite(track.duration) and track.duration >= 0) then
			table.insert(problems, where .. ".duration must be >= 0")
		end
		if track.spring ~= nil then
			if track.ease ~= nil then
				table.insert(problems, where .. ": use ease or spring, not both")
			elseif not Ease.validSpring(track.spring) then
				table.insert(problems, where .. ".spring needs dampingRatio > 0 and frequency > 0")
			end
		elseif track.ease ~= nil and not Ease.valid(track.ease) then
			table.insert(problems, where .. ".ease " .. tostring(track.ease) .. " is not Style.Direction")
		end
		if Check.finite(track.delay) and Check.finite(track.duration) then
			longest = math.max(longest, track.delay + track.duration)
		end
	end
	if not (Check.finite(plan.duration) and math.abs(plan.duration - longest) < 1e-9) then
		table.insert(problems, string.format("duration must equal the longest track end (%.3f)", longest))
	end
	return problems
end

local function finalize(name: string, phase: string, tracks: { Track }, reducedFade: Fallback?): Plan
	local longest = 0
	for _, track in tracks do
		longest = math.max(longest, track.delay + track.duration)
	end
	local plan: Plan = {
		kind = "transition",
		name = name,
		phase = phase,
		duration = longest,
		tracks = tracks,
		reduced = false,
		reducedFade = reducedFade,
	}
	local problems = Transitions.validate(plan)
	if #problems > 0 then
		error("Transitions." .. name .. ": " .. table.concat(problems, "; "), 3)
	end
	return plan
end

local function springDuration(spring: Ease.SpringParams): number
	return Ease.spring(spring).settle(0, 1e-3)
end

local function track(node: string, property: string, from: Value?, to: Value, options: any): Track
	local spring = options.spring
	return {
		node = node,
		property = property,
		from = from,
		to = to,
		delay = options.delay or 0,
		duration = if spring then springDuration(spring) else (options.duration or DEFAULT_DURATION),
		ease = if spring then nil else (options.ease or "Quint.Out"),
		spring = spring,
	}
end

local function phaseOf(options: any): string
	local phase = options.phase or "in"
	if phase ~= "in" and phase ~= "out" then
		error("Transitions: phase must be in or out", 3)
	end
	return phase
end

export type Options = {
	phase: ("in" | "out")?,
	duration: number?,
	delay: number?,
	ease: string?,
	spring: Ease.SpringParams?,
	node: string?,
	property: string?,
	fade: boolean?,
}

-- Opacity 1 -> 0 (in) or 0 -> 1 (out) on node.property (default root.GroupTransparency, a
-- CanvasGroup, so children fade together).
function Transitions.fade(options: Options?): Plan
	local o: any = options or {}
	local phase = phaseOf(o)
	local node, property = o.node or "root", o.property or "GroupTransparency"
	local from, to = if phase == "in" then 1 else 0, if phase == "in" then 0 else 1
	local ease = o.ease or (if phase == "in" then "Quad.Out" else "Quad.In")
	return finalize(
		"fade",
		phase,
		{ track(node, property, from, to, { delay = o.delay, duration = o.duration, ease = ease }) },
		{ node = node, property = property }
	)
end

-- Position from base offset by distance px toward side (bottom, top, left, right), plus a fade
-- unless fade = false. base is the resting UDim2 { xs, xo, ys, yo }.
function Transitions.slide(options: Options & { from: string?, distance: number?, base: { number }? }): Plan
	local o: any = options
	local phase = phaseOf(o)
	local base = o.base or { 0, 0, 0, 0 }
	assert(type(base) == "table" and #base == 4, "Transitions.slide: base must be a UDim2 { xs, xo, ys, yo }")
	local distance = o.distance or 24
	local side = o.from or "bottom"
	local dx, dy = 0, 0
	if side == "bottom" then
		dy = distance
	elseif side == "top" then
		dy = -distance
	elseif side == "left" then
		dx = -distance
	elseif side == "right" then
		dx = distance
	else
		error("Transitions.slide: from must be bottom, top, left or right", 2)
	end
	local away = { base[1], base[2] + dx, base[3], base[4] + dy }
	local rest = { base[1], base[2], base[3], base[4] }
	local tracks = {
		track(
			o.node or "root",
			"Position",
			if phase == "in" then away else rest,
			if phase == "in" then rest else away,
			{
				delay = o.delay,
				duration = o.duration,
				ease = o.ease or (if phase == "in" then "Quint.Out" else "Quad.In"),
				spring = o.spring,
			}
		),
	}
	if o.fade ~= false then
		local fade = Transitions.fade({
			phase = phase,
			delay = o.delay,
			duration = o.duration,
			node = o.fadeNode or o.node or "root",
		})
		table.insert(tracks, fade.tracks[1])
	end
	return finalize(
		"slide",
		phase,
		tracks,
		{ node = o.fadeNode or o.node or "root", property = "GroupTransparency" }
	)
end

-- UIScale.Scale from `from` (default 0.92) to 1 (in) or back (out) on node "scale", with a
-- Back.Out ease or a spring, plus a fade on node "root" unless fade = false.
function Transitions.scalePop(options: Options & { from: number?, scaleNode: string? }): Plan
	local o: any = options or {}
	local phase = phaseOf(o)
	local small = o.from or 0.92
	local scaleNode = o.scaleNode or "scale"
	local tracks = {
		track(scaleNode, "Scale", if phase == "in" then small else 1, if phase == "in" then 1 else small, {
			delay = o.delay,
			duration = o.duration,
			ease = o.ease or (if phase == "in" then "Back.Out" else "Quad.In"),
			spring = o.spring,
		}),
	}
	if o.fade ~= false then
		table.insert(
			tracks,
			Transitions.fade({
				phase = phase,
				delay = o.delay,
				duration = o.duration,
				node = o.node or "root",
			}).tracks[1]
		)
	end
	return finalize("scalePop", phase, tracks, { node = o.node or "root", property = "GroupTransparency" })
end

-- UIGradient.Offset sweep on node "gradient": a hard-edged transparency gradient (opaque half,
-- clear half; the component sets the NumberSequence and Rotation for the direction) moves
-- from -0.5 (hidden) to 0.5 (shown) on X. reducedFade falls back to root.GroupTransparency.
function Transitions.wipe(options: Options?): Plan
	local o: any = options or {}
	local phase = phaseOf(o)
	local hidden, shown = { -0.5, 0 }, { 0.5, 0 }
	return finalize("wipe", phase, {
		track(
			o.node or "gradient",
			"Offset",
			if phase == "in" then hidden else shown,
			if phase == "in" then shown else hidden,
			{
				delay = o.delay,
				duration = o.duration or 0.35,
				ease = o.ease or "Cubic.InOut",
			}
		),
	}, { node = o.fadeNode or "root", property = "GroupTransparency" })
end

-- Iris: node "iris" is a circle (UICorner pill) whose huge UIStroke covers the screen outside
-- it; Size grows from 0 to `size` px (in = opening) or shrinks to 0 (out = closing). Under
-- reduced motion it becomes a fade of node "cover".
function Transitions.iris(options: Options & { size: number, coverNode: string? }): Plan
	local o: any = options
	local phase = phaseOf(o)
	assert(Check.finite(o.size) and o.size > 0, "Transitions.iris: size must be the open diameter in px")
	local closed, open = { 0, 0, 0, 0 }, { 0, o.size, 0, o.size }
	return finalize("iris", phase, {
		track(
			o.node or "iris",
			"Size",
			if phase == "in" then closed else open,
			if phase == "in" then open else closed,
			{
				delay = o.delay,
				duration = o.duration or 0.5,
				ease = o.ease or (if phase == "in" then "Quart.Out" else "Quart.In"),
			}
		),
	}, { node = o.coverNode or "cover", property = "BackgroundTransparency" })
end

-- Plans one after another (each starts gap s after the previous ends).
function Transitions.sequence(plans: { Plan }, gap: number?): Plan
	assert(type(plans) == "table" and #plans > 0, "Transitions.sequence: needs plans")
	local tracks = {}
	local offset = 0
	for _, plan in plans do
		for _, item in plan.tracks do
			local copy = table.clone(item)
			copy.delay += offset
			table.insert(tracks, copy)
		end
		offset += plan.duration + (gap or 0)
	end
	return finalize("sequence", plans[#plans].phase, tracks, plans[1].reducedFade)
end

-- Plans at the same time.
function Transitions.parallel(plans: { Plan }): Plan
	assert(type(plans) == "table" and #plans > 0, "Transitions.parallel: needs plans")
	local tracks = {}
	for _, plan in plans do
		for _, item in plan.tracks do
			table.insert(tracks, table.clone(item))
		end
	end
	return finalize("parallel", plans[1].phase, tracks, plans[1].reducedFade)
end

-- The plan repeated for count nodes named nodeFormat:format(i) ("item_%d"), each delayed by step s.
function Transitions.stagger(plan: Plan, count: number, step: number, nodeFormat: string): Plan
	assert(Check.integer(count) and count >= 1 and count <= 64, "Transitions.stagger: count must be 1-64")
	assert(Check.finite(step) and step >= 0, "Transitions.stagger: step must be >= 0")
	local tracks = {}
	for index = 1, count do
		for _, item in plan.tracks do
			local copy = table.clone(item)
			copy.node = string.format(nodeFormat, index)
			copy.delay += (index - 1) * step
			table.insert(tracks, copy)
		end
	end
	return finalize("stagger", plan.phase, tracks, nil)
end

-- The reduced-motion form of a plan: opacity tracks become linear fades of at most `fade` s
-- with no delay; other tracks jump to their end state (duration 0); with no opacity track the
-- plan's reducedFade fallback fades instead. instant = true makes every track 0 s.
function Transitions.reduce(plan: Plan, fade: number?, instant: boolean?): Plan
	local limit = if instant then 0 else (fade or DEFAULT_REDUCED_FADE)
	local tracks: { Track } = {}
	local seen: { [string]: boolean } = {}
	local hasOpacity = false
	for _, item in plan.tracks do
		local key = item.node .. "\0" .. item.property
		if seen[key] then
			continue -- staggered or sequenced repeats collapse to one change
		end
		seen[key] = true
		local copy = table.clone(item)
		copy.delay = 0
		copy.spring = nil
		if Transitions.OPACITY[item.property] then
			hasOpacity = true
			copy.duration = math.min(item.duration, limit)
			copy.ease = "Linear.In"
		else
			copy.duration = 0
			copy.ease = "Linear.In"
		end
		table.insert(tracks, copy)
	end
	if not hasOpacity and plan.reducedFade then
		local fallback = plan.reducedFade :: Fallback
		local phaseIn = plan.phase ~= "out"
		table.insert(tracks, {
			node = fallback.node,
			property = fallback.property,
			from = if phaseIn then 1 else 0,
			to = if phaseIn then 0 else 1,
			delay = 0,
			duration = limit,
			ease = "Linear.In",
		})
	end
	local reduced = finalize(plan.name, plan.phase, tracks, plan.reducedFade)
	reduced.reduced = true
	return reduced
end

-- One track (spring options give it the spring's settle time as duration). For component
-- motion that the presets do not cover; combine with Transitions.make.
function Transitions.track(node: string, property: string, from: Value?, to: Value, options: Options?): Track
	return track(node, property, from, to, options or {})
end

-- A validated plan from tracks (duration is the longest track end).
function Transitions.make(name: string, phase: string, tracks: { Track }, reducedFade: Fallback?): Plan
	assert(type(name) == "string" and name ~= "", "Transitions.make: needs a name")
	assert(phase == "in" or phase == "out", "Transitions.make: phase must be in or out")
	return finalize(name, phase, tracks, reducedFade)
end

local PRESETS: { [string]: (any) -> Plan } = {
	fade = Transitions.fade,
	slide = Transitions.slide,
	scalePop = Transitions.scalePop,
	wipe = Transitions.wipe,
	iris = Transitions.iris,
}

export type Motion = { reducedMotion: boolean?, reducedFade: number?, instant: boolean? }

-- A preset by name, reduced when motion.reducedMotion (pass Settings.effective(...)).
function Transitions.plan(name: string, options: any, motion: Motion?): Plan
	local preset = PRESETS[name]
	if preset == nil then
		error("Transitions.plan: unknown preset " .. tostring(name), 2)
	end
	local plan = preset(options or {})
	if motion and motion.reducedMotion then
		return Transitions.reduce(plan, motion.reducedFade, motion.instant)
	end
	return plan
end

-- ------------------------------------------------------------------ sampling

local function lerpValue(a: Value, b: Value, alpha: number): Value
	if type(a) == "number" then
		return a + ((b :: number) - a) * alpha
	end
	local out = table.create(#(a :: { number }))
	for index, item in a :: { number } do
		out[index] = item + ((b :: { number })[index] - item) * alpha
	end
	return out
end

local function copyValue(value: Value): Value
	if type(value) == "number" then
		return value
	end
	return table.clone(value :: { number })
end

-- The value of a track local time t after its delay (t clamped to 0..duration); v0 is the
-- per-component initial velocity for spring tracks (value units per second).
function Transitions.valueAt(item: Track, from: Value, t: number, v0: Value?): Value
	if item.duration <= 0 or t >= item.duration then
		return copyValue(item.to)
	end
	if t <= 0 then
		return copyValue(from)
	end
	if item.spring then
		local spring = Ease.spring(item.spring)
		if type(from) == "number" then
			local span = (item.to :: number) - from
			local nv = if span ~= 0 and type(v0) == "number" then v0 / span else 0
			local x = spring.at(t, nv)
			return from + span * x
		end
		local out = table.create(#(from :: { number }))
		for index, start in from :: { number } do
			local span = (item.to :: { number })[index] - start
			local velocity = if type(v0) == "table" then v0[index] or 0 else 0
			local nv = if span ~= 0 then velocity / span else 0
			out[index] = start + span * (spring.at(t, nv))
		end
		return out
	end
	local style, direction = Ease.parse(item.ease or "Linear.In")
	return lerpValue(from, item.to, Ease.get(style, direction, t / item.duration))
end

-- ------------------------------------------------------------------ runner

export type Handle = {
	state: (self: Handle) -> string,
	cancel: (self: Handle) -> (),
	finish: (self: Handle) -> (),
	plan: Plan,
}

type Active = {
	handle: any,
	track: Track,
	target: any,
	from: Value?,
	elapsed: number,
	started: boolean,
	velocity0: Value?,
	value: Value?,
	velocity: Value?,
	done: boolean,
}

type HandleState = {
	plan: Plan,
	state: string,
	remaining: number,
	onComplete: ((state: string) -> ())?,
	actives: { Active },
}

export type Runner = {
	play: (self: Runner, plan: Plan, bindings: { [string]: any }, options: PlayOptions?) -> Handle,
	step: (self: Runner, dt: number) -> (),
	attach: (self: Runner, env: any) -> any,
	count: (self: Runner) -> number,
	current: (self: Runner, target: any, property: string) -> Value?,
	stop: (self: Runner, target: any) -> (),
}
export type PlayOptions = { onComplete: ((state: string) -> ())?, fill: boolean? }

-- A runner writing values with apply(target, property, value). read(target, property) (optional)
-- supplies `from` for tracks that leave it nil and nothing is animating that property yet.
-- env.report (optional) receives onComplete errors.
function Transitions.runner(
	apply: (target: any, property: string, value: Value) -> (),
	read: ((target: any, property: string) -> Value?)?,
	env: any?
): Runner
	assert(type(apply) == "function", "Transitions.runner: apply must be a function")
	local channels: { [any]: { [string]: Active } } = setmetatable({}, { __mode = "k" }) :: any
	local actives: { Active } = {}
	local runner: any = {}

	local function report(message: string)
		if env and type(env.report) == "function" then
			env.report(message)
		else
			warn(message)
		end
	end

	local function settle(handle: HandleState, state: string)
		if handle.state ~= "playing" then
			return
		end
		handle.state = state
		if handle.onComplete then
			local ok, err = pcall(handle.onComplete :: any, state)
			if not ok then
				report("Transitions onComplete error: " .. tostring(err))
			end
		end
	end

	local function release(active: Active)
		if active.done then
			return
		end
		active.done = true
		local channel = channels[active.target]
		if channel and channel[active.track.property] == active then
			channel[active.track.property] = nil
		end
		local handle = active.handle :: HandleState
		handle.remaining -= 1
	end

	local function write(active: Active, value: Value)
		active.value = value
		local ok, err = pcall(apply, active.target, active.track.property, value)
		if not ok then
			report("Transitions apply error: " .. tostring(err))
		end
	end

	local function start(active: Active)
		active.started = true
		local channel = channels[active.target]
		if channel == nil then
			channel = {}
			channels[active.target] = channel
		end
		local property = active.track.property
		local previous = channel[property]
		if previous and previous ~= active and not previous.done then
			-- Interrupt: continue from where the old track is, with its velocity.
			if previous.value ~= nil and sameShape(previous.value :: Value, active.track.to) then
				active.from = copyValue(previous.value :: Value)
				active.velocity0 = previous.velocity
			end
			local oldHandle = previous.handle :: HandleState
			release(previous)
			if oldHandle.remaining <= 0 then
				settle(oldHandle, "interrupted")
			end
		end
		if active.from == nil then
			active.from = active.track.from
		end
		if active.from == nil and read then
			local ok, value = pcall(read, active.target, property)
			if ok and value ~= nil and isValue(value) and sameShape(value, active.track.to) then
				active.from = value
			end
		end
		if active.from == nil then
			active.from = copyValue(active.track.to)
		end
		channel[property] = active
	end

	local function advance(active: Active, dt: number)
		if active.done then
			return
		end
		local item = active.track
		local before = active.elapsed
		active.elapsed += dt
		if not active.started then
			if active.elapsed < item.delay then
				return
			end
			start(active)
		end
		local t = active.elapsed - item.delay
		local value = Transitions.valueAt(item, active.from :: Value, t, active.velocity0)
		local previous = active.value
		write(active, value)
		local local0 = before - item.delay
		if previous ~= nil and dt > 0 and local0 >= 0 then
			if type(value) == "number" and type(previous) == "number" then
				active.velocity = (value - previous) / dt
			elseif type(value) == "table" and type(previous) == "table" then
				local velocity = {}
				for index, item2 in value do
					velocity[index] = (item2 - (previous[index] or item2)) / dt
				end
				active.velocity = velocity
			end
		end
		if t >= item.duration then
			release(active)
		end
	end

	function runner.play(_self: any, plan: Plan, bindings: { [string]: any }, options: PlayOptions?): Handle
		local problems = Transitions.validate(plan)
		if #problems > 0 then
			error("Transitions runner: " .. table.concat(problems, "; "), 2)
		end
		assert(type(bindings) == "table", "Transitions runner: bindings must map node names to targets")
		local handle: HandleState = {
			plan = plan,
			state = "playing",
			remaining = 0,
			onComplete = options and options.onComplete,
			actives = {},
		}
		local fill = not (options and options.fill == false)
		for _, item in plan.tracks do
			local target = bindings[item.node]
			if target == nil then
				error("Transitions runner: no binding for node " .. item.node, 2)
			end
			local active: Active = {
				handle = handle,
				track = item,
				target = target,
				from = nil,
				elapsed = 0,
				started = false,
				velocity0 = nil,
				value = nil,
				velocity = nil,
				done = false,
			}
			handle.remaining += 1
			table.insert(handle.actives, active)
		end
		-- Start every undelayed track now (interrupting older ones); delayed tracks show their
		-- start value until their delay passes when fill is on.
		for _, active in handle.actives do
			if active.track.delay <= 0 then
				start(active)
				write(active, Transitions.valueAt(active.track, active.from :: Value, 0, active.velocity0))
				if active.track.duration <= 0 then
					release(active)
				end
			elseif fill and active.track.from ~= nil then
				local current = channels[active.target] and channels[active.target][active.track.property]
				if current == nil then
					write(active, copyValue(active.track.from :: Value))
				end
			end
			if not active.done then
				table.insert(actives, active)
			end
		end
		if handle.remaining <= 0 then
			settle(handle, "completed")
		end
		local public: any = { plan = plan }
		function public.state(_s: any): string
			return handle.state
		end
		function public.cancel(_s: any)
			if handle.state ~= "playing" then
				return
			end
			for _, active in handle.actives do
				release(active)
			end
			settle(handle, "cancelled")
		end
		function public.finish(_s: any)
			if handle.state ~= "playing" then
				return
			end
			for _, active in handle.actives do
				if not active.done then
					if not active.started then
						start(active)
					end
					write(active, copyValue(active.track.to))
					release(active)
				end
			end
			settle(handle, "completed")
		end
		return public
	end

	function runner.step(_self: any, dt: number)
		if not (Check.finite(dt) and dt >= 0) then
			error("Transitions runner: dt must be a finite number >= 0", 2)
		end
		local list = actives
		actives = {}
		local finished: { HandleState } = {}
		for _, active in list do
			local handle = active.handle :: HandleState
			if handle.state ~= "playing" or active.done then
				continue
			end
			advance(active, dt)
			if not active.done then
				table.insert(actives, active)
			elseif handle.remaining <= 0 and not table.find(finished, handle) then
				table.insert(finished, handle)
			end
		end
		for _, handle in finished do
			settle(handle, "completed")
		end
	end

	function runner.attach(self: any, attachEnv: any): any
		local runService = Env.service(attachEnv, "RunService")
		return runService.PreRender:Connect(function(dt: number)
			self:step(dt)
		end)
	end

	-- Tracks still running (finished, cancelled and stopped ones are not counted, even before
	-- the next step prunes them).
	function runner.count(_self: any): number
		local live = 0
		for _, active in actives do
			if not active.done and (active.handle :: HandleState).state == "playing" then
				live += 1
			end
		end
		return live
	end

	function runner.current(_self: any, target: any, property: string): Value?
		local channel = channels[target]
		local active = channel and channel[property]
		return active and active.value
	end

	-- Cancels every track on target (the handles report cancelled when nothing remains).
	function runner.stop(_self: any, target: any)
		for _, active in table.clone(actives) do
			if active.target == target and not active.done then
				local handle = active.handle :: HandleState
				release(active)
				if handle.remaining <= 0 then
					settle(handle, "cancelled")
				end
			end
		end
	end

	return runner
end

-- ------------------------------------------------------------------ Roblox values

local function toRoblox(r: any, kind: string, value: Value): any
	if kind == "number" then
		return value
	elseif kind == "integer" then
		return math.round(value :: number)
	end
	local v = value :: { number }
	if kind == "UDim2" then
		return r.UDim2.new(v[1], v[2], v[3], v[4])
	elseif kind == "Vector2" then
		return r.Vector2.new(v[1], v[2])
	elseif kind == "Color3" then
		return r.Color3.new(v[1], v[2], v[3])
	end
	error("Transitions: cannot convert to " .. kind, 2)
end

local function fromRoblox(kind: string, value: any): Value?
	if kind == "number" or kind == "integer" then
		return if type(value) == "number" then value else nil
	elseif kind == "UDim2" then
		return { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset }
	elseif kind == "Vector2" then
		return { value.X, value.Y }
	elseif kind == "Color3" then
		return { value.R, value.G, value.B }
	end
	return nil
end

-- apply(target, property, value) for Instances: converts arrays to UDim2, Vector2 or Color3 by
-- property (Transitions.TYPES) with env.roblox datatypes.
function Transitions.instanceApply(env: any): (any, string, Value) -> ()
	local r = env and env.roblox
	assert(r, "Transitions.instanceApply: env.roblox is required")
	return function(target: any, property: string, value: Value)
		local kind = Transitions.TYPES[property]
		if kind == nil then
			error(
				"Transitions: " .. property .. " is not an animatable property (add it to Transitions.TYPES)"
			)
		end
		target[property] = toRoblox(r, kind, value)
	end
end

-- read(target, property) for Instances (nil for unknown properties).
function Transitions.instanceRead(): (any, string) -> Value?
	return function(target: any, property: string): Value?
		local kind = Transitions.TYPES[property]
		if kind == nil then
			return nil
		end
		return fromRoblox(kind, target[property])
	end
end

return Transitions
