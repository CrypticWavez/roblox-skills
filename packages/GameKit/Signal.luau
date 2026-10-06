--!strict
-- @tier T0
-- Signal: an RBXScriptSignal-shaped event (names follow RbxUtil Signal). Handlers run in
-- connection order, each on its own thread (env.spawn when given, else a coroutine), so a
-- handler that errors or yields never stops the others. Fire snapshots the handlers: one
-- connected during a Fire waits for the next Fire; one disconnected earlier in the same Fire
-- is skipped. FireDeferred queues the same snapshot through env.defer (task.defer in Roblox,
-- FakeEnv:flush() in Lune). Wait yields the calling thread until the next Fire; call it from a
-- spawned thread, never from a step function. Errors that do not go through env.spawn are
-- passed to env.report (or warn).
local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

type ConnectionFields = {
	Connected: boolean,
	_signal: any,
	_fn: ((...any) -> ...any)?,
	_thread: thread?,
	_once: boolean,
}
export type Connection = typeof(setmetatable({} :: ConnectionFields, Connection))

type SignalFields = {
	_handlers: { Connection },
	_env: any,
	_destroyed: boolean,
}
export type Signal = typeof(setmetatable({} :: SignalFields, Signal))

function Connection.Disconnect(self: Connection)
	if not self.Connected then
		return
	end
	self.Connected = false
	local handlers = self._signal._handlers
	local index = table.find(handlers, self)
	if index then
		table.remove(handlers, index)
	end
end

function Signal.new(env: any?): Signal
	return setmetatable({ _handlers = {}, _env = env, _destroyed = false }, Signal)
end

local function report(self: Signal, err: any)
	local env = self._env
	local message = "Signal handler error: " .. tostring(err)
	if env and type(env.report) == "function" then
		env.report(message)
	else
		warn(message)
	end
end

local function resumeThread(self: Signal, thread: thread, ...: any)
	local env = self._env
	if env and type(env.spawn) == "function" then
		env.spawn(thread, ...)
		return
	end
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		report(self, err)
	end
end

local function call(self: Signal, connection: Connection, ...: any)
	if connection._thread then
		resumeThread(self, connection._thread :: thread, ...)
		return
	end
	local fn = connection._fn :: (...any) -> ...any
	local env = self._env
	if env and type(env.spawn) == "function" then
		env.spawn(fn, ...)
		return
	end
	resumeThread(self, coroutine.create(fn), ...)
end

local function add(self: Signal, fn: ((...any) -> ...any)?, thread: thread?, once: boolean): Connection
	if self._destroyed then
		error("Signal: connect on a destroyed signal", 3)
	end
	local connection = setmetatable({
		Connected = true,
		_signal = self,
		_fn = fn,
		_thread = thread,
		_once = once,
	}, Connection)
	table.insert(self._handlers, connection)
	return connection
end

function Signal.Connect(self: Signal, fn: (...any) -> ...any): Connection
	if type(fn) ~= "function" then
		error("Signal:Connect needs a function", 2)
	end
	return add(self, fn, nil, false)
end

-- Like Connect, but disconnects before its first call.
function Signal.Once(self: Signal, fn: (...any) -> ...any): Connection
	if type(fn) ~= "function" then
		error("Signal:Once needs a function", 2)
	end
	return add(self, fn, nil, true)
end

-- Yields until the next Fire and returns its arguments.
function Signal.Wait(self: Signal): ...any
	if not coroutine.isyieldable() then
		error("Signal:Wait needs a yieldable thread", 2)
	end
	add(self, nil, coroutine.running(), true)
	return coroutine.yield()
end

-- Calls each handler of a snapshot that is still connected; a Once handler is disconnected just
-- before its call, so a second dispatch of the same snapshot skips it.
local function dispatch(self: Signal, list: { Connection }, ...: any)
	for _, connection in list do
		if connection.Connected then
			if connection._once then
				connection:Disconnect()
			end
			call(self, connection, ...)
		end
	end
end

function Signal.Fire(self: Signal, ...: any)
	if self._destroyed then
		return
	end
	dispatch(self, table.clone(self._handlers), ...)
end

-- Queues this Fire through env.defer; the handler snapshot is taken now.
function Signal.FireDeferred(self: Signal, ...: any)
	if self._destroyed then
		return
	end
	local env = self._env
	if not (env and type(env.defer) == "function") then
		error("Signal:FireDeferred needs an env with defer (Signal.new(env))", 2)
	end
	local list = table.clone(self._handlers)
	local args = table.pack(...)
	env.defer(function()
		dispatch(self, list, table.unpack(args, 1, args.n))
	end)
end

-- Disconnects every handler and drops every waiting thread (they are never resumed).
function Signal.DisconnectAll(self: Signal)
	for _, connection in self._handlers do
		connection.Connected = false
	end
	self._handlers = {}
end

-- DisconnectAll, then further Fire calls do nothing and Connect raises.
function Signal.Destroy(self: Signal)
	self:DisconnectAll()
	self._destroyed = true
end

return Signal
