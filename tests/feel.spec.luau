--!strict
-- Feel cores: Spring (closed form vs a reference integration, frame-rate independence, damping
-- regimes), Shake (bounded, deterministic, decays, honours shakeScale), HitStop (clamp, merge,
-- budget), Popups (format, aggregate, stacking, reduced motion), Screen (the 3-per-second flash
-- limiter, reduce-flashing, reduced motion), Haptics (validate, clamp, rate limit, disabled) and
-- Cues (sound needs a visual channel, channels fire, frame budget, marker binding). Settings
-- come from GameKit/Settings.effective so the flags are the real settings/1 ones.
local AudioCues = require("../packages/AVKit/AudioCues")
local Cues = require("../packages/Feel/Cues")
local Haptics = require("../packages/Feel/Haptics")
local HitStop = require("../packages/Feel/HitStop")
local Popups = require("../packages/Feel/Popups")
local Screen = require("../packages/Feel/Screen")
local Settings = require("../packages/GameKit/Settings")
local Shake = require("../packages/Feel/Shake")
local Spring = require("../packages/Feel/Spring")
local VfxLibrary = require("../packages/AVKit/VfxLibrary")

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

local function effective(patch: { [string]: any }): any
	local values = Settings.defaults()
	for key, value in patch do
		values[key] = value
	end
	return Settings.effective(values)
end

-- Reference: semi-implicit Euler at a tiny step on x'' = -w^2 (x - target) - 2 zeta w x'.
local function reference(
	x0: number,
	v0: number,
	target: number,
	zeta: number,
	hz: number,
	t: number
): (number, number)
	local w = 2 * math.pi * hz
	local x, v = x0, v0
	local h = 1e-5
	for _ = 1, math.floor(t / h + 0.5) do
		local a = -w * w * (x - target) - 2 * zeta * w * v
		v += a * h
		x += v * h
	end
	return x, v
end

test("spring closed form matches a reference integration in all three damping regimes", function(t)
	for _, zeta in { 0.3, 1, 2.5 } do
		for _, at in { 0.05, 0.2, 0.6 } do
			local x, v = Spring.solve(0, 3, 1, zeta, 2, at)
			local rx, rv = reference(0, 3, 1, zeta, 2, at)
			t.near(x, rx, 2e-3, string.format("x zeta=%s t=%s", zeta, at))
			t.near(v, rv, 2e-2, string.format("v zeta=%s t=%s", zeta, at))
		end
	end
end)

test("spring steps are frame-rate independent", function(t)
	local a = Spring.new(0, { dampingRatio = 0.5, frequency = 3, target = 10 })
	local b = Spring.new(0, { dampingRatio = 0.5, frequency = 3, target = 10 })
	for _ = 1, 30 do
		a:step(1 / 60)
	end
	for _ = 1, 15 do
		b:step(1 / 30)
	end
	t.near(a.value, b.value, 1e-9)
	t.near(a.velocity, b.velocity, 1e-9)
end)

test("critical damping never overshoots; under-damping overshoots by the closed-form amount", function(t)
	local critical = Spring.new(0, { dampingRatio = 1, frequency = 4, target = 1 })
	local peak = 0
	for _ = 1, 240 do
		local x = critical:step(1 / 120)
		peak = math.max(peak, x)
	end
	t.ok(peak <= 1 + 1e-12, "critical overshoot " .. peak)
	local zeta = 0.3
	local under = Spring.new(0, { dampingRatio = zeta, frequency = 2, target = 1 })
	local maxValue = 0
	for _ = 1, 2000 do
		local x = under:step(1 / 2000)
		maxValue = math.max(maxValue, x)
	end
	-- first-peak overshoot of a step response: exp(-zeta pi / sqrt(1 - zeta^2))
	t.near(maxValue - 1, math.exp(-zeta * math.pi / math.sqrt(1 - zeta * zeta)), 1e-4)
	local _, _, settled = under:step(30)
	t.eq(settled, true)
	t.eq(under.value, 1)
end)

test("springs animate tables componentwise and reject bad input", function(t)
	local spring = Spring.new({ x = 0, y = 5 }, { frequency = 3, target = { x = 2, y = 5 } })
	local value = spring:step(0.1)
	t.ok(value.x > 0 and value.x < 2)
	t.eq(value.y, 5)
	spring:impulse({ x = 0, y = 4 })
	t.ok(spring.velocity.y == 4)
	t.throws(function()
		spring:setTarget({ x = 1 })
	end)
	t.throws(function()
		Spring.new(0 / 0)
	end)
	t.throws(function()
		Spring.new(0, { dampingRatio = -1 })
	end)
	t.throws(function()
		Spring.new(0):step(-0.1)
	end)
end)

