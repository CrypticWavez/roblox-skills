--!strict
-- @tier T0
-- PlayerData: session-locked player data with versioned migrations, template reconcile,
-- validated atomic updates, grant-once receipts, an autosave scheduler and a shutdown flush.
-- One server owns a player's data at a time (the session); every change goes through
-- session:update(fn), which runs fn on a copy and commits only a storable, in-budget result, so
-- a failed or invalid update never touches live data. Storage is a backend passed in:
--   memoryBackend()                       in-memory (Lune specs, Studio without DataStores)
--   dataStoreBackend(dataStore, opts)     Roblox's documented lock-in-metadata pattern over
--                                         UpdateAsync, with a serial save queue
--   profileStoreBackend(ProfileStore, n)  ProfileStore 1.0.3 injected by the game (never
--                                         vendored or required here)
-- Real DataStore and ProfileStore sessions are T4 (published place); the core and the backends'
-- logic are proven in Lune against FakeDataStore and FakeProfileStore. Engine wiring (players,
-- BindToClose, the autosave loop, kicks) is PlayerDataRoblox. Data keys are camelCase; the core
-- reserves two top-level keys: schemaVersion and purchaseIds (the receipt ring).
local Check = require("./Check")
local Retry = require("./Retry")
local Schema = require("./Schema")
local Signal = require("./Signal")

local PlayerData = {}

PlayerData.RESERVED = table.freeze({ "schemaVersion", "purchaseIds" })
-- Conventions (not Roblox limits) unless noted.
PlayerData.DEFAULT_SIZE_BUDGET = 4000000 -- under the documented 4,194,304-character value limit
PlayerData.DEFAULT_RECEIPT_RING = 100
PlayerData.DEFAULT_AUTOSAVE = 180 -- Roblox player-data reference architecture: 180 s, per-player jitter
PlayerData.DEFAULT_JITTER = 0.1
PlayerData.DEFAULT_CLOSE_DEADLINE = 25 -- inside the 30 s BindToClose window
PlayerData.DEFAULT_LOCK_TIMEOUT = 300 -- dataStoreBackend: longer than an autosave interval
PlayerData.DEFAULT_LOCK_RETRY = 5
PlayerData.DEFAULT_LOCK_WAIT = 60
PlayerData.MAX_KEY_LENGTH = 50 -- DataStore key names are at most 50 characters
PlayerData.LOAD_REASONS = table.freeze({
	"closed", -- the store is shutting down
	"invalid_user",
	"loading", -- a load for this user is already running
	"cancelled", -- the player left (cancel() returned true)
	"locked", -- another server holds the session
	"backend_error",
	"corrupt", -- stored data is not a table or has a bad version or receipt ring
	"newer_schema", -- written by a newer server version; never downgraded
	"migration_failed",
	"invalid", -- not storable or fails options.schema after migration
	"too_large",
})

export type Handle = {
	data: () -> { [string]: any },
	replace: (value: { [string]: any }) -> (),
	saved: () -> { [string]: any }?,
	active: () -> boolean,
	save: () -> (),
	saveAsync: (predicate: ((saved: any) -> boolean)?) -> (boolean, string?),
	close: (save: boolean) -> (boolean, string?),
	onLost: (fn: (reason: string) -> ()) -> () -> (),
}
export type OpenOptions = { cancel: (() -> boolean)?, env: any }
export type Backend = {
	name: string,
	managesAutosave: boolean,
	open: (self: any, key: string, userId: number, opts: OpenOptions) -> (Handle?, string?),
}
export type Options = {
	template: { [string]: any },
	version: number,
	migrations: { [number]: (data: { [string]: any }) -> { [string]: any } }?,
	firstVersion: number?,
	backend: Backend,
	keyPrefix: string?,
	schema: Schema.Schema?,
	sizeBudget: number?,
	receiptRing: number?,
	autosave: ({ interval: number?, jitter: number?, seed: (number | string)? } | false)?,
	closeDeadline: number?,
}

