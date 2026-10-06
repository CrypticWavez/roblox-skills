--!strict
-- @tier T0
-- LiveOps: a config-driven schedule of UTC windows and seeded rotations. It defines no events:
-- the game's data names them. A window is either one-off
--   { id, start, ["end"], data? }                      (UTC seconds or "YYYY-MM-DDTHH:MM:SSZ")
-- or recurring
--   { id, every = "daily" | "weekly" | seconds, at = offset into the period, duration,
--     from?, ["until"]?, data? }
-- Daily periods start at 00:00 UTC, weekly ones on Monday 00:00 UTC, numeric periods at the
-- epoch. active(now) lists the windows open at now (start <= now < end), next(now) the earliest
-- start after now. rotation() picks count items from a pool per period with a seed, so every
-- server shows the same rotating shop or featured list in the same period. Time is server UTC
-- passed by the adapter (os.time() or DateTime.now().UnixTimestamp), never a client clock.
local Check = require("./Check")
local Rng = require("../ProcGen/Rng")

local LiveOps = {}
LiveOps.__index = LiveOps
LiveOps.DAY = 86400
LiveOps.WEEK = 7 * 86400
LiveOps.MONDAY_ANCHOR = 4 * 86400 -- 1970-01-05T00:00:00Z, the first Monday

-- Days from 1970-01-01 to a civil date (proleptic Gregorian; Howard Hinnant's algorithm).
local function daysFromCivil(y: number, m: number, d: number): number
	y -= if m <= 2 then 1 else 0
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z: number): (number, number, number)
	z += 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return y + (if m <= 2 then 1 else 0), m, d
end

-- UTC seconds for "YYYY-MM-DDTHH:MM:SSZ", or nil for anything else (including impossible dates).
function LiveOps.parseUtc(text: any): number?
	if type(text) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
	if y == nil then
		return nil
	end
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	local hour, minute, second = tonumber(h) :: number, tonumber(mi) :: number, tonumber(s) :: number
	if month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59 then
		return nil
	end
	local days = daysFromCivil(year, month, day)
	local cy, cm, cd = civilFromDays(days)
	if cy ~= year or cm ~= month or cd ~= day then
		return nil -- 2026-02-30 and friends
	end
	return days * LiveOps.DAY + hour * 3600 + minute * 60 + second
end

