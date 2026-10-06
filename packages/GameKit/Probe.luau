--!strict
-- @tier T0
-- Probe: the engine-probe line protocol (docs/runtime-kits.md "Probe contract"). A probe is a
-- function(ctx) registered by name; ctx.check(check, ok, detail?) records one result and the
-- runner prints one line per check and one line per run:
--   ENGINE_CHECK {"check":"...","detail":...,"ok":true,"probe":"..."}
--   ENGINE_DONE {"checks":n,"errors":n,"failed":n,"ok":bool,"passed":n,"probes":[...]}
-- JSON is canonical (GameKit/Json), so Lune and Studio print identical lines. A probe that
-- raises records check "error" with ok = false. ctx.env is the runner's Env (EnvRoblox.studio()
-- in Studio, FakeEnv in Lune); ctx.kit("GameKit/Signal") loads a kit module through the
-- runner's loader, so probe registries never use relative requires (fixtures live outside
-- packages/). The Studio runner and its probe discovery are G9b's Pipeline/KitSmoke.
local Json = require("./Json")

local Probe = {}
Probe.CHECK_PREFIX = "ENGINE_CHECK "
Probe.DONE_PREFIX = "ENGINE_DONE "
Probe.NAME_PATTERN = "^[a-z][a-z0-9_]+$"

export type Context = {
	probe: string,
	env: any,
	check: (check: string, ok: boolean, detail: any?) -> boolean,
	kit: (path: string) -> any,
}
export type ProbeFn = (ctx: Context) -> ()
export type Summary = {
	probes: { string },
	checks: number,
	passed: number,
	failed: number,
	errors: number,
	ok: boolean,
}
export type Options = {
	emit: ((line: string) -> ())?, -- default print
	env: any?,
	kit: ((path: string) -> any)?,
	only: { string }?, -- run just these names
}

function Probe.validName(name: any): boolean
	return type(name) == "string" and #name <= 64 and string.match(name, Probe.NAME_PATTERN) ~= nil
end

function Probe.checkLine(probe: string, check: string, ok: boolean, detail: any?): string
	return Probe.CHECK_PREFIX .. Json.encode({ probe = probe, check = check, ok = ok, detail = detail })
end

function Probe.doneLine(summary: Summary): string
	return Probe.DONE_PREFIX .. Json.encode(summary)
end

-- Runs every probe in registry ({ [name] = fn }) in name order, emitting their check lines and
-- then exactly one ENGINE_DONE line. Returns the summary. A run with no checks is not ok.
function Probe.runAll(registry: { [string]: ProbeFn }, opts: Options?): Summary
	local emit = (opts and opts.emit) or print
	local env = opts and opts.env
	local loader = opts and opts.kit
	local names = {}
	for name in registry do
		if not Probe.validName(name) then
			error("Probe: invalid probe name " .. tostring(name), 2)
		end
		if opts and opts.only and not table.find(opts.only, name) then
			continue
		end
		table.insert(names, name)
	end
	table.sort(names)
	local summary: Summary = { probes = names, checks = 0, passed = 0, failed = 0, errors = 0, ok = false }
	for _, name in names do
		local function check(checkName: string, ok: boolean, detail: any?): boolean
			local passed = ok == true
			summary.checks += 1
			if passed then
				summary.passed += 1
			else
				summary.failed += 1
			end
			local okLine, line = pcall(Probe.checkLine, name, tostring(checkName), passed, detail)
			emit(
				if okLine then line else Probe.checkLine(name, tostring(checkName), passed, tostring(detail))
			)
			return passed
		end
		local ctx: Context = {
			probe = name,
			env = env,
			check = check,
			kit = function(path: string): any
				if loader == nil then
					error("Probe: this runner has no kit loader", 2)
				end
				return loader(path)
			end,
		}
		local ok, err = pcall(registry[name], ctx)
		if not ok then
			summary.errors += 1
			check("error", false, tostring(err))
		end
	end
	summary.ok = summary.checks > 0 and summary.failed == 0 and summary.errors == 0
	emit(Probe.doneLine(summary))
	return summary
end

function Probe.run(name: string, fn: ProbeFn, opts: Options?): Summary
	return Probe.runAll({ [name] = fn }, opts)
end

return Probe
