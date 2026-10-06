--!strict
-- @tier T3
-- probe: platform_playerdata_memory
-- PlayerDataRoblox: wires a PlayerData store to a server. bind() loads each player's session on
-- join (cancelled if they leave first), releases it on leave, kicks a player whose data could
-- not load or whose session was lost (another server took it), runs the autosave scheduler and
-- flushes every session in game:BindToClose. chooseBackend() picks the storage: memory in Studio
-- unless DataStores are explicitly allowed, else DataStores or an injected ProfileStore.
-- The probe proves the wiring against the real task scheduler and Players with the memory
-- backend; real DataStore and ProfileStore sessions only run in a published game (T4, owner).
local PlayerData = require("./PlayerData")
local Signal = require("./Signal")

local PlayerDataRoblox = {}

PlayerDataRoblox.DEFAULT_AUTOSAVE_STEP = 1 -- seconds between scheduler ticks (the scheduler spaces saves)

-- Neutral default kick texts by reason; games pass their own (localized) kickMessage.
PlayerDataRoblox.KICK_MESSAGES = table.freeze({
	locked = "Your data is still open on another server. Please rejoin in a minute.",
	lock_lost = "Your data was opened on another server. Please rejoin.",
	session_ended = "Your data was opened on another server. Please rejoin.",
	newer_schema = "This server is out of date. Please rejoin to get a newer server.",
	default = "Your data could not be loaded. Please rejoin.",
})

-- The kick text for a load or session-lost reason (pure).
function PlayerDataRoblox.kickMessage(reason: string?): string
	return (PlayerDataRoblox.KICK_MESSAGES :: any)[reason or ""] or PlayerDataRoblox.KICK_MESSAGES.default
end

export type BackendChoice = {
	storeName: string,
	kind: ("auto" | "memory" | "datastore" | "profilestore")?,
	allowStudioDataStores: boolean?, -- Studio uses memory unless this is true
	dataStoreService: any?, -- default env.services.DataStoreService
	profileStore: any?, -- the ProfileStore module (required for kind profilestore)
	serverId: string?, -- game.JobId (empty in Studio: a random id is used)
	now: (() -> number)?, -- UTC seconds (default DateTime.now() from env.roblox)
	mock: boolean?, -- profilestore: use store.Mock
	lockTimeout: number?,
}

