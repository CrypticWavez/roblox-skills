--!strict
-- @tier T0
-- Streaks: daily check-in streaks from server UTC seconds (the adapter passes os.time() or
-- DateTime.now().UnixTimestamp from the server, never a client clock). Days are
-- floor((utc + offset) / 86400): offset moves the daily reset away from 00:00 UTC. Rules:
--   same day                -> "already" (no change)
--   next day                -> "continued"
--   missed <= graceDays     -> "continued" with grace = true
--   missed > graceDays      -> onMiss "reset" (streak restarts at 1) or "decay" (loses decay
--                              days, then counts today)
--   an earlier day          -> "clock_skew" (never punishes; no change)
-- Rewards are the game's data: rewards[streakDay], or with cycle = n, rewards[((streak-1) % n)+1].
-- Also dayIndex/weekIndex/nextReset helpers that Objectives and LiveOps share.
local Check = require("./Check")
local Events = require("./Events")

local Streaks = {}
Streaks.__index = Streaks
Streaks.SCHEMA = "streaks/1"
Streaks.DAY = 86400
Streaks.WEEK = 7 * 86400

local function assertTime(utc: any, offset: any)
	if not (Check.finite(utc) and utc >= 0) then
		error("Streaks: utc seconds must be a finite number >= 0 (got " .. Check.describe(utc) .. ")", 3)
	end
	if offset ~= nil and not (Check.integer(offset) and math.abs(offset) < Streaks.DAY) then
		error("Streaks: offset must be whole seconds within one day", 3)
	end
end

-- Day number since 1970-01-01 (UTC, shifted by offset seconds).
function Streaks.dayIndex(utc: number, offset: number?): number
	assertTime(utc, offset)
	return (math.floor(utc) + (offset or 0)) // Streaks.DAY
end

-- Week number with weeks starting Monday 00:00 (UTC + offset). 1970-01-01 was a Thursday.
function Streaks.weekIndex(utc: number, offset: number?): number
	return (Streaks.dayIndex(utc, offset) + 3) // 7
end

-- Seconds until the next daily reset.
function Streaks.nextReset(utc: number, offset: number?): number
	local day = Streaks.dayIndex(utc, offset)
	return (day + 1) * Streaks.DAY - (offset or 0) - utc
end

export type Options = {
	graceDays: number?, -- missed days forgiven (default 0)
	onMiss: ("reset" | "decay")?, -- default reset
	decay: number?, -- days lost per broken streak with onMiss = decay (default 1)
	max: number?, -- streak cap (optional)
	offset: number?, -- seconds added to UTC before taking the day (default 0)
	rewards: { [number]: any }?,
	cycle: number?, -- rewards repeat every cycle days
	sink: Events.Sink?,
	player: string?,
	name: string?, -- custom event name (default "streak_check_in")
	data: any?,
}
export type Result = {
	status: "started" | "continued" | "already" | "reset" | "decayed" | "clock_skew",
	streak: number,
	best: number,
	day: number,
	missed: number,
	grace: boolean,
	reward: any?,
}
type StreakFields = {
	notes: { string },
	_options: Options,
	_lastDay: number?,
	_streak: number,
	_best: number,
	_total: number,
}
export type Streak = typeof(setmetatable({} :: StreakFields, Streaks))

-- Problems with streak options (empty when valid).
function Streaks.validate(options: any): { string }
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	local problems = {}
	local function int(key: string, low: number, high: number?)
		local value = options[key]
		if
			value ~= nil and not (Check.integer(value) and value >= low and (high == nil or value <= high))
		then
			table.insert(
				problems,
				string.format(
					"%s must be an integer >= %d%s",
					key,
					low,
					if high then " and <= " .. high else ""
				)
			)
		end
	end
	int("graceDays", 0, 365)
	int("decay", 1)
	int("max", 1)
	int("cycle", 1)
	if
		options.offset ~= nil
		and not (Check.integer(options.offset) and math.abs(options.offset) < Streaks.DAY)
	then
		table.insert(problems, "offset must be whole seconds within one day")
	end
	if options.onMiss ~= nil and options.onMiss ~= "reset" and options.onMiss ~= "decay" then
		table.insert(problems, "onMiss must be reset or decay")
	end
	if options.rewards ~= nil and type(options.rewards) ~= "table" then
		table.insert(problems, "rewards must map streak day -> reward data")
	end
	if options.name ~= nil and not Check.label(options.name) then
		table.insert(problems, "name must be a label")
	end
	return problems
