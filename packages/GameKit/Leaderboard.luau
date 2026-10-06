--!strict
-- @tier T0
-- Leaderboard: pure ranking with explicit tie-breaks, score validation and the integer packing an
-- OrderedDataStore needs (it sorts whole numbers only, so "who got there first" has to live in the
-- number). Ranks:
--   standard  1, 2, 2, 4 (equal scores share a rank, the next rank skips)
--   dense     1, 2, 2, 3
--   ordinal   1, 2, 3, 4 (ties broken by `at`, earlier first, then key)
-- Entries are { key, score, at? } with key a string (tostring(UserId), never a user name).
-- LeaderboardRoblox persists boards; LiveBoard keeps session boards in a sorted map.
local Check = require("./Check")

local Leaderboard = {}

export type Entry = { key: string, score: number, at: number? }
export type Ranked = { key: string, score: number, at: number?, rank: number }
export type Options = {
	order: ("desc" | "asc")?, -- desc: higher is better (default)
	ranks: ("standard" | "dense" | "ordinal")?, -- default standard
	integer: boolean?, -- scores must be whole numbers (default true: OrderedDataStore stores integers)
	min: number?, -- inclusive score bounds (default 0 .. 2^53 - 1)
	max: number?,
	limit: number?, -- entries a board keeps (default 100)
}

Leaderboard.MAX_SAFE = 2 ^ 53 - 1

local function option(options: Options?, key: string, default: any): any
	local value = options and (options :: any)[key]
	if value == nil then
		return default
	end
	return value
end

-- Problems with options (empty when valid).
function Leaderboard.validate(options: Options?): { string }
	local problems = {}
	local order = option(options, "order", "desc")
	if order ~= "desc" and order ~= "asc" then
		table.insert(problems, "order must be desc or asc")
	end
	local ranks = option(options, "ranks", "standard")
	if ranks ~= "standard" and ranks ~= "dense" and ranks ~= "ordinal" then
		table.insert(problems, "ranks must be standard, dense or ordinal")
	end
	local min, max = option(options, "min", 0), option(options, "max", Leaderboard.MAX_SAFE)
	if not Check.finite(min) or not Check.finite(max) or min > max then
		table.insert(problems, "min and max must be finite with min <= max")
	end
	local limit = option(options, "limit", 100)
	if not Check.integer(limit) or limit < 1 then
		table.insert(problems, "limit must be an integer >= 1")
	end
	return problems
end

-- Why a score is refused (nil when accepted): not_finite, not_integer, out_of_range.
function Leaderboard.scoreProblem(score: any, options: Options?): string?
	if not Check.finite(score) then
		return "not_finite"
	end
	if option(options, "integer", true) and score % 1 ~= 0 then
		return "not_integer"
	end
	if score < option(options, "min", 0) or score > option(options, "max", Leaderboard.MAX_SAFE) then
		return "out_of_range"
	end
	return nil
end

-- True when score a beats score b under the order.
function Leaderboard.better(a: number, b: number, options: Options?): boolean
	if option(options, "order", "desc") == "asc" then
		return a < b
	end
	return a > b
end

-- Sorted copy with ranks. Equal scores order by `at` (earlier first; missing last), then key.
function Leaderboard.rank(entries: { Entry }, options: Options?): { Ranked }
	local sorted: { Ranked } = {}
	for _, entry in entries do
		table.insert(sorted, { key = entry.key, score = entry.score, at = entry.at, rank = 0 })
	end
	table.sort(sorted, function(a, b)
		if a.score ~= b.score then
			return Leaderboard.better(a.score, b.score, options)
		end
		local at, bt = a.at or math.huge, b.at or math.huge
		if at ~= bt then
			return at < bt
		end
		return a.key < b.key
	end)
	local mode = option(options, "ranks", "standard")
	local dense = 0
	for i, entry in sorted do
		local previous = sorted[i - 1]
		local tied = previous ~= nil and previous.score == entry.score
		if mode == "ordinal" then
			entry.rank = i
		elseif mode == "dense" then
			dense += if tied then 0 else 1
			entry.rank = dense
		else
			entry.rank = if tied then previous.rank else i
		end
	end
	return sorted
