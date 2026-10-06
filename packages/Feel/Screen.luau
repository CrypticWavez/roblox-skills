--!strict
-- @tier T0
-- Screen: full-screen feedback as data: flashes, tints, a vignette and camera punches (field of
-- view and blur), sampled per frame into values FeelRoblox writes to an owned
-- ColorCorrectionEffect, BlurEffect, Camera.FieldOfView and a vignette gradient.
-- Flash safety (WCAG 2.3.1 "three flashes or below threshold"): at most LIMIT flashes start in
-- any rolling second; extra flashes are dropped (rate_limited), never queued. With flashes off
-- (settings/1 reduceFlashing, i.e. effective.allowFlashes == false) a flash becomes a soft tint:
-- brightness capped at SOFT_INTENSITY and stretched to at least SOFT_DURATION. Flash intensity is
-- always capped at MAX_INTENSITY. Reduced motion drops FOV and blur punches (reduced_motion) and
-- keeps fades and tints.
--   Screen.new(options?) -> screen;  screen:flash(spec, now) -> (accepted, reason?)
--   screen:tint(spec, now), screen:vignette(amount, seconds?, now), screen:punch(spec, now)
--   screen:sample(now) -> { brightness, tint = { r, g, b }, tintAmount, saturation, vignette,
--       blur, fov }
local Screen = {}

Screen.LIMIT = 3 -- flashes per rolling second (WCAG 2.3.1)
Screen.WINDOW = 1
Screen.MAX_INTENSITY = 0.5 -- convention: ColorCorrection brightness added at the flash peak
Screen.SOFT_INTENSITY = 0.12 -- convention
Screen.SOFT_DURATION = 0.35 -- convention (seconds)
Screen.MAX_PUNCH_FOV = 12 -- convention (degrees)
Screen.MAX_BLUR = 24 -- BlurEffect.Size convention ceiling

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function color(value: any): { number }
	if value == nil then
		return { 255, 255, 255 }
	end
	assert(
		type(value) == "table" and finite(value[1]) and finite(value[2]) and finite(value[3]),
		"Screen: colour must be { r, g, b } 0-255"
	)
	return { math.clamp(value[1], 0, 255), math.clamp(value[2], 0, 255), math.clamp(value[3], 0, 255) }
end

export type FlashSpec = { intensity: number?, duration: number?, color: { number }? }
export type TintSpec = { color: { number }?, amount: number?, duration: number?, saturation: number? }
export type PunchSpec = { fov: number?, blur: number?, duration: number? }

export type Sample = {
	brightness: number,
	tint: { number },
	tintAmount: number,
	saturation: number,
	vignette: number,
	blur: number,
	fov: number,
}

export type Options = { effective: any?, limit: number?, window: number? }

