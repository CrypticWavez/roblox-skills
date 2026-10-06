--!strict
-- @tier T0
-- RemoteGuard: the server-side gate for every client-to-server remote. A guard knows each
-- remote by name (kind, argument schemas, rate, optional request-id dedupe and authorize hook);
-- wrap(name, handler) returns the function to connect to OnServerEvent or assign to
-- OnServerInvoke. Each call is checked in this order, cheapest first, and a rejected call never
-- reaches the handler, never raises and never yields:
--   invalid_player -> unknown_remote -> rate -> arity -> schema -> duplicate -> unauthorized
-- Rate comes first so a flood of malformed payloads costs one table lookup per call. The rate
-- limit uses the server clock (env.clock); client timestamps are never read, so a client cannot
-- buy itself tokens. Handler errors are caught (handler_error) and reported through
-- env.report, never sent to the client. Rejections are counted per player, optionally sent to
-- an onReject hook, an onAbuse hook (many rejects in a window) and a kit-event/1 sink
-- (rate-limited custom event remote_rejected). Engine wiring: RemoteGuardRoblox.
local Check = require("./Check")
local Events = require("./Events")
local RateLimit = require("./RateLimit")
local Schema = require("./Schema")

local RemoteGuard = {}
RemoteGuard.__index = RemoteGuard

RemoteGuard.KINDS = table.freeze({ "event", "function", "unreliable" })
RemoteGuard.REASONS = table.freeze({
	"invalid_player",
	"unknown_remote",
	"rate",
	"arity",
	"schema",
	"duplicate",
	"unauthorized",
	"handler_error",
})
-- Defaults are conventions, not Roblox limits (Roblox also rate-limits client messages per
-- remote type, shared across instances; scripting/events/remote).
RemoteGuard.DEFAULT_RATE = table.freeze({ capacity = 10, refillPerSec = 5 })
RemoteGuard.DEFAULT_TELEMETRY_RATE = table.freeze({ capacity = 5, refillPerSec = 0.1 })
RemoteGuard.DEFAULT_DEDUPE_WINDOW = 32

export type Rate = { capacity: number, refillPerSec: number }
export type RemoteSpec = {
	kind: ("event" | "function" | "unreliable")?, -- default "event"
	args: { Schema.Schema }, -- positional argument schemas (Schema.optional for optional ones)
	rate: Rate?, -- per player for this remote (default options.rateLimit, else DEFAULT_RATE)
	cost: number?, -- tokens per call (default 1)
	dedupe: { arg: number, window: number? }?, -- reject a repeated request id in argument `arg`
	authorize: ((player: any, ...any) -> boolean)?, -- runs after the schema; false -> unauthorized
}
export type Options = {
	schemas: { [string]: RemoteSpec },
	rateLimit: Rate?, -- default per-remote rate
	telemetry: any?, -- kit-event/1 sink (:emit(event))
	telemetryRate: Rate?, -- per player budget for remote_rejected events
	onReject: ((player: any, remote: string, reason: string, detail: any) -> ())?,
	abuse: { rejects: number, window: number, onAbuse: (player: any, summary: any) -> () }?,
	keyOf: ((player: any) -> string?)?, -- default: tostring(player.UserId)
	maxDepth: number?,
	maxNodes: number?,
}
-- accepted: calls that passed every check; rejected: calls refused (by reason); handlerErrors:
-- accepted calls whose handler raised.
export type Stats =
	{ accepted: number, rejected: number, reasons: { [string]: number }, handlerErrors: number }

type Remote = {
	name: string,
	kind: string,
	args: { Schema.Schema },
	cost: number,
	limiter: RateLimit.RateLimit,
	dedupe: { arg: number, window: number }?,
	authorize: ((player: any, ...any) -> boolean)?,
}
type PlayerState = {
	stats: Stats,
	byRemote: { [string]: Stats },
	recent: { [string]: { list: { any }, set: { [any]: boolean } } },
	abuseStart: number,
	abuseCount: number,
	abuseFired: boolean,
}

type GuardFields = {
	_remotes: { [string]: Remote },
	_names: { string },
	_env: any,
	_options: Options,
	_players: { [string]: PlayerState },
	_telemetryLimit: RateLimit.RateLimit?,
	_checkOptions: Schema.CheckOptions,
}
export type RemoteGuard = typeof(setmetatable({} :: GuardFields, RemoteGuard))

local function rateProblems(rate: any, where: string, problems: { string })
	if rate == nil then
		return
	end
	for _, problem in RateLimit.validate(rate) do
		table.insert(problems, where .. ": " .. problem)
	end
end

