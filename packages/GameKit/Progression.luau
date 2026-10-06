--!strict
-- @tier T0
-- Progression: XP curves, levels, prestige and reward hooks. A curve is data:
--   { kind = "linear", base, step, maxLevel }        xp to go from level L to L+1 = base + step*(L-1)
--   { kind = "power", base, exponent, maxLevel }     floor(base * L^exponent), at least 1
--   { kind = "table", requirements = { n, ... } }    explicit per-level requirements
-- Levels start at 1; every requirement and cumulative total is a whole number within 2^53.
-- A track (Progression.new) adds XP, crosses levels, lists the rewards (game data, never
-- granted here: the caller grants through Wallet or Inventory), fires `leveled` and emits one
-- kit-event/1 progression event per addXp that gains levels (status complete, level = the level
-- reached) and one per prestige. No curve numbers ship here.
local Check = require("./Check")
local Events = require("./Events")
local Signal = require("./Signal")

local Progression = {}
Progression.SCHEMA = "progression/1"
-- Upper bound on maxLevel so cumulative tables stay small (convention).
Progression.MAX_LEVEL = 100000

local Curve = {}
Curve.__index = Curve
local Track = {}
Track.__index = Track

type CurveFields = { kind: string, maxLevel: number, _cumulative: { number } }
export type Curve = typeof(setmetatable({} :: CurveFields, Curve))

local function requirementOf(spec: any, level: number): number
	if spec.kind == "linear" then
		return spec.base + spec.step * (level - 1)
	elseif spec.kind == "power" then
		return math.max(1, math.floor(spec.base * level ^ spec.exponent))
	end
	return spec.requirements[level]
end

-- Problems with a curve spec (empty when valid), including cumulative overflow past 2^53.
function Progression.validateCurve(spec: any): { string }
	if type(spec) ~= "table" then
		return { "curve must be a table" }
	end
	local problems = {}
	local kind = spec.kind
	local maxLevel = spec.maxLevel
	if kind == "linear" then
		if not (Check.integer(spec.base) and spec.base >= 1) then
			table.insert(problems, "linear: base must be an integer >= 1")
		end
		if not (Check.integer(spec.step) and spec.step >= 0) then
			table.insert(problems, "linear: step must be an integer >= 0")
		end
	elseif kind == "power" then
		if not (Check.finite(spec.base) and spec.base > 0) then
			table.insert(problems, "power: base must be a finite number > 0")
		end
		if not (Check.finite(spec.exponent) and spec.exponent > 0 and spec.exponent <= 8) then
			table.insert(problems, "power: exponent must be a finite number in (0, 8]")
		end
	elseif kind == "table" then
		local list = spec.requirements
		if type(list) ~= "table" or #list == 0 then
			table.insert(problems, "table: requirements must be a non-empty list")
		else
			for index, value in list do
				if not (Check.integer(value) and value >= 1) then
					table.insert(
						problems,
						string.format("table: requirement %s must be an integer >= 1", tostring(index))
					)
				end
			end
			maxLevel = #list + 1
			if spec.maxLevel ~= nil and spec.maxLevel ~= maxLevel then
				table.insert(problems, "table: maxLevel must equal #requirements + 1 (or be omitted)")
			end
		end
	else
		table.insert(problems, "kind must be linear, power or table")
		return problems
	end
	if not (Check.integer(maxLevel) and maxLevel >= 1 and maxLevel <= Progression.MAX_LEVEL) then
		table.insert(
			problems,
			string.format("maxLevel must be an integer from 1 to %d", Progression.MAX_LEVEL)
		)
	end
	if #problems > 0 then
		return problems
	end
	local total = 0
	for level = 1, maxLevel - 1 do
		local need = requirementOf(spec, level)
		if not (Check.integer(need) and need >= 1) then
			table.insert(
				problems,
				string.format("level %d requirement %s is not a whole number >= 1", level, tostring(need))
			)
			break
		end
		total += need
		if total > Check.MAX_SAFE_INTEGER then
			table.insert(problems, string.format("cumulative xp passes 2^53 at level %d", level + 1))
			break
		end
	end
	return problems
end

