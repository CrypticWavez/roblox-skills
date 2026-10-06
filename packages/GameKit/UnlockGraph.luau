--!strict
-- @tier T0
-- UnlockGraph: tycoon-style purchase buttons (and skill trees, area gates, research) as a
-- dependency graph of data the game supplies:
--   { id, requires? = { ids }, mode? = "all" | "any", cost? = { [currency] = amount }, data? }
-- validate() refuses unknown requirements, cycles (directed) and nodes that can never unlock
-- from the start nodes (those with no requirements), so every button is reachable. A tracker
-- holds one player's unlocked set: available() lists what can be bought now in a stable
-- topological order, unlock(id, wallet) pays the cost atomically through Wallet (transaction
-- id "unlock:<id>", sku = id, so a retry never charges twice) and emits a kit-event/1
-- progression event. Loading keeps every unlocked id the graph still has (purchases are never
-- taken away, even if requirements changed) and notes the rest. No buttons or costs ship here.
local Check = require("./Check")
local Events = require("./Events")

local UnlockGraph = {}
UnlockGraph.SCHEMA = "unlocks/1"
UnlockGraph.REASON = "unlock" -- wallet transaction type

export type Node = {
	id: string,
	requires: { string },
	mode: "all" | "any",
	cost: { [string]: number },
	data: any?,
}
export type Spec = { nodes: { Node }, byId: { [string]: Node }, order: { string }, roots: { string } }

-- Problems with node definitions (empty when valid).
function UnlockGraph.validate(nodes: any): { string }
	if type(nodes) ~= "table" or #nodes == 0 then
		return { "nodes must be a non-empty list" }
	end
	local problems = {}
	local byId: { [string]: any } = {}
	for index, node in nodes do
		local where = "node "
			.. (
				if type(node) == "table" and type(node.id) == "string"
					then node.id
					else "#" .. tostring(index)
			)
		if type(node) ~= "table" then
			table.insert(problems, where .. ": must be a table")
			continue
		end
		if not Check.label(node.id) then
			table.insert(problems, where .. ": id is not a label")
		elseif byId[node.id] then
			table.insert(problems, where .. ": duplicate id")
		else
			byId[node.id] = node
		end
		if node.requires ~= nil and type(node.requires) ~= "table" then
			table.insert(problems, where .. ": requires must be a list of ids")
		end
		if node.mode ~= nil and node.mode ~= "all" and node.mode ~= "any" then
			table.insert(problems, where .. ": mode must be all or any")
		end
		if node.cost ~= nil then
			if type(node.cost) ~= "table" then
				table.insert(problems, where .. ": cost must map currency -> amount")
			else
				for currency, amount in node.cost do
					if not Check.label(currency) or not (Check.integer(amount) and amount >= 1) then
						table.insert(
							problems,
							where .. ": cost " .. Check.describe(currency) .. " needs an integer amount >= 1"
						)
					end
				end
			end
		end
		for key in node do
			if not table.find({ "id", "requires", "mode", "cost", "data" }, key) then
				table.insert(problems, where .. ": unknown key " .. Check.describe(key))
			end
		end
	end
	if #problems > 0 then
		return problems
	end
	local roots = 0
	for _, node in nodes do
		local requires = node.requires or {}
		if #requires == 0 then
			roots += 1
		end
		for _, need in requires do
			if byId[need] == nil then
				table.insert(
					problems,
					string.format("node %s: requires unknown node %s", node.id, Check.describe(need))
				)
			elseif need == node.id then
				table.insert(problems, string.format("node %s: requires itself", node.id))
			end
		end
	end
	if roots == 0 then
		table.insert(problems, "no start node (a node with no requirements)")
	end
	if #problems > 0 then
		return problems
	end
	-- Directed cycles (DFS with colours).
	local color: { [string]: number } = {}
	local reported: { [string]: boolean } = {}
	local function visit(id: string, trail: { string })
		color[id] = 1
		table.insert(trail, id)
		for _, need in byId[id].requires or {} do
			if color[need] == 1 then
				local from = table.find(trail, need) :: number
				local cycle = {}
				for i = from, #trail do
					table.insert(cycle, trail[i])
				end
				table.insert(cycle, need)
				local text = table.concat(cycle, " -> ")
				if not reported[need] then
					reported[need] = true
					table.insert(problems, "requires cycle: " .. text)
				end
			elseif color[need] == nil then
				visit(need, trail)
			end
		end
		table.remove(trail)
		color[id] = 2
	end
	for _, node in nodes do
		if color[node.id] == nil then
			visit(node.id, {})
		end
	end
	-- Fixpoint from the start nodes: anything never unlockable is unreachable.
	local open: { [string]: boolean } = {}
	local changed = true
	while changed do
		changed = false
		for _, node in nodes do
			if not open[node.id] then
				local requires = node.requires or {}
				local ok
				if #requires == 0 then
					ok = true
				elseif node.mode == "any" then
					ok = false
					for _, need in requires do
						ok = ok or open[need] == true
					end
				else
					ok = true
					for _, need in requires do
						ok = ok and open[need] == true
					end
				end
				if ok then
					open[node.id] = true
					changed = true
				end
			end
		end
	end
	for _, node in nodes do
		if not open[node.id] then
			table.insert(problems, "node " .. node.id .. " can never unlock from the start nodes")
		end
	end
	return problems
