--!strict
-- GameKit/Onboarding: step order, onboarding funnel events (once per step, after the durable
-- write), resume after rejoin from the key store, skip-ahead, skip, store failures and a changed
-- step list.
local Events = require("../packages/GameKit/Events")
local Onboarding = require("../packages/GameKit/Onboarding")
local FakeEconomyStore = require("./fakes/FakeEconomyStore")
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

local STEPS = { "joined", "moved", "first_action", "first_reward" }

test("step lists are validated", function(t)
	t.eq(Onboarding.validate(STEPS), {})
	t.ok(contains(Onboarding.validate({}), "non-empty"))
	t.ok(contains(Onboarding.validate({ "a", "a" }), "duplicate step a"))
	t.ok(contains(Onboarding.validate({ "done" }), "reserved"))
	t.ok(contains(Onboarding.validate({ "Bad" }), "is not a label"))
	local many = {}
	for index = 1, 101 do
		table.insert(many, "step_" .. index)
	end
	t.ok(contains(Onboarding.validate(many), "at most 100"))
	t.throws(function()
		Onboarding.new({ steps = {} } :: any)
	end)
end)

test("steps complete in order and each reports one onboarding event", function(t)
	local sink = Events.recorder()
	local onboarding = Onboarding.new({ steps = STEPS, sink = sink, player = "5" })
	t.eq(onboarding:current(), "joined")
	t.eq(onboarding:stepNumber(), 1)
	t.eq({ onboarding:complete("moved") }, { false, "out_of_order" })
	t.eq({ onboarding:complete("joined") }, { true, nil })
	t.eq({ onboarding:complete("joined") }, { true, "already" })
	t.eq({ onboarding:complete("nope") }, { false, "unknown_step" })
	for _, step in { "moved", "first_action", "first_reward" } do
		t.ok((onboarding:complete(step)))
	end
	t.ok(onboarding:isDone())
	t.eq(onboarding:current(), nil)
	t.eq(onboarding:stepNumber(), 5)
	t.eq(sink:count("onboarding"), 4)
	t.eq(sink.events[1].onboarding, { step = 1, step_name = "joined" })
	t.eq(sink.events[4].onboarding, { step = 4, step_name = "first_reward" })
	t.eq(sink:named("onboarding_complete")[1].value, 4)
	for _, event in sink.events do
		t.eq(Events.validate(event), {})
		t.eq(event.player, "5")
	end
	t.eq(onboarding:serialize().state, "fsm/1:onboarding:done")
end)

test("a rejoin resumes at the first open step and never re-reports", function(t)
	local store = FakeEconomyStore.new()
	local sink = Events.recorder()
	local first = Onboarding.new({ steps = STEPS, store = store, sink = sink })
	first:complete("joined")
	first:complete("moved")
	local again = Onboarding.new({ steps = STEPS, store = store, sink = sink })
	t.eq(again:current(), "first_action")
	t.eq({ again:complete("moved") }, { true, "already" })
	t.ok((again:complete("first_action")))
	t.eq(sink:count("onboarding"), 3, "no duplicates across sessions")
	t.eq(store.data.onboarding.completed, { "joined", "moved", "first_action" })
end)

test("a failed store write changes nothing and reports nothing", function(t)
	local env = FakeEnv.new()
	local store = FakeEconomyStore.new()
	local sink = Events.recorder()
	local onboarding = Onboarding.new({ steps = STEPS, store = store, sink = sink }, env)
	store:failSet(1)
	t.eq({ onboarding:complete("joined") }, { false, "store_failed" })
	t.eq(onboarding:current(), "joined")
	t.eq(sink:count(), 0)
	t.ok(contains(env.reports, "store:set failed"))
	t.ok((onboarding:complete("joined")))
	t.eq(sink:count(), 1)
end)

test("skip-ahead completes the steps before it; skip ends onboarding", function(t)
	local sink = Events.recorder()
	local ahead = Onboarding.new({ steps = STEPS, sink = sink, allowSkipAhead = true })
	t.ok((ahead:complete("first_action")))
	t.eq(ahead:current(), "first_reward")
	t.eq(sink:count("onboarding"), 3)
	t.eq(ahead:progress(), { completed = 3, total = 4, skipped = false })
	local store = FakeEconomyStore.new()
	local skipper = Onboarding.new({ steps = STEPS, sink = sink, store = store })
	skipper:complete("joined")
	t.ok((skipper:skip()))
	t.ok(skipper:isDone())
	t.eq(sink:named("onboarding_skipped")[1].value, 2)
	t.eq({ skipper:skip() }, { false, "done" })
	t.eq({ skipper:complete("moved") }, { false, "done" })
	t.ok(Onboarding.new({ steps = STEPS, store = store }):isDone(), "skip persists")
end)

test("a changed step list resumes sensibly and notes retired steps", function(t)
	local store = FakeEconomyStore.new({
		onboarding = { schema = "onboarding/1", completed = { "joined", "retired_step" } },
	})
	local onboarding = Onboarding.new({ steps = { "joined", "new_step", "moved" }, store = store })
	t.eq(onboarding:current(), "new_step")
	t.ok(contains(onboarding.notes, '"retired_step" is no longer a step'))
	local garbage = Onboarding.new({ steps = STEPS, store = FakeEconomyStore.new({ onboarding = "x" }) })
	t.eq(garbage:current(), "joined")
	t.ok(contains(garbage.notes, "not onboarding/1"))
end)

return cases
