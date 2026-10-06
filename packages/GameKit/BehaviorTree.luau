--!strict
-- @tier T0
-- BehaviorTree: data-built behaviour trees with a blackboard and a per-tick budget.
--   composites  sequence (all in order), selector (first that does not fail), parallel (every
--               child each tick; policy success = "all" | "one", failure = "one" | "all")
--   decorators  inverter, cooldown (after a success the child is skipped, failing, for `seconds`),
--               timeout (a child still running after `seconds` is halted and fails)
--   leaves      action(name, fn(bb, ctx) -> "success" | "failure" | "running", halt?),
--               condition(name, fn(bb, ctx) -> boolean)
-- Composites keep the running child between ticks (memory semantics): the next tick resumes it
-- instead of re-checking earlier children. The budget caps node visits per tick; a tick that
-- runs out returns "running" (info.budgetExhausted) and the next tick resumes where it stopped,
-- so a large tree spreads over frames instead of spiking one. Time comes from env.clock; ticks
-- never yield, so a runner can live inside a simulation step.
local Check = require("./Check")

local BehaviorTree = {}

export type Status = "success" | "failure" | "running"
export type Node = { [string]: any }
export type Info = { visits: number, budgetExhausted: boolean, trace: { string }? }

local KINDS = {
	sequence = "composite",
	selector = "composite",
	parallel = "composite",
	inverter = "decorator",
	cooldown = "decorator",
	timeout = "decorator",
	action = "leaf",
	condition = "leaf",
}

function BehaviorTree.sequence(children: { Node }, name: string?): Node
	return { kind = "sequence", name = name or "sequence", children = children }
end

function BehaviorTree.selector(children: { Node }, name: string?): Node
	return { kind = "selector", name = name or "selector", children = children }
end

function BehaviorTree.parallel(
	children: { Node },
	policy: { success: string?, failure: string? }?,
	name: string?
): Node
	return {
		kind = "parallel",
		name = name or "parallel",
		children = children,
		success = policy and policy.success or "all",
		failure = policy and policy.failure or "one",
	}
end

function BehaviorTree.inverter(child: Node, name: string?): Node
	return { kind = "inverter", name = name or "inverter", children = { child } }
end

function BehaviorTree.cooldown(child: Node, seconds: number, name: string?): Node
	return { kind = "cooldown", name = name or "cooldown", children = { child }, seconds = seconds }
end

function BehaviorTree.timeout(child: Node, seconds: number, name: string?): Node
	return { kind = "timeout", name = name or "timeout", children = { child }, seconds = seconds }
end

function BehaviorTree.action(name: string, fn: (any, any) -> Status, halt: ((any, any) -> ())?): Node
	return { kind = "action", name = name, fn = fn, halt = halt }
end

function BehaviorTree.condition(name: string, fn: (any, any) -> boolean): Node
	return { kind = "condition", name = name, fn = fn }
end

-- Problems with a tree (empty when valid): unknown kinds, missing functions, empty composites,
-- bad policies or durations, and a node table used twice (each node keeps its own state).
function BehaviorTree.validate(root: any): { string }
	local problems = {}
	local seen = {}
	local function visit(node: any, path: string)
		if type(node) ~= "table" then
			table.insert(problems, path .. ": not a node")
			return
		end
		local here = path .. "/" .. tostring(node.name)
		local family = KINDS[node.kind]
		if family == nil then
			table.insert(problems, here .. ": unknown kind " .. tostring(node.kind))
			return
		end
		if seen[node] then
			table.insert(problems, here .. ": node used twice (build a new one)")
			return
		end
		seen[node] = true
		if type(node.name) ~= "string" or node.name == "" then
			table.insert(problems, here .. ": name must be a non-empty string")
		end
		if family == "leaf" then
			if type(node.fn) ~= "function" then
				table.insert(problems, here .. ": " .. node.kind .. " needs a function")
			end
			return
		end
		if type(node.children) ~= "table" or #node.children == 0 then
			table.insert(problems, here .. ": needs at least one child")
			return
		end
		if family == "decorator" and #node.children ~= 1 then
			table.insert(problems, here .. ": a decorator has exactly one child")
		end
		if node.kind == "cooldown" or node.kind == "timeout" then
			if not Check.finite(node.seconds) or node.seconds <= 0 then
				table.insert(problems, here .. ": seconds must be a finite number > 0")
			end
		end
		if node.kind == "parallel" then
			if node.success ~= "all" and node.success ~= "one" then
				table.insert(problems, here .. ": success policy must be all or one")
			end
			if node.failure ~= "all" and node.failure ~= "one" then
				table.insert(problems, here .. ": failure policy must be all or one")
			end
		end
		for index, child in node.children do
			visit(child, here .. "[" .. index .. "]")
		end
	end
	visit(root, "")
	return problems
end

-- Blackboard: per-agent memory shared by every node of a runner.
export type Blackboard = {
	get: (self: Blackboard, key: string) -> any,
	set: (self: Blackboard, key: string, value: any) -> (),
	has: (self: Blackboard, key: string) -> boolean,
	clear: (self: Blackboard, key: string?) -> (),
	snapshot: (self: Blackboard) -> { [string]: any },
}

function BehaviorTree.blackboard(initial: { [string]: any }?): Blackboard
	local data: { [string]: any } = table.clone(initial or {})
	local bb = {}
	function bb.get(_, key: string): any
		return data[key]
	end
	function bb.set(_, key: string, value: any)
		assert(type(key) == "string", "Blackboard: keys are strings")
		data[key] = value
	end
	function bb.has(_, key: string): boolean
		return data[key] ~= nil
	end
	function bb.clear(_, key: string?)
		if key == nil then
			table.clear(data)
		else
			data[key] = nil
		end
	end
	function bb.snapshot(_): { [string]: any }
		return table.clone(data)
	end
	return bb :: any
