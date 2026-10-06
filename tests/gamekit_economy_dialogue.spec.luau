--!strict
-- GameKit/Dialogue: dialogue/1 validation (unreachable nodes, islands, exits, orphan choices,
-- trap loops, handler kinds), sessions with conditions and effects, and resume.
local Dialogue = require("../packages/GameKit/Dialogue")
local FakeEnv = require("./fakes/FakeEnv")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function graph(): any
	return {
		schema = "dialogue/1",
		id = "npc_a",
		start = "greet",
		nodes = {
			greet = {
				speaker = "npc_a",
				textKey = "dialogue.npc_a.greet",
				effects = { { kind = "set_flag", flag = "met_npc_a" } },
				choices = {
					{ id = "ask", textKey = "dialogue.npc_a.ask", to = "info" },
					{
						id = "trade",
						textKey = "dialogue.npc_a.trade",
						to = "trade_offer",
						conditions = { { kind = "has_item", item = "token_a", count = 1 } },
					},
					{ id = "bye", textKey = "dialogue.npc_a.bye", ["end"] = true },
				},
			},
			info = { textKey = "dialogue.npc_a.info", next = "info_more" },
			info_more = { textKey = "dialogue.npc_a.info_more", next = "greet" },
			trade_offer = {
				textKey = "dialogue.npc_a.trade_offer",
				choices = {
					{
						id = "accept",
						textKey = "dialogue.npc_a.accept",
						to = "farewell",
						effects = { { kind = "give_item", item = "reward_a" } },
					},
					{ id = "back", textKey = "dialogue.npc_a.back", to = "greet" },
				},
			},
			farewell = { textKey = "dialogue.npc_a.farewell", ["end"] = true },
		},
	}
end

local KINDS = { conditions = { "has_item" }, effects = { "set_flag", "give_item" } }

test("a well-formed graph validates, with handler kinds", function(t)
	t.eq(Dialogue.validate(graph(), KINDS), {})
	t.eq(Dialogue.lint(Dialogue.define(graph())), {})
end)

test("an unreachable node is rejected", function(t)
	local g = graph()
	g.nodes.orphan = { textKey = "dialogue.npc_a.orphan", next = "greet" }
	local problems = Dialogue.validate(g)
	t.ok(contains(problems, "node orphan is unreachable from greet"), table.concat(problems, " | "))
	t.throws(function()
		Dialogue.define(g)
	end)
end)

test("islands, missing exits, orphan choices and trap loops are rejected", function(t)
	local island = graph()
	island.nodes.island_a = { textKey = "dialogue.x.a", next = "island_b" }
	island.nodes.island_b = { textKey = "dialogue.x.b", ["end"] = true }
	t.ok(contains(Dialogue.validate(island), "nodes island_a, island_b form an island cut off from start"))
	local noExit = graph()
	noExit.nodes.info.next = nil
	t.ok(contains(Dialogue.validate(noExit), "node info: a non-end node needs choices or next (no exit)"))
	local orphanChoice = graph()
	orphanChoice.nodes.greet.choices[1].to = "nowhere"
	t.ok(contains(Dialogue.validate(orphanChoice), 'choice ask: to "nowhere" is not a node (orphan choice)'))
	local trap = graph()
	trap.nodes.greet.choices[1].to = "loop_a"
	trap.nodes.loop_a = { textKey = "dialogue.x.loop_a", next = "loop_b" }
	trap.nodes.loop_b = { textKey = "dialogue.x.loop_b", next = "loop_a" }
	local problems = Dialogue.validate(trap)
	t.ok(contains(problems, "node loop_a cannot reach an end (trap loop)"), table.concat(problems, " | "))
	t.ok(contains(problems, "node info is unreachable"))
end)