function Screen.new(options: Options?)
	local opts: any = options or {}
	local effective: any = opts.effective or {}
	local limit = opts.limit or Screen.LIMIT
	local window = opts.window or Screen.WINDOW
	assert(finite(limit) and limit >= 0 and limit <= Screen.LIMIT, "Screen: limit must be within 0..3")
	assert(finite(window) and window >= Screen.WINDOW, "Screen: window must be >= 1 s")
	local flashStarts: { number } = {}
	local pulses: { any } = {} -- { kind, start, duration, ... }
	local vignette = { from = 0, to = 0, start = 0, duration = 0 }
	local counters = { flashes = 0, softened = 0, rateLimited = 0, punchesDropped = 0 }
	local api = {}

	function api:setEffective(value: any)
		effective = value or {}
	end

	function api:flash(spec: FlashSpec?, now: number): (boolean, string?)
		local s: any = spec or {}
		assert(finite(now), "Screen: now must be finite")
		for index = #flashStarts, 1, -1 do
			if now - flashStarts[index] >= window then
				table.remove(flashStarts, index)
			end
		end
		if #flashStarts >= limit then
			counters.rateLimited += 1
			return false, "rate_limited"
		end
		local intensity =
			math.clamp(if s.intensity == nil then 0.35 else s.intensity, 0, Screen.MAX_INTENSITY)
		local duration = math.clamp(if s.duration == nil then 0.12 else s.duration, 0.03, 2)
		local reason = nil
		if effective.allowFlashes == false then
			intensity = math.min(intensity, Screen.SOFT_INTENSITY)
			duration = math.max(duration, Screen.SOFT_DURATION)
			reason = "softened"
			counters.softened += 1
		end
		table.insert(flashStarts, now)
		counters.flashes += 1
		table.insert(pulses, {
			kind = "flash",
			start = now,
			duration = duration,
			intensity = intensity,
			color = color(s.color),
			soft = reason ~= nil,
		})
		return true, reason
	end

	-- A colour wash (no brightness spike): fades in over 25% and out over the rest. Not a flash.
	function api:tint(spec: TintSpec?, now: number): boolean
		local s: any = spec or {}
		table.insert(pulses, {
			kind = "tint",
			start = now,
			duration = math.clamp(s.duration or 0.6, 0.05, 10),
			amount = math.clamp(s.amount or 0.3, 0, 1),
			saturation = math.clamp(s.saturation or 0, -1, 1),
			color = color(s.color),
		})
		return true
	end

	-- Moves the vignette to `amount` (0..1) over `seconds`.
	function api:vignette(amount: number, seconds: number?, now: number)
		assert(finite(amount), "Screen: vignette amount must be finite")
		local current = api:sample(now).vignette
		vignette = {
			from = current,
			to = math.clamp(amount, 0, 1),
			start = now,
			duration = math.max(seconds or 0.3, 0),
		}
	end

	-- A camera punch: FOV kick (degrees, negative zooms in) and blur, easing back over duration.
	function api:punch(spec: PunchSpec?, now: number): (boolean, string?)
		if effective.reducedMotion == true then
			counters.punchesDropped += 1
			return false, "reduced_motion"
		end
		local s: any = spec or {}
		table.insert(pulses, {
			kind = "punch",
			start = now,
			duration = math.clamp(s.duration or 0.25, 0.05, 2),
			fov = math.clamp(s.fov or 0, -Screen.MAX_PUNCH_FOV, Screen.MAX_PUNCH_FOV),
			blur = math.clamp(s.blur or 0, 0, Screen.MAX_BLUR),
		})
		return true, nil
	end

	function api:sample(now: number): Sample
		local out: Sample = {
			brightness = 0,
			tint = { 255, 255, 255 },
			tintAmount = 0,
			saturation = 0,
			vignette = 0,
			blur = 0,
			fov = 0,
		}
		local tintWeight = 0
		local tintColor = { 0, 0, 0 }
		for index = #pulses, 1, -1 do
			local pulse = pulses[index]
			local t = now - pulse.start
			if t >= pulse.duration then
				table.remove(pulses, index)
			elseif t >= 0 then
				local x = t / pulse.duration
				if pulse.kind == "flash" then
					-- instant attack, quadratic decay
					local envelope = (1 - x) ^ 2
					out.brightness += pulse.intensity * envelope
					local weight = pulse.intensity * envelope
					tintWeight += weight
					for channel = 1, 3 do
						tintColor[channel] += pulse.color[channel] * weight
					end
				elseif pulse.kind == "tint" then
					local envelope = if x < 0.25 then x / 0.25 else (1 - x) / 0.75
					local weight = pulse.amount * envelope
					out.saturation += pulse.saturation * envelope
					tintWeight += weight
					for channel = 1, 3 do
						tintColor[channel] += pulse.color[channel] * weight
					end
				else
					local envelope = (1 - x) ^ 3
					out.fov += pulse.fov * envelope
					out.blur += pulse.blur * envelope
				end
			end
		end
		out.brightness = math.min(out.brightness, Screen.MAX_INTENSITY)
		if tintWeight > 0 then
			for channel = 1, 3 do
				out.tint[channel] = tintColor[channel] / tintWeight
			end
			out.tintAmount = math.min(tintWeight, 1)
		end
		out.saturation = math.clamp(out.saturation, -1, 1)
		out.blur = math.min(out.blur, Screen.MAX_BLUR)
		out.fov = math.clamp(out.fov, -Screen.MAX_PUNCH_FOV, Screen.MAX_PUNCH_FOV)
		local v = vignette
		if v.duration <= 0 or now >= v.start + v.duration then
			out.vignette = v.to
		elseif now <= v.start then
			out.vignette = v.from
		else
			out.vignette = v.from + (v.to - v.from) * ((now - v.start) / v.duration)
		end
		return out
	end

	-- Flash starts inside the rolling window ending at `now` (for audits and tests).
	function api:recentFlashes(now: number): number
		local count = 0
		for _, start in flashStarts do
			if now - start < window and now >= start then
				count += 1
			end
		end
		return count
	end

	function api:stats(): any
		return table.clone(counters)
	end

	return api
end

return Screen
