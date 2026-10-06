--!strict
-- @tier T3
-- probe: platform_remoteguard_flood
-- RemoteGuardRoblox: wires a RemoteGuard to the remotes in a folder. Every RemoteEvent and
-- UnreliableRemoteEvent gets OnServerEvent connected to guard:wrap(name, handler); every
-- RemoteFunction gets OnServerInvoke = guard:wrap(...). It fails closed: binding raises when
-- the folder holds a remote the guard has no schema for (an unguarded remote), when a schema has
-- no remote or handler, or when a remote's class does not match its kind. PlayerRemoving clears
-- the guard's per-player state. plan() is the pure mapping (tested in Lune with descriptors);
-- build() creates missing remotes on the server. The flood probe calls the bound handlers with a
-- real Player in a play session; delivery over the network needs a Server & Clients run with a
-- client script (docs/gamekit-platform.md), which is the owner's Studio step.
local RemoteGuardRoblox = {}

RemoteGuardRoblox.CLASS = table.freeze({
	event = "RemoteEvent",
	["function"] = "RemoteFunction",
	unreliable = "UnreliableRemoteEvent",
})
local KIND_OF_CLASS =
	{ RemoteEvent = "event", RemoteFunction = "function", UnreliableRemoteEvent = "unreliable" }

export type Descriptor = { Name: string, ClassName: string }
export type Plan = {
	bind: { { name: string, kind: string, index: number } },
	missing: { string },
	problems: { string },
}

-- Pure: which children to bind and what is wrong. children are Instances or { Name, ClassName }
-- tables; handlers maps remote names to functions (nil skips the handler check).
function RemoteGuardRoblox.plan(guard: any, children: { Descriptor }, handlers: { [string]: any }?): Plan
	local out: Plan = { bind = {}, missing = {}, problems = {} }
	local seen: { [string]: boolean } = {}
	for index, child in children do
		local kind = KIND_OF_CLASS[child.ClassName]
		if kind == nil then
			continue -- folders, values and other children are not remotes
		end
		local name = child.Name
		if seen[name] then
			table.insert(out.problems, "duplicate remote name " .. name)
			continue
		end
		seen[name] = true
		local expected = guard:kind(name)
		if expected == nil then
			table.insert(
				out.problems,
				string.format("unguarded remote %s (%s has no schema)", name, child.ClassName)
			)
		elseif expected ~= kind then
			table.insert(
				out.problems,
				string.format("remote %s is a %s but its schema says %s", name, child.ClassName, expected)
			)
		elseif handlers ~= nil and type(handlers[name]) ~= "function" then
			table.insert(out.problems, "no handler for remote " .. name)
		else
			table.insert(out.bind, { name = name, kind = kind, index = index })
		end
	end
	for _, name in guard:names() do
		if not seen[name] then
			table.insert(out.missing, name)
		end
	end
	table.sort(out.problems)
	return out
end

-- Creates every remote the guard knows that the folder lacks (server side, before clients look
-- for them). roblox supplies Instance (env.roblox or the global). Returns the names created.
function RemoteGuardRoblox.build(folder: any, guard: any, roblox: any?): { string }
	local Instance_ = (roblox and roblox.Instance) or (Instance :: any)
	local created = {}
	for _, name in guard:names() do
		if folder:FindFirstChild(name) == nil then
			local remote = Instance_.new(RemoteGuardRoblox.CLASS[guard:kind(name)])
			remote.Name = name
			remote.Parent = folder
			table.insert(created, name)
		end
	end
	return created
end

export type Binding = {
	handlers: { [string]: (player: any, ...any) -> ...any },
	plan: Plan,
	unbind: () -> (),
}

-- Binds every remote in folder. opts.players (the Players service) clears guard state on
-- PlayerRemoving; opts.allowMissing lets a schema exist without its remote yet.
function RemoteGuardRoblox.bind(
	folder: any,
	guard: any,
	handlers: { [string]: (...any) -> ...any },
	opts: { players: any?, allowMissing: boolean? }?
): Binding
	local children = folder:GetChildren()
	local plan = RemoteGuardRoblox.plan(guard, children, handlers)
	local problems = table.clone(plan.problems)
	if #plan.missing > 0 and not (opts and opts.allowMissing) then
		table.insert(problems, "no remote for " .. table.concat(plan.missing, ", "))
	end
	if #problems > 0 then
		error("RemoteGuardRoblox.bind refused: " .. table.concat(problems, "; "), 2)
	end
	local connections = {}
	local wrapped: { [string]: (player: any, ...any) -> ...any } = {}
	local invoked: { any } = {}
	for _, item in plan.bind do
		local remote = children[item.index]
		local fn = guard:wrap(item.name, handlers[item.name])
		wrapped[item.name] = fn
		if item.kind == "function" then
			remote.OnServerInvoke = fn
			table.insert(invoked, remote)
		else
			table.insert(connections, remote.OnServerEvent:Connect(fn))
		end
	end
	if opts and opts.players then
		table.insert(
			connections,
			opts.players.PlayerRemoving:Connect(function(player: any)
				guard:forget(player)
			end)
		)
	end
	return {
		handlers = wrapped,
		plan = plan,
		unbind = function()
			for _, connection in connections do
				connection:Disconnect()
			end
			for _, remote in invoked do
				remote.OnServerInvoke = nil
			end
			table.clear(connections)
			table.clear(invoked)
		end,
	}
end

return RemoteGuardRoblox