end

-- A validated, frozen spec with a stable topological order. Raises with every problem listed.
function UnlockGraph.define(nodes: { any }): Spec
	local problems = UnlockGraph.validate(nodes)
	if #problems > 0 then
		error("UnlockGraph.define: " .. table.concat(problems, "; "), 2)
	end
	local list, byId, roots = {}, {}, {}
	for _, raw in nodes do
		local node: Node = {
			id = raw.id,
			requires = if raw.requires then table.clone(raw.requires) else {},
			mode = raw.mode or "all",
			cost = if raw.cost then table.clone(raw.cost) else {},
			data = Check.copy(raw.data),
		}
		table.insert(list, node)
		byId[node.id] = node
		if #node.requires == 0 then
			table.insert(roots, node.id)
		end
	end
	-- Kahn's algorithm, always taking the earliest-declared ready node, so the order only
	-- depends on the requirements and the declaration order (O(n^2): fine for button graphs).
	local indegree: { [string]: number } = {}
	local dependents: { [string]: { string } } = {}
	for _, node in list do
		indegree[node.id] = #node.requires
		for _, need in node.requires do
			dependents[need] = dependents[need] or {}
			table.insert(dependents[need], node.id)
		end
	end
	local order = {}
	local placed: { [string]: boolean } = {}
	while #order < #list do
		for _, node in list do
			if not placed[node.id] and indegree[node.id] == 0 then
				placed[node.id] = true
				table.insert(order, node.id)
				for _, child in dependents[node.id] or {} do
					indegree[child] -= 1
				end
				break
			end
		end
	end
	return Check.freeze({ nodes = list, byId = byId, order = order, roots = roots })
end

local Tracker = {}
Tracker.__index = Tracker
type TrackerFields = {
	notes: { string },
	_spec: Spec,
	_unlocked: { [string]: boolean },
	_sink: Events.Sink?,
	_player: string?,
	_path: string,
}
export type Tracker = typeof(setmetatable({} :: TrackerFields, Tracker))
export type Options = { data: any?, sink: Events.Sink?, player: string?, path: string? }

-- One player's unlock state over spec.
function UnlockGraph.new(spec: Spec, options: Options?, _env: any?): Tracker
	assert(
		type(spec) == "table" and table.isfrozen(spec) and spec.byId,
		"UnlockGraph.new needs a spec from define"
	)
	local opts: Options = options or {}
	assert(opts.path == nil or Check.label(opts.path), "UnlockGraph: path must be a label")
	local self = setmetatable({
		notes = {},
		_spec = spec,
		_unlocked = {},
		_sink = opts.sink,
		_player = opts.player,
		_path = opts.path or "unlocks",
	}, Tracker)
	local data = opts.data
	if data ~= nil then
		if type(data) ~= "table" or data.schema ~= UnlockGraph.SCHEMA or type(data.unlocked) ~= "table" then
			table.insert(self.notes, "stored data is not unlocks/1; starting with nothing unlocked")
		else
			for _, id in data.unlocked do
				if spec.byId[id] then
					self._unlocked[id] = true
				else
					table.insert(
						self.notes,
						"unlocked id " .. Check.describe(id) .. " is no longer in the graph"
					)
				end
			end
			for _, id in spec.order do
				if self._unlocked[id] and not self:requirementsMet(id) then
					table.insert(self.notes, "kept " .. id .. " although its requirements changed")
				end
			end
		end
	end
	return self
end