-- "YYYY-MM-DDTHH:MM:SSZ" for UTC seconds (whole seconds).
function LiveOps.formatUtc(utc: number): string
	local seconds = math.floor(utc)
	local days = seconds // LiveOps.DAY
	local rest = seconds - days * LiveOps.DAY
	local y, m, d = civilFromDays(days)
	return string.format(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		y,
		m,
		d,
		rest // 3600,
		(rest // 60) % 60,
		rest % 60
	)
end

local function time(value: any): number?
	if type(value) == "string" then
		return LiveOps.parseUtc(value)
	end
	if Check.finite(value) then
		return value
	end
	return nil
end

export type Window = {
	id: string,
	start: number?,
	finish: number?,
	period: number?,
	anchor: number?,
	at: number?,
	duration: number?,
	from: number?,
	untilTime: number?,
	data: any?,
}
export type Occurrence = { id: string, start: number, ["end"]: number, data: any? }

-- Problems with a schedule config (empty when valid).
function LiveOps.validate(config: any): { string }
	if type(config) ~= "table" or type(config.windows) ~= "table" then
		return { "config needs a windows list" }
	end
	local problems = {}
	local seen = {}
	for index, raw in config.windows do
		local where = "window "
			.. (if type(raw) == "table" and type(raw.id) == "string" then raw.id else "#" .. tostring(index))
		if type(raw) ~= "table" then
			table.insert(problems, where .. ": must be a table")
			continue
		end
		if not Check.label(raw.id) then
			table.insert(problems, where .. ": id is not a label")
		elseif seen[raw.id] then
			table.insert(problems, where .. ": duplicate id")
		end
		seen[raw.id] = true
		if raw.every == nil then
			local start, finish = time(raw.start), time(raw["end"])
			if start == nil or finish == nil then
				table.insert(problems, where .. ": start and end must be UTC seconds or YYYY-MM-DDTHH:MM:SSZ")
			elseif finish <= start then
				table.insert(problems, where .. ": end must be after start")
			end
		else
			local period = if raw.every == "daily"
				then LiveOps.DAY
				elseif raw.every == "weekly" then LiveOps.WEEK
				else raw.every
			if not (Check.integer(period) and period >= 60) then
				table.insert(problems, where .. ": every must be daily, weekly or whole seconds >= 60")
				continue
			end
			local at = raw.at or 0
			if not (Check.integer(at) and at >= 0 and at < period) then
				table.insert(problems, where .. ": at must be whole seconds within the period")
			end
			if not (Check.integer(raw.duration) and raw.duration >= 1 and raw.duration <= period) then
				table.insert(problems, where .. ": duration must be whole seconds from 1 to the period")
			end
			local from, untilTime = raw.from and time(raw.from), raw["until"] and time(raw["until"])
			if (raw.from ~= nil and from == nil) or (raw["until"] ~= nil and untilTime == nil) then
				table.insert(problems, where .. ": from and until must be UTC seconds or ISO 8601")
			elseif from and untilTime and untilTime <= from then
				table.insert(problems, where .. ": until must be after from")
			end
		end
	end
	return problems
end

type ScheduleFields = { _windows: { Window } }
export type Schedule = typeof(setmetatable({} :: ScheduleFields, LiveOps))

-- A validated, frozen schedule. Raises with every problem listed.
function LiveOps.define(config: any): Schedule
	local problems = LiveOps.validate(config)
	if #problems > 0 then
		error("LiveOps.define: " .. table.concat(problems, "; "), 2)
	end
	local windows = {}
	for _, raw in config.windows do
		local window: Window
		if raw.every == nil then
			window = {
				id = raw.id,
				start = time(raw.start),
				finish = time(raw["end"]),
				data = Check.copy(raw.data),
			}
		else
			local period = if raw.every == "daily"
				then LiveOps.DAY
				elseif raw.every == "weekly" then LiveOps.WEEK
				else raw.every
			window = {
				id = raw.id,
				period = period,
				anchor = if raw.every == "weekly" then LiveOps.MONDAY_ANCHOR else 0,
				at = raw.at or 0,
				duration = raw.duration,
				from = raw.from and time(raw.from),
				untilTime = raw["until"] and time(raw["until"]),
				data = Check.copy(raw.data),
			}
		end
		table.insert(windows, Check.freeze(window))
	end
	table.sort(windows, function(a: Window, b: Window): boolean
		return a.id < b.id
	end)
	return setmetatable({ _windows = windows }, LiveOps)
end

local function allowed(window: Window, start: number): boolean
	return (window.from == nil or start >= window.from)
		and (window.untilTime == nil or start < window.untilTime)
end

-- The occurrence of window open at now, or nil.
local function openAt(window: Window, now: number): Occurrence?
	if window.period == nil then
		if (window.start :: number) <= now and now < (window.finish :: number) then
			return {
				id = window.id,
				start = window.start :: number,
				["end"] = window.finish :: number,
				data = window.data,
			}
		end
		return nil
	end
	local period, base = window.period :: number, (window.anchor :: number) + (window.at :: number)
	local k = (now - base) // period
	local start = base + k * period
	if now < start + (window.duration :: number) and allowed(window, start) then
		return {
			id = window.id,
			start = start,
			["end"] = start + (window.duration :: number),
			data = window.data,
		}
	end
	return nil
end

-- Windows open at now (UTC seconds), sorted by id.
function LiveOps.active(self: Schedule, now: number): { Occurrence }
	assert(Check.finite(now), "LiveOps.active needs UTC seconds")
	local out = {}
	for _, window in self._windows do
		local occurrence = openAt(window, now)
		if occurrence then
			table.insert(out, occurrence)
		end
	end
	return out
end

function LiveOps.isActive(self: Schedule, id: string, now: number): boolean
	for _, occurrence in self:active(now) do
		if occurrence.id == id then
			return true
		end
	end
	return false
end

-- The earliest window start strictly after now (ties by id), or nil when none is left.
function LiveOps.next(self: Schedule, now: number): Occurrence?
	assert(Check.finite(now), "LiveOps.next needs UTC seconds")
	local best: Occurrence? = nil
	for _, window in self._windows do
		local candidate: Occurrence? = nil
		if window.period == nil then
			if (window.start :: number) > now then
				candidate = {
					id = window.id,
					start = window.start :: number,
					["end"] = window.finish :: number,
					data = window.data,
				}
			end
		else
			local period, base = window.period :: number, (window.anchor :: number) + (window.at :: number)
			local k = (now - base) // period + 1
			local start = base + k * period
			if window.from and start < window.from then
				start = base + math.ceil((window.from - base) / period) * period
			end
			if allowed(window, start) then
				candidate = {
					id = window.id,
					start = start,
					["end"] = start + (window.duration :: number),
					data = window.data,
				}
			end
		end
		if candidate and (best == nil or candidate.start < (best :: Occurrence).start) then
			best = candidate
		end
	end
	return best
end

export type RotationOptions = { period: number, count: number, seed: number | string, offset: number? }

-- count picks from pool for the period that holds now: { picks, index, startsAt, endsAt }. The
-- same seed and period give the same picks everywhere; consecutive periods reshuffle.
function LiveOps.rotation(pool: { any }, options: RotationOptions, now: number): any
	assert(type(pool) == "table" and #pool >= 1, "LiveOps.rotation needs a non-empty pool")
	assert(
		Check.integer(options.period) and options.period >= 60,
		"rotation period must be whole seconds >= 60"
	)
	assert(Check.integer(options.count) and options.count >= 1, "rotation count must be an integer >= 1")
	assert(options.seed ~= nil, "rotation needs a seed")
	assert(Check.finite(now), "LiveOps.rotation needs UTC seconds")
	local offset = options.offset or 0
	local index = (now - offset) // options.period
	local order = table.clone(pool)
	Rng.new(tostring(options.seed) .. ":" .. string.format("%d", index)):shuffle(order)
	local picks = {}
	for i = 1, math.min(options.count, #order) do
		table.insert(picks, order[i])
	end
	local startsAt = offset + index * options.period
	return { picks = picks, index = index, startsAt = startsAt, endsAt = startsAt + options.period }
end

return LiveOps
