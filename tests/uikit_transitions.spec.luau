--!strict
-- G4 specs: UIKit/Ease (Enum parity of names and values, exact endpoints, the uikit-ease golden,
-- the closed-form spring), UIKit/Transitions (validation, presets, composition, reduced-motion
-- collapse, the steppable runner with interruption and velocity hand-off, Instance values),
-- UIKit/State (glitch-free propagation, batching, scope cleanup) and Build.play/Build.after.
-- Whether Ease matches TweenService:GetValue is probe ui_ease_parity.
local roblox = require("@lune/roblox")

local Build = require("../packages/UIKit/Build")
local Ease = require("../packages/UIKit/Ease")
local Scope = require("../packages/GameKit/Scope")
local State = require("../packages/UIKit/State")
local Transitions = require("../packages/UIKit/Transitions")
local FakeEnv = require("./fakes/FakeEnv")
local Golden = require("./lib/Golden")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function round6(x: number): number
	local r = math.round(x * 1e6) / 1e6
	return if r == 0 then 0 else r -- no -0 in the golden
end

-- A runner that records writes into plain tables.
local function recorder(): (any, { [any]: { [string]: any } })
	local values: { [any]: { [string]: any } } = {}
	local runner = Transitions.runner(function(target, property, value)
		values[target] = values[target] or {}
		values[target][property] = value
	end)
	return runner, values
end

-- ---------------------------------------------------------------- Ease