function Tracker.isUnlocked(self: Tracker, id: string): boolean
	return self._unlocked[id] == true
end

-- Whether id's requirements are met now (all, or any for mode any).
function Tracker.requirementsMet(self: Tracker, id: string): boolean
	local node = self._spec.byId[id]
	if node == nil then
		return false
	end
	if #node.requires == 0 then
		return true
	end
	if node.mode == "any" then
		for _, need in node.requires do
			if self._unlocked[need] then
				return true
			end
		end
		return false
	end
	for _, need in node.requires do
		if not self._unlocked[need] then
			return false
		end
	end
	return true
end

-- Ids purchasable now (requirements met, not unlocked), in topological order.
function Tracker.available(self: Tracker): { string }
	local out = {}
	for _, id in self._spec.order do
		if not self._unlocked[id] and self:requirementsMet(id) then
			table.insert(out, id)
		end
	end
	return out
end

local function costChanges(node: Node): { any }
	local currencies = {}
	for currency in node.cost do
		table.insert(currencies, currency)
	end
	table.sort(currencies)
	local changes = {}
	for _, currency in currencies do
		table.insert(
			changes,
			{ currency = currency, delta = -node.cost[currency], reason = UnlockGraph.REASON, sku = node.id }
		)
	end
	return changes
end

-- (ok, reason) for unlock(id, wallet) now: unknown, already_unlocked, locked, no_wallet or a
-- Wallet error such as insufficient_funds.
function Tracker.canUnlock(self: Tracker, id: string, wallet: any?): (boolean, string?)
	local node = self._spec.byId[id]
	if node == nil then
		return false, "unknown"
	end
	if self._unlocked[id] then
		return false, "already_unlocked"
	end
	if not self:requirementsMet(id) then
		return false, "locked"
	end
	local changes = costChanges(node)
	if #changes == 0 then
		return true, nil
	end
	if wallet == nil then
		return false, "no_wallet"
	end
	local ok, err = wallet:canTransact(changes, { txId = "unlock:" .. id })
	if not ok and err == "duplicate" then
		return true, nil -- already paid; unlock() completes without charging again
	end
	return ok, err
end

-- Unlocks id, paying its cost through wallet in one transaction. (true, nil, data) or
-- (false, reason) as canUnlock. A wallet that already saw "unlock:<id>" (a retried request
-- after a crash between the wallet write and this tracker's save) unlocks without paying again.
function Tracker.unlock(self: Tracker, id: string, wallet: any?): (boolean, string?, any)
	local node = self._spec.byId[id]
	if node == nil then
		return false, "unknown", nil
	end
	if self._unlocked[id] then
		return false, "already_unlocked", nil
	end
	if not self:requirementsMet(id) then
		return false, "locked", nil
	end
	local changes = costChanges(node)
	if #changes > 0 then
		if wallet == nil then
			return false, "no_wallet", nil
		end
		local ok, err = wallet:transact(changes, { txId = "unlock:" .. id })
		if not ok then
			return false, err, nil
		end
	end
	self._unlocked[id] = true
	local sink = self._sink
	if sink then
		local count = 0
		for _ in self._unlocked do
			count += 1
		end
		local event = Events.progression(
			"unlock",
			{ path = self._path, status = "complete", level = count },
			{ node = id }
		)
		if self._player then
			event.player = self._player
		end
		pcall(function()
			(sink :: any):emit(event)
		end)
	end
	return true, nil, Check.copy(node.data)
end

-- Unlocks without paying (rewards, migrations); requirements still apply unless force.
function Tracker.grant(self: Tracker, id: string, force: boolean?): (boolean, string?)
	if self._spec.byId[id] == nil then
		return false, "unknown"
	end
	if self._unlocked[id] then
		return false, "already_unlocked"
	end
	if not force and not self:requirementsMet(id) then
		return false, "locked"
	end
	self._unlocked[id] = true
	return true, nil
end

-- Unlocked ids in topological order.
function Tracker.unlocked(self: Tracker): { string }
	local out = {}
	for _, id in self._spec.order do
		if self._unlocked[id] then
			table.insert(out, id)
		end
	end
	return out
end

function Tracker.progress(self: Tracker): any
	return { unlocked = #self:unlocked(), total = #self._spec.order }
end

function Tracker.serialize(self: Tracker): any
	return { schema = UnlockGraph.SCHEMA, unlocked = self:unlocked() }
end

return UnlockGraph
