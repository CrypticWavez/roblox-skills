--!strict
-- @tier T0
-- Env: the services a kit core receives instead of Roblox globals, so the same core runs in
-- Lune (tests/fakes/FakeEnv.luau) and in Studio (EnvRoblox.studio(), also reachable as
-- Env.studio()). Shape (docs/runtime-kits.md "Env"):
--   clock()           seconds on the simulation clock: time() in Roblox, never tick/os.time/os.clock
--   defer(fn, ...)    run later this frame (task.defer); spawn(fn, ...) run now on a new thread
--   wait(seconds?)    yield the calling thread (task.wait); returns the time waited
--   services          name -> service or fake; read with Env.service(env, name)
--   rng(seed?)        ProcGen/Rng factory; a seed is required except where the env supplies one
--   place?            { isStudio, gameId, placeId, isServer?, isClient? } for Env.check
--   roblox?           Roblox datatypes (Instance, Vector3, CFrame, Color3, Enum, UDim2, ...):
--                     the globals in Studio, require("@lune/roblox") in Lune
--   report(message)   where swallowed errors go (warn by default)
local Rng = require("../ProcGen/Rng")

local Env = {}

export type PlaceInfo = {
	isStudio: boolean,
	gameId: number,
	placeId: number,
	isServer: boolean?,
	isClient: boolean?,
}

export type Env = {
	clock: () -> number,
	defer: (fn: (...any) -> ...any, ...any) -> (),
	spawn: (fn: (...any) -> ...any, ...any) -> (),
	wait: (seconds: number?) -> number,
	services: { [string]: any },
	rng: (seed: (number | string)?) -> Rng.Rng,
	place: PlaceInfo?,
	roblox: any?,
	report: (message: string) -> (),
}

local REQUIRED = { "clock", "defer", "wait" }
local FUNCTIONS = { "clock", "defer", "spawn", "wait", "rng", "report" }

local function defaultSpawn(fn: (...any) -> ...any, ...: any)
	local thread = coroutine.create(fn)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		warn("Env.spawn: " .. tostring(err))
	end
end

local function seededRng(seed: (number | string)?): Rng.Rng
	if seed == nil then
		error("env.rng needs a seed in this env (EnvRoblox and FakeEnv supply one when omitted)", 2)
	end
	return Rng.new(seed :: number | string)
end

-- Problems with an env table (empty when it is usable). Extra fields are allowed.
function Env.validate(env: any): { string }
	if type(env) ~= "table" then
		return { "env must be a table" }
	end
	local problems = {}
	for _, name in FUNCTIONS do
		if type(env[name]) ~= "function" then
			table.insert(problems, "env." .. name .. " must be a function")
		end
	end
	if type(env.services) ~= "table" then
		table.insert(problems, "env.services must be a table")
	end
	local place = env.place
	if place ~= nil then
		if type(place) ~= "table" then
			table.insert(problems, "env.place must be a table")
		elseif
			type(place.isStudio) ~= "boolean"
			or type(place.gameId) ~= "number"
			or type(place.placeId) ~= "number"
		then
			table.insert(problems, "env.place needs isStudio (boolean), gameId and placeId (numbers)")
		end
	end
	return problems
end

-- Builds an Env from parts: clock, defer and wait are required; spawn, services, rng, place,
-- roblox and report get defaults. Raises with every problem listed.
function Env.new(parts: { [string]: any }): Env
	assert(type(parts) == "table", "Env.new: parts must be a table")
	local missing = {}
	for _, name in REQUIRED do
		if parts[name] == nil then
			table.insert(missing, name)
		end
	end
	if #missing > 0 then
		error("Env.new: missing " .. table.concat(missing, ", "), 2)
	end
	local env = table.clone(parts)
	env.spawn = env.spawn or defaultSpawn
	env.services = env.services or {}
	env.rng = env.rng or seededRng
	env.report = env.report or function(message: string)
		warn(message)
	end
	local problems = Env.validate(env)
	if #problems > 0 then
		error("Env.new: " .. table.concat(problems, "; "), 2)
	end
	return env :: any
end

-- The named service, or an error that says which fake to register.
function Env.service(env: Env, name: string): any
	local service = env.services[name]
	if service == nil then
		error(string.format("env.services.%s is missing (register a fake for it in Lune)", name), 2)
	end
	return service
end

-- Diagnostic-place guard: ok only in Studio on an unpublished place (GameId 0 and PlaceId 0).
-- Reasons: missing_place, invalid_place, not_studio, published_game, published_place. A place
-- opened from a Studio template may report a non-zero PlaceId (UNVERIFIED); it is refused.
function Env.check(place: any): (boolean, string?)
	if place == nil then
		return false, "missing_place"
	end
	if
		type(place) ~= "table"
		or type(place.isStudio) ~= "boolean"
		or type(place.gameId) ~= "number"
		or type(place.placeId) ~= "number"
	then
		return false, "invalid_place"
	end
	if not place.isStudio then
		return false, "not_studio"
	end
	if place.gameId ~= 0 then
		return false, "published_game"
	end
	if place.placeId ~= 0 then
		return false, "published_place"
	end
	return true, nil
end

-- Raises unless Env.check passes for env.place; for debug-only and diagnostic code paths.
function Env.assertDiagnostic(env: Env, what: string?)
	local ok, reason = Env.check(env.place)
	if not ok then
		error(
			string.format("%s refused: %s (diagnostic places only)", what or "operation", tostring(reason)),
			2
		)
	end
end

-- The Roblox env (T3): forwards to EnvRoblox.studio(), which reads the Roblox globals. It serves
-- Studio and live servers alike; Env.check is what limits code to diagnostic places. Required
-- lazily so Lune never loads the adapter through Env (EnvRoblox does not require Env).
function Env.studio(overrides: { [string]: any }?): Env
	local EnvRoblox: any = require("./EnvRoblox")
	return EnvRoblox.studio(overrides)
end

return Env