local function count(map: { [any]: any }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

local function isList(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local n = count(value)
	for index = 1, n do
		if value[index] == nil then
			return false
		end
	end
	return true
end

local function replaceContents(target: { [any]: any }, source: { [any]: any })
	for key in target do
		target[key] = nil
	end
	for key, value in source do
		target[key] = value
	end
end

local function segments(path: string | { string }): { string }
	if type(path) == "table" then
		return path
	end
	return string.split(path, ".")
end

-- Fills keys the data lacks from the template (deep for maps; lists are not merged); never
-- overwrites or removes a key.
function PlayerData.reconcile(data: { [string]: any }, template: { [string]: any }): { [string]: any }
	for key, value in template do
		local current = data[key]
		if current == nil then
			data[key] = Check.copy(value)
		elseif
			type(value) == "table"
			and type(current) == "table"
			and not isList(value)
			and next(value) ~= nil
		then
			PlayerData.reconcile(current, value)
		end
	end
	return data
end

-- The data an options.schema sees: everything but the reserved keys the core manages.
local function userView(data: { [string]: any }): { [string]: any }
	local view = table.clone(data)
	for _, key in PlayerData.RESERVED do
		view[key] = nil
	end
	return view
end

local function validPurchaseId(value: any): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 128
		and string.match(value, "^[%w_%-]+$") ~= nil
end

-- ---------------------------------------------------------------- autosave scheduler

export type Scheduler = {
	add: (self: Scheduler, id: any, now: number) -> number,
	remove: (self: Scheduler, id: any) -> (),
	due: (self: Scheduler, now: number) -> { any },
	nextAt: (self: Scheduler, id: any) -> number?,
	size: (self: Scheduler) -> number,
}

-- A pure per-player cadence: each id is first due at now + interval * (1 +- jitter) (so saves
-- spread out), then every interval after that. due(now) returns the ids due, oldest first, and
-- schedules their next turn; an id far behind (a stalled server) restarts from now.
function PlayerData.scheduler(options: { interval: number, jitter: number?, rng: any }): Scheduler
	local interval = options.interval
	local jitter = options.jitter or PlayerData.DEFAULT_JITTER
	assert(Check.finite(interval) and interval > 0, "PlayerData.scheduler: interval must be > 0")
	assert(
		Check.finite(jitter) and jitter >= 0 and jitter < 1,
		"PlayerData.scheduler: jitter must be in [0, 1)"
	)
	assert(options.rng ~= nil and type(options.rng.next) == "function", "PlayerData.scheduler: rng required")
	local entries: { [any]: number } = {}
	local order: { [any]: number } = {}
	local serial = 0
	local scheduler = {} :: any
	function scheduler.add(_self: any, id: any, now: number): number
		local first = now + interval * (1 + jitter * (2 * options.rng:next() - 1))
		entries[id] = first
		serial += 1
		order[id] = serial
		return first
	end
	function scheduler.remove(_self: any, id: any)
		entries[id] = nil
		order[id] = nil
	end
	function scheduler.due(_self: any, now: number): { any }
		local ids = {}
		for id, at in entries do
			if at <= now then
				table.insert(ids, id)
			end
		end
		table.sort(ids, function(a: any, b: any): boolean
			if entries[a] ~= entries[b] then
				return entries[a] < entries[b]
			end
			return order[a] < order[b]
		end)
		for _, id in ids do
			local nextAt = entries[id] + interval
			entries[id] = if nextAt <= now then now + interval else nextAt
		end
		return ids
	end
	function scheduler.nextAt(_self: any, id: any): number?
		return entries[id]
	end
	function scheduler.size(_self: any): number
		return count(entries)
	end
	return scheduler
end

-- ---------------------------------------------------------------- backends

-- (fire(reason), connect(fn) -> disconnect) for a handle's onLost.
local function lostSignal(env: any): (any, any)
	local signal = Signal.new(env)
	return function(reason: string)
		signal:Fire(reason)
	end, function(fn: (string) -> ()): () -> ()
		local connection = signal:Connect(fn)
		return function()
			connection:Disconnect()
		end
	end
end

export type MemoryShared = { values: { [string]: any }, locks: { [string]: string } }

-- In-memory storage. Backends that share `shared` act as servers of one game: a key held by one
-- serverId is "locked" for the others until closed. failSaves (on the backend) makes the next
-- n saves fail. For Lune specs and Studio sessions that must not touch DataStores.
function PlayerData.memoryBackend(options: { serverId: string?, shared: MemoryShared? }?): any
	local serverId = options and options.serverId or "memory"
	local shared: MemoryShared = options and options.shared or { values = {}, locks = {} }
	local backend =
		{ name = "memory", managesAutosave = false, shared = shared, failSaves = 0, saves = 0 } :: any
	function backend.open(self: any, key: string, _userId: number, opts: OpenOptions): (Handle?, string?)
		if opts.cancel and opts.cancel() then
			return nil, "cancelled"
		end
		local holder = shared.locks[key]
		if holder ~= nil and holder ~= serverId then
			return nil, "locked"
		end
		shared.locks[key] = serverId
		local stored = shared.values[key]
		local live: any = if stored == nil then {} else Check.copy(stored)
		local saved: any = if stored == nil then nil else Check.copy(stored)
		local active = true
		local fireLost, connectLost = lostSignal(opts.env)
		local function write(): (boolean, string?)
			if not active then
				return false, "inactive"
			end
			if shared.locks[key] ~= serverId then
				active = false
				fireLost("lock_lost")
				return false, "lock_lost"
			end
			if self.failSaves > 0 then
				self.failSaves -= 1
				return false, "save_failed"
			end
			local snapshot = Check.copy(live)
			shared.values[key] = snapshot
			saved = Check.copy(snapshot)
			self.saves += 1
			return true, nil
		end
		local handle: Handle = {
			data = function(): any
				return live
			end,
			replace = function(value: any)
				if type(live) == "table" then
					replaceContents(live, value)
				else
					live = value
				end
			end,
			saved = function(): any
				return saved
			end,
			active = function(): boolean
				return active
			end,
			save = function()
				write()
			end,
			saveAsync = function(predicate: ((any) -> boolean)?): (boolean, string?)
				local ok, reason = write()
				if not ok then
					return false, reason
				end
				if predicate and not predicate(saved) then
					return false, "not_in_save"
				end
				return true, nil
			end,
			close = function(save: boolean): (boolean, string?)
				local ok, reason = true, nil
				if active and save then
					ok, reason = write()
				end
				if shared.locks[key] == serverId then
					shared.locks[key] = nil
				end
				active = false
				return ok, reason
			end,
			onLost = connectLost,
		}
		return handle, nil
	end
	-- Test helper: another server takes the lock (as a steal or an expired lock would).
	function backend.steal(_self: any, key: string, byServer: string)
		shared.locks[key] = byServer
	end
	return backend
end

export type DataStoreOptions = {
	serverId: string, -- this server (game.JobId; any unique string in Studio)
	now: () -> number, -- UTC seconds shared across servers (os.time / DateTime in the adapter)
	lockTimeout: number?, -- seconds before another server may take a silent lock
	lockRetry: number?, -- seconds between lock checks while waiting
	lockWait: number?, -- give up waiting for a lock after this long (seconds)
	retry: Retry.Options?, -- per DataStore call (default Retry.dataStore)
	sizeBudget: number?,
}

-- Roblox's documented session lock: the lock lives in the key's metadata and is written in the
-- same UpdateAsync as the data, with this server's id and a timestamp; a lock older than
-- lockTimeout may be taken over (a crashed server). Every save checks the lock first, so a
-- server that lost it never overwrites the new owner's data and reports the session lost.
-- Saves for one key run one at a time (a serial queue), so an older snapshot can never land
-- after a newer one. Calls are retried with Retry (throttles and server errors).
function PlayerData.dataStoreBackend(dataStore: any, options: DataStoreOptions, env: any): any
	assert(
		dataStore ~= nil and type(dataStore.UpdateAsync) == "function",
		"dataStoreBackend: needs a DataStore"
	)
	assert(type(options) == "table", "dataStoreBackend: options required")
	assert(
		type(options.serverId) == "string" and options.serverId ~= "",
		"dataStoreBackend: serverId required"
	)
	assert(type(options.now) == "function", "dataStoreBackend: now (UTC seconds) required")
	assert(env ~= nil and type(env.clock) == "function", "dataStoreBackend: env required")
	local serverId = options.serverId
	local lockTimeout = options.lockTimeout or PlayerData.DEFAULT_LOCK_TIMEOUT
	local lockRetry = options.lockRetry or PlayerData.DEFAULT_LOCK_RETRY
	local lockWait = options.lockWait or PlayerData.DEFAULT_LOCK_WAIT
	local sizeBudget = options.sizeBudget or PlayerData.DEFAULT_SIZE_BUDGET
	local retry = options.retry or Retry.dataStore()
	local backend = { name = "datastore", managesAutosave = false, lockTimeout = lockTimeout } :: any

	local function update(key: string, transform: (any, any) -> ...any): (boolean, any)
		local ok, result = Retry.run(function(): any
			return dataStore:UpdateAsync(key, transform)
		end, retry, env)
		return ok, result
	end

	local function metadataOf(info: any): { [string]: any }
		if info == nil then
			return {}
		end
		local ok, meta = pcall(function(): any
			return info:GetMetadata()
		end)
		return if ok and type(meta) == "table" then Check.copy(meta) else {}
	end

	local function userIdsOf(info: any, userId: number): { number }
		local ids: { number } = {}
		if info ~= nil then
			local ok, list = pcall(function(): any
				return info:GetUserIds()
			end)
			if ok and type(list) == "table" then
				for _, id in list do
					table.insert(ids, id)
				end
			end
		end
		if not table.find(ids, userId) then
			table.insert(ids, userId)
		end
		return ids
	end

	local function heldElsewhere(meta: { [string]: any }, t: number): boolean
		local lock = meta.lock
		return type(lock) == "table"
			and lock.server ~= serverId
			and Check.finite(lock.at)
			and t - lock.at < lockTimeout
	end

	function backend.open(_self: any, key: string, userId: number, opts: OpenOptions): (Handle?, string?)
		local deadline = env.clock() + lockWait
		local value: any = nil
		while true do
			if opts.cancel and opts.cancel() then
				return nil, "cancelled"
			end
			local outcome = nil
			local t = options.now()
			local ok, result = update(key, function(current: any, info: any): ...any
				local meta = metadataOf(info)
				if heldElsewhere(meta, t) then
					outcome = "locked"
					return nil
				end
				outcome = "acquired"
				meta.lock = { server = serverId, at = t }
				return (if current == nil then {} else current), userIdsOf(info, userId), meta
			end)
			if not ok then
				env.report(string.format("PlayerData %s: lock read failed: %s", key, tostring(result)))
				return nil, "backend_error"
			end
			if outcome == "acquired" then
				value = result
				break
			end
			if env.clock() + lockRetry > deadline then
				return nil, "locked"
			end
			env.wait(lockRetry)
		end

		local live: any = value
		local saved: any = Check.copy(value)
		local active = true
		local closed = false
		local saving = false
		local generation = 0
		local savedGeneration = 0
		local failedGeneration = 0
		local lastError: string? = nil
		local saveDone = Signal.new(env)
		local fireLost, connectLost = lostSignal(env)

		local function write(final: boolean): (boolean, string?)
			if not active then
				return false, "inactive"
			end
			if type(live) ~= "table" then
				return false, "corrupt"
			end
			if Schema.size(live) > sizeBudget then
				return false, "too_large"
			end
			local snapshot = Check.copy(live)
			local t = options.now()
			local outcome = nil
			local ok, result = update(key, function(_current: any, info: any): ...any
				local meta = metadataOf(info)
				local lock = meta.lock
				if type(lock) ~= "table" or lock.server ~= serverId then
					outcome = "lock_lost"
					return nil
				end
				outcome = "written"
				meta.lock = if final then nil else { server = serverId, at = t }
				return snapshot, userIdsOf(info, userId), meta
			end)
			if not ok then
				env.report(string.format("PlayerData %s: save failed: %s", key, tostring(result)))
				return false, "save_failed"
			end
			if outcome == "lock_lost" then
				active = false
				fireLost("lock_lost")
				return false, "lock_lost"
			end
			saved = snapshot
			return true, nil
		end

		local function pump()
			if saving then
				return
			end
			saving = true
			while active and savedGeneration < generation do
				local target = generation
				local ok, reason = write(false)
				if ok then
					savedGeneration = target
				else
					failedGeneration = target
					lastError = reason
					saveDone:Fire(false)
					break
				end
				saveDone:Fire(true)
			end
			saving = false
			saveDone:Fire(nil)
		end

		local function request(): number
			generation += 1
			if not saving then
				env.spawn(pump)
			end
			return generation
		end

		local handle: Handle = {
			data = function(): any
				return live
			end,
			replace = function(next: any)
				if type(live) == "table" then
					replaceContents(live, next)
				else
					live = next
				end
			end,
			saved = function(): any
				return saved
			end,
			active = function(): boolean
				return active
			end,
			save = function()
				if active then
					request()
				end
			end,
			saveAsync = function(predicate: ((any) -> boolean)?): (boolean, string?)
				if not active then
					return false, "inactive"
				end
				local mine = request()
				while savedGeneration < mine do
					if failedGeneration >= mine then
						return false, lastError or "save_failed"
					end
					if not active then
						return false, "inactive"
					end
					if not saving then
						request()
					end
					saveDone:Wait()
				end
				if predicate and not predicate(saved) then
					return false, "not_in_save"
				end
				return true, nil
			end,
			close = function(save: boolean): (boolean, string?)
				if closed then
					return true, nil
				end
				closed = true
				while saving do
					saveDone:Wait()
				end
				if not active then
					return false, "inactive"
				end
				local ok, reason = true, nil
				if save then
					ok, reason = write(true)
				else
					-- release the lock without writing data
					local released, err = update(key, function(current: any, info: any): ...any
						local meta = metadataOf(info)
						if type(meta.lock) ~= "table" or meta.lock.server ~= serverId then
							return nil
						end
						meta.lock = nil
						return current, userIdsOf(info, userId), meta
					end)
					if not released then
						ok, reason = false, "save_failed"
						env.report(string.format("PlayerData %s: unlock failed: %s", key, tostring(err)))
					end
				end
				active = false
				return ok, reason
			end,
			onLost = connectLost,
		}
		return handle, nil
	end
	return backend
end

export type ProfileStoreOptions = { mock: boolean? }

-- ProfileStore 1.0.3 (MadStudioRoblox, Apache-2.0), injected: pass require(ServerPackages.ProfileStore)
-- from the game. Uses ProfileStore.New(name, {}) (the core reconciles the template itself),
-- store:StartSessionAsync(key, { Cancel }), Profile.Data, Profile.LastSavedData, Profile:Save(),
-- Profile:IsActive(), Profile:EndSession(), Profile:AddUserId(), Profile.OnSessionEnd and
-- Profile.OnAfterSave. ProfileStore autosaves on its own (managesAutosave) and resolves session
-- conflicts through MessagingService. opts.mock uses store.Mock (no DataStore writes). Steal is
-- never used: it is for debugging and risks duplication.
function PlayerData.profileStoreBackend(
	ProfileStore: any,
	storeName: string,
	options: ProfileStoreOptions?
): any
	assert(
		type(ProfileStore) == "table" and type(ProfileStore.New) == "function",
		"profileStoreBackend: inject the ProfileStore module"
	)
	assert(
		type(storeName) == "string" and #storeName >= 1 and #storeName <= 50,
		"profileStoreBackend: storeName is 1-50 characters"
	)
	local store: any = nil
	local backend = { name = "profilestore", managesAutosave = true } :: any
	local function getStore(): any
		if store == nil then
			local created = ProfileStore.New(storeName, {})
			store = if options and options.mock then created.Mock else created
		end
		return store
	end
	function backend.open(_self: any, key: string, userId: number, opts: OpenOptions): (Handle?, string?)
		local env = opts.env
		local cancel = opts.cancel
		local ok, profile = pcall(function(): any
			return getStore():StartSessionAsync(key, { Cancel = cancel })
		end)
		if not ok then
			env.report(string.format("PlayerData %s: StartSessionAsync failed: %s", key, tostring(profile)))
			return nil, "backend_error"
		end
		if profile == nil then
			return nil, if cancel and cancel() then "cancelled" else "locked"
		end
		pcall(function()
			profile:AddUserId(userId)
		end)
		local fireLost, connectLost = lostSignal(env)
		local ending = false
		local endConnection = profile.OnSessionEnd:Connect(function()
			if not ending then
				fireLost("session_ended")
			end
		end)
		-- Waits for whichever comes first: a save (returns its data) or the end of the session
		-- (returns nil). before() runs after the listeners are connected, so a save it starts
		-- cannot be missed even if it completes at once.
		local function nextSaveOrEnd(before: (() -> ())?): any
			local thread = coroutine.running()
			local done = false
			local waiting = false
			local result: any = nil
			local connections: { any } = {} -- the ProfileStore profile's signal connections
			local function finish(value: any)
				if done then
					return
				end
				done = true
				result = value
				for _, connection in connections do
					connection:Disconnect()
				end
				if waiting then
					env.spawn(thread, value)
				end
			end
			table.insert(
				connections,
				profile.OnAfterSave:Connect(function(lastSaved: any)
					finish(lastSaved)
				end)
			)
			table.insert(
				connections,
				profile.OnSessionEnd:Connect(function()
					finish(nil)
				end)
			)
			if before then
				before()
			end
			if done then
				return result
			end
			waiting = true
			return coroutine.yield()
		end
		local handle: Handle = {
			data = function(): any
				return profile.Data
			end,
			replace = function(value: any)
				replaceContents(profile.Data, value)
			end,
			saved = function(): any
				return profile.LastSavedData
			end,
			active = function(): boolean
				return profile:IsActive()
			end,
			save = function()
				if profile:IsActive() then
					profile:Save()
				end
			end,
			saveAsync = function(predicate: ((any) -> boolean)?): (boolean, string?)
				if not profile:IsActive() then
					return false, "inactive"
				end
				-- ProfileStore's receipt pattern: wait for saves (this one, then autosaves) until
				-- one holds what the predicate needs, or the session ends.
				local lastSaved = nextSaveOrEnd(function()
					profile:Save()
				end)
				while true do
					if lastSaved ~= nil and (predicate == nil or predicate(lastSaved)) then
						return true, nil
					end
					if not profile:IsActive() then
						return false, "inactive"
					end
					lastSaved = nextSaveOrEnd(nil)
				end
			end,
			close = function(_save: boolean): (boolean, string?)
				ending = true
				endConnection:Disconnect()
				if profile:IsActive() then
					profile:EndSession() -- ProfileStore saves the profile as it ends the session
				end
				return true, nil
			end,
			onLost = connectLost,
		}
		return handle, nil
	end
	return backend
end

-- ---------------------------------------------------------------- sessions

local Session = {}
Session.__index = Session

type SessionFields = {
	userId: number,
	key: string,
	onSessionLost: Signal.Signal,
	changed: Signal.Signal,
	_store: any,
	_handle: Handle,
	_updating: boolean,
	_released: boolean,
	_lost: boolean,
}
export type Session = typeof(setmetatable({} :: SessionFields, Session))

function Session.isActive(self: Session): boolean
	return not self._released and not self._lost and self._handle.active()
end

-- A deep copy of the value at path ("a.b" or { "a", "b" }), or of all data when path is nil.
function Session.get(self: Session, path: (string | { string })?): any
	local node: any = self._handle.data()
	if path ~= nil then
		for _, part in segments(path) do
			if type(node) ~= "table" then
				return nil
			end
			node = node[part]
		end
	end
	return Check.copy(node)
end

-- Runs fn on a deep copy of the data; fn mutates the copy (and returns nil) or returns a new
-- table. The result is committed only if it is storable, passes options.schema and fits the size
-- budget; the reserved keys are kept as they were. fn must not yield. Returns (true) or
-- (false, reason, detail) with reasons inactive, busy, update_failed, not_storable, schema,
-- too_large, reserved_key.
function Session.update(
	self: Session,
	fn: (data: { [string]: any }) -> { [string]: any }?,
	purchaseId: string?
): (boolean, string?, string?)
	if not self:isActive() then
		return false, "inactive", nil
	end
	if self._updating then
		return false, "busy", nil
	end
	local store = self._store
	local live = self._handle.data()
	local draft = Check.copy(live)
	self._updating = true
	local ok, result = pcall(fn, draft)
	self._updating = false
	if not ok then
		return false, "update_failed", tostring(result)
	end
	local nextData: any = if result == nil then draft else result
	if type(nextData) ~= "table" then
		return false, "update_failed", "fn must return a table or nil"
	end
	nextData.schemaVersion = live.schemaVersion
	local ring = Check.copy(live.purchaseIds)
	if purchaseId ~= nil then
		table.insert(ring, purchaseId)
		while #ring > store._receiptRing do
			table.remove(ring, 1)
		end
	end
	nextData.purchaseIds = ring
	local storable, path, why = Schema.storable(nextData)
	if not storable then
		return false, "not_storable", string.format("%s at %s", tostring(why), tostring(path))
	end
	if store._schema then
		local valid, schemaPath, schemaWhy = Schema.check(store._schema, userView(nextData))
		if not valid then
			return false, "schema", string.format("%s at %s", tostring(schemaWhy), tostring(schemaPath))
		end
	end
	local size = Schema.size(nextData)
	if size > store._sizeBudget then
		return false, "too_large", tostring(size)
	end
	-- a fresh copy, so nothing fn kept a reference to can change live data later
	self._handle.replace(Check.copy(nextData))
	self.changed:Fire()
	return true, nil, nil
end

-- Sets one path ("a.b.c"), creating missing tables on the way.
function Session.set(self: Session, path: string | { string }, value: any): (boolean, string?, string?)
	local parts = segments(path)
	for _, part in parts do
		if table.find(PlayerData.RESERVED, part) and #parts == 1 then
			return false, "reserved_key", part
		end
	end
	return self:update(function(data: any): any
		local node = data
		for index = 1, #parts - 1 do
			local part = parts[index]
			if type(node[part]) ~= "table" then
				node[part] = {}
			end
			node = node[part]
		end
		node[parts[#parts]] = Check.copy(value)
		return nil
	end)
end

-- The key-store interface other kits take (Inventory, Wallet, SettingsStore): get(key) and
-- set(key, value) -> (ok, reason) under an optional prefix path.
function Session.keyStore(self: Session, prefix: string?): any
	local session = self
	local function path(key: string): string
		assert(
			type(key) == "string" and key ~= "" and not string.find(key, ".", 1, true),
			"keyStore keys are non-empty and dot-free"
		)
		return if prefix then prefix .. "." .. key else key
	end
	return {
		get = function(_self: any, key: string): any
			return session:get(path(key))
		end,
		set = function(_self: any, key: string, value: any): (boolean, string?)
			local ok, reason = session:set(path(key), value)
			return ok, reason
		end,
	}
end

-- Whether purchaseId is in the live receipt ring (granted in this session or saved before).
function Session.hasReceipt(self: Session, purchaseId: string): boolean
	return table.find(self._handle.data().purchaseIds or {}, purchaseId) ~= nil
end

-- Grants a developer-product purchase exactly once (the documented receipt pattern): if the
-- purchase id is not in the ring, grant(draft) runs as one update that also records the id;
-- then it waits (yields) until a durable save holds the id. Returns "granted" only then; else
-- "not_processed" with a reason, and Roblox retries the receipt later. A duplicate receipt skips
-- grant and only waits for the save.
function Session.grantReceipt(
	self: Session,
	purchaseId: string,
	grant: (data: { [string]: any }) -> { [string]: any }?
): (string, string?)
	if not validPurchaseId(purchaseId) then
		return "not_processed", "invalid_purchase_id"
	end
	if not self:isActive() then
		return "not_processed", "inactive"
	end
	if not self:hasReceipt(purchaseId) then
		local ok, reason, detail = self:update(grant, purchaseId)
		if not ok then
			self._store._env.report(
				string.format(
					"PlayerData receipt %s not granted: %s %s",
					purchaseId,
					tostring(reason),
					tostring(detail)
				)
			)
			return "not_processed", reason
		end
	end
	local saved, why = self._handle.saveAsync(function(snapshot: any): boolean
		return type(snapshot) == "table"
			and type(snapshot.purchaseIds) == "table"
			and table.find(snapshot.purchaseIds, purchaseId) ~= nil
	end)
	if saved then
		return "granted", nil
	end
	return "not_processed", why or "not_saved"
end

-- Requests a save without waiting (memory and DataStore backends; ProfileStore saves itself).
function Session.save(self: Session)
	if self:isActive() then
		self._handle.save()
	end
end

-- Saves and waits (yields) until it is durable. Returns (ok, reason).
function Session.saveAsync(self: Session): (boolean, string?)
	if not self:isActive() then
		return false, "inactive"
	end
	return self._handle.saveAsync(nil)
end

-- Ends the session: final save, then the lock is released (yields). Idempotent.
function Session.release(self: Session): (boolean, string?)
	if self._released then
		return true, nil
	end
	self._released = true
	self._store:_forget(self.userId, self)
	if self._lost then
		return false, "lost"
	end
	local ok, result, reason = pcall(self._handle.close, true)
	if not ok then
		self._store._env.report(
			string.format("PlayerData %s: release failed: %s", self.key, tostring(result))
		)
		return false, "backend_error"
	end
	return result, reason
end

-- ---------------------------------------------------------------- store

local Store = {}
Store.__index = Store

type StoreFields = {
	sessionLost: Signal.Signal,
	_options: Options,
	_env: any,
	_backend: Backend,
	_template: { [string]: any },
	_version: number,
	_firstVersion: number,
	_migrations: { [number]: (any) -> any },
	_keyPrefix: string,
	_schema: Schema.Schema?,
	_sizeBudget: number,
	_receiptRing: number,
	_sessions: { [number]: Session },
	_loading: { [number]: boolean },
	_scheduler: Scheduler?,
	_closeDeadline: number,
	_closed: boolean,
}
export type Store = typeof(setmetatable({} :: StoreFields, Store))

-- Problems with PlayerData options (empty when valid).
function PlayerData.validate(options: any): { string }
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	local problems = {}
	local template = options.template
	if type(template) ~= "table" then
		table.insert(problems, "template must be a table")
	else
		local ok, path, why = Schema.storable(template)
		if not ok then
			table.insert(
				problems,
				string.format("template is not storable: %s at %s", tostring(why), tostring(path))
			)
		end
		for _, key in PlayerData.RESERVED do
			if template[key] ~= nil then
				table.insert(problems, "template must not set the reserved key " .. key)
			end
		end
	end
	local version = options.version
	if not (Check.integer(version) and version >= 1) then
		table.insert(problems, "version must be an integer >= 1")
	end
	local first = options.firstVersion or 1
	if not (Check.integer(first) and first >= 1 and (not Check.integer(version) or first <= version)) then
		table.insert(problems, "firstVersion must be an integer from 1 to version")
	end
	local migrations = options.migrations or {}
	if type(migrations) ~= "table" then
		table.insert(problems, "migrations must map versions to functions")
	elseif Check.integer(version) and Check.integer(first) then
		for step = first, version - 1 do
			if type(migrations[step]) ~= "function" then
				table.insert(
					problems,
					string.format("migrations[%d] (version %d to %d) is missing", step, step, step + 1)
				)
			end
		end
		for step in migrations do
			if not (Check.integer(step) and step >= first and step < version) then
				table.insert(problems, "migrations has an unused step " .. tostring(step))
			end
		end
	end
	local backend = options.backend
	if type(backend) ~= "table" or type(backend.open) ~= "function" then
		table.insert(
			problems,
			"backend must have an open function (memoryBackend, dataStoreBackend, profileStoreBackend)"
		)
	end
	local prefix = options.keyPrefix
	if
		prefix ~= nil
		and not (type(prefix) == "string" and #prefix <= 30 and string.match(prefix, "^[%w_%-:]*$") ~= nil)
	then
		table.insert(problems, "keyPrefix must be at most 30 letters, digits or _ - :")
	end
	if options.schema ~= nil and not Schema.isSchema(options.schema) then
		table.insert(problems, "schema must be a GameKit/Schema schema")
	end
	local budget = options.sizeBudget
	if
		budget ~= nil
		and not (Check.integer(budget) and budget >= 1 and budget <= Schema.DATASTORE_VALUE_LIMIT)
	then
		table.insert(problems, "sizeBudget must be an integer from 1 to 4194304")
	end
	local ring = options.receiptRing
	if ring ~= nil and not (Check.integer(ring) and ring >= 1 and ring <= 1000) then
		table.insert(problems, "receiptRing must be an integer from 1 to 1000")
	end
	local autosave = options.autosave
	if autosave ~= nil and autosave ~= false then
		if type(autosave) ~= "table" then
			table.insert(problems, "autosave must be a table or false")
		else
			if
				autosave.interval ~= nil and not (Check.finite(autosave.interval) and autosave.interval > 0)
			then
				table.insert(problems, "autosave.interval must be > 0 seconds")
			end
			if
				autosave.jitter ~= nil
				and not (Check.finite(autosave.jitter) and autosave.jitter >= 0 and autosave.jitter < 1)
			then
				table.insert(problems, "autosave.jitter must be in [0, 1)")
			end
		end
	end
	if
		options.closeDeadline ~= nil
		and not (Check.finite(options.closeDeadline) and options.closeDeadline > 0)
	then
		table.insert(problems, "closeDeadline must be > 0 seconds")
	end
	-- a dataStoreBackend lock is refreshed by saves: the autosave must come round before it expires
	if type(backend) == "table" and Check.finite(backend.lockTimeout) then
		if autosave == false then
			table.insert(problems, "autosave = false lets the dataStoreBackend lock expire; keep autosave on")
		elseif autosave == nil or type(autosave) == "table" then
			local settings: any = autosave or {}
			local interval = settings.interval or PlayerData.DEFAULT_AUTOSAVE
			local jitter = settings.jitter or PlayerData.DEFAULT_JITTER
			if
				Check.finite(interval)
				and Check.finite(jitter)
				and interval * (1 + jitter) >= backend.lockTimeout
			then
				table.insert(
					problems,
					"autosave interval (with jitter) must be shorter than the backend lockTimeout"
				)
			end
		end
	end
	return problems
end

function PlayerData.new(options: Options, env: any): Store
	local problems = PlayerData.validate(options)
	if
		env == nil
		or type(env.clock) ~= "function"
		or type(env.spawn) ~= "function"
		or type(env.wait) ~= "function"
	then
		table.insert(problems, "env with clock, spawn and wait is required")
	end
	if #problems > 0 then
		error("PlayerData.new: " .. table.concat(problems, "; "), 2)
	end
	local scheduler = nil
	local autosave = options.autosave
	if autosave ~= false and not options.backend.managesAutosave then
		local settings: any = if type(autosave) == "table" then autosave else {}
		scheduler = PlayerData.scheduler({
			interval = settings.interval or PlayerData.DEFAULT_AUTOSAVE,
			jitter = settings.jitter or PlayerData.DEFAULT_JITTER,
			rng = env.rng(settings.seed),
		})
	end
	return setmetatable({
		sessionLost = Signal.new(env),
		_options = options,
		_env = env,
		_backend = options.backend,
		_template = Check.freeze(Check.copy(options.template)),
		_version = options.version,
		_firstVersion = options.firstVersion or 1,
		_migrations = options.migrations or {},
		_keyPrefix = options.keyPrefix or "player_",
		_schema = options.schema,
		_sizeBudget = options.sizeBudget or PlayerData.DEFAULT_SIZE_BUDGET,
		_receiptRing = options.receiptRing or PlayerData.DEFAULT_RECEIPT_RING,
		_sessions = {},
		_loading = {},
		_scheduler = scheduler,
		_closeDeadline = options.closeDeadline or PlayerData.DEFAULT_CLOSE_DEADLINE,
		_closed = false,
	}, Store)
end

function Store.keyFor(self: Store, userId: number): string
	assert(Check.integer(userId) and userId > 0, "PlayerData: userId must be an integer > 0")
	return self._keyPrefix .. tostring(userId)
end

-- Migrates stored data to the current version on a copy. Returns (data) or (nil, reason, detail).
function Store.prepare(self: Store, raw: any): ({ [string]: any }?, string?, string?)
	if type(raw) ~= "table" then
		return nil, "corrupt", "stored value is a " .. type(raw)
	end
	local data: any
	if next(raw) == nil then
		data = Check.copy(self._template)
		data.schemaVersion = self._version
		data.purchaseIds = {}
	else
		local from = raw.schemaVersion
		if from == nil then
			from = self._firstVersion -- data written before versioning: the oldest supported shape
		end
		if not Check.integer(from) or from < self._firstVersion then
			return nil, "corrupt", "schemaVersion " .. Check.describe(from)
		end
		if from > self._version then
			return nil, "newer_schema", string.format("stored %d, this server %d", from, self._version)
		end
		local ring = raw.purchaseIds
		if ring ~= nil then
			if not isList(ring) then
				return nil, "corrupt", "purchaseIds is not a list"
			end
			for _, id in ring do
				if not validPurchaseId(id) then
					return nil, "corrupt", "purchaseIds holds " .. Check.describe(id)
				end
			end
		end
		data = Check.copy(raw)
		for step = from, self._version - 1 do
			local ok, result = pcall(self._migrations[step], data)
			if not ok or type(result) ~= "table" then
				return nil,
					"migration_failed",
					string.format(
						"step %d: %s",
						step,
						if ok then "returned " .. type(result) else tostring(result)
					)
			end
			data = result
			data.schemaVersion = step + 1
		end
		data.schemaVersion = self._version
		data.purchaseIds = if type(ring) == "table" then Check.copy(ring) else {}
		PlayerData.reconcile(data, self._template)
	end
	local ok, path, why = Schema.storable(data)
	if not ok then
		return nil, "invalid", string.format("%s at %s", tostring(why), tostring(path))
	end
	if self._schema then
		local valid, schemaPath, schemaWhy = Schema.check(self._schema, userView(data))
		if not valid then
			return nil, "invalid", string.format("%s at %s", tostring(schemaWhy), tostring(schemaPath))
		end
	end
	if Schema.size(data) > self._sizeBudget then
		return nil, "too_large", tostring(Schema.size(data))
	end
	return data, nil, nil
end

-- Starts the user's session (yields while the backend loads). Returns the session, or nil and
-- one of PlayerData.LOAD_REASONS. opts.cancel (e.g. the player left) is checked while waiting
-- and after loading. Loading an already loaded user returns the same session.
function Store.load(self: Store, userId: number, opts: { cancel: (() -> boolean)? }?): (Session?, string?)
	if self._closed then
		return nil, "closed"
	end
	if not (Check.integer(userId) and userId > 0) then
		return nil, "invalid_user"
	end
	local existing = self._sessions[userId]
	if existing then
		return existing, nil
	end
	if self._loading[userId] then
		return nil, "loading"
	end
	self._loading[userId] = true
	local session, reason = self:_start(userId, opts and opts.cancel)
	self._loading[userId] = nil
	return session, reason
end

-- load() after its guards: opens, prepares and registers the session (yields).
function Store._start(self: Store, userId: number, cancel: (() -> boolean)?): (Session?, string?)
	local env = self._env
	local key = self:keyFor(userId)
	local called, handle, openReason =
		pcall(self._backend.open, self._backend, key, userId, { cancel = cancel, env = env })
	if not called then
		env.report(string.format("PlayerData %s: open failed: %s", key, tostring(handle)))
		return nil, "backend_error"
	end
	if handle == nil then
		return nil, openReason or "backend_error"
	end
	local data, reason, detail = self:prepare(handle.data())
	if data == nil then
		env.report(
			string.format(
				"PlayerData %s: not loaded (%s: %s); stored data left untouched",
				key,
				tostring(reason),
				tostring(detail)
			)
		)
		pcall(handle.close, false)
		return nil, reason
	end
	handle.replace(data)
	if self._closed or (cancel and cancel()) then
		-- nothing changed yet, so the lock is released without writing
		pcall(handle.close, false)
		return nil, if self._closed then "closed" else "cancelled"
	end
	local session: Session = setmetatable({
		userId = userId,
		key = key,
		onSessionLost = Signal.new(env),
		changed = Signal.new(env),
		_store = self,
		_handle = handle,
		_updating = false,
		_released = false,
		_lost = false,
	}, Session)
	self._sessions[userId] = session
	if self._scheduler then
		self._scheduler:add(userId, env.clock())
	end
	handle.onLost(function(why: string)
		if session._released or session._lost then
			return
		end
		session._lost = true
		self:_forget(userId, session)
		session.onSessionLost:Fire(why)
		self.sessionLost:Fire(userId, why)
	end)
	return session, nil
end

function Store._forget(self: Store, userId: number, session: Session)
	if self._sessions[userId] == session then
		self._sessions[userId] = nil
		if self._scheduler then
			self._scheduler:remove(userId)
		end
	end
end

-- The active session for a user, or nil.
function Store.get(self: Store, userId: number): Session?
	return self._sessions[userId]
end

-- User ids with an active session, sorted.
function Store.loaded(self: Store): { number }
	local ids = {}
	for userId in self._sessions do
		table.insert(ids, userId)
	end
	table.sort(ids)
	return ids
end

-- Ends the user's session with a final save (yields). Returns (ok, reason); true when none.
function Store.release(self: Store, userId: number): (boolean, string?)
	local session: Session? = self._sessions[userId]
	if session == nil then
		return true, nil
	end
	return session:release()
end

-- Autosave step (non-yielding): asks the sessions that are due to save. Returns their user ids.
-- Does nothing for backends that autosave themselves (ProfileStore) or with autosave = false.
function Store.tick(self: Store, now: number?): { number }
	local scheduler = self._scheduler
	if scheduler == nil or self._closed then
		return {}
	end
	local due = scheduler:due(now or self._env.clock())
	for _, userId in due do
		local session = self._sessions[userId]
		if session then
			session:save()
		end
	end
	return due
end

export type CloseSummary = { released: { number }, failed: { number }, timedOut: { number } }

-- The shutdown flush (BindToClose): refuses new loads, releases every session in parallel and
-- waits until all finish or the deadline passes (default 25 s, inside the 30 s window). Yields.
function Store.releaseAll(self: Store, opts: { deadline: number? }?): CloseSummary
	self._closed = true
	local env = self._env
	local summary: CloseSummary = { released = {}, failed = {}, timedOut = {} }
	local pending: { [number]: boolean } = {}
	local sessions = table.clone(self._sessions)
	for userId, session in sessions do
		pending[userId] = true
		env.spawn(function()
			local ok = session:release()
			pending[userId] = nil
			table.insert(if ok then summary.released else summary.failed, userId)
		end)
	end
	local deadline = env.clock() + (opts and opts.deadline or self._closeDeadline)
	-- loads still running see _closed when they finish and close their own handles
	while (next(pending) ~= nil or next(self._loading) ~= nil) and env.clock() < deadline do
		env.wait(0.1)
	end
	for userId in pending do
		table.insert(summary.timedOut, userId)
	end
	table.sort(summary.released)
	table.sort(summary.failed)
	table.sort(summary.timedOut)
	return summary
end

-- ---------------------------------------------------------------- erasure

export type EraseStore = { name: string, keyPrefix: string? }

-- Lists the DataStore keys that hold a user's data, for the owner's manual handling of a data
-- erasure request (they delete with RemoveAsync or the Creator Hub / Open Cloud tools). It never
-- deletes anything. stores: the PlayerData store(s) ({ name, keyPrefix }) plus any ledgers
-- (a ReceiptLedger namespace keys "<namespace>:<userId>": pass { name, keyPrefix = ns .. ":" }).
function PlayerData.eraseKeys(userId: number, stores: { EraseStore }): { { store: string, key: string } }
	assert(Check.integer(userId) and userId > 0, "PlayerData.eraseKeys: userId must be an integer > 0")
	assert(
		type(stores) == "table" and #stores > 0,
		"PlayerData.eraseKeys: list the stores that hold player data"
	)
	local out = {}
	for _, entry in stores do
		assert(
			type(entry.name) == "string" and entry.name ~= "",
			"PlayerData.eraseKeys: each store needs a name"
		)
		local prefix = entry.keyPrefix or "player_"
		table.insert(out, { store = entry.name, key = prefix .. tostring(userId) })
	end
	return out
end

return PlayerData
