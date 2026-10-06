--!strict
-- @tier T0
-- Dialogue: dialogue/1 conversation graphs as data, validated, then run as sessions.
--   { schema = "dialogue/1", id, start, nodes = { [nodeId] = Node } }
--   Node   = { speaker?, textKey, choices? = { Choice }, next?, ["end"]?, effects? }
--   Choice = { id, textKey, to? , ["end"]?, conditions?, effects? }
--   Condition / Effect = { kind = label, ...label params (string, number, boolean) }
-- Text is never stored: textKey and speaker are localisation keys. Conditions and effects are
-- resolved by handlers the game passes in ({ conditions = { [kind] = fn(params, ctx) -> bool },
-- effects = { [kind] = fn(params, ctx) } }), so Dialogue never touches wallets, flags or quests.
-- validate() builds the graph with ProcGen/Graph and checks: start exists; every node is
-- reachable from start (directed) and none sits on a disconnected island; every non-end node
-- has an exit (choices or next); every choice id is unique in its node and points at an existing
-- node or ends the conversation (no orphan choice ids); every reachable node can still reach an
-- end (no trap loops); condition and effect kinds exist when kinds are given.
local Check = require("./Check")
local Graph = require("../ProcGen/Graph")

local Dialogue = {}
Dialogue.SCHEMA = "dialogue/1"
Dialogue.SESSION_SCHEMA = "dialogue-session/1"
Dialogue.KEY_PATTERN = "^[a-z][a-z0-9_]*%.[a-z0-9_%.]*[a-z0-9_]$"

export type Rule = { kind: string, [string]: any }
export type Choice = {
	id: string,
	textKey: string,
	to: string?,
	["end"]: boolean?,
	conditions: { Rule }?,
	effects: { Rule }?,
}
export type Node = {
	speaker: string?,
	textKey: string,
	choices: { Choice }?,
	next: string?,
	["end"]: boolean?,
	effects: { Rule }?,
}
export type Spec = { schema: string, id: string, start: string, nodes: { [string]: Node } }
export type Kinds = { conditions: { string }?, effects: { string }? }

local function key(value: any): boolean
	return type(value) == "string" and #value <= 128 and string.match(value, Dialogue.KEY_PATTERN) ~= nil
end

local function sortedKeys(map: { [string]: any }): { string }
	local out = {}
	for k in map do
		if type(k) == "string" then
			table.insert(out, k)
		end
	end
	table.sort(out)
	return out
end

local function rules(list: any, what: string, where: string, known: { string }?, problems: { string })
	if list == nil then
		return
	end
	if type(list) ~= "table" then
		table.insert(problems, string.format("%s: %s must be a list", where, what))
		return
	end
	for index, rule in list do
		if type(rule) ~= "table" or not Check.label(rule.kind) then
			table.insert(
				problems,
				string.format("%s: %s[%s] needs a kind label", where, what, tostring(index))
			)
			continue
		end
		if known and not table.find(known, rule.kind) then
			table.insert(problems, string.format("%s: %s kind %s has no handler", where, what, rule.kind))
		end
		for name, value in rule do
			local kind = type(value)
			if
				not Check.label(name)
				or not (kind == "string" or kind == "boolean" or (kind == "number" and Check.finite(value)))
			then
				table.insert(
					problems,
					string.format(
						"%s: %s[%s].%s must be a string, number or boolean",
						where,
						what,
						tostring(index),
						tostring(name)
					)
				)
			end
		end
	end
end