-- Problems with guard options (empty when valid).
function RemoteGuard.validate(options: any): { string }
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	local problems = {}
	if type(options.schemas) ~= "table" or next(options.schemas) == nil then
		table.insert(problems, "schemas must map remote names to specs")
		return problems
	end
	rateProblems(options.rateLimit, "rateLimit", problems)
	rateProblems(options.telemetryRate, "telemetryRate", problems)
	for name, spec in options.schemas do
		local where = "remote " .. tostring(name)
		if type(name) ~= "string" or not string.match(name, "^[%a][%w_]*$") or #name > 64 then
			table.insert(problems, where .. ": names are 1-64 letters, digits or _, starting with a letter")
			continue
		end
		if type(spec) ~= "table" then
			table.insert(problems, where .. ": spec must be a table")
			continue
		end
		if spec.kind ~= nil and not table.find(RemoteGuard.KINDS, spec.kind) then
			table.insert(problems, where .. ": kind must be event, function or unreliable")
		end
		if type(spec.args) ~= "table" then
			table.insert(problems, where .. ": args must be a list of schemas ({} for none)")
		else
			for index, schema in spec.args do
				if not Schema.isSchema(schema) then
					table.insert(
						problems,
						string.format("%s: args[%s] is not a schema", where, tostring(index))
					)
				end
			end
		end
		rateProblems(spec.rate, where .. " rate", problems)
		if spec.cost ~= nil and not (Check.finite(spec.cost) and spec.cost > 0) then
			table.insert(problems, where .. ": cost must be a finite number > 0")
		end
		if spec.dedupe ~= nil then
			local dedupe = spec.dedupe
			if
				type(dedupe) ~= "table"
				or not Check.integer(dedupe.arg)
				or dedupe.arg < 1
				or (type(spec.args) == "table" and dedupe.arg > #spec.args)
			then
				table.insert(problems, where .. ": dedupe.arg must name one of the arguments")
			elseif dedupe.window ~= nil and not (Check.integer(dedupe.window) and dedupe.window >= 1) then
				table.insert(problems, where .. ": dedupe.window must be an integer >= 1")
			else
				-- Request ids become table keys: only strings and finite numbers are safe.
				local idSchema = spec.args[dedupe.arg]
				local kind = Schema.isSchema(idSchema) and idSchema.kind
				if kind ~= "string" and kind ~= "number" and kind ~= "enum" and kind ~= "literal" then
					table.insert(problems, where .. ": the dedupe argument needs a string or number schema")
				end
			end
		end
		if spec.authorize ~= nil and type(spec.authorize) ~= "function" then
			table.insert(problems, where .. ": authorize must be a function")
		end
	end
	local abuse = options.abuse
	if abuse ~= nil then
		if
			type(abuse) ~= "table"
			or not (Check.integer(abuse.rejects) and abuse.rejects >= 1)
			or not (Check.finite(abuse.window) and abuse.window > 0)
			or type(abuse.onAbuse) ~= "function"
		then
			table.insert(problems, "abuse needs rejects (integer >= 1), window (seconds > 0) and onAbuse")
		end
	end
	for _, hook in { "onReject", "keyOf" } do
		if options[hook] ~= nil and type(options[hook]) ~= "function" then
			table.insert(problems, hook .. " must be a function")
		end
	end
	if
		options.telemetry ~= nil
		and (type(options.telemetry) ~= "table" or type(options.telemetry.emit) ~= "function")
	then
		table.insert(problems, "telemetry must be a sink with :emit(event)")
	end
	return problems
end

-- A guard for the remotes in options.schemas. env.clock drives the rate limits.
function RemoteGuard.new(options: Options, env: any): RemoteGuard
	local problems = RemoteGuard.validate(options)
	if env == nil or type(env.clock) ~= "function" then
		table.insert(problems, "env with clock is required")
	end
	if #problems > 0 then
		error("RemoteGuard.new: " .. table.concat(problems, "; "), 2)
	end
	local remotes: { [string]: Remote } = {}
	local names = {}
	for name, spec in options.schemas do
		local rate = spec.rate or options.rateLimit or RemoteGuard.DEFAULT_RATE
		remotes[name] = {
			name = name,
			kind = spec.kind or "event",
			args = table.clone(spec.args),
			cost = spec.cost or 1,
			limiter = RateLimit.new({ capacity = rate.capacity, refillPerSec = rate.refillPerSec }, env),
			dedupe = if spec.dedupe
				then {
					arg = spec.dedupe.arg,
					window = spec.dedupe.window or RemoteGuard.DEFAULT_DEDUPE_WINDOW,
				}
				else nil,
			authorize = spec.authorize,
		}
		table.insert(names, name)
	end
	table.sort(names)
	local telemetryLimit = nil
	if options.telemetry then
		local rate = options.telemetryRate or RemoteGuard.DEFAULT_TELEMETRY_RATE
		telemetryLimit = RateLimit.new({ capacity = rate.capacity, refillPerSec = rate.refillPerSec }, env)
	end
	return setmetatable({
		_remotes = remotes,
		_names = names,
		_env = env,
		_options = options,
		_players = {},
		_telemetryLimit = telemetryLimit,
		_checkOptions = { maxDepth = options.maxDepth, maxNodes = options.maxNodes },
	}, RemoteGuard)
end

-- The stable key for a player: tostring(UserId) by default (options.keyOf overrides).
function RemoteGuard.keyOf(self: RemoteGuard, player: any): string?
	if self._options.keyOf then
		local ok, key = pcall(self._options.keyOf, player)
		return if ok and type(key) == "string" and key ~= "" then key else nil
	end
	if player == nil then
		return nil
	end
	local ok, userId = pcall(function()
		return (player :: any).UserId
	end)
	if ok and Check.integer(userId) then
		return tostring(userId)
	end
	return nil
end

local function newStats(): Stats
	return { accepted = 0, rejected = 0, reasons = {}, handlerErrors = 0 }
end

local function stateFor(self: RemoteGuard, key: string): PlayerState
	local state = self._players[key]
	if state == nil then
		state = {
			stats = newStats(),
			byRemote = {},
			recent = {},
			abuseStart = -math.huge,
			abuseCount = 0,
			abuseFired = false,
		}
		self._players[key] = state
	end
	return state
end

local function bump(stats: Stats, accepted: boolean, reason: string?)
	if reason == "handler_error" then
		stats.handlerErrors += 1
	elseif accepted then
		stats.accepted += 1
	else
		stats.rejected += 1
		local name = reason :: string
		stats.reasons[name] = (stats.reasons[name] or 0) + 1
	end
end

local function record(self: RemoteGuard, key: string?, remote: string, accepted: boolean, reason: string?)
	if key == nil then
		return
	end
	local state = stateFor(self, key)
	bump(state.stats, accepted, reason)
	local perRemote = state.byRemote[remote]
	if perRemote == nil then
		perRemote = newStats()
		state.byRemote[remote] = perRemote
	end
	bump(perRemote, accepted, reason)
end

local function report(self: RemoteGuard, message: string)
	local env = self._env
	if type(env.report) == "function" then
		pcall(env.report, message)
	end
end

local function reject(
	self: RemoteGuard,
	player: any,
	key: string?,
	remote: string,
	reason: string,
	detail: any
): (boolean, string, any)
	record(self, key, remote, false, reason)
	local options = self._options
	if options.onReject then
		local ok, err = pcall(options.onReject, player, remote, reason, detail)
		if not ok then
			report(self, "RemoteGuard onReject error: " .. tostring(err))
		end
	end
	if key ~= nil and options.abuse then
		local state = stateFor(self, key)
		local now = self._env.clock()
		if now - state.abuseStart >= options.abuse.window then
			state.abuseStart, state.abuseCount, state.abuseFired = now, 0, false
		end
		state.abuseCount += 1
		if state.abuseCount >= options.abuse.rejects and not state.abuseFired then
			state.abuseFired = true
			local summary =
				{ key = key, rejects = state.abuseCount, window = options.abuse.window, remote = remote }
			local ok, err = pcall(options.abuse.onAbuse, player, summary)
			if not ok then
				report(self, "RemoteGuard onAbuse error: " .. tostring(err))
			end
		end
	end
	local sink = options.telemetry
	local limiter = self._telemetryLimit
	if sink and limiter and key ~= nil and limiter:take(key) then
		local event =
			Events.custom("remote_rejected", 1, { remote = string.sub(remote, 1, 64), reason = reason })
		event.player = key
		local ok, err = pcall(sink.emit, sink, event)
		if not ok then
			report(self, "RemoteGuard telemetry error: " .. tostring(err))
		end
	end
	return false, reason, detail
end

-- Runs every check for one call without calling a handler. Returns (true) or
-- (false, reason, detail); detail is { path, reason } for schema rejects, else nil.
function RemoteGuard.check(self: RemoteGuard, name: string, player: any, ...: any): (boolean, string?, any)
	local key = self:keyOf(player)
	if key == nil then
		return reject(self, player, nil, tostring(name), "invalid_player", nil)
	end
	local remote = self._remotes[name]
	if remote == nil then
		return reject(self, player, key, tostring(name), "unknown_remote", nil)
	end
	if not remote.limiter:take(key, remote.cost) then
		return reject(self, player, key, name, "rate", nil)
	end
	local args = table.pack(...)
	local ok, path, reason = Schema.checkArgs(remote.args, args, self._checkOptions)
	if not ok then
		if reason == "arity" then
			return reject(self, player, key, name, "arity", { got = args.n, max = #remote.args })
		end
		return reject(self, player, key, name, "schema", { path = path, reason = reason })
	end
	local dedupe = remote.dedupe
	if dedupe then
		local id = args[dedupe.arg]
		if id ~= nil then
			local state = stateFor(self, key)
			local recent = state.recent[name]
			if recent == nil then
				recent = { list = {}, set = {} }
				state.recent[name] = recent
			end
			if recent.set[id] then
				return reject(self, player, key, name, "duplicate", nil)
			end
			recent.set[id] = true
			table.insert(recent.list, id)
			if #recent.list > dedupe.window then
				recent.set[table.remove(recent.list, 1)] = nil
			end
		end
	end
	if remote.authorize then
		local called, allowed = pcall(remote.authorize, player, ...)
		if not called then
			report(self, string.format("RemoteGuard %s authorize error: %s", name, tostring(allowed)))
			return reject(self, player, key, name, "unauthorized", nil)
		end
		if allowed ~= true then
			return reject(self, player, key, name, "unauthorized", nil)
		end
	end
	record(self, key, name, true, nil)
	return true, nil, nil
end

-- Checks the call and runs handler(player, ...) when it passes. Returns (true, results...) or
-- (false, reason, detail). A handler error is caught: (false, "handler_error").
function RemoteGuard.handle(
	self: RemoteGuard,
	name: string,
	handler: (...any) -> ...any,
	player: any,
	...: any
): ...any
	local ok, reason, detail = self:check(name, player, ...)
	if not ok then
		return false, reason, detail
	end
	local results = table.pack(pcall(handler, player, ...))
	if not results[1] then
		report(self, string.format("RemoteGuard %s handler error: %s", name, tostring(results[2])))
		record(self, self:keyOf(player), name, false, "handler_error")
		return false, "handler_error", nil
	end
	return true, table.unpack(results, 2, results.n)
end

-- The function to connect to OnServerEvent (event, unreliable) or assign to OnServerInvoke
-- (function). For a RemoteFunction it returns the handler's results, or nothing on a reject.
-- Raises for a name the guard does not know (a wiring bug, found at startup).
function RemoteGuard.wrap(
	self: RemoteGuard,
	name: string,
	handler: (...any) -> ...any
): (player: any, ...any) -> ...any
	local remote = self._remotes[name]
	if remote == nil then
		error("RemoteGuard:wrap: no schema for remote " .. tostring(name), 2)
	end
	if type(handler) ~= "function" then
		error("RemoteGuard:wrap: handler for " .. name .. " must be a function", 2)
	end
	if remote.kind == "function" then
		return function(player: any, ...: any): ...any
			local results = table.pack(self:handle(name, handler, player, ...))
			if results[1] then
				return table.unpack(results, 2, results.n)
			end
			return
		end
	end
	return function(player: any, ...: any)
		self:handle(name, handler, player, ...)
	end
end

-- The spec kind ("event", "function", "unreliable") for a remote, or nil.
function RemoteGuard.kind(self: RemoteGuard, name: string): string?
	local remote = self._remotes[name]
	return if remote then remote.kind else nil
end

-- Remote names the guard knows, sorted.
function RemoteGuard.names(self: RemoteGuard): { string }
	return table.clone(self._names)
end

-- Counts for one player ({ accepted, rejected, reasons, byRemote }), or totals over all players.
function RemoteGuard.stats(self: RemoteGuard, player: any?): any
	if player ~= nil then
		local key = self:keyOf(player)
		local state = key and self._players[key]
		if state == nil then
			return { accepted = 0, rejected = 0, reasons = {}, byRemote = {} }
		end
		local out: any = Check.copy(state.stats)
		out.byRemote = Check.copy(state.byRemote)
		return out
	end
	local total: any = newStats()
	total.players = 0
	for _, state in self._players do
		total.players += 1
		total.accepted += state.stats.accepted
		total.rejected += state.stats.rejected
		total.handlerErrors += state.stats.handlerErrors
		for reason, n in state.stats.reasons do
			total.reasons[reason] = (total.reasons[reason] or 0) + n
		end
	end
	return total
end

-- Drops everything held for a player (rate buckets, dedupe ids, counts). Call on PlayerRemoving.
function RemoteGuard.forget(self: RemoteGuard, player: any)
	local key = self:keyOf(player)
	if key == nil then
		return
	end
	self._players[key] = nil
	for _, remote in self._remotes do
		remote.limiter:forget(key)
	end
	if self._telemetryLimit then
		self._telemetryLimit:forget(key)
	end
end

return RemoteGuard
