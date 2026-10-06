--!strict
-- @tier T0
-- Boot: the phase runner both entry scripts use (src/server/init.server.luau, src/client/init.client.luau).
-- Pure: time, threads and waiting come from an injected env, so tests/boot.spec.luau drives it in Lune.
-- Phases run in one fixed order; a side runs the subset it owns:
--   server  config, kits, data, remotes, telemetry
--   client  config, kits, remotes, ui, input
-- Each phase is function(ctx) -> note? and runs on its own thread with a timeout. The first phase that
-- errors or times out stops the boot: later phases report "not_run", cleanups registered so far run in
-- reverse order, and Boot.run returns a structured report (boot-report/1) instead of raising.
--   env = { clock: () -> number, spawn: (fn) -> thread?, wait: (seconds) -> (), cancel: ((thread) -> ())? }
--   In Roblox: { clock = time, spawn = task.spawn, wait = task.wait, cancel = task.cancel }.
local Boot = {}

Boot.PHASES = table.freeze({ "config", "kits", "data", "remotes", "telemetry", "ui", "input" })
Boot.SIDES = table.freeze({
	server = table.freeze({ config = true, kits = true, data = true, remotes = true, telemetry = true }),
	client = table.freeze({ config = true, kits = true, remotes = true, ui = true, input = true }),
})
Boot.DEFAULT_TIMEOUT = 10 -- seconds per phase (convention; Config.boot.timeouts overrides per phase)
Boot.POLL = 0.05 -- seconds between deadline checks while a phase yields

export type PhaseFn = (ctx: { [string]: any }) -> any
export type Spec = {
	side: string,
	phases: { [string]: PhaseFn },
	timeouts: { [string]: number }?,
	defaultTimeout: number?,
	context: { [string]: any }?,
	onPhase: ((result: PhaseResult) -> ())?,
}
export type Env = {
	clock: () -> number,
	spawn: (fn: () -> ()) -> any,
	wait: (seconds: number) -> any,
	cancel: ((thread: any) -> ())?,
}
export type PhaseResult = {
	name: string,
	status: string, -- ok, failed, timeout, skipped, not_run
	seconds: number,
	error: string?,
	note: string?,
}
export type Report = {
	schema: string,
	side: string,
	ok: boolean,
	failed: string?,
	reason: string?,
	phases: { PhaseResult },
	seconds: number,
	cleanups: number,
}

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

-- Problems with a spec (empty when valid): unknown side, phases outside the side, bad timeouts.
function Boot.validate(spec: any): { string }
	local problems = {}
	if type(spec) ~= "table" then
		return { "spec must be a table" }
	end
	local allowed = Boot.SIDES[spec.side]
	if allowed == nil then
		table.insert(problems, `side must be "server" or "client", got {tostring(spec.side)}`)
	end
	if type(spec.phases) ~= "table" then
		table.insert(problems, "phases must be a table of name -> function")
	else
		for name, fn in spec.phases do
			if table.find(Boot.PHASES, name) == nil then
				table.insert(problems, `unknown phase {tostring(name)}`)
			elseif allowed and not allowed[name] then
				table.insert(problems, `phase {name} does not run on the {spec.side}`)
			end
			if type(fn) ~= "function" then
				table.insert(problems, `phase {tostring(name)} must be a function`)
			end
		end
	end
	if spec.timeouts ~= nil then
		if type(spec.timeouts) ~= "table" then
			table.insert(problems, "timeouts must be a table")
		else
			for name, seconds in spec.timeouts do
				if table.find(Boot.PHASES, name) == nil then
					table.insert(problems, `timeout for unknown phase {tostring(name)}`)
				elseif not finitePositive(seconds) then
					table.insert(problems, `timeout for {name} must be a positive number`)
				end
			end
		end
	end
	if spec.defaultTimeout ~= nil and not finitePositive(spec.defaultTimeout) then
		table.insert(problems, "defaultTimeout must be a positive number")
	end
	table.sort(problems)
	return problems
end

local function timeoutFor(spec: Spec, name: string): number
	local timeouts = spec.timeouts
	local seconds = timeouts and timeouts[name]
	if finitePositive(seconds) then
		return seconds :: number
	end
	if finitePositive(spec.defaultTimeout) then
		return spec.defaultTimeout :: number
	end
	return Boot.DEFAULT_TIMEOUT