-- Problems with a dialogue/1 graph (empty when valid). kinds lists the condition and effect
-- kinds the game handles, so a typo fails here instead of in play.
function Dialogue.validate(graph: any, kinds: Kinds?): { string }
	if type(graph) ~= "table" then
		return { "graph must be a table" }
	end
	local problems = {}
	if graph.schema ~= Dialogue.SCHEMA then
		table.insert(problems, "schema must be dialogue/1")
	end
	if not Check.label(graph.id) then
		table.insert(problems, "id must be a label")
	end
	local nodes = graph.nodes
	if type(nodes) ~= "table" or next(nodes) == nil then
		table.insert(problems, "nodes must be a non-empty map of id -> node")
		return problems
	end
	if type(graph.start) ~= "string" or nodes[graph.start] == nil then
		table.insert(problems, "start " .. Check.describe(graph.start) .. " is not a node")
	end
	local ids = sortedKeys(nodes)
	local graphView = Graph.new()
	local edges: { [string]: { string } } = {}
	local ends: { [string]: boolean } = {}
	for nodeId, _ in nodes do
		if not Check.label(nodeId) then
			table.insert(problems, "node id " .. Check.describe(nodeId) .. " is not a label")
		end
	end
	for _, id in ids do
		graphView:addNode(id)
		edges[id] = {}
	end
	for _, id in ids do
		local node = nodes[id]
		local where = "node " .. id
		if type(node) ~= "table" then
			table.insert(problems, where .. ": must be a table")
			continue
		end
		if not key(node.textKey) then
			table.insert(
				problems,
				where .. ": textKey must be a dotted localisation key (e.g. dialogue.npc_a.greeting)"
			)
		end
		if node.speaker ~= nil and not (Check.label(node.speaker) or key(node.speaker)) then
			table.insert(problems, where .. ": speaker must be a label or localisation key")
		end
		rules(node.effects, "effects", where, kinds and kinds.effects, problems)
		local isEnd = node["end"] == true
		local hasChoices = type(node.choices) == "table" and #node.choices > 0
		local hasNext = node.next ~= nil
		if isEnd then
			ends[id] = true
			if hasChoices or hasNext then
				table.insert(problems, where .. ": an end node has no choices or next")
			end
		elseif not hasChoices and not hasNext then
			table.insert(problems, where .. ": a non-end node needs choices or next (no exit)")
		elseif hasChoices and hasNext then
			table.insert(problems, where .. ": use choices or next, not both")
		end
		if hasNext then
			if type(node.next) ~= "string" or nodes[node.next] == nil then
				table.insert(problems, where .. ": next " .. Check.describe(node.next) .. " is not a node")
			else
				table.insert(edges[id], node.next)
			end
		end
		if node.choices ~= nil and type(node.choices) ~= "table" then
			table.insert(problems, where .. ": choices must be a list")
		elseif hasChoices then
			local seen = {}
			for index, choice in node.choices do
				local at = string.format(
					"%s choice %s",
					where,
					if type(choice) == "table" and type(choice.id) == "string"
						then choice.id
						else "#" .. index
				)
				if type(choice) ~= "table" then
					table.insert(problems, at .. ": must be a table")
					continue
				end
				if not Check.label(choice.id) then
					table.insert(problems, at .. ": id is not a label")
				elseif seen[choice.id] then
					table.insert(problems, at .. ": duplicate choice id")
				end
				seen[choice.id] = true
				if not key(choice.textKey) then
					table.insert(problems, at .. ": textKey must be a dotted localisation key")
				end
				local endsHere = choice["end"] == true
				if endsHere == (choice.to ~= nil) then
					table.insert(problems, at .. ": needs exactly one of to or end = true")
				elseif choice.to ~= nil then
					if type(choice.to) ~= "string" or nodes[choice.to] == nil then
						table.insert(
							problems,
							at .. ": to " .. Check.describe(choice.to) .. " is not a node (orphan choice)"
						)
					else
						table.insert(edges[id], choice.to)
					end
				else
					ends[id] = true
				end
				rules(choice.conditions, "conditions", at, kinds and kinds.conditions, problems)
				rules(choice.effects, "effects", at, kinds and kinds.effects, problems)
			end
		end
		for name in node do
			if not table.find({ "speaker", "textKey", "choices", "next", "end", "effects" }, name) then
				table.insert(problems, where .. ": unknown key " .. Check.describe(name))
			end
		end
	end
	if #problems > 0 or nodes[graph.start] == nil then
		return problems
	end
	-- Undirected islands (ProcGen/Graph), then directed reachability from start.
	for _, id in ids do
		for _, target in edges[id] do
			if target ~= id then
				graphView:addEdge(id, target)
			end
		end
	end
	local components = graphView:components()
	if #components > 1 then
		for _, component in components do
			if not table.find(component, graph.start) then
				table.insert(
					problems,
					"nodes " .. table.concat(component, ", ") .. " form an island cut off from start"
				)
			end
		end
	end
	local reached: { [string]: boolean } = { [graph.start] = true }
	local queue = { graph.start }
	while #queue > 0 do
		local id = table.remove(queue, 1) :: string
		for _, target in edges[id] do
			if not reached[target] then
				reached[target] = true
				table.insert(queue, target)
			end
		end
	end
	for _, id in ids do
		if not reached[id] then
			table.insert(problems, "node " .. id .. " is unreachable from " .. graph.start)
		end
	end
	-- Every reachable node must still be able to reach an end.
	local reverse: { [string]: { string } } = {}
	for _, id in ids do
		reverse[id] = {}
	end
	for _, id in ids do
		for _, target in edges[id] do
			table.insert(reverse[target], id)
		end
	end
	local canEnd: { [string]: boolean } = {}
	local back = {}
	for _, id in ids do
		if ends[id] then
			canEnd[id] = true
			table.insert(back, id)
		end
	end
	while #back > 0 do
		local id = table.remove(back, 1) :: string
		for _, source in reverse[id] do
			if not canEnd[source] then
				canEnd[source] = true
				table.insert(back, source)
			end
		end
	end
	for _, id in ids do
		if reached[id] and not canEnd[id] then
			table.insert(problems, "node " .. id .. " cannot reach an end (trap loop)")
		end
	end
	return problems