end

export type Runner = {
	root: Node,
	blackboard: Blackboard,
	budget: number,
	tick: (self: Runner, ctx: any?) -> (Status, Info),
	reset: (self: Runner, ctx: any?) -> (),
}

-- options: budget (node visits per tick, default 64), blackboard (table or Blackboard),
-- trace (record "name:status" per visit in info.trace).
function BehaviorTree.new(
	root: Node,
	options: { budget: number?, blackboard: any?, trace: boolean? }?,
	env: any?
): Runner
	local problems = BehaviorTree.validate(root)
	local budget = options and options.budget or 64
	if not Check.integer(budget) or budget < 1 then
		table.insert(problems, "budget must be an integer >= 1")
	end
	if #problems > 0 then
		error("BehaviorTree.new: " .. table.concat(problems, "; "), 2)
	end
	local initial = options and options.blackboard
	local bb: Blackboard = if type(initial) == "table" and type(initial.get) == "function"
		then initial
		else BehaviorTree.blackboard(initial)
	local state: { [Node]: { [string]: any } } = {}
	local function stateOf(node: Node): { [string]: any }
		local s = state[node]
		if s == nil then
			s = {}
			state[node] = s
		end
		return s
	end
	local function now(): number
		assert(env and type(env.clock) == "function", "BehaviorTree: cooldown and timeout need env.clock")
		return env.clock()
	end

	-- Halts a subtree: running actions get their halt hook, every state resets (cooldowns keep
	-- their ready time, since a halt is not a success).
	local function halt(node: Node, ctx: any)
		local s = state[node]
		if s and s.running and node.kind == "action" and node.halt then
			node.halt(bb, ctx)
		end
		if s then
			local readyAt = s.readyAt
			table.clear(s)
			s.readyAt = readyAt
		end
		for _, child in node.children or {} do
			halt(child, ctx)
		end
	end

	local visits, exhausted, trace = 0, false, nil :: { string }?
	local evaluate: (Node, any) -> Status

	evaluate = function(node: Node, ctx: any): Status
		if visits >= budget then
			exhausted = true
			return "running"
		end
		visits += 1
		local s = stateOf(node)
		local status: Status
		local kind = node.kind
		if kind == "action" then
			local result = node.fn(bb, ctx)
			if result ~= "success" and result ~= "failure" and result ~= "running" then
				error("BehaviorTree: action " .. node.name .. " returned " .. tostring(result), 0)
			end
			status = result
		elseif kind == "condition" then
			status = if node.fn(bb, ctx) then "success" else "failure"
		elseif kind == "sequence" or kind == "selector" then
			local stopOn: Status = if kind == "sequence" then "failure" else "success"
			local index = s.index or 1
			status = if kind == "sequence" then "success" else "failure"
			while index <= #node.children do
				local result = evaluate(node.children[index], ctx)
				if result == "running" then
					status = "running"
					break
				elseif result == stopOn then
					status = stopOn
					break
				end
				index += 1
			end
			s.index = if status == "running" then index else nil
		elseif kind == "parallel" then
			s.done = s.done or {}
			local successes, failures = 0, 0
			for i, child in node.children do
				local result = s.done[i]
				if result == nil then
					local r = evaluate(child, ctx)
					if r ~= "running" then
						s.done[i] = r
						result = r
					end
				end
				if result == "success" then
					successes += 1
				elseif result == "failure" then
					failures += 1
				end
			end
			local n = #node.children
			local succeeded = if node.success == "all" then successes == n else successes >= 1
			local failed = if node.failure == "one" then failures >= 1 else failures == n
			if succeeded and not failed then
				status = "success"
			elseif failed or successes + failures == n then
				status = "failure" -- the failure policy was met, or every child finished without meeting the success policy
			else
				status = "running"
			end
			if status ~= "running" then
				for _, child in node.children do
					halt(child, ctx)
				end
				s.done = nil
			end
		elseif kind == "inverter" then
			local result = evaluate(node.children[1], ctx)
			status = if result == "success"
				then "failure"
				elseif result == "failure" then "success"
				else "running"
		elseif kind == "cooldown" then
			if s.readyAt and now() < s.readyAt then
				status = "failure"
			else
				status = evaluate(node.children[1], ctx)
				if status == "success" then
					s.readyAt = now() + node.seconds
				end
			end
		else -- timeout
			local result = evaluate(node.children[1], ctx)
			if result == "running" then
				s.startedAt = s.startedAt or now()
				if now() - s.startedAt >= node.seconds then
					halt(node.children[1], ctx)
					s.startedAt = nil
					result = "failure"
				end
			else
				s.startedAt = nil
			end
			status = result
		end
		s.running = status == "running"
		if trace then
			table.insert(trace, node.name .. ":" .. status)
		end
		return status
	end

	local runner: any = { root = root, blackboard = bb, budget = budget }
	function runner.tick(_, ctx: any?): (Status, Info)
		visits, exhausted = 0, false
		trace = if options and options.trace then {} else nil
		local status = evaluate(root, ctx)
		return status, { visits = visits, budgetExhausted = exhausted, trace = trace }
	end
	function runner.reset(_, ctx: any?)
		halt(root, ctx)
		table.clear(state)
	end
	return runner
end

return BehaviorTree
