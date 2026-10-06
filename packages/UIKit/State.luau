--!strict
-- @tier T0
-- State: the small reactive layer UIKit needs instead of a UI framework (docs/uikit.md
-- "State"). State.value(x) holds a value; State.computed({ a, b }, fn) derives one; :observe(fn)
-- calls fn(new, old) after a change. Propagation is glitch-free: a set marks every dependent
-- dirty, recomputes them once in depth order (a diamond a -> b, c -> d recomputes d once, with
-- b and c already current) and only then notifies observers. State.batch(fn) holds all
-- notifications until fn returns. Equal values (==) do not propagate. Computeds must not
-- yield or set state. Observers are bounded (256 per node); an observer that errors is
-- reported (env.report, else warn) and never stops the others. Passing a Stage 0 Scope ties
-- the node's lifetime to it: scope:Clean() destroys the node and its observers.
local State = {}

local MAX_OBSERVERS = 256
local MAX_DEPTH = 64

export type Node = {
	get: (self: Node) -> any,
	observe: (self: Node, fn: (new: any, old: any) -> (), immediate: boolean?) -> () -> (),
	destroy: (self: Node) -> (),
	destroyed: (self: Node) -> boolean,
	-- values only
	set: (self: Node, value: any) -> boolean,
	update: (self: Node, fn: (any) -> any) -> boolean,
}

type Internal = {
	kind: "value" | "computed",
	value: any,
	previous: any,
	depth: number,
	sources: { Internal },
	dependents: { Internal },
	observers: { (any, any) -> () },
	compute: ((...any) -> any)?,
	dead: boolean,
	env: any,
	public: any,
}

local batching = 0
local pendingRoots: { Internal } = {}
-- public table -> internal node (weak keys, so dropped nodes are collected)
local registry: { [any]: Internal } = setmetatable({}, { __mode = "k" }) :: any

local function report(node: Internal, message: string)
	local env = node.env
	if env and type(env.report) == "function" then
		env.report(message)
	else
		warn(message)
	end
end

