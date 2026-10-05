--!strict
local Motion = {}

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function Motion.curve(alpha: number, reduced: boolean): number
	assert(finite(alpha), "finite alpha required")
	local t = math.clamp(alpha, 0, 1)
	return if reduced then 1 else t * t * (3 - 2 * t)
end

function Motion.transition(initial: number, duration: number)
	assert(finite(initial) and finite(duration) and duration >= 0, "invalid transition")
	local api = { value = initial, target = initial, elapsed = 0, duration = duration, generation = 0 }
	local origin = initial
	function api:set(target: number, reduced: boolean)
		assert(finite(target), "invalid target")
		origin, api.target, api.elapsed = api.value, target, 0
		api.generation += 1
		if reduced or api.duration == 0 then
			api.value, api.elapsed = target, api.duration
		end
		return api.generation
	end
	function api:step(dt: number)
		assert(finite(dt) and dt >= 0, "invalid dt")
		api.elapsed = math.min(api.elapsed + dt, api.duration)
		local alpha = if api.duration == 0 then 1 else Motion.curve(api.elapsed / api.duration, false)
		api.value = origin + (api.target - origin) * alpha
		return api.value, api.elapsed >= api.duration
	end
	return api
end

function Motion.validateMarkers(
	duration: number,
	markers: { { name: string, time: number } },
	required: { string }
): { string }
	local errors, found = {}, {}
	if not finite(duration) or duration <= 0 then
		return { "invalid duration" }
	end
	local previous = -1
	for index, marker in markers do
		if
			type(marker.name) ~= "string"
			or marker.name == ""
			or not finite(marker.time)
			or marker.time < 0
			or marker.time > duration
		then
			table.insert(errors, "invalid marker " .. tostring(index))
		elseif marker.time < previous then
			table.insert(errors, "markers out of order")
		else
			found[marker.name], previous = true, marker.time
		end
	end
	for _, name in required do
		if not found[name] then
			table.insert(errors, "missing marker " .. name)
		end
	end
	return errors
end

-- Positions must be in world space, sampled while this foot is declared planted.
-- A large delta is a diagnostic flag, not an automatic animation-quality verdict.
function Motion.contactDrift(
	samples: { { time: number, x: number, y: number, z: number, planted: boolean } },
	tolerance: number
)
	assert(finite(tolerance) and tolerance >= 0, "invalid tolerance")
	assert(#samples <= 10000, "sample capacity exceeded")
	for index, sample in samples do
		assert(
			finite(sample.time) and finite(sample.x) and finite(sample.y) and finite(sample.z),
			"nonfinite sample"
		)
		assert(type(sample.planted) == "boolean", "planted state required")
		if index > 1 then
			assert(sample.time > samples[index - 1].time, "timestamps must increase")
		end
	end
	local maximum, total, segments = 0, 0, 0
	for index = 2, #samples do
		local a, b = samples[index - 1], samples[index]
		if a.planted and b.planted then
			assert(b.time > a.time, "timestamps must increase")
			local distance = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
			maximum, total, segments = math.max(maximum, distance), total + distance, segments + 1
		end
	end
	return {
		maximumStep = maximum,
		totalDrift = total,
		plantedSegments = segments,
		flagged = maximum > tolerance,
	}
end

return Motion