-- Picks and builds a PlayerData backend. Returns (backend, kindUsed). kind "auto" means
-- profilestore when a ProfileStore module is given, else datastore; Studio falls back to memory
-- unless allowStudioDataStores (so a Studio play test never writes to the game's DataStores).
function PlayerDataRoblox.chooseBackend(choice: BackendChoice, env: any): (any, string)
	assert(type(choice) == "table", "PlayerDataRoblox.chooseBackend: options required")
	assert(
		type(choice.storeName) == "string" and #choice.storeName >= 1 and #choice.storeName <= 50,
		"PlayerDataRoblox.chooseBackend: storeName is 1-50 characters"
	)
	local kind = choice.kind or "auto"
	if kind == "auto" then
		kind = if choice.profileStore ~= nil then "profilestore" else "datastore"
	end
	local inStudio = env.place ~= nil and env.place.isStudio == true
	if kind == "memory" or (inStudio and not choice.allowStudioDataStores) then
		return PlayerData.memoryBackend({ serverId = "studio" }), "memory"
	end
	if kind == "profilestore" then
		assert(choice.profileStore ~= nil, "PlayerDataRoblox.chooseBackend: inject the ProfileStore module")
		return PlayerData.profileStoreBackend(choice.profileStore, choice.storeName, { mock = choice.mock }),
			"profilestore"
	end
	assert(kind == "datastore", "PlayerDataRoblox.chooseBackend: unknown kind " .. tostring(kind))
	local service = choice.dataStoreService or env.services.DataStoreService
	assert(service ~= nil, "PlayerDataRoblox.chooseBackend: DataStoreService missing")
	local serverId = choice.serverId
	if serverId == nil or serverId == "" then
		serverId = string.format("server-%08x", env.rng():int(0, 0x7fffffff))
	end
	local now = choice.now
	if now == nil then
		local DateTime = env.roblox and env.roblox.DateTime
		assert(DateTime ~= nil, "PlayerDataRoblox.chooseBackend: pass now() or env.roblox.DateTime")
		now = function(): number
			return DateTime.now().UnixTimestampMillis / 1000
		end
	end
	return PlayerData.dataStoreBackend(service:GetDataStore(choice.storeName), {
		serverId = serverId :: string,
		now = now :: () -> number,
		lockTimeout = choice.lockTimeout,
	}, env),
		"datastore"
end

export type BindOptions = {
	players: any?, -- default env.services.Players
	game: any?, -- the DataModel, for BindToClose (required unless bindToClose = false)
	bindToClose: boolean?, -- default true
	kickOnFailure: boolean?, -- default true: a player whose data did not load cannot play
	kickMessage: ((reason: string) -> string)?,
	autosaveStep: number?,
	closeDeadline: number?,
}

-- Binds store to the server's players. Returns a binding with:
--   loaded    Signal(player, session) after a session starts
--   failed    Signal(player, reason) when a load fails (not when the player left first)
--   sessionFor(player) -> session?; waitForSession(player, timeout?) -> session? (yields)
--   unbind()  disconnects everything (sessions stay; release them or call store:releaseAll())
function PlayerDataRoblox.bind(store: any, options: BindOptions?, env: any): any
	local opts: BindOptions = options or {}
	local players = opts.players or env.services.Players
	assert(players ~= nil, "PlayerDataRoblox.bind: Players service missing")
	local bindToClose = opts.bindToClose ~= false
	assert(
		not bindToClose or (opts.game ~= nil and type(opts.game.BindToClose) == "function"),
		"PlayerDataRoblox.bind: pass game (for BindToClose) or bindToClose = false"
	)
	local step = opts.autosaveStep or PlayerDataRoblox.DEFAULT_AUTOSAVE_STEP
	assert(type(step) == "number" and step > 0, "PlayerDataRoblox.bind: autosaveStep must be > 0")
	local kickOnFailure = opts.kickOnFailure ~= false
	local message: (reason: string) -> string = opts.kickMessage or PlayerDataRoblox.kickMessage
	local bound = true
	local connections: { any } = {}
	local binding = { loaded = Signal.new(env), failed = Signal.new(env) } :: any

	local function inGame(player: any): boolean
		return player.Parent == players
	end

	local function kick(player: any, reason: string)
		if kickOnFailure and inGame(player) then
			player:Kick(message(reason))
		end
	end

	local function load(player: any)
		local session, reason = store:load(player.UserId, {
			cancel = function(): boolean
				return not bound or not inGame(player)
			end,
		})
		if session ~= nil then
			binding.loaded:Fire(player, session)
			return
		end
		if reason == "cancelled" or reason == "closed" or reason == "loading" then
			return
		end
		binding.failed:Fire(player, reason)
		kick(player, reason :: string)
	end

	table.insert(
		connections,
		players.PlayerAdded:Connect(function(player: any)
			env.spawn(load, player)
		end)
	)
	table.insert(
		connections,
		players.PlayerRemoving:Connect(function(player: any)
			env.spawn(function()
				store:release(player.UserId)
			end)
		end)
	)
	table.insert(
		connections,
		store.sessionLost:Connect(function(userId: number, why: string)
			local player = players:GetPlayerByUserId(userId)
			if player then
				kick(player, why)
			end
		end)
	)
	for _, player in players:GetPlayers() do
		env.spawn(load, player)
	end
	env.spawn(function()
		while bound do
			env.wait(step)
			if bound then
				store:tick()
			end
		end
	end)
	if bindToClose then
		opts.game:BindToClose(function()
			if bound then
				store:releaseAll({ deadline = opts.closeDeadline })
			end
		end)
	end

	function binding.sessionFor(_self: any, player: any): any
		return store:get(player.UserId)
	end

	-- Yields until the player's session is loaded, they leave, or timeout (default 30 s) passes.
	function binding.waitForSession(_self: any, player: any, timeout: number?): any
		local deadline = env.clock() + (timeout or 30)
		while bound and inGame(player) do
			local session = store:get(player.UserId)
			if session ~= nil then
				return session
			end
			if env.clock() >= deadline then
				break
			end
			env.wait(0.1)
		end
		return store:get(player.UserId)
	end

	function binding.unbind(_self: any)
		bound = false
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end

	return binding
end

return PlayerDataRoblox