-- A frozen curve. Raises with every problem listed.
function Progression.curve(spec: any): Curve
	local problems = Progression.validateCurve(spec)
	if #problems > 0 then
		error("Progression.curve: " .. table.concat(problems, "; "), 2)
	end
	local maxLevel = if spec.kind == "table" then #spec.requirements + 1 else spec.maxLevel
	local cumulative = { 0 }
	for level = 1, maxLevel - 1 do
		cumulative[level + 1] = cumulative[level] + requirementOf(spec, level)
	end
	return setmetatable({ kind = spec.kind, maxLevel = maxLevel, _cumulative = cumulative }, Curve)
end

function Progression.isCurve(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Curve
end

-- XP needed to go from level to level + 1 (0 at or past maxLevel).
function Curve.xpToNext(self: Curve, level: number): number
	if level >= self.maxLevel or level < 1 then
		return 0
	end
	return self._cumulative[level + 1] - self._cumulative[level]
end

-- Cumulative XP from level 1 to reach level (clamped to 1..maxLevel).
function Curve.totalFor(self: Curve, level: number): number
	return self._cumulative[math.clamp(math.floor(level), 1, self.maxLevel)]
end

-- (level, xp into that level, xp needed for the next level; 0 at max) for a total.
function Curve.levelFor(self: Curve, totalXp: number): (number, number, number)
	local cumulative = self._cumulative
	if totalXp <= 0 then
		return 1, 0, self:xpToNext(1)
	end
	-- Binary search for the highest level whose cumulative total is <= totalXp.
	local low, high = 1, self.maxLevel
	while low < high do
		local mid = (low + high + 1) // 2
		if cumulative[mid] <= totalXp then
			low = mid
		else
			high = mid - 1
		end
	end
	return low, totalXp - cumulative[low], self:xpToNext(low)
end

-- Rewards for levels from (exclusive) .. to (inclusive), ascending: { { level, reward } }.
function Progression.rewardsBetween(rewards: { [number]: any }?, from: number, to: number): { any }
	local out = {}
	if rewards == nil then
		return out
	end
	for level = from + 1, to do
		if rewards[level] ~= nil then
			table.insert(out, { level = level, reward = Check.copy(rewards[level]) })
		end
	end
	return out
end

export type Options = {
	curve: Curve,
	path: string, -- kit-event/1 progression path label
	rewards: { [number]: any }?, -- level -> reward data (the game's)
	prestige: { max: number? }?, -- allow prestige (reset to level 1 at max level), optionally capped
	sink: Events.Sink?,
	player: string?,
	data: any?, -- progression/1 data to start from
	report: ((message: string) -> ())?,
}
type TrackFields = {
	leveled: Signal.Signal,
	prestiged: Signal.Signal,
	notes: { string },
	_curve: Curve,
	_path: string,
	_rewards: { [number]: any }?,
	_prestige: { max: number? }?,
	_sink: Events.Sink?,
	_player: string?,
	_xp: number,
	_prestiges: number,
	_report: (message: string) -> (),
}
export type Track = typeof(setmetatable({} :: TrackFields, Track))

-- A level track for one player. Raises on invalid options. track.notes lists load repairs.
function Progression.new(options: Options, env: any?): Track
	assert(type(options) == "table", "Progression.new: options must be a table")
	local problems = {}
	if not Progression.isCurve(options.curve) then
		table.insert(problems, "curve must come from Progression.curve")
	end
	if not Check.label(options.path, 48) then
		table.insert(problems, "path must be a label of at most 48 characters")
	end
	if options.rewards ~= nil then
		if type(options.rewards) ~= "table" then
			table.insert(problems, "rewards must map level -> reward data")
		else
			for level in options.rewards do
				if not (Check.integer(level) and level >= 2) then
					table.insert(
						problems,
						"reward level " .. Check.describe(level) .. " must be an integer >= 2"
					)
				end
			end
		end
	end
	local prestige = options.prestige
	if
		prestige ~= nil
		and (
			type(prestige) ~= "table"
			or (prestige.max ~= nil and not (Check.integer(prestige.max) and prestige.max >= 1))
		)
	then
		table.insert(problems, "prestige must be { max = integer >= 1 }?")
	end
	if #problems > 0 then
		error("Progression.new: " .. table.concat(problems, "; "), 2)
	end
	local self = setmetatable({
		leveled = Signal.new(env),
		prestiged = Signal.new(env),
		notes = {},
		_curve = options.curve,
		_path = options.path,
		_rewards = options.rewards and Check.copy(options.rewards),
		_prestige = prestige,
		_sink = options.sink,
		_player = options.player,
		_xp = 0,
		_prestiges = 0,
		_report = options.report
			or (env and type(env.report) == "function" and env.report)
			or function(_message: string) end,
	}, Track)
	local data = options.data
	if data ~= nil then
		if type(data) ~= "table" or data.schema ~= Progression.SCHEMA then
			table.insert(self.notes, "stored data is not progression/1; starting at level 1")
		else
			if Check.integer(data.xp) and data.xp >= 0 then
				local cap = self._curve:totalFor(self._curve.maxLevel)
				if data.xp > cap then
					table.insert(self.notes, "xp above the curve's maximum clamped")
				end
				self._xp = math.min(data.xp, cap)
			else
				table.insert(self.notes, "invalid xp reset to 0")
			end
			if Check.integer(data.prestige) and data.prestige >= 0 then
				self._prestiges = data.prestige
			elseif data.prestige ~= nil then
				table.insert(self.notes, "invalid prestige reset to 0")
			end
		end
	end
	return self
end

local function emit(self: Track, name: string, path: string, level: number, fields: { [string]: string }?)
	local sink = self._sink
	if sink == nil then
		return
	end
	local event = Events.progression(name, { path = path, status = "complete", level = level }, fields)
	if self._player then
		event.player = self._player
	end
	local ok, err = pcall(function()
		(sink :: any):emit(event)
	end)
	if not ok then
		self._report("Progression: sink error: " .. tostring(err))
	end
end

function Track.level(self: Track): number
	return (self._curve:levelFor(self._xp))
end

-- Total XP within the current prestige.
function Track.xp(self: Track): number
	return self._xp
end

function Track.prestiges(self: Track): number
	return self._prestiges
end

-- { level, into, needed, fraction (0..1; 1 at max level), maxed }
function Track.progress(self: Track): any
	local level, into, needed = self._curve:levelFor(self._xp)
	return {
		level = level,
		into = into,
		needed = needed,
		fraction = if needed == 0 then 1 else into / needed,
		maxed = level >= self._curve.maxLevel,
	}
end

-- Adds XP (integer > 0). At max level the rest is discarded and reported. Returns
-- (true, nil, { applied, discarded, from, to, rewards = { { level, reward } } }) or
-- (false, "invalid_amount").
function Track.addXp(self: Track, amount: number): (boolean, string?, any)
	if not (Check.integer(amount) and amount > 0) then
		return false, "invalid_amount", nil
	end
	local curve = self._curve
	local cap = curve:totalFor(curve.maxLevel)
	local from = self:level()
	local applied = math.min(amount, cap - self._xp)
	self._xp += applied
	local to = self:level()
	local rewards = Progression.rewardsBetween(self._rewards, from, to)
	if to > from then
		for level = from + 1, to do
			local reward = self._rewards and self._rewards[level]
			self.leveled:Fire(level, if reward ~= nil then Check.copy(reward) else nil)
		end
		emit(self, "level_up", self._path, to, { gained = tostring(to - from) })
	end
	return true,
		nil,
		{ applied = applied, discarded = amount - applied, from = from, to = to, rewards = rewards }
end

-- Resets to level 1 and counts a prestige. Needs a prestige option and max level; refuses past
-- prestige.max. Returns (ok, err) with err not_enabled, not_max_level or prestige_cap.
function Track.prestige(self: Track): (boolean, string?)
	local options = self._prestige
	if options == nil then
		return false, "not_enabled"
	end
	if self:level() < self._curve.maxLevel then
		return false, "not_max_level"
	end
	if options.max and self._prestiges >= options.max then
		return false, "prestige_cap"
	end
	self._prestiges += 1
	self._xp = 0
	self.prestiged:Fire(self._prestiges)
	emit(self, "prestige", self._path, self._prestiges, nil)
	return true, nil
end

function Track.serialize(self: Track): any
	return { schema = Progression.SCHEMA, xp = self._xp, prestige = self._prestiges }
end

return Progression