test("shape problems are listed together", function(t)
	t.ok(contains(Dialogue.validate(nil), "graph must be a table"))
	t.ok(
		contains(
			Dialogue.validate({ schema = "dialogue/1", id = "a", start = "x", nodes = {} }),
			"non-empty map"
		)
	)
	local g = graph()
	g.schema = "dialogue/2"
	g.id = "Bad"
	g.nodes.greet.textKey = "Hello there!"
	g.nodes.greet.choices[2].id = "ask"
	g.nodes.greet.choices[3]["end"] = nil
	g.nodes.info.choices = { { id = "x", textKey = "dialogue.a.b", ["end"] = true } }
	g.nodes.farewell.next = "greet"
	g.nodes.trade_offer.choices[1].effects = { { kind = "give_item", item = {} } }
	g.nodes.trade_offer.mood = "happy"
	local problems = Dialogue.validate(g, KINDS)
	for _, needle in
		{
			"schema must be dialogue/1",
			"id must be a label",
			"node greet: textKey must be a dotted localisation key",
			"choice ask: duplicate choice id",
			"choice bye: needs exactly one of to or end = true",
			"node info: use choices or next, not both",
			"node farewell: an end node has no choices or next",
			"effects[1].item must be a string, number or boolean",
			'node trade_offer: unknown key "mood"',
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	local unknownKind = graph()
	unknownKind.nodes.greet.effects[1].kind = "set_flagg"
	t.ok(contains(Dialogue.validate(unknownKind, KINDS), "effects kind set_flagg has no handler"))
	local badStart = graph()
	badStart.start = "nope"
	t.ok(contains(Dialogue.validate(badStart), 'start "nope" is not a node'))
end)

test("sessions run effects, hide failing choices and end", function(t)
	local spec = Dialogue.define(graph(), KINDS)
	local flags, given = {}, {}
	local handlers = {
		conditions = {
			has_item = function(params: any, ctx: any): boolean
				return (ctx.items[params.item] or 0) >= params.count
			end,
		},
		effects = {
			set_flag = function(params: any)
				flags[params.flag] = true
			end,
			give_item = function(params: any)
				table.insert(given, params.item)
			end,
		},
	}
	local session = Dialogue.session(spec, handlers)
	t.eq({ session:choose("ask", {}) }, { false, "not_started", nil })
	local ctx = { items = {} }
	local view = session:start(ctx)
	t.ok(flags.met_npc_a, "start node effects ran")
	t.eq(view.speaker, "npc_a")
	t.eq(#view.choices, 2, "trade hidden without token_a")
	t.eq({ session:choose("trade", ctx) }, { false, "hidden_choice", nil })
	t.eq({ session:choose("zzz", ctx) }, { false, "unknown_choice", nil })
	local _, _, info = session:choose("ask", ctx)
	t.ok(assert(info).canAdvance)
	t.eq({ session:advance(ctx) }, { true, nil, session:view(ctx) })
	session:advance(ctx)
	t.eq(session:view(ctx).node, "greet")
	t.eq({ session:advance(ctx) }, { false, "has_choices", nil })
	ctx.items.token_a = 1
	t.eq(#session:view(ctx).choices, 3)
	session:choose("trade", ctx)
	local _, _, final = session:choose("accept", ctx)
	t.ok(assert(final).ended)
	t.eq(given, { "reward_a" })
	t.eq({ session:choose("accept", ctx) }, { false, "ended", nil })
	local quick = Dialogue.session(spec, handlers)
	quick:start(ctx)
	local _, _, bye = quick:choose("bye", ctx)
	t.ok(assert(bye).ended and quick:ended())
end)

test("missing or failing handlers are reported and fail closed", function(t)
	local env = FakeEnv.new()
	local spec = Dialogue.define(graph())
	local session = Dialogue.session(spec, {
		conditions = {
			has_item = function(): boolean
				error("inventory offline")
			end,
		},
	}, env)
	local view = session:start({})
	t.eq(#view.choices, 2, "a raising condition hides the choice")
	t.ok(contains(env.reports, "condition has_item raised"))
	t.ok(contains(env.reports, "no effect handler for set_flag"))
	local stuckGraph = graph()
	stuckGraph.nodes.trade_offer.choices[2].conditions = { { kind = "has_item", item = "x", count = 1 } }
	stuckGraph.nodes.trade_offer.choices[1].conditions = { { kind = "has_item", item = "y", count = 1 } }
	local stuckSpec = Dialogue.define(stuckGraph)
	t.ok(contains(Dialogue.lint(stuckSpec), "node trade_offer: every choice has conditions"))
	local stuck = Dialogue.session(stuckSpec, {
		conditions = {
			has_item = function(params: any): boolean
				return params.item == "token_a"
			end,
		},
	})
	stuck:start({})
	stuck:choose("trade", {})
	t.ok(stuck:view({}).stuck, "the view reports a stuck node")
end)

test("a session resumes at its node without re-running effects", function(t)
	local spec = Dialogue.define(graph())
	local runs = 0
	local handlers = {
		effects = {
			set_flag = function()
				runs += 1
			end,
		},
	}
	local session = Dialogue.session(spec, handlers)
	session:start({})
	session:choose("ask", {})
	local data = session:serialize()
	t.eq(data, { schema = "dialogue-session/1", graph = "npc_a", node = "info", ended = false })
	local resumed = assert(Dialogue.resume(spec, data, handlers))
	t.eq(resumed:view({}).node, "info")
	t.eq(runs, 1)
	t.eq({ Dialogue.resume(spec, { schema = "x" }) }, { nil, "bad_format" })
	t.eq(
		{ Dialogue.resume(spec, { schema = "dialogue-session/1", graph = "other" }) },
		{ nil, "wrong_graph" }
	)
	t.eq(
		{ Dialogue.resume(spec, { schema = "dialogue-session/1", graph = "npc_a", node = "gone" }) },
		{ nil, "unknown_node" }
	)
	t.throws(function()
		Dialogue.session(graph())
	end)
end)

return cases
