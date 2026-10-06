--!strict
-- @tier T0
-- Scope: a cleanup bag (Trove/Janitor naming). Add takes a function (called), a thread
-- (env.cancel when given, else coroutine.close), an Instance (Destroy), a connection
-- (Disconnect) or any table with Destroy/Disconnect/destroy/disconnect, or an explicit method
-- name. Clean runs every cleanup in reverse order of adding (LIFO), keeps going when one
-- errors (errors go to env.report, else warn), and leaves the scope reusable. Adding to or
-- cleaning a scope while it cleans raises, as does any use after Destroy. Extend makes a child
-- scope that its parent cleans.
local Scope = {}
Scope.__index = Scope

type Entry = { object: any, method: string? }

type ScopeFields = {
	_entries: { Entry },
	_env: any,
	_cleaning: boolean,
	_destroyed: boolean,
}
export type Scope = typeof(setmetatable({} :: ScopeFields, Scope))

local TABLE_METHODS = { "Destroy", "Disconnect", "destroy", "disconnect" }

function Scope.new(env: any?): Scope
	return setmetatable({ _entries = {}, _env = env, _cleaning = false, _destroyed = false }, Scope)
end

local function usable(self: Scope, what: string)
	if self._destroyed then
		error("Scope:" .. what .. " on a destroyed scope", 3)
	end
	if self._cleaning then
		error("Scope:" .. what .. " while the scope is cleaning", 3)
	end
end

-- The cleanup method for object, or nil for functions and threads (handled directly).
local function methodFor(object: any, method: string?): string?
	local kind = typeof(object)
	if kind == "function" or kind == "thread" then
		return nil
	end
	if method then
		return method
	end
	if kind == "Instance" then
		return "Destroy"
	elseif kind == "RBXScriptConnection" then
		return "Disconnect"
	elseif kind == "table" then
		for _, name in TABLE_METHODS do
			if type(object[name]) == "function" then
				return name
			end
		end
	end
	error("Scope:Add cannot clean a " .. kind .. " without a method name", 3)
end

-- Tracks object for cleanup and returns it. method names the cleanup call for tables and
-- userdata ("Destroy" for Instances and "Disconnect" for connections are found on their own).
function Scope.Add<T>(self: Scope, object: T, method: string?): T
	usable(self, "Add")
	if object == nil then
		error("Scope:Add needs an object", 2)
	end
	table.insert(self._entries, { object = object, method = methodFor(object, method) })
	return object
end

-- Connects fn to signal (anything with :Connect) and tracks the connection.
function Scope.Connect(self: Scope, signal: any, fn: (...any) -> ...any): any
	usable(self, "Connect")
	local connection = signal:Connect(fn)
	self:Add(connection)
	return connection
end

-- A child scope cleaned (and destroyed) when this one cleans.
function Scope.Extend(self: Scope): Scope
	usable(self, "Extend")
	local child = Scope.new(self._env)
	self:Add(child, "Destroy")
	return child
end

local function cleanup(self: Scope, entry: Entry)
	local object = entry.object
	local ok, err
	if type(object) == "function" then
		ok, err = pcall(object)
	elseif type(object) == "thread" then
		local env = self._env
		if env and type(env.cancel) == "function" then
			ok, err = pcall(env.cancel, object)
		elseif coroutine.status(object) ~= "dead" and coroutine.running() ~= object then
			ok, err = pcall(coroutine.close, object)
		else
			ok = true
		end
	else
		ok, err = pcall(function()
			object[entry.method :: string](object)
		end)
	end
	if not ok then
		local env = self._env
		local message = "Scope cleanup error: " .. tostring(err)
		if env and type(env.report) == "function" then
			env.report(message)
		else
			warn(message)
		end
	end
end

-- Cleans one tracked object now and stops tracking it; returns whether it was tracked.
function Scope.Remove(self: Scope, object: any): boolean
	usable(self, "Remove")
	for index = #self._entries, 1, -1 do
		local entry = self._entries[index]
		if entry.object == object then
			table.remove(self._entries, index)
			self._cleaning = true
			cleanup(self, entry)
			self._cleaning = false
			return true
		end
	end
	return false
end

-- Runs every cleanup, newest first. The scope can be used again afterwards.
function Scope.Clean(self: Scope)
	usable(self, "Clean")
	self._cleaning = true
	local entries = self._entries
	self._entries = {}
	for index = #entries, 1, -1 do
		cleanup(self, entries[index])
	end
	self._cleaning = false
end

-- Clean, then refuse further use. Destroying twice is a no-op.
function Scope.Destroy(self: Scope)
	if self._destroyed then
		return
	end
	self:Clean()
	self._destroyed = true
end

return Scope