end

-- Design warnings (not errors): nodes where every choice is conditional, so a player whose
-- conditions all fail would see no way on.
function Dialogue.lint(graph: Spec): { string }
	local warnings = {}
	for _, id in sortedKeys(graph.nodes) do
		local node = graph.nodes[id]
		if node.choices and #node.choices > 0 then
			local open = false
			for _, choice in node.choices do
				if choice.conditions == nil or #choice.conditions == 0 then
					open = true
				end
			end
			if not open then
				table.insert(
					warnings,
					"node " .. id .. ": every choice has conditions; add an unconditional exit"
				)
			end
		end
	end
	return warnings
end

-- A validated, frozen copy of a graph. Raises with every problem listed.
function Dialogue.define(graph: any, kinds: Kinds?): Spec
	local problems = Dialogue.validate(graph, kinds)
	if #problems > 0 then
		error("Dialogue.define: " .. table.concat(problems, "; "), 2)
	end
	return Check.freeze(Check.copy(graph))
end

export type Handlers = {
	conditions: { [string]: (params: Rule, ctx: any) -> boolean }?,
	effects: { [string]: (params: Rule, ctx: any) -> () }?,
	report: ((message: string) -> ())?,
}
export type View = {
	node: string?,
	speaker: string?,
	textKey: string?,
	choices: { { id: string, textKey: string } },
	canAdvance: boolean,
	ended: boolean,
	stuck: boolean,
}

local Session = {}
Session.__index = Session
type SessionFields = {
	spec: Spec,
	_handlers: Handlers,
	_node: string?,
	_ended: boolean,
	_report: (string) -> (),
}
export type Session = typeof(setmetatable({} :: SessionFields, Session))

-- A conversation over spec. Nothing runs until start(ctx).
function Dialogue.session(spec: Spec, handlers: Handlers?, env: any?): Session
	assert(
		type(spec) == "table" and table.isfrozen(spec) and spec.schema == Dialogue.SCHEMA,
		"Dialogue.session needs a spec from Dialogue.define"
	)
	local h: Handlers = handlers or {}
	return setmetatable({
		spec = spec,
		_handlers = h,
		_node = nil,
		_ended = false,
		_report = h.report
			or (env and type(env.report) == "function" and env.report)
			or function(_message: string) end,
	}, Session)
end

local function check(self: Session, conditions: { Rule }?, ctx: any): boolean
	local rules: { Rule } = conditions or {}
	for _, rule in rules do
		local fn = self._handlers.conditions and self._handlers.conditions[rule.kind]
		if fn == nil then
			self._report("Dialogue: no condition handler for " .. rule.kind .. " (treated as false)")
			return false
		end
		local ok, result = pcall(fn, rule, ctx)
		if not ok then
			self._report("Dialogue: condition " .. rule.kind .. " raised: " .. tostring(result))
			return false
		end
		if result ~= true then
			return false
		end
	end
	return true
end

