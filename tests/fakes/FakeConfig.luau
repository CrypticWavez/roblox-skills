--!strict
-- FakeConfig (G1): a ConfigService stand-in for Lune specs, following the method names
-- ConfigRoblox uses: GetConfigAsync() and GetConfigForPlayerAsync(player) return a snapshot
-- with GetValue(key), Refresh() and an UpdateAvailable signal. publish(values) changes the
-- published values and fires UpdateAvailable on every snapshot (the values a snapshot returns
-- change only after its Refresh). Faults: fail(message) makes the next Get*Async raise, hang = true
-- makes it wait forever (on env), latency waits before answering, failKey(key) makes
-- GetValue(key) raise. playerValues overrides values per UserId (experiments).
local FakePlatformRoblox = require("./FakePlatformRoblox")

local FakeConfig = {}

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

function FakeConfig.new(options: {
	values: { [string]: any }?,
	playerValues: { [number]: { [string]: any } }?,
	env: any?,
	latency: number?,
}?): any
	local env = options and options.env
	local service = {
		published = copy(options and options.values or {}),
		playerValues = copy(options and options.playerValues or {}),
		hang = false,
		calls = 0,
		_failNext = nil :: string?,
		_failKeys = {} :: { [string]: boolean },
		_snapshots = {} :: { any },
	} :: any
	local latency = options and options.latency or 0

	local function makeSnapshot(userId: number?): any
		local function current(): { [string]: any }
			local values = copy(service.published)
			if userId and service.playerValues[userId] then
				for key, value in service.playerValues[userId] do
					values[key] = copy(value)
				end
			end
			return values
		end
		local snapshot =
			{ UpdateAvailable = FakePlatformRoblox.signal(), refreshes = 0, _values = current() } :: any
		function snapshot.GetValue(self: any, key: string): any
			if service._failKeys[key] then
				error("GetValue failed for " .. key, 0)
			end
			return copy(self._values[key])
		end
		function snapshot.Refresh(self: any)
			self.refreshes += 1
			self._values = current()
		end
		table.insert(service._snapshots, snapshot)
		return snapshot
	end

	local function answer(userId: number?): any
		service.calls += 1
		if latency > 0 and env then
			env.wait(latency)
		end
		if service.hang then
			assert(env ~= nil, "FakeConfig: hang needs an env")
			env.wait(math.huge)
		end
		local message = service._failNext
		if message then
			service._failNext = nil
			error(message, 0)
		end
		return makeSnapshot(userId)
	end

	function service.GetConfigAsync(_self: any): any
		return answer(nil)
	end

	function service.GetConfigForPlayerAsync(_self: any, player: any): any
		if type(player) ~= "table" or type(player.UserId) ~= "number" then
			error("GetConfigForPlayerAsync: argument 1 must be a Player", 0)
		end
		return answer(player.UserId)
	end

	function service.fail(self: any, message: string?)
		self._failNext = message or "ConfigService unavailable"
	end

	function service.failKey(self: any, key: string)
		self._failKeys[key] = true
	end

	function service.publish(self: any, values: { [string]: any })
		self.published = copy(values)
		for _, snapshot in self._snapshots do
			snapshot.UpdateAvailable:Fire()
		end
	end

	return service
end

return FakeConfig
