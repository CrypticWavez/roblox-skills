--!strict
-- @tier T0
-- LiveBoard: a short-lived cross-server board (current round, today's event) on a sorted map with
-- MemoryStore semantics: items { key, value, sortKey } with an expiration, read in sort-key order
-- by GetRangeAsync. The map is passed in: LiveBoardRoblox.map(name, env) wraps a MemoryStore
-- sorted map (T4), and Lune specs use tests/fakes/FakeLiveSortedMap. The sort key is the score;
-- the value keeps { score, at } so Leaderboard.rank breaks ties by time. Every method calls the
-- map and so may yield in Roblox: never call one from a simulation step.
--
-- Map interface (MemoryStoreSortedMap names; direction is "Ascending" or "Descending"):
--   map:GetAsync(key) -> (value?, sortKey?)
--   map:UpdateAsync(key, transform(value?, sortKey?) -> (value?, sortKey?), expiration) -> (value?, sortKey?)
--   map:RemoveAsync(key)
--   map:GetRangeAsync(direction, count, exclusiveLowerBound?, exclusiveUpperBound?) -> { { key, value, sortKey } }
local Check = require("./Check")
local Leaderboard = require("./Leaderboard")

local LiveBoard = {}

-- MemoryStore limits (Roblox documentation): expiration up to 45 days, GetRangeAsync count 1-200,
-- keys up to 128 characters.
LiveBoard.MAX_EXPIRATION = 3888000
LiveBoard.MAX_RANGE = 200
LiveBoard.MAX_KEY = 128

export type Options = Leaderboard.Options & {
	ttl: number?, -- seconds an entry lives after its last improvement (default 600, convention)
}

export type Board = {
	map: any,
	options: Options,
	submit: (self: Board, key: string, score: number, at: number?) -> (boolean, string?),
	top: (self: Board, count: number) -> { Leaderboard.Ranked },
	get: (self: Board, key: string) -> Leaderboard.Entry?,
	remove: (self: Board, key: string) -> (),
}

function LiveBoard.validate(options: Options?): { string }
	local problems = Leaderboard.validate(options)
	local ttl = options and options.ttl
	if ttl ~= nil and (not Check.finite(ttl) or ttl <= 0 or ttl > LiveBoard.MAX_EXPIRATION) then
		table.insert(problems, "ttl must be in (0, 3888000] seconds (MemoryStore expiration limit)")
	end
	return problems
end

function LiveBoard.new(map: any, options: Options?, env: any?): Board
	local problems = LiveBoard.validate(options)
	if type(map) ~= "table" then
		table.insert(problems, "map must be a sorted-map object")
	end
	if #problems > 0 then
		error("LiveBoard.new: " .. table.concat(problems, "; "), 2)
	end
	local opts: Options = table.clone(options or {}) :: any
	if opts.integer == nil then
		opts.integer = false -- sort keys may be fractional
	end
	local ttl = opts.ttl or 600
	local descending = (opts.order or "desc") == "desc"
	local self: any = { map = map, options = opts }

	-- Keeps the best score per key; reasons bad_key, not_finite, not_integer, out_of_range,
	-- not_better.
	function self.submit(_, key: string, score: number, at: number?): (boolean, string?)
		if type(key) ~= "string" or key == "" or #key > LiveBoard.MAX_KEY then
			return false, "bad_key"
		end
		local problem = Leaderboard.scoreProblem(score, opts)
		if problem then
			return false, problem
		end
		local stamp = at or (env and env.clock and env.clock()) or 0
		local kept = false
		map:UpdateAsync(key, function(old: any, _oldSort: any): (any, any)
			if type(old) == "table" and type(old.score) == "number" then
				if not Leaderboard.better(score, old.score, opts) then
					kept = true
					return nil, nil -- cancel: the stored score stands
				end
			end
			return { score = score, at = stamp }, score
		end, ttl)
		if kept then
			return false, "not_better"
		end
		return true, nil
	end

	function self.top(_, count: number): { Leaderboard.Ranked }
		assert(Check.integer(count) and count >= 1, "LiveBoard.top: count must be an integer >= 1")
		local items = map:GetRangeAsync(
			if descending then "Descending" else "Ascending",
			math.min(count, LiveBoard.MAX_RANGE)
		)
		local entries = {}
		for _, item in items do
			local value = item.value
			if type(value) == "table" and type(value.score) == "number" then
				table.insert(entries, { key = item.key, score = value.score, at = value.at })
			end
		end
		return Leaderboard.rank(entries, opts)
	end

	function self.get(_, key: string): Leaderboard.Entry?
		local value = map:GetAsync(key)
		if type(value) == "table" and type(value.score) == "number" then
			return { key = key, score = value.score, at = value.at }
		end
		return nil
	end

	function self.remove(_, key: string)
		map:RemoveAsync(key)
	end

	return self
end

return LiveBoard
