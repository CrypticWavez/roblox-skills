--!strict
-- @tier T0
-- Haptics: HapticEffect patterns as data, clamped and rate-limited before FeelRoblox plays them.
-- A pattern: { type, intensity?, waveform?, looped?, duration? }. waveform keys are
-- { timeMs, intensity 0..1 } (HapticEffect:SetWaveformKeys takes FloatCurveKeys in ms) and are
-- only used with type Custom. Clamps (conventions): intensity 0..1, at most 32 keys, at most
-- 1000 ms per pattern, at least 50 ms between plays (a buzz storm is noise, not feedback).
-- settings/1: effective.haptics == false turns everything off (disabled); unsupported devices
-- are the adapter's no-op.
--   Haptics.validate(pattern) -> problems;  Haptics.clamp(pattern) -> pattern
--   Haptics.new(options?) -> haptics;  haptics:request(pattern, now) -> (pattern?, reason?)
local Haptics = {}

-- Types confirmed on the HapticEffect class page (the full HapticEffectType list is UNVERIFIED).
Haptics.TYPES = table.freeze({ "UIClick", "GameplayCollision", "GameplayExplosion", "Custom" })
Haptics.MAX_KEYS = 32
Haptics.MAX_DURATION_MS = 1000
Haptics.MIN_INTERVAL = 0.05

local KEYS = { type = true, intensity = true, waveform = true, looped = true, duration = true }

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Haptics.validate(pattern: any): { string }
	local problems = {}
	if type(pattern) ~= "table" then
		return { "pattern must be a table" }
	end
	for key in pattern do
		if not KEYS[key] then
			table.insert(problems, tostring(key) .. " is not a haptic field")
		end
	end
	table.sort(problems)
	if not table.find(Haptics.TYPES, pattern.type) then
		table.insert(problems, "type must be one of " .. table.concat(Haptics.TYPES, ", "))
	end
	if pattern.intensity ~= nil and not finite(pattern.intensity) then
		table.insert(problems, "intensity must be a number")
	end
	if pattern.looped ~= nil and type(pattern.looped) ~= "boolean" then
		table.insert(problems, "looped must be a boolean")
	end
	if pattern.looped == true and pattern.duration == nil then
		table.insert(problems, "a looped pattern needs duration (seconds) so it always stops")
	end
	if pattern.duration ~= nil and not (finite(pattern.duration) and pattern.duration > 0) then
		table.insert(problems, "duration must be > 0 seconds")
	end
	local waveform = pattern.waveform
	if waveform ~= nil then
		if pattern.type ~= "Custom" then
			table.insert(problems, "waveform needs type Custom")
		end
		if type(waveform) ~= "table" or #waveform == 0 then
			table.insert(problems, "waveform must be a list of { timeMs, intensity }")
		else
			local last = -1
			for index, key in waveform do
				if type(key) ~= "table" or not finite(key[1]) or not finite(key[2]) then
					table.insert(problems, "waveform key " .. index .. " must be { timeMs, intensity }")
					break
				end
				if key[1] < last then
					table.insert(problems, "waveform times must not decrease")
					break
				end
				last = key[1]
			end
		end
	elseif pattern.type == "Custom" then
		table.insert(problems, "type Custom needs a waveform")
	end
	return problems
end

-- A copy inside the clamps: intensity 0..1, waveform times 0..MAX_DURATION_MS, values 0..1
-- (scaled by intensity), at most MAX_KEYS keys (evenly thinned), looped duration <= 5 s.
function Haptics.clamp(pattern: any): any
	local problems = Haptics.validate(pattern)
	assert(#problems == 0, "Haptics.clamp: " .. table.concat(problems, "; "))
	local out: any = { type = pattern.type, looped = pattern.looped == true }
	local intensity = math.clamp(if pattern.intensity == nil then 1 else pattern.intensity, 0, 1)
	out.intensity = intensity
	if pattern.duration ~= nil then
		out.duration = math.min(pattern.duration, 5)
	end
	if pattern.waveform then
		local keys = {}
		for _, key in pattern.waveform do
			if key[1] <= Haptics.MAX_DURATION_MS then
				table.insert(keys, { math.max(0, key[1]), math.clamp(key[2], 0, 1) * intensity })
			end
		end
		if #keys > Haptics.MAX_KEYS then
			local thinned = {}
			for index = 1, Haptics.MAX_KEYS do
				local source = math.floor((index - 1) * (#keys - 1) / (Haptics.MAX_KEYS - 1) + 0.5) + 1
				table.insert(thinned, keys[source])
			end
			keys = thinned
		end
		out.waveform = keys
	end
	return out
end

export type Options = { effective: any?, minInterval: number? }

function Haptics.new(options: Options?)
	local opts: any = options or {}
	local effective: any = opts.effective or {}
	local minInterval = opts.minInterval or Haptics.MIN_INTERVAL
	assert(finite(minInterval) and minInterval >= 0, "Haptics: minInterval must be >= 0")
	local last = -math.huge
	local api = {}

	function api:setEffective(value: any)
		effective = value or {}
	end

	-- The clamped pattern to play, or (nil, reason): disabled, rate_limited, invalid.
	function api:request(pattern: any, now: number): (any?, string?)
		if effective.haptics == false then
			return nil, "disabled"
		end
		if #Haptics.validate(pattern) > 0 then
			return nil, "invalid"
		end
		if now - last < minInterval then
			return nil, "rate_limited"
		end
		last = now
		return Haptics.clamp(pattern), nil
	end

	return api
end

return Haptics
