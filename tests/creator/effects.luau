local Pool = require("../../packages/Creator/EffectsPool")
local results = {}
local function equal(actual, expected)
	assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function test(name, fn)
	local ok, failure = pcall(fn)
	table.insert(results, { name = name, passed = ok })
	print((if ok then "PASS " else "FAIL ") .. name .. (if ok then "" else ": " .. tostring(failure)))
end
local function adapter()
	local state = { created = 0, resets = 0, destroyed = 0, seen = {}, resources = {} }
	local implementation = {}
	function implementation.create()
		state.created += 1
		local object = { id = state.created, destroyCalls = 0 }
		table.insert(state.resources, object)
		return object
	end
	function implementation.activate(object, recipe, config)
		object.active = true
		table.insert(state.seen, { id = object.id, recipe = recipe, config = config })
	end
	function implementation.reset(object)
		object.active = false
		state.resets += 1
	end
	function implementation.destroy(object)
		object.destroyCalls += 1
		object.destroyed = true
		state.destroyed += 1
	end
	return implementation, state
end

test("released objects reuse across recipes; stale cancellation cannot cancel a new lease", function()
	local mock, state = adapter()
	local pool = Pool.new(mock, { capacity = 1 })
	local first = assert(pool:emit("reward"))
	equal(first:cancel(), true)
	local nextLease = assert(pool:emit("impact"))
	equal(first:cancel(), false)
	equal(state.created, 1)
	equal(pool:stats().active, 1)
	equal(pool:stats().reused, 1)
	equal(nextLease:cancel(), true)
	pool:destroy()
	equal(state.destroyed, 1)
end)
test("capacity drops equal priority and preempts only a weaker effect", function()
	local mock, state = adapter()
	local pool = Pool.new(mock, { capacity = 1 })
	local reward = assert(pool:emit("reward"))
	local rejected, reason = pool:emit("reward")
	equal(rejected, nil)
	equal(reason, "capacity")
	assert(pool:emit("telegraph"))
	equal(reward:cancel(), false)
	equal(state.created, 1)
	equal(pool:stats().evicted, 1)
	equal(pool:stats().dropped, 1)
	pool:destroy()
end)
test("expiry updates use actual elapsed time and reset at the deadline", function()
	local mock, state = adapter()
	local alpha
	function mock.update(_, value)
		alpha = value
	end
	local pool = Pool.new(mock)
	local lease = assert(pool:emit("impact", { duration = 0.4 }))
	pool:step(0.2)
	equal(alpha, 0.5)
	equal(pool:stats().active, 1)
	pool:step(0.2)
	equal(pool:stats().active, 0)
	equal(state.resets, 1)
	equal(lease:cancel(), false)
	pool:destroy()
end)
test("reduced effects remove cosmetics and preserve critical cue admission", function()
	local mock, state = adapter()
	local pool = Pool.new(mock)
	local cue = assert(pool:emit("telegraph"))
	local cosmetic = assert(pool:emit("reward"))
	pool:setReducedEffects(true)
	equal(cosmetic:cancel(), false)
	equal(pool:stats().active, 1)
	local dropped, reason = pool:emit("impact")
	equal(dropped, nil)
	equal(reason, "reduced_effects")
	assert(pool:emit("telegraph", { particleCount = 20 }))
	equal(state.seen[#state.seen].config.particleCount, 0)
	equal(state.seen[#state.seen].config.reducedEffects, true)
	equal(cue:cancel(), true)
	pool:destroy()
end)
test("nonfinite and invalid parameters fail before resource creation", function()
	local mock, state = adapter()
	local pool = Pool.new(mock)
	for _, override in
		{
			{ duration = 0 },
			{ duration = 6 },
			{ duration = 0 / 0 },
			{ radius = math.huge },
			{ radius = -1 },
			{ width = 0 },
			{ priority = 2.5 },
			{ particleCount = 49 },
			{ unknown = true },
		}
	do
		equal(
			pcall(function()
				pool:emit("telegraph", override)
			end),
			false
		)
	end
	equal(
		pcall(function()
			pool:emit("missing")
		end),
		false
	)
	equal(
		pcall(function()
			pool:step(math.huge)
		end),
		false
	)
	equal(
		pcall(function()
			pool:step(-1)
		end),
		false
	)
	equal(
		pcall(function()
			pool:cancel(0 / 0)
		end),
		false
	)
	equal(state.created, 0)
	pool:destroy()
end)
test("constructor validates caps and configured recipes", function()
	equal(
		pcall(function()
			Pool.new(adapter(), { misspelledCapacity = 100 })
		end),
		false
	)
	equal(
		pcall(function()
			Pool.new(adapter(), { capacity = false })
		end),
		false
	)
	equal(
		pcall(function()
			Pool.new(adapter(), false)
		end),
		false
	)
	for _, capacity in { 0, 257, 1.5, 0 / 0, math.huge } do
		equal(
			pcall(function()
				Pool.new(adapter(), { capacity = capacity })
			end),
			false
		)
	end
	equal(
		pcall(function()
			Pool.new(adapter(), { reducedEffects = "yes" })
		end),
		false
	)
	equal(
		pcall(function()
			Pool.new(adapter(), { recipes = { telegraph = { duration = -1 } } })
		end),
		false
	)
	equal(
		pcall(function()
			Pool.new(adapter(), { recipes = { missing = {} } })
		end),
		false
	)
end)
test("caller and adapter configuration mutations cannot extend an accepted lifetime", function()
	local mock, state = adapter()
	local recipes = { impact = { duration = 0.2 } }
	function mock.activate(object, _, config)
		object.active = true
		config.duration = 999
	end
	local pool = Pool.new(mock, { recipes = recipes })
	recipes.impact.duration = 5
	assert(pool:emit("impact"))
	pool:step(0.2)
	equal(pool:stats().active, 0)
	equal(state.resets, 1)
	pool:destroy()
end)
test("cleanup failure destroys the unusable object and permits a bounded replacement", function()
	local mock, state = adapter()
	function mock.reset()
		error("reset failure")
	end
	local pool = Pool.new(mock, { capacity = 1 })
	local lease = assert(pool:emit("reward"))
	equal(lease:cancel(), true)
	equal(state.destroyed, 1)
	equal(pool:stats().cleanupErrors, 1)
	equal(pool:stats().allocated, 0)
	assert(pool:emit("impact"))
	equal(pool:stats().allocated, 1)
	pool:destroy()
end)
test("cleanup cannot recursively admit or step; removed token cannot fire twice", function()
	local mock = adapter()
	local pool, lease
	function mock.reset()
		local value, reason = pool:emit("telegraph")
		equal(value, nil)
		equal(reason, "operation_in_progress")
		local stepped, stepReason = pool:step(0)
		equal(stepped, false)
		equal(stepReason, "operation_in_progress")
		equal(lease:cancel(), false)
	end
	pool = Pool.new(mock)
	lease = assert(pool:emit("impact"))
	lease:cancel()
	equal(pool:stats().cleanupErrors, 0)
	pool:destroy()
end)
test("destroy during reset leaves no resurrected idle resource", function()
	local mock, state = adapter()
	local pool
	function mock.reset()
		pool:destroy()
	end
	pool = Pool.new(mock)
	local lease = assert(pool:emit("reward"))
	assert(pool:emit("impact"))
	lease:cancel()
	equal(pool:stats().allocated, 0)
	equal(pool:stats().active, 0)
	equal(pool:stats().idle, 0)
	equal(state.destroyed, 2)
	pool:destroy()
	equal(state.destroyed, 2)
end)
test("destroy during activation disposes once and returns no accepted lease", function()
	local mock, state = adapter()
	local pool
	function mock.activate()
		pool:destroy()
	end
	pool = Pool.new(mock)
	local lease, reason = pool:emit("telegraph")
	equal(lease, nil)
	equal(reason, "closed_during_activate")
	equal(state.destroyed, 1)
	equal(pool:stats().allocated, 0)
end)
test("destroy during creation cannot leak an untracked returned resource", function()
	local mock, state = adapter()
	local create = mock.create
	local pool
	function mock.create()
		local resource = create()
		pool:destroy()
		return resource
	end
	pool = Pool.new(mock)
	local lease, reason = pool:emit("telegraph")
	equal(lease, nil)
	equal(reason, "closed_during_create")
	equal(state.destroyed, 1)
	equal(pool:stats().allocated, 0)
end)
test("activation and update failures release ownership", function()
	local mock = adapter()
	function mock.activate()
		error("activate failure")
	end
	local pool = Pool.new(mock)
	local lease, reason = pool:emit("impact")
	equal(lease, nil)
	equal(reason, "activate_failed")
	equal(pool:stats().active, 0)
	function mock.activate() end
	function mock.update()
		error("update failure")
	end
	assert(pool:emit("impact"))
	pool:step(0.01)
	equal(pool:stats().active, 0)
	equal(pool:stats().adapterErrors, 2)
	pool:destroy()
end)
test("destructor failure poisons admission instead of growing unreclaimable resources", function()
	local mock, state = adapter()
	function mock.reset()
		error("reset failure")
	end
	function mock.destroy()
		error("destroy failure")
	end
	local pool = Pool.new(mock, { capacity = 1 })
	assert(pool:emit("impact")):cancel()
	equal(pool:stats().poisoned, true)
	for _ = 1, 20 do
		local lease, reason = pool:emit("telegraph")
		equal(lease, nil)
		equal(reason, "cleanup_failed")
	end
	equal(state.created, 1)
	equal(pool:stats().cleanupErrors, 2)
	pool:destroy()
end)
test("sustained interleaved bursts remain bounded and teardown each resource once", function()
	local mock, state = adapter()
	local pool = Pool.new(mock, { capacity = 4 })
	local held = {}
	for index = 1, 400 do
		local kind = if index % 7 == 0 then "telegraph" else (if index % 3 == 0 then "impact" else "reward")
		local lease = pool:emit(kind)
		if lease then
			table.insert(held, lease)
		end
		if index % 5 == 0 and #held > 0 then
			table.remove(held, 1):cancel()
		end
		pool:step(0.025)
		local stats = pool:stats()
		assert(stats.allocated <= 4, "allocation exceeded configured cap")
		equal(stats.active + stats.idle, stats.allocated)
	end
	pool:destroy()
	for _, resource in state.resources do
		equal(resource.destroyCalls, 1)
	end
	equal(pool:stats().allocated, 0)
	equal(pool:stats().active, 0)
	equal(pool:stats().idle, 0)
end)

for _, result in results do
	assert(result.passed, "Effect pool gate failed: " .. result.name)
end
print("Effect pool tests passed: " .. #results)
