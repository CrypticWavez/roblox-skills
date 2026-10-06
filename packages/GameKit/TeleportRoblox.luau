--!strict
-- @tier T4
-- TeleportRoblox: TeleportService:TeleportAsync with TeleportOptions and the retry pattern from
-- Roblox's teleport guide (retry a failed call after a short delay; on TeleportInitFailed retry
-- Flooded after 15 s and Failure after 1 s; report anything else). T4 and BLOCKED_EXTERNAL here:
-- "TeleportService doesn't support playtesting in Roblox Studio", so teleport() refuses in
-- Studio (and when env.place is unknown) and real teleports need a published universe. Lune specs use the fake TeleportService
-- in tests/fakes/FakePlatformRoblox.
--   options(roblox, spec)                 a TeleportOptions: reserve (ShouldReserveServer),
--                                         accessCode (ReservedServerAccessCode), serverInstanceId,
--                                         data (SetTeleportData)
--   teleport(service, placeId, players, options?, env, opts?) -> (ok, result | reason, detail)
--   reserve(service, placeId, env, opts?) -> (ok, accessCode | reason, privateServerId)
--   bindRetry(service, env, opts?) -> disconnect   TeleportInitFailed handling with a cap
-- Teleport data travels through the client: never put anything there the destination must
-- trust (match membership, rewards). Record matches server-side (MemoryStore, DataStore) and
-- check them on arrival.
local Retry = require("./Retry")

local TeleportRoblox = {}