end

function Streaks.new(options: Options?, _env: any?): Streak
	local opts: Options = options or {}
	local problems = Streaks.validate(opts)
	if #problems > 0 then
		error("Streaks.new: " .. table.concat(problems, "; "), 2)
	end
	local self = setmetatable({
		notes = {},
		-- Shallow copy so the sink stays the caller's object; rewards are data and deep-copied.
		_options = table.clone(opts),
		_lastDay = nil,
		_streak = 0,
		_best = 0,
		_total = 0,
	}, Streaks)
	if opts.rewards then
		self._options.rewards = Check.copy(opts.rewards)
	end
	local data = opts.data
	if data ~= nil then
		if type(data) ~= "table" or data.schema ~= Streaks.SCHEMA then
			table.insert(self.notes, "stored data is not streaks/1; starting fresh")
		else
			if data.lastDay ~= nil and Check.integer(data.lastDay) and data.lastDay >= 0 then
				self._lastDay = data.lastDay
			end
			for _, key in { "streak", "best", "total" } do
				local value = data[key]
				if Check.integer(value) and value >= 0 then
					(self :: any)["_" .. key] = value
				elseif value ~= nil then
					table.insert(self.notes, key .. " was invalid and reset to 0")
				end
			end
		end
	end
	return self
end

local function rewardFor(options: Options, streak: number): any
	local rewards = options.rewards
	if rewards == nil then
		return nil
	end
	local index = if options.cycle then ((streak - 1) % options.cycle) + 1 else streak
	local reward = rewards[index]
	return if reward ~= nil then Check.copy(reward) else nil
end

-- What checkIn(utc) would do, without changing anything.
function Streaks.peek(self: Streak, utc: number): Result
	local options = self._options
	local day = Streaks.dayIndex(utc, options.offset)
	local last = self._lastDay
	local streak, status, missed, grace = self._streak, "started", 0, false
	if last == nil then
		streak, status = 1, "started"
	elseif day == last then
		status = "already"
	elseif day < last then
		status = "clock_skew"
	else
		missed = day - last - 1
		if missed == 0 then
			streak, status = streak + 1, "continued"
		elseif missed <= (options.graceDays or 0) then
			streak, status, grace = streak + 1, "continued", true
		elseif options.onMiss == "decay" then
			streak, status = math.max(streak - (options.decay or 1), 0) + 1, "decayed"
		else
			streak, status = 1, "reset"
		end
		if self._streak == 0 and status ~= "continued" then
			status = "started"
		end
	end
	if options.max then
		streak = math.min(streak, options.max)
	end
	local changed = status ~= "already" and status ~= "clock_skew"
	return {
		status = status :: any,
		streak = streak,
		best = math.max(self._best, streak),
		day = day,
		missed = missed,
		grace = grace,
		reward = if changed then rewardFor(options, streak) else nil,
	}
end

-- Records a check-in at server UTC seconds and returns the result (see the header).
function Streaks.checkIn(self: Streak, utc: number): Result
	local result = self:peek(utc)
	if result.status == "already" or result.status == "clock_skew" then
		return result
	end
	self._lastDay = result.day
	self._streak = result.streak
	self._best = result.best
	self._total += 1
	local sink = self._options.sink
	if sink then
		local event =
			Events.custom(self._options.name or "streak_check_in", result.streak, { status = result.status })
		if self._options.player then
			event.player = self._options.player
		end
		pcall(function()
			(sink :: any):emit(event)
		end)
	end
	return result
end

function Streaks.streak(self: Streak): number
	return self._streak
end

function Streaks.best(self: Streak): number
	return self._best
end

function Streaks.total(self: Streak): number
	return self._total
end

function Streaks.lastDay(self: Streak): number?
	return self._lastDay
end

function Streaks.serialize(self: Streak): any
	return {
		schema = Streaks.SCHEMA,
		lastDay = self._lastDay,
		streak = self._streak,
		best = self._best,
		total = self._total,
	}
end

return Streaks