local function sourceValues(node: Internal): { any }
	local values = table.create(#node.sources)
	for index, source in node.sources do
		values[index] = source.value
	end
	return values
end

-- Recomputes every dependent reachable from roots once (depth order), then notifies observers
-- of every node whose value changed.
local function propagate(roots: { Internal })
	local changed: { Internal } = {}
	local seen: { [Internal]: boolean } = {}
	local queue: { Internal } = {}
	for _, root in roots do
		if not seen[root] then
			seen[root] = true
			table.insert(changed, root)
			for _, dependent in root.dependents do
				table.insert(queue, dependent)
			end
		end
	end
	-- Every node reachable from the roots, recomputed in depth order.
	local reachable: { Internal } = {}
	local index = 1
	while index <= #queue do
		local node = queue[index]
		index += 1
		if not seen[node] and not node.dead then
			seen[node] = true
			table.insert(reachable, node)
			for _, dependent in node.dependents do
				table.insert(queue, dependent)
			end
		end
	end
	table.sort(reachable, function(a: Internal, b: Internal): boolean
		return a.depth < b.depth
	end)
	local dirty: { [Internal]: boolean } = {}
	for _, root in roots do
		dirty[root] = true
	end
	for _, node in reachable do
		local needs = false
		for _, source in node.sources do
			if dirty[source] then
				needs = true
				break
			end
		end
		if needs then
			local ok, result = pcall(node.compute :: any, table.unpack(sourceValues(node)))
			if not ok then
				report(node, "State.computed error: " .. tostring(result))
			elseif result ~= node.value then
				node.previous = node.value
				node.value = result
				dirty[node] = true
				table.insert(changed, node)
			end
		end
	end
	for _, node in changed do
		if node.dead then
			continue
		end
		for _, observer in table.clone(node.observers) do
			local ok, err = pcall(observer, node.value, node.previous)
			if not ok then
				report(node, "State observer error: " .. tostring(err))
			end
		end
	end
end

local function flush()
	while #pendingRoots > 0 do
		local roots = pendingRoots
		pendingRoots = {}
		propagate(roots)
	end
end

local function makePublic(node: Internal, scope: any): Node
	local public: any = {}
	function public.get(_self: any): any
		return node.value
	end
	function public.observe(_self: any, fn: (any, any) -> (), immediate: boolean?): () -> ()
		if node.dead then
			error("State: observe on a destroyed node", 2)
		end
		if type(fn) ~= "function" then
			error("State: observe needs a function", 2)
		end
		if #node.observers >= MAX_OBSERVERS then
			error("State: more than " .. MAX_OBSERVERS .. " observers on one node", 2)
		end
		table.insert(node.observers, fn)
		if immediate then
			fn(node.value, nil)
		end
		local connected = true
		return function()
			if connected then
				connected = false
				local at = table.find(node.observers, fn)
				if at then
					table.remove(node.observers, at)
				end
			end
		end
	end
	function public.destroy(_self: any)
		if node.dead then
			return
		end
		node.dead = true
		table.clear(node.observers)
		for _, source in node.sources do
			local at = table.find(source.dependents, node)
			if at then
				table.remove(source.dependents, at)
			end
		end
		-- Dependents of a destroyed node stop updating; they keep their last value.
	end
	function public.destroyed(_self: any): boolean
		return node.dead
	end
	if node.kind == "value" then
		function public.set(_self: any, value: any): boolean
			if node.dead then
				error("State: set on a destroyed value", 2)
			end
			if value == node.value then
				return false
			end
			node.previous = node.value
			node.value = value
			table.insert(pendingRoots, node)
			if batching == 0 then
				flush()
			end
			return true
		end
		function public.update(self: any, fn: (any) -> any): boolean
			return self:set(fn(node.value))
		end
	end
	node.public = public
	registry[public] = node
	if scope ~= nil then
		scope:Add(function()
			public:destroy()
		end)
	end
	return public :: Node
end

-- A writable value. scope (a GameKit/Scope) destroys it on Clean; env.report receives
-- observer errors.
function State.value(initial: any, scope: any?, env: any?): Node
	local node: Internal = {
		kind = "value",
		value = initial,
		previous = nil,
		depth = 0,
		sources = {},
		dependents = {},
		observers = {},
		compute = nil,
		dead = false,
		env = env,
		public = nil,
	}
	return makePublic(node, scope)
end

local function internalOf(public: any): Internal?
	return registry[public]
end

-- A derived value: fn(...source values) runs now and again whenever a source changes.
function State.computed(sources: { Node }, fn: (...any) -> any, scope: any?, env: any?): Node
	if type(sources) ~= "table" or #sources == 0 then
		error("State.computed: needs a non-empty list of sources", 2)
	end
	if type(fn) ~= "function" then
		error("State.computed: needs a function", 2)
	end
	local internals: { Internal } = {}
	local depth = 0
	for index, source in sources do
		local internal = internalOf(source)
		if internal == nil then
			error("State.computed: source " .. index .. " is not a State node", 2)
		end
		if internal.dead then
			error("State.computed: source " .. index .. " is destroyed", 2)
		end
		table.insert(internals, internal)
		depth = math.max(depth, internal.depth + 1)
	end
	if depth > MAX_DEPTH then
		error("State.computed: dependency chain deeper than " .. MAX_DEPTH, 2)
	end
	local node: Internal = {
		kind = "computed",
		value = nil,
		previous = nil,
		depth = depth,
		sources = internals,
		dependents = {},
		observers = {},
		compute = fn,
		dead = false,
		env = env,
		public = nil,
	}
	node.value = fn(table.unpack(sourceValues(node)))
	for _, internal in internals do
		table.insert(internal.dependents, node)
	end
	return makePublic(node, scope)
end

-- Runs fn with notifications held; observers run once after it returns (even if it raises).
function State.batch(fn: () -> ())
	batching += 1
	local ok, err = pcall(fn)
	batching -= 1
	if batching == 0 then
		flush()
	end
	if not ok then
		error(err, 2)
	end
end

-- True for a node made by State.value or State.computed.
function State.is(value: any): boolean
	return internalOf(value) ~= nil
end

return State