-- TeleportInitFailed results worth retrying, and the delay before the retry (Roblox's sample).
TeleportRoblox.RETRYABLE = table.freeze({ Flooded = 15, Failure = 1 })
TeleportRoblox.RETRY = table.freeze({ attempts = 5, base = 1, factor = 1, maxDelay = 1, jitter = "none" })
TeleportRoblox.MAX_INIT_RETRIES = 3 -- convention: TeleportInitFailed retries per player per teleport

export type OptionsSpec = {
	reserve: boolean?,
	accessCode: string?,
	serverInstanceId: string?,
	data: any?,
}

-- Builds a TeleportOptions instance from a spec. reserve and accessCode/serverInstanceId are
-- exclusive (a reserved server is either new or named).
function TeleportRoblox.options(roblox: any, spec: OptionsSpec?): any
	assert(roblox ~= nil and roblox.Instance ~= nil, "TeleportRoblox.options: roblox datatypes required")
	local s: OptionsSpec = spec or {}
	local targets = (if s.reserve then 1 else 0)
		+ (if s.accessCode ~= nil then 1 else 0)
		+ (if s.serverInstanceId ~= nil then 1 else 0)
	assert(targets <= 1, "TeleportRoblox.options: pick one of reserve, accessCode, serverInstanceId")
	local options = roblox.Instance.new("TeleportOptions")
	if s.reserve then
		options.ShouldReserveServer = true
	end
	if s.accessCode ~= nil then
		assert(
			type(s.accessCode) == "string" and #s.accessCode > 0,
			"TeleportRoblox.options: accessCode must be a string"
		)
		options.ReservedServerAccessCode = s.accessCode
	end
	if s.serverInstanceId ~= nil then
		assert(
			type(s.serverInstanceId) == "string" and #s.serverInstanceId > 0,
			"TeleportRoblox.options: serverInstanceId must be a string"
		)
		options.ServerInstanceId = s.serverInstanceId
	end
	if s.data ~= nil then
		options:SetTeleportData(s.data)
	end
	return options
end

-- An unknown place counts as Studio (fail closed): only env.place.isStudio == false teleports.
local function studio(env: any): boolean
	return not (env ~= nil and type(env.place) == "table" and env.place.isStudio == false)
end

-- Teleports players to placeId. Retries a raising TeleportAsync (opts.retry, default 5 tries 1 s
-- apart). Returns (true, TeleportAsyncResult) or (false, reason, detail) with reasons studio
-- (refused before calling), invalid (bad place or player list) and failed (detail: the error).
-- A true result means the teleport started; arrival failures come through TeleportInitFailed.
function TeleportRoblox.teleport(
	service: any,
	placeId: number,
	players: { any },
	options: any,
	env: any,
	opts: { retry: Retry.Options? }?
): (boolean, any, any)
	if studio(env) then
		return false, "studio", nil
	end
	if
		type(placeId) ~= "number"
		or placeId <= 0
		or placeId % 1 ~= 0
		or type(players) ~= "table"
		or #players == 0
	then
		return false, "invalid", nil
	end
	local list = table.clone(players)
	local ok, result = Retry.run(function(): any
		return service:TeleportAsync(placeId, list, options)
	end, ((opts and opts.retry) or TeleportRoblox.RETRY) :: any, env)
	if not ok then
		env.report(string.format("TeleportRoblox: TeleportAsync to %d failed: %s", placeId, tostring(result)))
		return false, "failed", tostring(result)
	end
	return true, result, nil
end

-- Reserves a server for placeId (TeleportService:ReserveServer). Returns (true, accessCode,
-- privateServerId) or (false, reason, detail). Refused in Studio like teleport().
function TeleportRoblox.reserve(
	service: any,
	placeId: number,
	env: any,
	opts: { retry: Retry.Options? }?
): (boolean, any, any)
	if studio(env) then
		return false, "studio", nil
	end
	if type(placeId) ~= "number" or placeId <= 0 or placeId % 1 ~= 0 then
		return false, "invalid", nil
	end
	local ok, result = Retry.run(function(): any
		local accessCode, privateServerId = service:ReserveServer(placeId)
		return { accessCode, privateServerId }
	end, ((opts and opts.retry) or TeleportRoblox.RETRY) :: any, env)
	if not ok then
		return false, "failed", tostring(result)
	end
	return true, result[1], result[2]
end

local function resultName(result: any): string
	if typeof(result) == "EnumItem" then
		return result.Name
	end
	return tostring(result)
end

-- Handles TeleportService.TeleportInitFailed: Flooded and Failure are retried for that player
-- after their delay, up to maxRetries per player and destination; other results (GameFull,
-- Unauthorized, ...) and exhausted retries call onGiveUp(player, resultName, message) and are
-- reported. Returns a disconnect function. Bind once per server.
function TeleportRoblox.bindRetry(
	service: any,
	env: any,
	opts: {
		maxRetries: number?,
		onGiveUp: ((player: any, result: string, message: string) -> ())?,
	}?
): () -> ()
	local maxRetries = (opts and opts.maxRetries) or TeleportRoblox.MAX_INIT_RETRIES
	local onGiveUp = opts and opts.onGiveUp
	local counts: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
	local connection = service.TeleportInitFailed:Connect(
		function(player: any, result: any, message: string, placeId: number, options: any)
			local name = resultName(result)
			local delay = (TeleportRoblox.RETRYABLE :: any)[name]
			local key = player
			local count = (counts[key] or 0) + 1
			counts[key] = count
			if delay == nil or count > maxRetries then
				counts[key] = nil
				env.report(
					string.format(
						"TeleportRoblox: teleport of %s gave up: %s %s",
						tostring(player),
						name,
						tostring(message)
					)
				)
				if onGiveUp then
					pcall(onGiveUp, player, name, message)
				end
				return
			end
			env.spawn(function()
				env.wait(delay)
				local ok = TeleportRoblox.teleport(service, placeId, { player }, options, env)
				if ok then
					-- a later TeleportInitFailed for this player counts on from here
					return
				end
				counts[key] = nil
				if onGiveUp then
					pcall(onGiveUp, player, "Failure", "retry failed")
				end
			end)
		end
	)
	return function()
		connection:Disconnect()
	end
end

return TeleportRoblox
