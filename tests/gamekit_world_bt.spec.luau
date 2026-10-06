-- GameKit BehaviorTree: sequence / selector / parallel / inverter / cooldown / timeout semantics,
-- memory of running children, the per-tick budget resuming where it stopped, halting running
-- actions, the blackboard, determinism of traces, and invalid trees.
local BT = require("../packages/GameKit/BehaviorTree")
local FakeEnv = require("./fakes/FakeEnv")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local function always(name, status, log)
	return BT.action(name, function()
		if log then
			table.insert(log, name)
		end
		return status
	end)
end

test("sequence stops at the first failure, selector at the first success", function(t)
	local log = {}
	local seq = BT.new(
		BT.sequence({ always("a", "success", log), always("b", "failure", log), always("c", "success", log) })
	)
	t.eq((seq:tick()), "failure")
	t.eq(log, { "a", "b" })
	table.clear(log)
	local sel = BT.new(
		BT.selector({ always("a", "failure", log), always("b", "success", log), always("c", "success", log) })
	)
	t.eq((sel:tick()), "success")
	t.eq(log, { "a", "b" })
	local none = BT.new(BT.selector({ always("x", "failure"), always("y", "failure") }))
	t.eq((none:tick()), "failure")
end)

test("a running child is resumed on the next tick (memory)", function(t)
	local log = {}
	local count = 0
	local slow = BT.action("slow", function()
		count += 1
		table.insert(log, "slow")
		return if count < 3 then "running" else "success"
	end)
	local runner =
		BT.new(BT.sequence({ always("first", "success", log), slow, always("last", "success", log) }))
	t.eq((runner:tick()), "running")
	t.eq((runner:tick()), "running")
	t.eq((runner:tick()), "success")
	t.eq(log, { "first", "slow", "slow", "slow", "last" }, "first ran once")
end)

test("parallel policies", function(t)
	local function run(children, policy)
		return (BT.new(BT.parallel(children, policy)):tick())
	end
	t.eq(run({ always("a", "success"), always("b", "running") }, { success = "all" }), "running")
	t.eq(run({ always("a", "success"), always("b", "running") }, { success = "one" }), "success")
	t.eq(run({ always("a", "failure"), always("b", "running") }, { failure = "one" }), "failure")
	t.eq(run({ always("a", "failure"), always("b", "running") }, { failure = "all" }), "running")
	t.eq(
		run({ always("a", "failure"), always("b", "success") }, { success = "all", failure = "all" }),
		"failure"
	)
	-- Completed children are not ticked again while the others run.
	local ticks = 0
	local once = BT.action("once", function()
		ticks += 1
		return "success"
	end)
	local n = 0
	local later = BT.action("later", function()
		n += 1
		return if n < 3 then "running" else "success"
	end)
	local runner = BT.new(BT.parallel({ once, later }))
	t.eq((runner:tick()), "running")
	t.eq((runner:tick()), "running")
	t.eq((runner:tick()), "success")
	t.eq(ticks, 1)
end)

test("inverter, cooldown and timeout use env.clock", function(t)
	local env = FakeEnv.new()
	t.eq((BT.new(BT.inverter(always("a", "success"))):tick()), "failure")
	t.eq((BT.new(BT.inverter(always("a", "failure"))):tick()), "success")
	t.eq((BT.new(BT.inverter(always("a", "running"))):tick()), "running")
	local fired = 0
	local attack = BT.action("attack", function()
		fired += 1
		return "success"
	end)
	local cooldown = BT.new(BT.cooldown(attack, 2), nil, env)
	t.eq((cooldown:tick()), "success")
	t.eq((cooldown:tick()), "failure", "cooling down")
	env:advance(1.9)
	t.eq((cooldown:tick()), "failure")
	env:advance(0.1)
	t.eq((cooldown:tick()), "success")
	t.eq(fired, 2)
	local halted = 0
	local forever = BT.action("forever", function()
		return "running"
	end, function()
		halted += 1
	end)
	local timeout = BT.new(BT.timeout(forever, 3), nil, env)
	t.eq((timeout:tick()), "running")
	env:advance(2.9)
	t.eq((timeout:tick()), "running")
	env:advance(0.1)
	t.eq((timeout:tick()), "failure", "timed out")
	t.eq(halted, 1, "the running action was halted")
	t.throws(function()
		BT.new(BT.cooldown(always("a", "success"), 1)):tick()
	end, "cooldown without env.clock")
end)

test("the per-tick budget spreads a tree over ticks and resumes where it stopped", function(t)
	local log = {}
	local children = {}
	for i = 1, 10 do
		table.insert(children, always("step" .. i, "success", log))
	end
	local runner = BT.new(BT.sequence(children), { budget = 4 })
	local status, info = runner:tick()
	t.eq(status, "running")
	t.eq(info.visits, 4)
	t.eq(info.budgetExhausted, true)
	t.eq(#log, 3, "the sequence node is one visit")
	status, info = runner:tick()
	t.eq(status, "running")
	t.eq(#log, 6, "resumed at step 4")
	runner:tick()
	status, info = runner:tick()
	t.eq(status, "success")
	t.eq(info.budgetExhausted, false)
	t.eq(log, { "step1", "step2", "step3", "step4", "step5", "step6", "step7", "step8", "step9", "step10" })
end)

test("blackboard, reset halts running actions, traces are deterministic", function(t)
	local seen = BT.condition("sees_target", function(bb)
		return bb:get("target") ~= nil
	end)
	local halted = 0
	local chase = BT.action("chase", function(bb, ctx)
		bb:set("chasing", ctx.frame)
		return "running"
	end, function()
		halted += 1
	end)
	local tree = BT.selector({ BT.sequence({ seen, chase }, "pursue"), always("wander", "running") }, "root")
	local runner = BT.new(tree, { trace = true, blackboard = { target = "t1" } })
	local status, info = runner:tick({ frame = 1 })
	t.eq(status, "running")
	t.eq(info.trace, { "sees_target:success", "chase:running", "pursue:running", "root:running" })
	t.eq(runner.blackboard:get("chasing"), 1)
	runner:reset()
	t.eq(halted, 1)
	runner.blackboard:clear("target")
	local _, again = runner:tick({ frame = 2 })
	t.eq(again.trace, { "sees_target:failure", "pursue:failure", "wander:running", "root:running" })
	t.eq(runner.blackboard:snapshot(), { chasing = 1 })
end)

test("an action returning a bad status raises; invalid trees list problems", function(t)
	t.throws(function()
		BT.new(BT.action("bad", function()
			return "done" :: any
		end)):tick()
	end)
	local shared = always("shared", "success")
	t.eq(
		BT.validate(BT.sequence({ shared, shared })),
		{ "/sequence[2]/shared: node used twice (build a new one)" }
	)
	t.eq(BT.validate(BT.selector({})), { "/selector: needs at least one child" })
	t.eq(
		BT.validate(BT.cooldown(always("a", "success"), 0)),
		{ "/cooldown: seconds must be a finite number > 0" }
	)
	t.eq(
		BT.validate(BT.parallel({ always("a", "success") }, { success = "most" })),
		{ "/parallel: success policy must be all or one" }
	)
	t.eq(BT.validate({ kind = "loop", name = "x" }), { "/x: unknown kind loop" })
	t.throws(function()
		BT.new(always("a", "success"), { budget = 0 })
	end)
end)

return cases