test("shake stays bounded, decays to rest and is deterministic per seed", function(t)
	local a = Shake.new({ seed = 3 })
	local b = Shake.new({ seed = 3 })
	local c = Shake.new({ seed = 4 })
	a:add("blast")
	b:add(0.8)
	c:add(0.8)
	local differs = false
	for _ = 1, 120 do
		local oa = a:step(1 / 60)
		local ob = b:step(1 / 60)
		local oc = c:step(1 / 60)
		t.eq(oa, ob)
		if oa.x ~= oc.x then
			differs = true
		end
		t.ok(math.abs(oa.x) <= Shake.DEFAULTS.maxOffset.x + 1e-12)
		t.ok(math.abs(oa.roll) <= Shake.DEFAULTS.maxAngle.roll + 1e-12)
		t.eq(oa.z, 0)
	end
	t.ok(differs, "another seed gives another shake")
	t.eq(a:trauma(), 0)
	t.eq(a:step(1 / 60).x, 0)
	for step = 0, 2000 do
		local n = Shake.noise("s", 1, step * 0.37)
		t.ok(n >= -1 and n <= 1)
	end
	a:add(5)
	t.eq(a:trauma(), 1, "trauma clamps to 1")
	t.throws(function()
		a:add("earthquake_of_doom")
	end)
end)

test("shake honours settings/1: reduced motion gives zero offsets and still drains trauma", function(t)
	local fx = effective({ reducedMotion = true })
	t.eq(fx.shakeScale, 0)
	local shake = Shake.new({ seed = 1 })
	shake:add("hit_heavy")
	local offsets = shake:step(1 / 60, fx.shakeScale)
	for _, value in offsets do
		t.eq(value, 0)
	end
	t.ok(shake:trauma() < Shake.PRESETS.hit_heavy)
	local half = Shake.new({ seed = 1 })
	local full = Shake.new({ seed = 1 })
	half:add(0.5)
	full:add(0.5)
	local h = half:step(0.1, 0.5)
	local f = full:step(0.1, 1)
	t.near(h.x, f.x * 0.5, 1e-12)
end)

test("hit-stop clamps, merges overlaps to the latest end and caps frozen time per second", function(t)
	local stop = HitStop.new()
	local granted, reason = stop:request(0.5, 0)
	t.near(granted, 0.2)
	t.eq(reason, "clamped")
	t.eq(stop:scale(0.1), 0)
	t.eq(stop:scale(0.2), 1)
	t.near(stop:request(0.05, 0.1), 0, 1e-12, "covered by the running freeze")
	t.near(stop:request(0.15, 0.1), 0.05, 1e-12, "extends to the later end, does not add up")
	t.near(stop:remaining(0.2), 0.05)
	-- budget 0.35 per rolling second: 0.25 used, so only 0.1 more
	local more, why = stop:request(0.2, 0.4)
	t.near(more, 0.1)
	t.eq(why, "budget")
	t.eq((stop:request(0.1, 0.6)), 0)
	t.near(stop:request(0.1, 1.6), 0.1, 1e-12, "the window has moved on")
	t.throws(function()
		stop:request(-1, 0)
	end)
end)