end

-- Packs (score, at) into one integer that sorts like Leaderboard.rank with ordinal ties under a
-- descending store: higher scores first, then the earlier `at`. `at` is whole seconds in
-- [0, horizon). The result must stay below 2^53 (raises otherwise).
function Leaderboard.pack(score: number, at: number, horizon: number): number
	assert(Check.integer(score) and score >= 0, "Leaderboard.pack: score must be an integer >= 0")
	assert(Check.integer(horizon) and horizon >= 1, "Leaderboard.pack: horizon must be an integer >= 1")
	assert(
		Check.integer(at) and at >= 0 and at < horizon,
		"Leaderboard.pack: at must be an integer in [0, horizon)"
	)
	local packed = score * horizon + (horizon - 1 - at)
	assert(packed <= Leaderboard.MAX_SAFE, "Leaderboard.pack: score * horizon exceeds 2^53")
	return packed
end

function Leaderboard.unpack(packed: number, horizon: number): (number, number)
	local score = packed // horizon
	return score, horizon - 1 - (packed - score * horizon)
end

export type Board = {
	options: Options,
	best: { [string]: Entry },
	submit: (self: Board, key: string, score: number, at: number?) -> (boolean, string?),
	top: (self: Board, count: number?) -> { Ranked },
	rankOf: (self: Board, key: string) -> Ranked?,
	remove: (self: Board, key: string) -> boolean,
	snapshot: (self: Board) -> { Entry },
}

local BoardMethods = {}

-- Keeps the best score per key; reasons not_finite, not_integer, out_of_range, not_better.
function BoardMethods.submit(self: Board, key: string, score: number, at: number?): (boolean, string?)
	if type(key) ~= "string" or key == "" then
		return false, "bad_key"
	end
	local problem = Leaderboard.scoreProblem(score, self.options)
	if problem then
		return false, problem
	end
	local current = self.best[key]
	if current and not Leaderboard.better(score, current.score, self.options) then
		return false, "not_better"
	end
	self.best[key] = { key = key, score = score, at = at }
	-- Trim to the limit (the worst ranked entries go).
	local limit = option(self.options, "limit", 100)
	local count = 0
	for _ in self.best do
		count += 1
	end
	if count > limit then
		local ranked = Leaderboard.rank(self:snapshot(), { order = self.options.order, ranks = "ordinal" })
		for i = limit + 1, #ranked do
			self.best[ranked[i].key] = nil
		end
		if self.best[key] == nil then
			return false, "below_limit"
		end
	end
	return true, nil
end

function BoardMethods.snapshot(self: Board): { Entry }
	local out = {}
	for _, entry in self.best do
		table.insert(out, table.clone(entry))
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

function BoardMethods.top(self: Board, count: number?): { Ranked }
	local ranked = Leaderboard.rank(self:snapshot(), self.options)
	local n = count or #ranked
	local out = {}
	for i = 1, math.min(n, #ranked) do
		table.insert(out, ranked[i])
	end
	return out
end

function BoardMethods.rankOf(self: Board, key: string): Ranked?
	for _, entry in Leaderboard.rank(self:snapshot(), self.options) do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

function BoardMethods.remove(self: Board, key: string): boolean
	local had = self.best[key] ~= nil
	self.best[key] = nil
	return had
end

-- An in-memory board (one server, or the merged view of a store's pages).
function Leaderboard.new(options: Options?): Board
	local problems = Leaderboard.validate(options)
	if #problems > 0 then
		error("Leaderboard.new: " .. table.concat(problems, "; "), 2)
	end
	local board = { options = table.clone(options or {}), best = {} }
	for name, fn in BoardMethods do
		(board :: any)[name] = fn
	end
	return board :: any
end

return Leaderboard
