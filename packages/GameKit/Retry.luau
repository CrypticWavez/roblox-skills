--!strict
-- @tier T0
-- Retry: exponential backoff with jitter for engine calls that fail transiently (DataStores,
-- PolicyService, MemoryStore, teleports), as the Roblox DataStore guidance asks ("exponential
-- backoff" plus "random jitter"). Pure: the jitter comes from an injected rng (anything with
-- :next() -> [0, 1), such as ProcGen/Rng) and waiting goes through opts.wait or env.wait, so
-- delay sequences are deterministic in Lune. Never call run() from a step function: it yields.
local Check = require("./Check")

local Retry = {}

export type Jitter = "full" | "equal" | "none"
export type Options = {
	attempts: number?, -- total tries including the first (default 4)
	base: number?, -- delay after the first failure, seconds (default 0.5)
	factor: number?, -- growth per failure (default 2)
	maxDelay: number?, -- cap per delay, seconds (default 30)
	jitter: Jitter?, -- full: U(0, d); equal: d/2 + U(0, d/2); none: d (default full)
	rng: any?, -- :next() -> [0, 1); required unless jitter is none (env.rng() is used when given)
	retryable: ((err: any, attempt: number) -> boolean)?, -- default: Retry.classify(err) ~= "fatal"
	wait: ((seconds: number) -> any)?, -- default env.wait
	onRetry: ((err: any, attempt: number, delay: number) -> ())?,
}

Retry.DEFAULTS = table.freeze({ attempts = 4, base = 0.5, factor = 2, maxDelay = 30, jitter = "full" })

local function option(opts: Options?, name: string): any
	local value = opts and (opts :: any)[name]
	if value == nil then
		return (Retry.DEFAULTS :: any)[name]
	end
	return value
end

-- Problems with an options table (empty when usable).
function Retry.validate(opts: Options?): { string }
	local problems = {}
	local attempts = option(opts, "attempts")
	if not Check.integer(attempts) or attempts < 1 then
		table.insert(problems, "attempts must be an integer >= 1")
	end
	for _, name in { "base", "maxDelay" } do
		local value = option(opts, name)
		if not Check.finite(value) or value < 0 then
			table.insert(problems, name .. " must be a finite number >= 0")
		end
	end
	local factor = option(opts, "factor")
	if not Check.finite(factor) or factor < 1 then
		table.insert(problems, "factor must be a finite number >= 1")
	end
	local jitter = option(opts, "jitter")
	if jitter ~= "full" and jitter ~= "equal" and jitter ~= "none" then
		table.insert(problems, "jitter must be full, equal or none")
	end
	return problems
end

local function assertValid(opts: Options?)
	local problems = Retry.validate(opts)
	if #problems > 0 then
		error("Retry: " .. table.concat(problems, "; "), 3)
	end
end

-- The delay after the failed attempt number `attempt` (1 = after the first try).
function Retry.delay(attempt: number, opts: Options?, rng: any?): number
	assertValid(opts)
	assert(Check.integer(attempt) and attempt >= 1, "Retry.delay: attempt must be an integer >= 1")
	local raw = option(opts, "base") * option(opts, "factor") ^ (attempt - 1)
	local capped = math.min(raw, option(opts, "maxDelay"))
	local jitter = option(opts, "jitter")
	if jitter == "none" then
		return capped
	end
	local source = rng or (opts and opts.rng)
	if source == nil then
		error("Retry.delay: jitter needs an rng (opts.rng or env.rng)", 2)
	end
	local u = source:next()
	if jitter == "full" then
		return capped * u
	end
	return capped / 2 + (capped / 2) * u
end

-- Every delay a run with these options could wait, in order (attempts - 1 values).
function Retry.delays(opts: Options?): { number }
	assertValid(opts)
	local out = {}
	for attempt = 1, option(opts, "attempts") - 1 do
		table.insert(out, Retry.delay(attempt, opts))
	end
	return out
end

-- Classifies an error for retrying. DataStore-style messages that start with a numeric code:
-- 301-306 (throttled or queue full) -> "throttle"; 5xx -> "transient"; other codes ->
-- "fatal" (bad keys, values, permissions). Anything else, including a code behind a script
-- location prefix, -> "transient" (retrying is the safe default).
function Retry.classify(err: any): "throttle" | "transient" | "fatal"
	local text = tostring(err)
	local code = tonumber(string.match(text, "^%s*(%d%d%d)%D") or string.match(text, "^%s*(%d%d%d)$"))
	if code == nil then
		return "transient"
	end
	if code >= 301 and code <= 306 then
		return "throttle"
	end
	if code >= 500 and code <= 599 then
		return "transient"
	end
	return "fatal"
end

-- Calls fn(attempt) until it succeeds, a failure is not retryable, or attempts run out.
-- Returns (true, result, attempts) or (false, lastError, attempts). Waits with opts.wait or
-- env.wait between tries; the rng is opts.rng or env.rng().
function Retry.run(fn: (attempt: number) -> any, opts: Options?, env: any?): (boolean, any, number)
	assertValid(opts)
	local wait = (opts and opts.wait) or (env and env.wait)
	local rng = (opts and opts.rng)
	if rng == nil and option(opts, "jitter") ~= "none" and env and type(env.rng) == "function" then
		rng = env.rng()
	end
	local retryable = (opts and opts.retryable)
		or function(err: any): boolean
			return Retry.classify(err) ~= "fatal"
		end
	local attempts = option(opts, "attempts")
	local lastError: any = nil
	for attempt = 1, attempts do
		local ok, result = pcall(fn, attempt)
		if ok then
			return true, result, attempt
		end
		lastError = result
		if attempt == attempts or not retryable(result, attempt) then
			return false, result, attempt
		end
		local delay = Retry.delay(attempt, opts, rng)
		if opts and opts.onRetry then
			opts.onRetry(result, attempt, delay)
		end
		if wait == nil then
			error("Retry.run: needs opts.wait or env.wait to back off", 2)
		end
		wait(delay)
	end
	return false, lastError, attempts
end

-- Options preset for DataStore calls: 5 tries, 1 s base, 2x, 16 s cap, full jitter, and the
-- classify() rule (throttles and server errors retry; key, value and permission errors stop).
function Retry.dataStore(rng: any?): Options
	return {
		attempts = 5,
		base = 1,
		factor = 2,
		maxDelay = 16,
		jitter = "full",
		rng = rng,
	}
end

return Retry
