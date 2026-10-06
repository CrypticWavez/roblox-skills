--!strict
-- @tier T4
-- LeaderboardRoblox: a persistent board on an OrderedDataStore (env.services.DataStoreService),
-- every call through GameKit/Retry (DataStore preset: throttles and 5xx retry, key and value
-- errors stop). Writes are off unless options.writes is true: a SETUP_ONLY factory never writes
-- live data, and the guard hooks ask before Studio Luau that names this module and calls submit or
-- remove or sets writes (matched by name: a require under another name is not seen, docs/mcp.md).
-- With options.horizon the stored integer packs the score and the time it was reached
-- (Leaderboard.pack), so equal scores rank by who got there first. T4: OrderedDataStores need a
-- published place with API access, so this is never verified here (BLOCKED_EXTERNAL); Lune specs
-- use FakeOrderedStore.
-- Every method yields: never call one from a simulation step.
local Env = require("./Env")
local Leaderboard = require("./Leaderboard")
local Retry = require("./Retry")

local LeaderboardRoblox = {}

export type Options = Leaderboard.Options & {
	scope: string?,
	writes: boolean?, -- default false: submit and remove return (false, "writes_disabled")
	horizon: number?, -- seconds `at` may span when packing (for example a season length)
	retry: Retry.Options?, -- default Retry.dataStore(env.rng())
}

export type Store = {
	name: string,
	options: Options,
	submit: (self: Store, key: string, score: number, at: number?) -> (boolean, any),
	top: (self: Store, count: number) -> (boolean, any),
	get: (self: Store, key: string) -> (boolean, any),
	remove: (self: Store, key: string) -> (boolean, any),
}

-- Problems with a board name and options (empty when valid).
function LeaderboardRoblox.validate(name: any, options: Options?): { string }
	local problems = Leaderboard.validate(options)
	if type(name) ~= "string" or name == "" or #name > 50 then
		table.insert(problems, "name must be a string of 1-50 characters (DataStore name limit)")
	end
	local horizon = options and options.horizon
	if horizon ~= nil and (type(horizon) ~= "number" or horizon < 1 or horizon % 1 ~= 0) then
		table.insert(problems, "horizon must be an integer >= 1")
	end
	return problems
end

function LeaderboardRoblox.new(name: string, options: Options?, env: any): Store
	local problems = LeaderboardRoblox.validate(name, options)
	if #problems > 0 then
		error("LeaderboardRoblox.new: " .. table.concat(problems, "; "), 2)
	end
	local opts: Options = table.clone(options or {}) :: any
	local service = Env.service(env, "DataStoreService")
	local store = service:GetOrderedDataStore(name, opts.scope)
	local retry = opts.retry or Retry.dataStore(env.rng())
	local descending = (opts.order or "desc") == "desc"

	local function encode(score: number, at: number?): number
		if opts.horizon then
			return Leaderboard.pack(score, at or 0, opts.horizon)
		end
		return score
	end
	local function decode(value: number): (number, number?)
		if opts.horizon then
			return Leaderboard.unpack(value, opts.horizon)
		end
		return value, nil
	end

	local self: any = { name = name, options = opts }

	-- (true, stored value) when written or kept; (false, reason) otherwise.
	function self.submit(_, key: string, score: number, at: number?): (boolean, any)
		if type(key) ~= "string" or key == "" or #key > 50 then
			return false, "bad_key"
		end
		local problem = Leaderboard.scoreProblem(score, opts)
		if problem then
			return false, problem
		end
		if opts.horizon and (type(at) ~= "number" or at % 1 ~= 0 or at < 0 or at >= opts.horizon) then
			return false, "bad_time"
		end
		if not opts.writes then
			return false, "writes_disabled"
		end
		local value = encode(score, at)
		local ok, result = Retry.run(function()
			return store:UpdateAsync(key, function(old: number?): number?
				if old ~= nil then
					local oldScore = decode(old)
					if not Leaderboard.better(score, oldScore, opts) then
						return nil -- keep the stored best (UpdateAsync cancels the write)
					end
				end
				return value
			end)
		end, retry, env)
		return ok, result
	end

	-- (true, ranked entries) for the best `count` (pages of at most 100), or (false, error).
	function self.top(_, count: number): (boolean, any)
		assert(
			type(count) == "number" and count >= 1 and count % 1 == 0,
			"top: count must be an integer >= 1"
		)
		local entries = {}
		local ok, err = Retry.run(function()
			entries = {}
			local pages = store:GetSortedAsync(not descending, math.min(count, 100), opts.min, nil)
			while true do
				for _, item in pages:GetCurrentPage() do
					local score, at = decode(item.value)
					table.insert(entries, { key = item.key, score = score, at = at })
					if #entries >= count then
						return entries
					end
				end
				if pages.IsFinished then
					return entries
				end
				pages:AdvanceToNextPageAsync()
			end
		end, retry, env)
		if not ok then
			return false, err
		end
		-- Packed times already order equal scores, so a timed board ranks them apart by default.
		local rankOptions = table.clone(opts)
		if rankOptions.ranks == nil and opts.horizon then
			rankOptions.ranks = "ordinal"
		end
		return true, Leaderboard.rank(entries, rankOptions)
	end

	function self.get(_, key: string): (boolean, any)
		local ok, value = Retry.run(function()
			return store:GetAsync(key)
		end, retry, env)
		if not ok then
			return false, value
		end
		if value == nil then
			return true, nil
		end
		local score, at = decode(value)
		return true, { key = key, score = score, at = at }
	end

	function self.remove(_, key: string): (boolean, any)
		if not opts.writes then
			return false, "writes_disabled"
		end
		return Retry.run(function()
			return store:RemoveAsync(key)
		end, retry, env)
	end

	return self
end

return LeaderboardRoblox