test("popups format, aggregate and stack without overlap", function(t)
	t.eq(Popups.format(999), "999")
	t.eq(Popups.format(1234), "1.2K")
	t.eq(Popups.format(15300), "15.3K")
	t.eq(Popups.format(2500000), "2.5M")
	t.eq(Popups.format(7e9), "7B")
	t.eq(Popups.format(-1500), "-1.5K")
	t.eq(Popups.format(2.5), "2.5")
	local merged = Popups.aggregate({
		{ key = "dmg", value = 5, anchor = "a", at = 0 },
		{ key = "dmg", value = 7, anchor = "a", at = 0.1 },
		{ key = "dmg", value = 1, anchor = "b", at = 0.1 },
		{ key = "dmg", value = 3, anchor = "a", at = 0.3 },
	}, 0.15)
	t.eq(#merged, 3)
	t.eq(merged[1].value, 12)
	local popups = Popups.new()
	local first = popups:push({ key = "dmg", kind = "damage", value = 10, anchor = "a" }, 0)
	t.eq(popups:push({ key = "dmg", kind = "damage", value = 5, anchor = "a" }, 0.1), first, "merged")
	popups:push({ key = "heal", kind = "heal", value = 3, anchor = "a" }, 0.3)
	local visible = popups:step(0.35)
	t.eq(#visible, 2)
	t.eq(visible[1].text, "15")
	t.eq(visible[2].text, "+3", "gains carry a + prefix, not colour alone")
	t.ok(visible[1].offset >= visible[2].offset + Popups.DEFAULTS.gap - 1e-9, "older popups sit above")
	t.ok(visible[2].scale > 1, "new popups pop")
	t.eq(#popups:step(2), 0, "expired")
	local reduced = Popups.new({ reducedMotion = true })
	reduced:push({ key = "dmg", value = 1, anchor = "a" }, 0)
	local still = reduced:step(0.5)[1]
	t.eq(still.offset, 0, "no rise under reduced motion")
	t.eq(still.scale, 1, "no pop under reduced motion")
	local capped = Popups.new({ maxActive = 2 })
	for index = 1, 4 do
		capped:push({ key = "k" .. index, value = index, anchor = "a" }, 0)
	end
	local kept = capped:step(0.1)
	t.eq(#kept, 2)
	t.eq(kept[1].value, 3, "the oldest go first")
end)

test("the flash limiter allows 3 flashes per rolling second and drops the rest", function(t)
	local screen = Screen.new({ effective = effective({}) })
	t.eq((screen:flash({}, 0)), true)
	t.eq((screen:flash({}, 0.2)), true)
	t.eq((screen:flash({}, 0.4)), true)
	local ok, reason = screen:flash({}, 0.6)
	t.eq(ok, false)
	t.eq(reason, "rate_limited")
	t.eq((screen:flash({}, 0.999)), false, "still inside the second that began at 0")
	t.eq((screen:flash({}, 1.0)), true, "the first flash left the window")
	t.eq((screen:flash({}, 1.1)), false)
	t.eq(screen:recentFlashes(1.1), 3)
	-- no rolling second ever holds more than 3 starts
	local strict = Screen.new()
	local starts = {}
	for step = 0, 400 do
		local now = step * 0.01
		if strict:flash({}, now) then
			table.insert(starts, now)
		end
	end
	for _, start in starts do
		local inWindow = 0
		for _, other in starts do
			if other >= start and other < start + 1 then
				inWindow += 1
			end
		end
		t.ok(inWindow <= 3, "window from " .. start)
	end
	t.eq(strict:stats().rateLimited, 401 - #starts)
	t.throws(function()
		Screen.new({ limit = 4 })
	end)
end)

test("reduce-flashing softens flashes; reduced motion drops punches and keeps tints", function(t)
	local soft = Screen.new({ effective = effective({ reduceFlashing = true }) })
	local ok, reason = soft:flash({ intensity = 0.5, duration = 0.1 }, 0)
	t.eq(ok, true)
	t.eq(reason, "softened")
	t.ok(soft:sample(0).brightness <= Screen.SOFT_INTENSITY + 1e-12)
	t.ok(soft:sample(0.2).brightness > 0, "stretched to the soft duration")
	local loud = Screen.new()
	loud:flash({ intensity = 5 }, 0)
	t.eq(loud:sample(0).brightness, Screen.MAX_INTENSITY, "intensity is capped")
	t.eq(loud:sample(1).brightness, 0)
	local calm = Screen.new({ effective = effective({ reducedMotion = true }) })
	local punched, why = calm:punch({ fov = -6, blur = 8 }, 0)
	t.eq(punched, false)
	t.eq(why, "reduced_motion")
	t.eq(calm:tint({ color = { 255, 0, 0 }, amount = 0.4, duration = 1 }, 0), true)
	local sample = calm:sample(0.25)
	t.near(sample.tintAmount, 0.4)
	t.eq(sample.tint, { 255, 0, 0 })
	t.eq(sample.fov, 0)
	local moving = Screen.new()
	moving:punch({ fov = -6, blur = 8, duration = 0.2 }, 0)
	t.near(moving:sample(0).fov, -6)
	t.near(moving:sample(0.1).blur, 8 * 0.125)
	moving:vignette(0.6, 0.5, 0)
	t.near(moving:sample(0.25).vignette, 0.3)
	t.near(moving:sample(1).vignette, 0.6)
end)

test("haptics validate, clamp waveforms, rate-limit and respect the setting", function(t)
	t.eq(Haptics.validate({ type = "UIClick" }), {})
	t.ok(has(Haptics.validate({ type = "Rumble" }), "type must be"))
	t.ok(has(Haptics.validate({ type = "Custom" }), "needs a waveform"))
	t.ok(has(Haptics.validate({ type = "UIClick", waveform = { { 0, 1 } } }), "needs type Custom"))
	t.ok(has(Haptics.validate({ type = "UIClick", looped = true }), "needs duration"))
	t.ok(has(Haptics.validate({ type = "Custom", waveform = { { 10, 1 }, { 5, 1 } } }), "must not decrease"))
	local keys = {}
	for index = 0, 99 do
		table.insert(keys, { index * 20, 2 })
	end
	local clamped = Haptics.clamp({ type = "Custom", intensity = 0.5, waveform = keys })
	t.eq(#clamped.waveform, Haptics.MAX_KEYS)
	for _, key in clamped.waveform do
		t.ok(key[1] <= Haptics.MAX_DURATION_MS)
		t.eq(key[2], 0.5)
	end
	local haptics = Haptics.new({ effective = effective({}) })
	t.ok(haptics:request({ type = "UIClick" }, 0))
	t.eq(select(2, haptics:request({ type = "UIClick" }, 0.01)), "rate_limited")
	t.ok(haptics:request({ type = "UIClick" }, 0.06))
	t.eq(select(2, haptics:request({ type = "Nope" }, 1)), "invalid")
	local off = Haptics.new({ effective = effective({ haptics = false }) })
	t.eq(select(2, off:request({ type = "UIClick" }, 0)), "disabled")
end)

test("a cue with a sound needs a visual channel; defaults know every VFX and sound id", function(t)
	local problems = Cues.validate({
		beep = { sound = "ui_click" },
		ok_ui = { sound = "ui_click", visual = "ui" },
		empty = {},
		bad = { hitStop = 0.5, shake = 2, haptic = "Buzz", flash = { intensity = 0.9 }, priority = 11 },
	})
	t.ok(has(problems, "cue beep has a sound but no visual channel"))
	t.ok(not has(problems, "cue ok_ui"))
	t.ok(has(problems, "cue empty fires nothing"))
	t.ok(has(problems, "hitStop must be within"))
	t.ok(has(problems, "shake must be a preset"))
	t.ok(has(problems, "haptic type"))
	t.ok(has(problems, "flash.intensity"))
	t.ok(has(problems, "priority"))
	local known = { vfx = VfxLibrary.all(), sounds = AudioCues.defaults() }
	t.eq(Cues.validate(Cues.defaults(), known), {})
	t.ok(has(Cues.validate({ x = { vfx = "nope", visual = "ui" } }, known), "not a known preset"))
end)

test("fire sends each channel to its sink; the frame budget keeps the strongest cues", function(t)
	local log = {}
	local sinks = {}
	for _, channel in Cues.CHANNELS do
		sinks[channel] = function(value: any, context: any)
			table.insert(
				log,
				channel .. ":" .. (if type(value) == "table" then (value.type or "t") else tostring(value))
			)
		end
	end
	sinks.flash = function()
		error("screen gone")
	end
	local reports = {}
	local cues = Cues.new(Cues.defaults(), sinks, {
		budget = 2,
		report = function(message: string)
			table.insert(reports, message)
		end,
	})
	local channels = assert(cues:fire("hit_heavy", { at = "p" }))
	t.eq(channels, { "vfx", "sound", "shake", "hitStop", "haptic" })
	t.eq(
		log,
		{ "vfx:hit_spark", "sound:hit_heavy", "shake:hit_heavy", "hitStop:0.08", "haptic:GameplayCollision" }
	)
	t.eq(#reports, 1, "a failing sink is reported, the others still fire")
	t.ok(cues:fire("land"))
	t.eq(select(2, cues:fire("land")), "frame_budget", "a full frame refuses equal or lower priorities")
	t.ok(cues:fire("blast"), "a stronger cue takes the weakest slot")
	t.eq(select(2, cues:fire("missing")), "unknown_cue")
	cues:frame()
	t.ok(cues:fire("land"))
	t.eq(cues:stats().dropped, 1)
end)

test("bindMarkers fires cues from an Animator-like track's marker signals", function(t)
	local handlers: { [string]: any } = {}
	local disconnected = 0
	local track = {
		GetMarkerReachedSignal = function(_self: any, name: string)
			return {
				Connect = function(_signal: any, fn: any)
					handlers[name] = fn
					return {
						Disconnect = function()
							disconnected += 1
						end,
					}
				end,
			}
		end,
	}
	local fired = {}
	local cues = Cues.new(Cues.defaults(), {
		vfx = function(id: string, context: any)
			table.insert(fired, id .. "@" .. tostring(context.param))
		end,
	})
	local connections = cues:bindMarkers(track, { Hit = "hit_light", Land = "land" }, function(param: any)
		return { param = param }
	end)
	t.eq(#connections, 2)
	handlers.Hit("left")
	handlers.Land("right")
	t.eq(fired, { "hit_spark@left", "impact_dust@right" })
	cues:unbind(connections)
	t.eq(disconnected, 2)
	t.throws(function()
		cues:bindMarkers(track, { Hit = "not_a_cue" })
	end)
end)

return cases
