--!strict
-- FakeProfileStore (G1): the subset of ProfileStore 1.0.3 (MadStudioRoblox) that
-- PlayerData.profileStoreBackend uses, for Lune specs. A `world` is the shared DataStore of one
-- game; world:server(jobId) returns a module table (what require(ProfileStore) gives a game
-- server) with New(name, template) -> store, store.Mock, store:StartSessionAsync(key,
-- { Cancel }) and profiles with Data, LastSavedData, Key, UserIds, IsActive, Save, EndSession,
-- AddUserId, OnSessionEnd and OnAfterSave(lastSavedData).
-- Session conflicts follow ProfileStore's documented behaviour: a server starting a session
-- that another server holds makes that server end its session (it saves and fires
-- OnSessionEnd), then takes the profile (world.conflict = "handoff", the default). With
-- world.conflict = "block" the holder never answers and StartSessionAsync waits until Cancel
-- returns true (then returns nil). Save() is asynchronous (it runs on its own thread after
-- world.saveLatency seconds); world:failSaves(n) makes the next n saves fail silently, as a
-- DataStore outage would (ProfileStore retries on its next autosave). world:autosave() saves
-- every active profile, standing in for the 300 s autosave. This is a fake of the documented
-- API, not ProfileStore's code (which is never vendored).
local Signal = require("../../packages/GameKit/Signal")

local FakeProfileStore = {}

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in value do
		out[key] = copy(item)
	end
	return out
end

export type Record = { data: any, holder: string?, profile: any?, userIds: { number } }

-- A shared ProfileStore backing for one simulated game.
function FakeProfileStore.world(env: any): any
	assert(env ~= nil and type(env.spawn) == "function", "FakeProfileStore.world needs an env")
	local world = {
		env = env,
		records = {} :: { [string]: Record },
		conflict = "handoff",
		saveLatency = 0,
		startLatency = 0,
		saves = 0,
		failedSaves = 0,
		pendingFailures = 0,
		sessionsStarted = 0,
		active = {} :: { any },
	} :: any

	function world.failSaves(self: any, count: number)
		self.pendingFailures += count
	end

	-- The committed data for a store key (a copy), or nil.
	function world.peek(self: any, storeName: string, key: string): any
		local record = self.records[storeName .. "/" .. key]
		return if record then copy(record.data) else nil
	end

	-- Writes committed data directly (seeding a spec).
	function world.seed(self: any, storeName: string, key: string, data: any)
		local id = storeName .. "/" .. key
		local record = self.records[id] or { data = nil, holder = nil, profile = nil, userIds = {} }
		record.data = copy(data)
		self.records[id] = record
	end

	-- Saves every active profile (the autosave).
	function world.autosave(self: any)
		for _, profile in table.clone(self.active) do
			profile:Save()
		end
	end

	local function commit(record: Record, profile: any): boolean
		if world.pendingFailures > 0 then
			world.pendingFailures -= 1
			world.failedSaves += 1
			return false
		end
		if record.holder ~= profile._server then
			return false -- the session moved on; ProfileStore never writes over the new owner
		end
		record.data = copy(profile.Data)
		record.userIds = copy(profile.UserIds)
		profile.LastSavedData = copy(profile.Data)
		world.saves += 1
		return true
	end

	local function newProfile(record: Record, key: string, server: string): any
		local profile = {
			Key = key,
			Data = copy(record.data),
			LastSavedData = copy(record.data),
			UserIds = copy(record.userIds),
			OnSessionEnd = Signal.new(env),
			OnAfterSave = Signal.new(env),
			_server = server,
			_active = true,
		} :: any
		function profile.IsActive(self: any): boolean
			return self._active
		end
		function profile.AddUserId(self: any, userId: number)
			if not table.find(self.UserIds, userId) then
				table.insert(self.UserIds, userId)
			end
		end
		function profile.Save(self: any)
			if not self._active then
				return
			end
			env.spawn(function()
				if world.saveLatency > 0 then
					env.wait(world.saveLatency)
				end
				if self._active and commit(record, self) then
					self.OnAfterSave:Fire(copy(self.LastSavedData))
				end
			end)
		end
		function profile.EndSession(self: any)
			if not self._active then
				return
			end
			self._active = false
			local index = table.find(world.active, self)
			if index then
				table.remove(world.active, index)
			end
			if commit(record, self) then
				self.OnAfterSave:Fire(copy(self.LastSavedData))
			end
			if record.holder == self._server then
				record.holder = nil
				record.profile = nil
			end
			self.OnSessionEnd:Fire()
		end
		return profile
	end

	-- The module table one game server sees.
	function world.server(self: any, jobId: string): any
		local module = { world = self, jobId = jobId }
		function module.New(storeName: string, template: any): any
			assert(type(storeName) == "string" and storeName ~= "", "ProfileStore.New: name required")
			local function makeStore(namespace: string): any
				local store = { Name = storeName }
				function store.StartSessionAsync(_store: any, key: string, params: any?): any
					local cancel = params and params.Cancel
					while true do
						if cancel and cancel() then
							return nil
						end
						if world.startLatency > 0 then
							env.wait(world.startLatency)
							if cancel and cancel() then
								return nil
							end
						end
						local id = namespace .. "/" .. key
						local record = world.records[id]
						if record == nil then
							record = { data = copy(template), holder = nil, profile = nil, userIds = {} }
							world.records[id] = record
						end
						if record.data == nil then
							record.data = copy(template)
						end
						if record.holder == nil then
							record.holder = jobId
							local profile = newProfile(record, key, jobId)
							record.profile = profile
							table.insert(world.active, profile)
							world.sessionsStarted += 1
							return profile
						elseif record.holder == jobId then
							error("[ProfileStore]: Profile " .. key .. " is already loaded in this server", 2)
						elseif world.conflict == "handoff" then
							record.profile:EndSession()
						else
							env.wait(1)
						end
					end
				end
				return store
			end
			local store = makeStore(storeName)
			store.Mock = makeStore("mock:" .. storeName)
			return store
		end
		return module
	end

	return world
end

return FakeProfileStore
