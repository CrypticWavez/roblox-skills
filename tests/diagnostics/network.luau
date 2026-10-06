local FaultQueue = require("../../packages/Diagnostics/FaultQueue")
local passed = 0
local failed = 0
local function equal(actual, expected)
	assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function test(name, fn)
	local ok, problem = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
	end
	print((if ok then "PASS " else "FAIL ") .. name .. (if ok then "" else ": " .. tostring(problem)))
end
local function options(overrides)
	local result =
		{ seed = 9, capacity = 32, minDelay = 0, maxDelay = 0, lossProbability = 0, duplicateProbability = 0 }
	for key, value in overrides or {} do
		result[key] = value
	end
	return result
end
local function packet(sequence)
	return { sequence = sequence, sentAt = 0, label = "neutral-echo" }
end
test("explicit options reject nonfinite, fractional, reversed and unknown parameters", function()
	equal(pcall(FaultQueue.new, nil), false)
	for key, values in
		{
			seed = { 0, 0.5, 4294967296 },
			capacity = { 0, 2.5, 1025 },
			minDelay = { -1, 0 / 0, math.huge },
			maxDelay = { 31, -math.huge },
			lossProbability = { -0.1, 1.1, math.huge },
			duplicateProbability = { 0 / 0, -1 },
		}
	do
		for _, value in values do
			equal(pcall(FaultQueue.new, options({ [key] = value })), false)
		end
	end
	equal(pcall(FaultQueue.new, options({ minDelay = 2, maxDelay = 1 })), false)
	equal(pcall(FaultQueue.new, options({ typo = 1 })), false)
end)
test("packets and elapsed time have finite bounded validation", function()
	local queue = FaultQueue.new(options())
	for _, malformed in
		{
			{},
			{ sequence = 0, sentAt = 0, label = "x" },
			{ sequence = 1, sentAt = math.huge, label = "x" },
			{ sequence = 1, sentAt = 0, label = string.rep("x", 65) },
			{ sequence = 1, sentAt = 0, label = "x", extra = true },
		}
	do
		equal(
			pcall(function()
				queue:enqueue(malformed)
			end),
			false
		)
	end
	for _, delta in { -1, 61, math.huge, 0 / 0 } do
		equal(
			pcall(function()
				queue:advance(delta)
			end),
			false
		)
	end
	equal(queue:stats().submitted, 0)
	queue:destroy()
end)
test("zero-delay order is stable and input/config mutations cannot affect ownership", function()
	local config = options()
	local queue = FaultQueue.new(config)
	config.capacity = 999
	local first = packet(1)
	assert(queue:enqueue(first))
	first.sequence = 99
	assert(queue:enqueue(packet(2)))
	local delivery = queue:advance(0)
	equal(delivery[1].sequence, 1)
	equal(delivery[2].sequence, 2)
	equal(queue:stats().capacity, 32)
	local stats = queue:stats()
	stats.delivered = 999
	equal(queue:stats().delivered, 2)
	queue:destroy()
end)
test("full loss consumes no capacity and accounts each submitted original", function()
	local queue = FaultQueue.new(options({ lossProbability = 1, duplicateProbability = 1 }))
	for index = 1, 100 do
		local accepted, reason = queue:enqueue(packet(index))
		equal(accepted, false)
		equal(reason, "loss")
	end
	equal(queue:stats().lost, 100)
	equal(queue:stats().accepted, 0)
	equal(queue:stats().queued, 0)
	equal(#queue:advance(1), 0)
	queue:destroy()
end)
test("duplicates are exactly two copies and saturation admission is atomic", function()
	local queue = FaultQueue.new(options({ capacity = 3, duplicateProbability = 1 }))
	local accepted, _, copies = queue:enqueue(packet(1))
	equal(accepted, true)
	equal(copies, 2)
	local rejected, reason = queue:enqueue(packet(2))
	equal(rejected, false)
	equal(reason, "capacity")
	equal(queue:stats().queued, 2)
	equal(queue:stats().duplicates, 1)
	equal(queue:stats().saturated, 1)
	local deliveries = queue:advance(0)
	equal(#deliveries, 2)
	equal(deliveries[1].sequence, deliveries[2].sequence)
	queue:destroy()
end)
test("same seed and clock steps reproduce loss, duplicates and delivery order", function()
	local function run(seed)
		local queue = FaultQueue.new(options({
			seed = seed,
			capacity = 64,
			maxDelay = 1,
			lossProbability = 0.2,
			duplicateProbability = 0.4,
		}))
		for index = 1, 20 do
			queue:enqueue(packet(index))
		end
		local sequence = {}
		for _ = 1, 10 do
			for _, delivery in queue:advance(0.11) do
				table.insert(sequence, delivery.sequence)
			end
		end
		local stats = queue:stats()
		queue:destroy()
		return table.concat(sequence, ","), stats
	end
	local first, a = run(9)
	local second, b = run(9)
	equal(first, second)
	equal(a.lost, b.lost)
	equal(a.duplicates, b.duplicates)
	assert(a.lost > 0 and a.duplicates > 0 and a.delivered > 0, "seed must exercise all fault cases")
	assert(run(10) ~= first, "different seeds should change this fixture sequence")
end)
test("variable delay produces reorder while respecting deadlines", function()
	local queue = FaultQueue.new(options({ minDelay = 0.1, maxDelay = 1 }))
	for index = 1, 20 do
		assert(queue:enqueue(packet(index)))
	end
	equal(#queue:advance(0.09), 0)
	local order = queue:advance(1)
	equal(#order, 20)
	local reorder = false
	for index = 2, #order do
		if order[index].sequence < order[index - 1].sequence then
			reorder = true
		end
	end
	assert(reorder, "variable delay should reorder this fixed seed")
	equal(queue:stats().queued, 0)
	queue:destroy()
end)
test("sustained synthetic pressure never exceeds a finite queue capacity", function()
	local queue =
		FaultQueue.new(options({ capacity = 16, minDelay = 0.2, maxDelay = 0.2, duplicateProbability = 0.5 }))
	for index = 1, 1000 do
		queue:enqueue(packet(index))
		queue:advance(0.001)
		assert(queue:stats().queued <= 16, "queue exceeded capacity under sustained pressure")
	end
	queue:advance(1)
	local stats = queue:stats()
	assert(stats.saturated > 0, "load case never saturated")
	equal(stats.peakQueued, 16)
	equal(stats.accepted + stats.lost + stats.rejected, stats.submitted)
	equal(stats.delivered, stats.accepted + stats.duplicates)
	queue:destroy()
end)
test("clear and destroy account pending packets exactly once and release all ownership", function()
	local queue = FaultQueue.new(options({ minDelay = 1, maxDelay = 1 }))
	assert(queue:enqueue(packet(1)))
	assert(queue:enqueue(packet(2)))
	equal(queue:clear(), 2)
	equal(queue:clear(), 0)
	assert(queue:enqueue(packet(3)))
	queue:destroy()
	queue:destroy()
	equal(queue:stats().discarded, 3)
	equal(queue:stats().queued, 0)
	equal(queue:stats().closed, true)
	local accepted, reason = queue:enqueue(packet(4))
	equal(accepted, false)
	equal(reason, "closed")
	equal(#queue:advance(1), 0)
	equal(queue:stats().submitted, 3)
end)
test("actual fixture settings produce two independent bounded fault cases", function()
	local settings = require("../../fixtures/network/Settings")
	for index = 1, 2 do
		local config = table.clone(settings.options)
		config.seed += index - 1
		local queue = FaultQueue.new(config)
		for sequence = 1, settings.packetCount do
			queue:enqueue(packet(sequence))
		end
		local deliveries = queue:advance(settings.options.maxDelay)
		local unique = {}
		for _, value in deliveries do
			unique[value.sequence] = true
		end
		local count = 0
		for _ in unique do
			count += 1
		end
		local stats = queue:stats()
		assert(stats.lost > 0 and stats.duplicates > 0, "fixture seed must exercise loss and duplicates")
		equal(count, stats.accepted)
		equal(#deliveries, stats.accepted + stats.duplicates)
		equal(stats.queued, 0)
		equal(stats.saturated, 0)
		assert(stats.peakQueued <= config.capacity, "fixture queue exceeded declared bounds")
		queue:destroy()
	end
end)
test("one-day logical horizon cannot admit delayed overflow or advance farther", function()
	local queue = FaultQueue.new(options({ minDelay = 1, maxDelay = 1 }))
	for _ = 1, 1440 do
		queue:advance(60)
	end
	local accepted, reason = queue:enqueue(packet(1))
	equal(accepted, false)
	equal(reason, "horizon")
	equal(queue:stats().rejected, 1)
	equal(
		pcall(function()
			queue:advance(0.1)
		end),
		false
	)
	queue:destroy()
end)
print(string.format("NETWORK_TEST_RESULT passed=%d failed=%d", passed, failed))
assert(failed == 0, "network diagnostics failed")