local function run(self: Session, effects: { Rule }?, ctx: any)
	local rules: { Rule } = effects or {}
	for _, rule in rules do
		local fn = self._handlers.effects and self._handlers.effects[rule.kind]
		if fn == nil then
			self._report("Dialogue: no effect handler for " .. rule.kind)
		else
			local ok: boolean, err: any = pcall(fn, rule, ctx)
			if not ok then
				self._report("Dialogue: effect " .. rule.kind .. " raised: " .. tostring(err))
			end
		end
	end
end

local function enter(self: Session, id: string, ctx: any)
	self._node = id
	local node = self.spec.nodes[id]
	run(self, node.effects, ctx)
	if node["end"] then
		self._ended = true
	end
end

-- The current node as the UI shows it: visible choices only (conditions pass).
function Session.view(self: Session, ctx: any?): View
	local id = self._node
	if id == nil then
		return { choices = {}, canAdvance = false, ended = self._ended, stuck = false }
	end
	local node = self.spec.nodes[id]
	local choices = {}
	local nodeChoices: { Choice } = node.choices or {}
	for _, choice in nodeChoices do
		if check(self, choice.conditions, ctx) then
			table.insert(choices, { id = choice.id, textKey = choice.textKey })
		end
	end
	local canAdvance = node.next ~= nil and not self._ended
	return {
		node = id,
		speaker = node.speaker,
		textKey = node.textKey,
		choices = if self._ended then {} else choices,
		canAdvance = canAdvance,
		ended = self._ended,
		stuck = not self._ended and not canAdvance and #choices == 0,
	}
end

-- Enters the start node (running its effects) and returns the view.
function Session.start(self: Session, ctx: any?): View
	self._ended = false
	enter(self, self.spec.start, ctx)
	return self:view(ctx)
end

-- Picks a visible choice. (true, nil, view) or (false, reason) with not_started, ended,
-- unknown_choice or hidden_choice (its conditions fail now).
function Session.choose(self: Session, choiceId: string, ctx: any?): (boolean, string?, View?)
	if self._node == nil then
		return false, "not_started", nil
	end
	if self._ended then
		return false, "ended", nil
	end
	local node = self.spec.nodes[self._node :: string]
	local picked: Choice? = nil
	local nodeChoices: { Choice } = node.choices or {}
	for _, choice in nodeChoices do
		if choice.id == choiceId then
			picked = choice
		end
	end
	if picked == nil then
		return false, "unknown_choice", nil
	end
	if not check(self, picked.conditions, ctx) then
		return false, "hidden_choice", nil
	end
	run(self, picked.effects, ctx)
	if picked["end"] then
		self._ended = true
	else
		enter(self, picked.to :: string, ctx)
	end
	return true, nil, self:view(ctx)
end

-- Follows next on a node without choices. (true, nil, view) or (false, reason).
function Session.advance(self: Session, ctx: any?): (boolean, string?, View?)
	if self._node == nil then
		return false, "not_started", nil
	end
	if self._ended then
		return false, "ended", nil
	end
	local node = self.spec.nodes[self._node :: string]
	if node.next == nil then
		return false, "has_choices", nil
	end
	enter(self, node.next, ctx)
	return true, nil, self:view(ctx)
end

function Session.ended(self: Session): boolean
	return self._ended
end

-- dialogue-session/1 data to resume after a rejoin (node effects do not run again).
function Session.serialize(self: Session): any
	return { schema = Dialogue.SESSION_SCHEMA, graph = self.spec.id, node = self._node, ended = self._ended }
end

-- A session resumed from serialize() output, or nil and a reason (bad_format, wrong_graph,
-- unknown_node) when the graph changed under it.
function Dialogue.resume(spec: Spec, data: any, handlers: Handlers?, env: any?): (Session?, string?)
	if type(data) ~= "table" or data.schema ~= Dialogue.SESSION_SCHEMA then
		return nil, "bad_format"
	end
	if data.graph ~= spec.id then
		return nil, "wrong_graph"
	end
	if data.node ~= nil and spec.nodes[data.node] == nil then
		return nil, "unknown_node"
	end
	local session = Dialogue.session(spec, handlers, env)
	session._node = data.node
	session._ended = data.ended == true
	return session, nil
end

return Dialogue
