--!strict
-- @tier T0
-- HitStop: brief freeze windows that sell an impact. Requests are clamped to MAX seconds each
-- (convention 0.2 s; longer reads as lag), overlapping requests merge to the latest end (never
-- add up), and the frozen time inside any rolling WINDOW is capped at BUDGET (convention
-- 0.35 s per second), so a flurry of hits cannot stall the game. scale(now) is the time scale to
-- apply (0 frozen, 1 running); FeelRoblox pauses AnimationTracks with AdjustSpeed(0) and restores
-- their speed. The caller supplies `now` (env.clock()).
--   HitStop.new(options?) -> stop;  stop:request(seconds, now) -> (granted, reason?)
--   stop:scale(now), stop:frozen(now), stop:remaining(now)
local HitStop = {}

HitStop.MAX = 0.2 -- convention
HitStop.BUDGET = 0.35 -- convention: frozen seconds per rolling window
HitStop.WINDOW = 1

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

export type Options = { max: number?, budget: number?, window: number? }

function HitStop.new(options: Options?)
	local opts: Options = options or {}
	local max = opts.max or HitStop.MAX
	local budget = opts.budget or HitStop.BUDGET
	local window = opts.window or HitStop.WINDOW
	assert(finite(max) and max > 0, "HitStop: max must be > 0")
	assert(finite(budget) and budget > 0, "HitStop: budget must be > 0")
	assert(finite(window) and window > 0, "HitStop: window must be > 0")
	local intervals: { { number } } = {} -- granted { start, finish }, disjoint and ordered
	local api = {}

	local function used(now: number): number
		local from = now - window
		local total = 0
		for index = #intervals, 1, -1 do
			local span = intervals[index]
			if span[2] <= from then
				table.remove(intervals, index) -- outside every future window too
			else
				total += span[2] - math.max(span[1], from)
			end
		end
		return total
	end

	local function finish(): number
		local last = intervals[#intervals]
		return if last then last[2] else -math.huge
	end

	-- Asks for a freeze of `seconds` starting at `now`. Returns the seconds actually added to the
	-- current freeze (0 when it is already covered) and a reason when the request was cut:
	-- "clamped" (above max), "budget" (window budget spent).
	function api:request(seconds: number, now: number): (number, string?)
		assert(finite(seconds) and seconds >= 0, "HitStop: seconds must be a finite number >= 0")
		assert(finite(now), "HitStop: now must be finite")
		local reason = nil
		local wanted = seconds
		if wanted > max then
			wanted = max
			reason = "clamped"
		end
		local currentEnd = finish()
		local start = math.max(now, currentEnd)
		local added = math.max(0, now + wanted - start)
		if added <= 0 then
			return 0, reason
		end
		local allowed = math.max(0, budget - used(now))
		if added > allowed then
			added = allowed
			reason = "budget"
		end
		if added <= 0 then
			return 0, reason
		end
		local last = intervals[#intervals]
		if last and last[2] >= now then
			last[2] += added
		else
			table.insert(intervals, { now, now + added })
		end
		return added, reason
	end

	function api:frozen(now: number): boolean
		for _, span in intervals do
			if now >= span[1] and now < span[2] then
				return true
			end
		end
		return false
	end

	function api:scale(now: number): number
		return if api:frozen(now) then 0 else 1
	end

	function api:remaining(now: number): number
		for _, span in intervals do
			if now >= span[1] and now < span[2] then
				return span[2] - now
			end
		end
		return 0
	end

	function api:clear()
		table.clear(intervals)
	end

	return api
end

return HitStop
