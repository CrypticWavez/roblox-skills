--!strict
-- @tier T4
-- ConfigRoblox: feeds a GameKit/Config from ConfigService. load() calls
-- ConfigService:GetConfigAsync() (or GetConfigForPlayerAsync(player) for per-player experiment
-- values) inside a pcall with a timeout, reads each declared key with snapshot:GetValue(key), and
-- applies the values; on any error or timeout the Config keeps its defaults (fail safe, the
-- research's rule after reports of a 30 s hang in games without configs). It then follows
-- snapshot.UpdateAvailable: snapshot:Refresh() and re-apply, so a published config change (the
-- kill switch) reaches running servers. Config publishes themselves are production changes and
-- owner-only. T4: ConfigService in an unpublished place is UNVERIFIED (research
-- release-monetization-analytics-2026-10 section 13); the logic is proven against
-- tests/fakes/FakeConfig, which follows the method names above.
local ConfigRoblox = {}

ConfigRoblox.DEFAULT_TIMEOUT = 10 -- convention: seconds before giving up and keeping defaults

-- Runs fn on a new thread and waits up to timeout seconds. Returns (finished, ok, result).
local function withTimeout(env: any, timeout: number, fn: () -> any): (boolean, boolean, any)
	local state = { done = false, ok = false, result = nil :: any }
	env.spawn(function()
		local ok, result = pcall(fn)
		state.done, state.ok, state.result = true, ok, result
	end)
	local deadline = env.clock() + timeout
	while not state.done and env.clock() < deadline do
		env.wait(0.1)
	end
	return state.done, state.ok, state.result
end

local function read(snapshot: any, keys: { string }): ({ [string]: any }, { string })
	local values, errors = {}, {}
	for _, key in keys do
		local ok, value = pcall(function(): any
			return snapshot:GetValue(key)
		end)
		if ok then
			values[key] = value
		else
			table.insert(errors, string.format("%s: GetValue failed: %s", key, tostring(value)))
		end
	end
	return values, errors
end

export type LoadOptions = { player: any?, timeout: number? }
export type Binding = {
	ok: boolean,
	reason: string?,
	notes: { string },
	refresh: () -> boolean,
	disconnect: () -> (),
}

-- Loads config values (yields up to timeout). Returns a binding: ok/reason/notes of the load,
-- refresh() to re-read now, disconnect() to stop following updates.
function ConfigRoblox.load(config: any, configService: any, options: LoadOptions?, env: any): Binding
	local timeout = options and options.timeout or ConfigRoblox.DEFAULT_TIMEOUT
	local player = options and options.player
	local source = if player ~= nil then "service_player" else "service"
	local keys = config:keys()
	local connection: any = nil
	local snapshot: any = nil
	local binding = { ok = false, reason = nil :: string?, notes = {} :: { string } } :: any

	local function apply(): boolean
		local values, errors = read(snapshot, keys)
		local notes = config:apply(values, source)
		for _, note in errors do
			table.insert(notes, note)
		end
		binding.notes = notes
		return #errors == 0
	end

	function binding.refresh(): boolean
		if snapshot == nil then
			return false
		end
		local ok = pcall(function()
			snapshot:Refresh()
		end)
		return ok and apply()
	end

	function binding.disconnect()
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end

	if configService == nil then
		binding.reason = "no_service"
		return binding
	end
	local finished, ok, result = withTimeout(env, timeout, function(): any
		if player ~= nil then
			return configService:GetConfigForPlayerAsync(player)
		end
		return configService:GetConfigAsync()
	end)
	if not finished then
		binding.reason = "timeout"
		env.report(string.format("ConfigRoblox: no config after %s s; defaults kept", tostring(timeout)))
		return binding
	end
	if not ok or result == nil then
		binding.reason = "error"
		env.report("ConfigRoblox: config not loaded (" .. tostring(result) .. "); defaults kept")
		return binding
	end
	snapshot = result
	binding.ok = apply()
	binding.reason = if binding.ok then nil else "partial"
	local signal = snapshot.UpdateAvailable
	if signal ~= nil then
		connection = signal:Connect(function()
			binding.refresh()
		end)
	end
	return binding
end

return ConfigRoblox