end

local function round(seconds: number): number
	return math.floor(seconds * 1000 + 0.5) / 1000
end

-- Runs one phase on its own thread and polls its deadline. Returns status, note or error.
local function runPhase(fn: PhaseFn, ctx: { [string]: any }, timeout: number, env: Env): (string, any)
	local finished, ok = false, false
	local value: any = nil
	local thread = env.spawn(function()
		local success, result = pcall(fn, ctx)
		ok, value, finished = success, result, true
	end)
	local deadline = env.clock() + timeout
	while not finished do
		local left = deadline - env.clock()
		if left <= 0 then
			break
		end
		env.wait(math.min(Boot.POLL, left))
	end
	if not finished then
		if env.cancel and thread ~= nil then
			pcall(env.cancel, thread)
		end
		return "timeout", `exceeded {timeout} s`
	end
	if not ok then
		return "failed", value
	end
	return "ok", value
end

-- Runs the spec's phases in Boot.PHASES order. Never raises for a phase error; an invalid spec or env
-- returns a failed report naming the problems.
function Boot.run(spec: Spec, env: Env): Report
	local report: Report = {
		schema = "boot-report/1",
		side = if type(spec) == "table" and type(spec.side) == "string" then spec.side else "unknown",
		ok = false,
		phases = {},
		seconds = 0,
		cleanups = 0,
	}
	local problems = Boot.validate(spec)
	if type(env) ~= "table" or type(env.clock) ~= "function" or type(env.spawn) ~= "function" then
		table.insert(problems, "env needs clock, spawn and wait functions")
	elseif type(env.wait) ~= "function" then
		table.insert(problems, "env needs clock, spawn and wait functions")
	end
	if #problems > 0 then
		report.failed = "spec"
		report.reason = table.concat(problems, "; ")
		return report
	end

	local ctx = spec.context or {}
	local cleanups: { () -> () } = {}
	ctx.side = spec.side
	ctx.addCleanup = function(fn: () -> ())
		assert(type(fn) == "function", "addCleanup takes a function")
		table.insert(cleanups, fn)
	end
	local started = env.clock()
	local stopped = false
	for _, name in Boot.PHASES do
		local fn = spec.phases[name]
		local result: PhaseResult
		if fn == nil then
			result = { name = name, status = "skipped", seconds = 0 }
		elseif stopped then
			result = { name = name, status = "not_run", seconds = 0 }
		else
			local phaseStart = env.clock()
			local status, value = runPhase(fn, ctx, timeoutFor(spec, name), env)
			result = { name = name, status = status, seconds = round(env.clock() - phaseStart) }
			if status == "ok" then
				result.note = if value ~= nil then tostring(value) else nil
			else
				result.error = tostring(value)
				report.failed = name
				report.reason = `{status}: {tostring(value)}`
				stopped = true
			end
		end
		table.insert(report.phases, result)
		if spec.onPhase then
			pcall(spec.onPhase, result)
		end
	end
	if stopped then
		for index = #cleanups, 1, -1 do
			pcall(cleanups[index])
			report.cleanups += 1
		end
	end
	report.ok = not stopped
	report.seconds = round(env.clock() - started)
	return report
end

-- Canonical JSON (sorted keys) for the BOOT_REPORT console line, so a Studio run can be compared.
local function encode(value: any): string
	local kind = type(value)
	if kind == "nil" then
		return "null"
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return string.format("%.17g", value)
	elseif kind == "string" then
		local escaped = string.gsub(value, '[%c"\\]', function(char: string): string
			local named = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
			return named[char] or string.format("\\u%04x", string.byte(char))
		end)
		return '"' .. escaped .. '"'
	elseif kind == "table" then
		if #value > 0 or next(value) == nil then
			local parts = {}
			for _, item in value do
				table.insert(parts, encode(item))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for key in value do
			table.insert(keys, tostring(key))
		end
		table.sort(keys)
		local parts = {}
		for _, key in keys do
			table.insert(parts, encode(key) .. ":" .. encode(value[key]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return encode(tostring(value))
end

Boot.encode = encode

-- One console line per boot: `BOOT_REPORT {json}`. Release item S07 asks for ok=true on both sides.
function Boot.line(report: Report): string
	return "BOOT_REPORT " .. encode(report)
end

return table.freeze(Boot)