test("Ease style and direction values match Enum.EasingStyle and Enum.EasingDirection", function(t)
	for name, value in Ease.STYLES do
		t.eq((roblox.Enum.EasingStyle :: any)[name].Value, value, name)
	end
	for name, value in Ease.DIRECTIONS do
		t.eq((roblox.Enum.EasingDirection :: any)[name].Value, value, name)
	end
	t.eq(#Ease.STYLE_NAMES, #roblox.Enum.EasingStyle:GetEnumItems(), "every EasingStyle is covered")
	-- Names, values and EnumItems address the same curve.
	local byName = Ease.get("Quad", "Out", 0.3)
	t.eq(Ease.get(3, 1, 0.3), byName)
	t.eq(Ease.get(roblox.Enum.EasingStyle.Quad, roblox.Enum.EasingDirection.Out, 0.3), byName)
end)

test("every curve is exact at 0 and 1, clamps alpha and InOut is symmetric", function(t)
	for _, style in Ease.STYLE_NAMES do
		for _, direction in Ease.DIRECTION_NAMES do
			local where = style .. "." .. direction
			t.eq(Ease.get(style, direction, 0), 0, where .. " at 0")
			t.eq(Ease.get(style, direction, 1), 1, where .. " at 1")
			t.eq(Ease.get(style, direction, -3), 0, where .. " clamps below")
			t.eq(Ease.get(style, direction, 7), 1, where .. " clamps above")
		end
		for _, alpha in { 0.1, 0.25, 0.4 } do
			t.near(Ease.get(style, "InOut", alpha) + Ease.get(style, "InOut", 1 - alpha), 1, 1e-9, style)
		end
	end
	t.near(Ease.get("Quad", "In", 0.5), 0.25, 1e-12)
	t.near(Ease.get("Quad", "Out", 0.5), 0.75, 1e-12)
	t.near(Ease.get("Linear", "InOut", 0.37), 0.37, 1e-12)
	t.ok(Ease.get("Back", "Out", 0.6) > 1, "Back.Out overshoots")
	t.ok(Ease.bounded("Quint.Out") and not Ease.bounded("Back.Out") and not Ease.bounded("Elastic.In"))
end)

test("Ease rejects unknown names and NaN alpha", function(t)
	t.ok(string.find(
		errorText(function()
			Ease.get("Wobble", "In", 0.5)
		end),
		"unknown EasingStyle Wobble",
		1,
		true
	))
	t.ok(string.find(
		errorText(function()
			Ease.get("Quad", "Sideways", 0.5)
		end),
		"unknown EasingDirection Sideways",
		1,
		true
	))
	t.throws(function()
		Ease.get("Quad", "In", 0 / 0)
	end)
	t.eq({ Ease.parse("Quad.Out") }, { "Quad", "Out" })
	t.eq({ Ease.parse("Linear") }, { "Linear", "In" })
	t.eq({ Ease.parse("Quad.Up") }, {})
	t.ok(not Ease.valid(42))
	t.throws(function()
		Ease.curve("Quad-Out")
	end)
	t.throws(function()
		Ease.sample("Quad.Out", 0)
	end)
end)

test("golden uikit-ease: 21 samples of every style and direction", function(t)
	local curves: { [string]: { number } } = {}
	for _, style in Ease.STYLE_NAMES do
		for _, direction in Ease.DIRECTION_NAMES do
			local samples = Ease.sample(style .. "." .. direction, 20)
			for index, value in samples do
				samples[index] = round6(value)
			end
			curves[style .. "." .. direction] = samples
		end
	end
	local springs: { [string]: { number } } = {}
	for name, params in { gentle = { 1, 3 }, snappy = { 0.82, 5 }, bouncy = { 0.55, 4 } } do
		local spring = Ease.spring({ dampingRatio = params[1], frequency = params[2] })
		local samples = {}
		for index = 0, 20 do
			table.insert(samples, round6((spring.at(index / 40))))
		end
		springs[name] = samples
	end
	local ok, message =
		Golden.check("uikit-ease", { schema = "uikit-ease/1", curves = curves, springs = springs })
	t.ok(ok, message)
end)

test("springs: critical damping never overshoots, low damping does, settle is bounded", function(t)
	local critical = Ease.spring({ dampingRatio = 1, frequency = 3 })
	local peak = 0
	for index = 1, 300 do
		peak = math.max(peak, (critical.at(index / 100)))
	end
	t.ok(peak <= 1 + 1e-9, "critical spring overshot: " .. peak)
	local bouncy = Ease.spring({ dampingRatio = 0.4, frequency = 4 })
	local over = 0
	for index = 1, 300 do
		over = math.max(over, (bouncy.at(index / 100)))
	end
	t.ok(over > 1.1, "a 0.4 damping ratio overshoots")
	t.eq({ bouncy.at(0) }, { 0, 0 })
	local x, v = critical.at(0, 5)
	t.eq({ x, v }, { 0, 5 }, "initial velocity is kept at t = 0")
	t.ok(critical.settle() > 0.2 and critical.settle() < 1.5, "3 Hz critical settles within a second or so")
	local over1 = Ease.spring({ dampingRatio = 2, frequency = 2 })
	t.near((over1.at(5)), 1, 1e-3, "over-damped converges")
	for _, bad in
		{
			{ dampingRatio = 0, frequency = 2 },
			{ dampingRatio = 1, frequency = -1 },
			{ dampingRatio = 0 / 0, frequency = 1 },
		}
	do
		t.throws(function()
			Ease.spring(bad :: any)
		end)
	end
end)

-- ---------------------------------------------------------------- plans

test("presets build valid plans with durations equal to their longest track", function(t)
	for _, plan in
		{
			Transitions.fade(),
			Transitions.fade({ phase = "out", duration = 0.3, delay = 0.1 }),
			Transitions.slide({ from = "left", distance = 40, base = { 0.5, 0, 0.5, 0 } }),
			Transitions.scalePop({ spring = { dampingRatio = 0.6, frequency = 4 } }),
			Transitions.wipe(),
			Transitions.iris({ size = 2000 }),
		}
	do
		t.eq(Transitions.validate(plan), {}, plan.name)
	end
	local fade = Transitions.fade({ phase = "out", duration = 0.3, delay = 0.1 })
	t.near(fade.duration, 0.4, 1e-12)
	t.eq({ fade.tracks[1].from, fade.tracks[1].to }, { 0, 1 })
	local slide = Transitions.slide({ from = "left", distance = 40, base = { 0.5, 0, 0.5, 0 } })
	t.eq(slide.tracks[1].from, { 0.5, -40, 0.5, 0 })
	t.eq(slide.tracks[1].to, { 0.5, 0, 0.5, 0 })
	t.eq(#slide.tracks, 2, "slide fades too")
	local pop = Transitions.scalePop({ spring = { dampingRatio = 0.6, frequency = 4 } })
	t.eq(pop.tracks[1].ease, nil, "spring tracks have no ease")
	t.ok(pop.tracks[1].duration > 0.3, "spring duration is its settle time")
	t.throws(function()
		Transitions.slide({ from = "diagonal" } :: any)
	end)
	t.throws(function()
		Transitions.fade({ phase = "sideways" } :: any)
	end)
	t.throws(function()
		Transitions.plan("explode", {})
	end)
end)

test("validate names every broken track field", function(t)
	t.eq(Transitions.validate({}), { "plan must be a transition table" })
	local problems = Transitions.validate({
		kind = "transition",
		duration = 1,
		tracks = {
			{ node = "", property = "Size", to = { 1, 2 }, from = { 1 }, delay = 0, duration = 1 },
			{ node = "a", property = "", to = "x", delay = -1, duration = 0 / 0 },
			{
				node = "a",
				property = "Scale",
				to = 1,
				delay = 0,
				duration = 1,
				ease = "Quad.Out",
				spring = { dampingRatio = 1, frequency = 1 },
			},
			{ node = "a", property = "Scale", to = 1, delay = 0, duration = 1, ease = "Bounce.Sideways" },
		},
	})
	t.ok(contains(problems, "tracks[1].node must be a binding name"))
	t.ok(contains(problems, "tracks[1].from must match the shape of .to"))
	t.ok(contains(problems, "tracks[2].property must be a property name"))
	t.ok(contains(problems, "tracks[2].to must be a number or a list of 1-4 numbers"))
	t.ok(contains(problems, "tracks[2].delay must be >= 0"))
	t.ok(contains(problems, "tracks[2].duration must be >= 0"))
	t.ok(contains(problems, "tracks[3]: use ease or spring, not both"))
	t.ok(contains(problems, "tracks[4].ease Bounce.Sideways is not Style.Direction"))
	local wrong = Transitions.fade()
	local copy: any = table.clone(wrong)
	copy.duration = 9
	t.ok(contains(Transitions.validate(copy), "duration must equal the longest track end"))
end)

test("sequence, parallel and stagger offset delays and keep the reduced-motion fallback", function(t)
	local a = Transitions.fade({ duration = 0.2 })
	local b = Transitions.scalePop({ duration = 0.3, fade = false })
	local seq = Transitions.sequence({ a, b }, 0.05)
	t.near(seq.tracks[2].delay, 0.25, 1e-12)
	t.near(seq.duration, 0.55, 1e-12)
	local par = Transitions.parallel({ a, b })
	t.near(par.duration, 0.3, 1e-12)
	local stag = Transitions.stagger(a, 4, 0.05, "item_%d")
	t.eq(#stag.tracks, 4)
	t.eq(stag.tracks[4].node, "item_4")
	t.near(stag.tracks[4].delay, 0.15, 1e-12)
	t.throws(function()
		Transitions.stagger(a, 0, 0.05, "item_%d")
	end)
	t.throws(function()
		Transitions.sequence({})
	end)
end)

test("reducedMotion collapse: fades stay (short, linear, undelayed), motion jumps to its end", function(t)
	local slide = Transitions.slide({ duration = 0.4, delay = 0.2 })
	local reduced = Transitions.reduce(slide, 0.15)
	t.ok(reduced.reduced)
	t.eq(Transitions.validate(reduced), {})
	local byProperty = {}
	for _, item in reduced.tracks do
		byProperty[item.property] = item
	end
	t.eq(byProperty.Position.duration, 0, "position jumps")
	t.eq(byProperty.Position.delay, 0)
	t.eq(byProperty.GroupTransparency.duration, 0.15, "fade capped at reducedFade")
	t.eq(byProperty.GroupTransparency.ease, "Linear.In")
	t.near(reduced.duration, 0.15, 1e-12)
	-- No opacity track: the plan's fallback fades instead (wipe -> root.GroupTransparency).
	local wipe = Transitions.reduce(Transitions.wipe(), 0.1)
	t.eq(#wipe.tracks, 2)
	t.eq(wipe.tracks[2].property, "GroupTransparency")
	t.eq({ wipe.tracks[2].from, wipe.tracks[2].to }, { 1, 0 })
	local irisOut = Transitions.reduce(Transitions.iris({ size = 100, phase = "out" }))
	t.eq(irisOut.tracks[2].node, "cover")
	t.eq({ irisOut.tracks[2].from, irisOut.tracks[2].to }, { 0, 1 })
	-- Staggered repeats on one node collapse to one change; instant makes everything 0 s.
	local stag = Transitions.stagger(Transitions.fade(), 3, 0.1, "row")
	t.eq(#Transitions.reduce(stag).tracks, 1)
	t.eq(Transitions.reduce(slide, nil, true).duration, 0)
	local viaPlan = Transitions.plan("scalePop", {}, { reducedMotion = true, reducedFade = 0.12 })
	t.ok(viaPlan.reduced)
	t.near(viaPlan.duration, 0.12, 1e-12)
	t.ok(not Transitions.plan("scalePop", {}, { reducedMotion = false }).reduced)
end)

-- ---------------------------------------------------------------- runner

test("the runner writes the start value at once and the exact end value at completion", function(t)
	local runner, values = recorder()
	local target = {}
	local states = {}
	local handle = runner:play(Transitions.fade({ duration = 0.2 }), { root = target }, {
		onComplete = function(state)
			table.insert(states, state)
		end,
	})
	t.eq(values[target].GroupTransparency, 1, "start value written by play")
	t.eq(runner:count(), 1)
	runner:step(0.1)
	t.near(values[target].GroupTransparency, 1 - Ease.get("Quad", "Out", 0.5), 1e-12)
	runner:step(0.2)
	t.eq(values[target].GroupTransparency, 0)
	t.eq(handle:state(), "completed")
	t.eq(states, { "completed" })
	t.eq(runner:count(), 0)
	t.throws(function()
		runner:step(-1)
	end)
	t.throws(function()
		runner:play(Transitions.fade(), {})
	end, "missing binding")
end)

test("sampling is frame-rate independent: 40 Hz and 144 Hz agree at the same time", function(t)
	local plan = Transitions.slide({ duration = 0.5, base = { 0, 100, 0, 100 } })
	local function at(rate: number, seconds: number): any
		local runner, values = recorder()
		local target = {}
		runner:play(plan, { root = target })
		for _ = 1, math.round(seconds * rate) do
			runner:step(1 / rate)
		end
		return values[target].Position
	end
	local slow, fast = at(40, 0.25), at(144, 0.25)
	for index = 1, 4 do
		t.near(slow[index], fast[index], 1e-9, "component " .. index)
	end
end)

test("interrupting a track starts from the current value and hands over spring velocity", function(t)
	local runner, values = recorder()
	local target = {}
	local first = runner:play(
		Transitions.make(
			"open",
			"in",
			{ Transitions.track("root", "Scale", 0, 1, { duration = 1, ease = "Linear.In" }) }
		),
		{ root = target }
	)
	for _ = 1, 30 do
		runner:step(1 / 60)
	end
	local mid = values[target].Scale
	t.near(mid, 0.5, 1e-9)
	local spring = { dampingRatio = 1, frequency = 2 }
	local second = runner:play(
		Transitions.make("close", "out", { Transitions.track("root", "Scale", nil, 0, { spring = spring }) }),
		{ root = target }
	)
	t.eq(first:state(), "interrupted")
	t.near(values[target].Scale, mid, 1e-9, "no jump on interrupt")
	runner:step(1 / 60)
	-- Velocity 1/s upward carried in: the value first keeps rising before it turns back.
	t.ok(values[target].Scale > mid, "inherited velocity continues the old motion")
	for _ = 1, 600 do
		runner:step(1 / 60)
	end
	t.eq(values[target].Scale, 0)
	t.eq(second:state(), "completed")
end)

test("cancel, finish, stop and delayed fill behave as documented", function(t)
	local runner, values = recorder()
	local a, b = {}, {}
	local cancelled = runner:play(Transitions.fade({ duration = 1 }), { root = a })
	runner:step(0.25)
	local frozen = values[a].GroupTransparency
	cancelled:cancel()
	runner:step(0.5)
	t.eq(values[a].GroupTransparency, frozen, "cancel leaves the current value")
	t.eq(cancelled:state(), "cancelled")
	local finished = runner:play(Transitions.fade({ duration = 1 }), { root = a })
	finished:finish()
	t.eq(values[a].GroupTransparency, 0, "finish jumps to the end")
	t.eq(finished:state(), "completed")
	local delayed = runner:play(Transitions.fade({ duration = 0.2, delay = 0.5 }), { root = b })
	t.eq(values[b].GroupTransparency, 1, "fill shows the start value during the delay")
	runner:stop(b)
	t.eq(delayed:state(), "cancelled")
	t.eq(runner:count(), 0)
end)

test("apply errors are reported, not raised, and onComplete errors do not stop the runner", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local runner = Transitions.runner(Transitions.instanceApply(env), Transitions.instanceRead(), env)
	local frame = roblox.Instance.new("Frame")
	runner:play(
		Transitions.make("bad", "in", { Transitions.track("root", "Visible", 0, 1, { duration = 0.1 }) }),
		{ root = frame },
		{
			onComplete = function()
				error("boom")
			end,
		}
	)
	runner:step(0.2)
	t.ok(contains(env.reports, "Visible is not an animatable property"))
	t.ok(contains(env.reports, "onComplete error"))
end)

test("instanceApply and instanceRead convert UDim2, Vector2, Color3 and integers", function(t)
	local env = { roblox = roblox }
	local apply, read = Transitions.instanceApply(env), Transitions.instanceRead()
	local label = roblox.Instance.new("TextLabel")
	apply(label, "Position", { 0.5, 10, 0.25, -4 })
	t.eq(label.Position, roblox.UDim2.new(0.5, 10, 0.25, -4))
	apply(label, "AnchorPoint", { 0.5, 1 })
	t.eq(label.AnchorPoint, roblox.Vector2.new(0.5, 1))
	apply(label, "TextColor3", { 1, 0.5, 0 })
	t.eq(label.TextColor3, roblox.Color3.new(1, 0.5, 0))
	apply(label, "MaxVisibleGraphemes", 3.6)
	t.eq(label.MaxVisibleGraphemes, 4)
	t.eq(read(label, "Position"), { 0.5, 10, 0.25, -4 })
	t.eq(read(label, "Name"), nil)
	-- read supplies `from` when a plan leaves it nil.
	local runner = Transitions.runner(apply, read, env)
	label.Size = roblox.UDim2.fromOffset(100, 20)
	runner:play(
		Transitions.make("grow", "in", {
			Transitions.track("root", "Size", nil, { 0, 200, 0, 20 }, { duration = 1, ease = "Linear.In" }),
		}),
		{ root = label }
	)
	runner:step(0.5)
	t.eq(label.Size, roblox.UDim2.fromOffset(150, 20))
	t.throws(function()
		Transitions.instanceApply({})
	end)
end)

-- ---------------------------------------------------------------- Build.play and after

test("Build.play reduces plans under reduced motion and Build.after shares the runner clock", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local calm = Build.context({ env = env, motion = { reducedMotion = true } })
	local frame = roblox.Instance.new("Frame")
	local handle = Build.play(calm, Transitions.slide({ duration = 0.5 }), { root = frame })
	t.ok(handle.plan.reduced, "reduced plan played")
	t.near(handle.plan.duration, calm.tokens.motion.reducedFade, 1e-12)
	local fired = 0
	local cancel = Build.after(calm, 1, function()
		fired += 1
	end)
	calm.runner:step(0.6)
	t.eq(fired, 0, "timers are never reduced")
	calm.runner:step(0.5)
	t.eq(fired, 1)
	Build.after(calm, 1, function()
		fired += 10
	end)()
	calm.runner:step(2)
	t.eq(fired, 1, "a cancelled timer never fires")
	cancel()
	local scoped = Build.after(calm, 0.5, function()
		fired += 100
	end)
	calm.scope:Clean()
	calm.runner:step(1)
	t.eq(fired, 1, "cleaning the scope cancels pending timers")
	scoped()
	t.throws(function()
		Build.after(calm, -1, function() end)
	end)
end)

-- ---------------------------------------------------------------- State

test("State propagates a diamond once per change, skips equal values and batches", function(t)
	local a = State.value(1)
	local b = State.computed({ a }, function(x)
		return x + 1
	end)
	local c = State.computed({ a }, function(x)
		return x * 2
	end)
	local runs = 0
	local d = State.computed({ b, c }, function(x, y)
		runs += 1
		return x + y
	end)
	local seen = {}
	d:observe(function(new, old)
		table.insert(seen, { new, old })
	end)
	runs = 0
	t.eq(a:set(2), true)
	t.eq(runs, 1, "d recomputed once")
	t.eq(d:get(), 7)
	t.eq(seen, { { 7, 4 } })
	t.eq(a:set(2), false, "equal values do not propagate")
	t.eq(#seen, 1)
	State.batch(function()
		a:set(3)
		a:set(4)
	end)
	t.eq(seen[2], { 13, 7 }, "one notification after the batch")
	t.eq(#seen, 2)
	t.ok(State.is(a) and not State.is({}))
end)

test("State reports observer and computed errors, refuses bad sources and dies with its scope", function(t)
	local env = FakeEnv.new()
	local scope = Scope.new(env)
	local a = State.value(1, scope, env)
	local good = 0
	a:observe(function()
		error("observer broke")
	end)
	a:observe(function()
		good += 1
	end)
	a:set(2)
	t.eq(good, 1, "a failing observer does not stop the others")
	t.ok(contains(env.reports, "State observer error"))
	local fragile = State.computed({ a }, function(x)
		if x > 2 then
			error("too big")
		end
		return x
	end, nil, env)
	a:set(3)
	t.eq(fragile:get(), 2, "a failing computed keeps its last value")
	t.ok(contains(env.reports, "State.computed error"))
	t.throws(function()
		State.computed({}, function() end)
	end)
	t.throws(function()
		State.computed({ {} :: any }, function() end)
	end)
	scope:Clean()
	t.ok(a:destroyed())
	t.throws(function()
		a:set(5)
	end, "set after destroy")
	t.throws(function()
		a:observe(function() end)
	end)
end)

return cases
