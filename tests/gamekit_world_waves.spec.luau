-- GameKit WaveDirector: budget curve, escalation and rest windows; plans are deterministic per
-- seed and spend within budget; the director spawns on schedule, waits for clears, respects
-- maxAlive, emits progression events and finishes; invalid specs list their problems.
local Events = require("../packages/GameKit/Events")
local FakeEnv = require("./fakes/FakeEnv")
local WaveDirector = require("../packages/GameKit/WaveDirector")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local function spec(extra)
	local s = {
		groups = {
			{ key = "enemy_basic", cost = 1, weight = 3 },
			{ key = "enemy_fast", cost = 2, weight = 2, minWave = 2 },
			{ key = "enemy_heavy", cost = 5, weight = 1, minWave = 3, maxPerWave = 2 },
		},
		waves = 6,
		budget = { base = 8, perWave = 4, growth = 1.1 },
		escalation = { every = 3, multiplier = 1.5 },
		rest = { base = 10, perWave = -2, min = 4 },
		spawnInterval = 0.5,
		lanes = { "lane_1", "lane_2", "lane_3" },
	}
	for k, value in extra or {} do
		s[k] = value
	end
	return s
end

test("budget curve, escalation and rest windows", function(t)
	local s = WaveDirector.define(spec())
	t.eq({ WaveDirector.budget(s, 1) }, { 8, false })
	t.eq({ WaveDirector.budget(s, 2) }, { 13, false }, "(8 + 4) * 1.1 = 13.2")
	t.eq({ WaveDirector.budget(s, 3) }, { 29, true }, "(8 + 8) * 1.21 * 1.5 = 29.04")
	t.eq(WaveDirector.rest(s, 1), 10)
	t.eq(WaveDirector.rest(s, 3), 6)
	t.eq(WaveDirector.rest(s, 6), 4, "clamped at min")
end)

test("plans are deterministic per seed, spend within budget and respect unlocks and caps", function(t)
	local s = WaveDirector.define(spec())
	for wave = 1, 6 do
		local a, b = WaveDirector.plan(s, wave, 99), WaveDirector.plan(s, wave, 99)
		t.eq(a, b, "wave " .. wave)
		t.ok(a.spent <= a.budget, "within budget")
		t.ok(a.budget - a.spent < 1, "spends until nothing fits (cheapest costs 1)")
		local heavy = 0
		for i, spawn in a.spawns do
			t.eq(spawn.at, (i - 1) * 0.5)
			if spawn.group == "enemy_fast" then
				t.ok(wave >= 2, "fast unlocks at wave 2")
			elseif spawn.group == "enemy_heavy" then
				t.ok(wave >= 3, "heavy unlocks at wave 3")
				heavy += 1
			end
			t.ok(spawn.lane ~= nil)
		end
		t.ok(heavy <= 2, "maxPerWave")
	end
	local differ = false
	for wave = 1, 6 do
		local a, b = WaveDirector.plan(s, wave, 99), WaveDirector.plan(s, wave, 100)
		if #a.spawns ~= #b.spawns or a.spawns[1].group ~= b.spawns[1].group then
			differ = true
		end
		local lanes = {}
		for _, spawn in a.spawns do
			lanes[spawn.lane] = true
		end
		if #a.spawns >= 3 then
			t.ok(lanes.lane_1 and lanes.lane_2 and lanes.lane_3, "lanes rotate")
		end
	end
	t.ok(differ, "another seed changes the waves")
end)

test("the director spawns on schedule, waits for the clear, rests, and finishes", function(t)
	local env = FakeEnv.new()
	local sink = Events.recorder({ clock = env.clock, strict = true })
	local s = spec({ waves = 2, firstDelay = 2 })
	local director = WaveDirector.new(s, { seed = 7, sink = sink }, env)
	local started, cleared, done = {}, {}, false
	director.waveStarted:Connect(function(wave)
		table.insert(started, wave)
	end)
	director.waveCleared:Connect(function(wave)
		table.insert(cleared, wave)
	end)
	director.finished:Connect(function()
		done = true
	end)
	director:start()
	t.eq(director:tick(), {}, "first delay")
	env:advance(2)
	local plan1 = WaveDirector.plan(WaveDirector.define(s), 1, 7)
	local first = director:tick()
	t.eq(#first, 1, "one spawn at t = 0")
	t.eq(first[1].group, plan1.spawns[1].group)
	t.eq(started, { 1 })
	local total = #first
	for _ = 1, 40 do
		env:advance(0.5)
		total += #director:tick()
	end
	t.eq(total, #plan1.spawns, "every planned spawn")
	t.eq(director:state(), "active", "still alive units")
	director:defeated(total)
	director:tick()
	t.eq(cleared, { 1 })
	t.eq(director:state(), "rest")
	t.eq(director:snapshot().restUntil, env.clock() + plan1.rest)
	env:advance(plan1.rest)
	local spawned = #director:tick()
	t.eq(started, { 1, 2 })
	for _ = 1, 60 do
		env:advance(0.5)
		spawned += #director:tick()
	end
	director:defeated(spawned)
	director:tick()
	t.eq(director:state(), "done")
	t.eq(done, true)
	local names = {}
	for _, event in sink.events do
		table.insert(names, event.progression.status .. ":" .. event.progression.level)
	end
	t.eq(names, { "start:1", "complete:1", "start:2", "complete:2" })
end)

test("maxAlive holds spawns until units are defeated", function(t)
	local env = FakeEnv.new()
	local director = WaveDirector.new(spec({ maxAlive = 2, waves = 1 }), { seed = 1 }, env)
	director:start()
	local spawned = #director:tick()
	for _ = 1, 20 do
		env:advance(0.5)
		spawned += #director:tick()
	end
	t.eq(spawned, 2, "capped")
	director:defeated(1)
	env:advance(0.5)
	t.eq(#director:tick(), 1)
end)

test("invalid specs list their problems", function(t)
	t.eq(
		WaveDirector.validate({
			groups = { { key = "Bad Key", cost = 1 }, { key = "a", cost = 0, minWave = 0 } },
			waves = 0,
			budget = { base = 0 },
			escalation = { every = 0, multiplier = 2 },
			spawnInterval = -1,
			lanes = {},
		}),
		{
			"group Bad Key: key must be a label",
			"group a: cost must be a finite number > 0",
			"group a: minWave must be an integer >= 1",
			"waves must be an integer >= 1 (or nil for endless)",
			"budget.base must be a finite number > 0",
			"escalation needs every (integer >= 1) and multiplier (> 0)",
			"spawnInterval must be a finite number >= 0",
			"lanes must be a non-empty list of labels",
		}
	)
	t.throws(function()
		WaveDirector.new(spec(), {} :: any, FakeEnv.new())
	end, "seed required")
end)

return cases
