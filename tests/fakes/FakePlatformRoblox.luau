--!strict
-- FakePlatformRoblox (G1): the few Roblox objects the platform adapters and probes touch, as
-- plain tables for Lune: Instances with Name/ClassName/Parent, children, attributes and IsA
-- (RemoteEvent, UnreliableRemoteEvent, RemoteFunction, Folder, Player), RBXScriptSignal-like
-- events (OnServerEvent, PlayerAdded, PlayerRemoving), a Players service, and a `game` with
-- BindToClose, GameId, PlaceId and JobId. Events fire synchronously in connection order.
-- Datatypes (Vector3, CFrame, Enum) come from @lune/roblox through FakePlatformRoblox.roblox().
local roblox = require("@lune/roblox")

local FakePlatformRoblox = {}

-- ---------------------------------------------------------------- signals

export type FakeSignal = {
	Connect: (self: FakeSignal, fn: (...any) -> ...any) -> any,
	Once: (self: FakeSignal, fn: (...any) -> ...any) -> any,
	Fire: (self: FakeSignal, ...any) -> (),
	count: (self: FakeSignal) -> number,
}

function FakePlatformRoblox.signal(): FakeSignal
	local handlers: { { fn: (...any) -> ...any, connected: boolean, once: boolean } } = {}
	local signal = {} :: any
	local function connect(fn: (...any) -> ...any, once: boolean): any
		local entry = { fn = fn, connected = true, once = once }
		table.insert(handlers, entry)
		local connection = { Connected = true }
		function connection.Disconnect(self: any)
			self.Connected = false
			entry.connected = false
			local index = table.find(handlers, entry)
			if index then
				table.remove(handlers, index)
			end
		end
		entry.connection = connection
		return connection
	end
	function signal.Connect(_self: any, fn: (...any) -> ...any): any
		return connect(fn, false)
	end
	function signal.Once(_self: any, fn: (...any) -> ...any): any
		return connect(fn, true)
	end
	function signal.Fire(_self: any, ...: any)
		for _, entry in table.clone(handlers) do
			if entry.connected then
				if entry.once then
					(entry :: any).connection:Disconnect()
				end
				entry.fn(...)
			end
		end
	end
	function signal.count(_self: any): number
		return #handlers
	end
	return signal
end

-- ---------------------------------------------------------------- instances

local ANCESTRY: { [string]: { string } } = {
	RemoteEvent = { "RemoteEvent", "BaseRemoteEvent", "Instance" },
	UnreliableRemoteEvent = { "UnreliableRemoteEvent", "BaseRemoteEvent", "Instance" },
	RemoteFunction = { "RemoteFunction", "Instance" },
	Folder = { "Folder", "Instance" },
	Player = { "Player", "Instance" },
	Players = { "Players", "Instance" },
}

-- A fake Instance. Setting Parent moves it between children lists; Destroy detaches it.
function FakePlatformRoblox.instance(className: string, name: string?): any
	local children: { any } = {}
	local attributes: { [string]: any } = {}
	local fields: { [string]: any } = {
		Name = name or className,
		ClassName = className,
		Parent = nil,
		Destroyed = false,
	}
	local object = {} :: any
	function object.GetChildren(_self: any): { any }
		return table.clone(children)
	end
	function object.FindFirstChild(_self: any, childName: string): any
		for _, child in children do
			if child.Name == childName then
				return child
			end
		end
		return nil
	end
	function object.IsA(_self: any, class: string): boolean
		return table.find(ANCESTRY[className] or { className, "Instance" }, class) ~= nil
	end
	function object.IsDescendantOf(self: any, ancestor: any): boolean
		local node = self.Parent
		while node ~= nil do
			if node == ancestor then
				return true
			end
			node = node.Parent
		end
		return false
	end
	function object.GetAttribute(_self: any, key: string): any
		return attributes[key]
	end
	function object.SetAttribute(_self: any, key: string, value: any)
		attributes[key] = value
	end
	function object.Destroy(self: any)
		self.Parent = nil
		fields.Destroyed = true
		for _, child in table.clone(children) do
			child:Destroy()
		end
	end
	object._children = children
	if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
		fields.OnServerEvent = FakePlatformRoblox.signal()
	elseif className == "RemoteFunction" then
		fields.OnServerInvoke = nil
	end
	return setmetatable(object, {
		__index = function(_t: any, key: string): any
			return fields[key]
		end,
		__newindex = function(t: any, key: string, value: any)
			if key == "Parent" then
				local old = fields.Parent
				if old ~= nil then
					local index = table.find(old._children, t)
					if index then
						table.remove(old._children, index)
					end
				end
				fields.Parent = value
				if value ~= nil then
					table.insert(value._children, t)
				end
			else
				fields[key] = value
			end
		end,
		__tostring = function(): string
			return fields.Name
		end,
	})
end

-- A fake Player: UserId, Name, PartyId (default ""), Parent (the Players service while in the
-- game), Kick(message) recorded in .kicked.
function FakePlatformRoblox.player(userId: number, partyId: string?): any
	local player = FakePlatformRoblox.instance("Player", "player_" .. tostring(userId))
	player.UserId = userId
	player.PartyId = partyId or ""
	player.kicked = nil
	function player.Kick(self: any, message: string?)
		self.kicked = message or ""
	end
	return player
end

-- A fake Players service. join(userId) adds a player and fires PlayerAdded; leave(player)
-- fires PlayerRemoving and then detaches it, as Roblox does.
function FakePlatformRoblox.players(userIds: { number }?): any
	local service = FakePlatformRoblox.instance("Players", "Players")
	service.PlayerAdded = FakePlatformRoblox.signal()
	service.PlayerRemoving = FakePlatformRoblox.signal()
	function service.GetPlayers(self: any): { any }
		return self:GetChildren()
	end
	function service.GetPlayerByUserId(self: any, userId: number): any
		for _, player in self:GetChildren() do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end
	function service.join(self: any, userId: number, partyId: string?): any
		local player = FakePlatformRoblox.player(userId, partyId)
		player.Parent = self
		self.PlayerAdded:Fire(player)
		return player
	end
	function service.leave(self: any, player: any)
		self.PlayerRemoving:Fire(player)
		player.Parent = nil
	end
	for _, userId in userIds or {} do
		local player = FakePlatformRoblox.player(userId)
		player.Parent = service
	end
	return service
end

-- A fake `game`: GameId, PlaceId, JobId and BindToClose (close() runs the callbacks in order).
function FakePlatformRoblox.game(options: { gameId: number?, placeId: number?, jobId: string? }?): any
	local game =
		{ GameId = options and options.gameId or 0, PlaceId = options and options.placeId or 0 } :: any
	game.JobId = options and options.jobId or "fake-job"
	game.closers = {}
	function game.BindToClose(self: any, fn: () -> ())
		table.insert(self.closers, fn)
	end
	function game.close(self: any)
		for _, fn in self.closers do
			fn()
		end
	end
	return game
end

-- A roblox datatype table for env.roblox: fake Instance.new plus @lune/roblox datatypes and Enum.
function FakePlatformRoblox.roblox(): any
	return {
		Instance = {
			new = function(className: string): any
				return FakePlatformRoblox.instance(className)
			end,
		},
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Enum = roblox.Enum,
	}
end

return FakePlatformRoblox
