--!strict
-- @tier T3
-- probe: foundation_env_studio
-- EnvRoblox: the GameKit Env (see Env.luau) built from the Roblox globals: clock = time(),
-- defer/spawn/wait = task.*, services through game:GetService, rng seeded from Random.new()
-- when no seed is given, place from RunService and game.GameId/PlaceId. fromGlobals takes the
-- globals as a table, so Lune specs drive the mapping with fakes; studio() passes the real ones.
-- Standalone on purpose (no require of Env): Env.studio() requires this module lazily.
local Rng = require("../ProcGen/Rng")

local EnvRoblox = {}

export type Globals = {
	game: any,
	task: any,
	time: () -> number,
	Random: any?,
	warn: ((...any) -> ())?,
	roblox: any?,
}

-- Builds the env table from injected globals; overrides replace individual fields.
function EnvRoblox.fromGlobals(globals: Globals, overrides: { [string]: any }?): any
	local game = globals.game
	local task = globals.task
	local runService = game:GetService("RunService")
	local services = setmetatable({}, {
		__index = function(cache: any, name: string): any
			local ok, service = pcall(game.GetService, game, name)
			if ok and service ~= nil then
				rawset(cache, name, service)
				return service
			end
			return nil
		end,
	})
	local entropy = if globals.Random then globals.Random.new() else nil
	local report = globals.warn or warn
	local env: { [string]: any } = {
		clock = globals.time,
		defer = function(fn: (...any) -> ...any, ...: any)
			task.defer(fn, ...)
		end,
		spawn = function(fn: (...any) -> ...any, ...: any)
			task.spawn(fn, ...)
		end,
		wait = function(seconds: number?): number
			return task.wait(seconds)
		end,
		services = services,
		rng = function(seed: (number | string)?): Rng.Rng
			if seed == nil then
				if entropy == nil then
					error("env.rng needs a seed (no Random global)", 2)
				end
				seed = entropy:NextInteger(1, 2147483646)
			end
			return Rng.new(seed :: number | string)
		end,
		place = {
			isStudio = runService:IsStudio(),
			gameId = game.GameId,
			placeId = game.PlaceId,
			isServer = runService:IsServer(),
			isClient = runService:IsClient(),
		},
		roblox = globals.roblox,
		report = function(message: string)
			report(message)
		end,
	}
	if overrides then
		for key, value in overrides do
			env[key] = value
		end
	end
	return env
end

-- The env for the running Roblox session (Studio or a live server). Reads the globals only
-- when called, so requiring this module in Lune is safe.
function EnvRoblox.studio(overrides: { [string]: any }?): any
	local roblox = {
		Instance = Instance,
		Vector2 = Vector2,
		Vector3 = Vector3,
		CFrame = CFrame,
		Color3 = Color3,
		ColorSequence = ColorSequence,
		ColorSequenceKeypoint = ColorSequenceKeypoint,
		NumberSequence = NumberSequence,
		NumberSequenceKeypoint = NumberSequenceKeypoint,
		NumberRange = NumberRange,
		UDim = UDim,
		UDim2 = UDim2,
		Rect = Rect,
		TweenInfo = TweenInfo,
		Font = Font,
		BrickColor = BrickColor,
		RaycastParams = RaycastParams,
		OverlapParams = OverlapParams,
		DateTime = DateTime,
		Enum = Enum,
	}
	return EnvRoblox.fromGlobals({
		game = game,
		task = task,
		time = time,
		Random = Random,
		warn = warn,
		roblox = roblox,
	}, overrides)
end

return EnvRoblox
