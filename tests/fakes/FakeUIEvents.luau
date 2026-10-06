--!strict
-- FakeUIEvents (G4): stands in for engine events on @lune/roblox Instances, which have none.
-- UIKit components wire behaviour through ctx.on(instance, event, fn) and
-- ctx.onChanged(instance, property, fn); a spec passes hub.on / hub.onChanged and drives the
-- component with hub:fire(instance, "Activated") or hub:changed(instance, "AbsoluteSize").
-- Connections are tables with Disconnect, so GameKit/Scope cleans them; hub:count() shows
-- what is still connected (0 after a handle is destroyed).
local FakeUIEvents = {}

type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }
type Entry = { instance: any, name: string, fn: (...any) -> (), connection: Connection }

function FakeUIEvents.new(): any
	local entries: { Entry } = {}
	local hub: any = {}

	local function connect(instance: any, name: string, fn: (...any) -> ()): Connection
		assert(instance ~= nil, "FakeUIEvents: connect on nil")
		assert(type(fn) == "function", "FakeUIEvents: handler must be a function")
		local connection: any = { Connected = true }
		local entry: Entry = { instance = instance, name = name, fn = fn, connection = connection }
		function connection.Disconnect(self: any)
			if not self.Connected then
				return
			end
			self.Connected = false
			local at = table.find(entries, entry)
			if at then
				table.remove(entries, at)
			end
		end
		table.insert(entries, entry)
		return connection
	end

	hub.on = function(instance: any, event: string, fn: (...any) -> ()): Connection
		return connect(instance, event, fn)
	end
	hub.onChanged = function(instance: any, property: string, fn: () -> ()): Connection
		return connect(instance, "changed:" .. property, fn)
	end

	-- Calls every handler of instance.event (connection order); returns how many ran.
	function hub.fire(_self: any, instance: any, event: string, ...: any): number
		local ran = 0
		for _, entry in table.clone(entries) do
			if entry.instance == instance and entry.name == event and entry.connection.Connected then
				ran += 1
				entry.fn(...)
			end
		end
		return ran
	end

	function hub.changed(self: any, instance: any, property: string): number
		return self:fire(instance, "changed:" .. property)
	end

	-- Connected handlers, optionally only for one instance or event.
	function hub.count(_self: any, instance: any?, event: string?): number
		local n = 0
		for _, entry in entries do
			if (instance == nil or entry.instance == instance) and (event == nil or entry.name == event) then
				n += 1
			end
		end
		return n
	end

	-- Every instance that has a handler for event (for "click every button" loops).
	function hub.targets(_self: any, event: string): { any }
		local out = {}
		for _, entry in entries do
			if entry.name == event and not table.find(out, entry.instance) then
				table.insert(out, entry.instance)
			end
		end
		return out
	end

	return hub
end

return FakeUIEvents
