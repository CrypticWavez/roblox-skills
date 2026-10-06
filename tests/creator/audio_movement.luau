local Director = require("../../packages/Creator/AudioDirector")
local Movement = require("../../packages/Creator/MovementProfile")
local Mixer = require("../../packages/Runtime/AudioMixer")
local passed = 0
local function expect(value, message)
	assert(value, message or "assertion failed in named Creator fixture")
end
local function test(name, callback)
	local ok, err = pcall(callback)
	expect(ok, name .. ": " .. tostring(err))
	passed += 1
	print("PASS " .. name)
end
local function director(backend)
	return Director.new({
		events = {
			cue = { channel = "effects", configured = true, gain = 1, looped = false },
			absent = { channel = "effects", configured = false, gain = 1, looped = false },
		},
		states = { quiet = { a = 1, b = 0 }, active = { a = 0, b = 1 } },
	}, Mixer.new({ "a", "b", "effects" }), backend)
end
test("unconfigured event never invokes backend; explicit rejection persists", function()
	local calls = 0
	local d = director({
		play = function()
			calls += 1
			return false
		end,
		stop = function() end,
	})
	expect(not d:emit("absent") and calls == 0)
	expect(not d:emit("cue") and calls == 1)
	expect(d:inspect().events[2].result == "backend_rejected")
	expect(d:inspect().hearing == "NOT_VERIFIED")
end)
test("interrupted music crossfade continuous and reduced snaps", function()
	local d = director({
		play = function()
			return true
		end,
		stop = function() end,
	})
	d:setState("quiet", 0, false)
	d:setState("active", 2, false)
	local midpoint = d:step(1)
	expect(midpoint.a == 0.5 and midpoint.b == 0.5)
	d:setState("quiet", 2, false)
	local held = d:step(0)
	expect(held.a == 0.5 and held.b == 0.5)
	d:setState("active", 2, true)
	expect(d:step(0).b == 1 and d:step(0).a == 0)
end)
test("director trace bounded and cleanup runs once despite backend error", function()
	local stops = 0
	local d = director({
		play = function()
			return true
		end,
		stop = function()
			stops += 1
			error("fixture")
		end,
	})
	for _ = 1, 200 do
		d:emit("cue")
	end
	expect(#d:inspect().events == 128)
	d:destroy()
	d:destroy()
	expect(stops == 1)
	expect(not d:emit("cue"))
	local snapshot = d:inspect()
	snapshot.events[1].result = "changed"
	expect(d:inspect().events[1].result ~= "changed")
end)
local profile = {
	speed = 10,
	acceleration = 20,
	deceleration = 40,
	turnRate = math.pi,
	camera = { height = 6, distance = 12, fieldOfView = 70 },
}
test("movement accelerates bounds diagonal speed and stops", function()
	local m = Movement.new(profile)
	expect(m:step(1, 1, 0.1).speed <= 2.000001)
	for _ = 1, 10 do
		m:step(1, 1, 0.1)
	end
	expect(m:step(1, 1, 0).speed <= 10.000001)
	for _ = 1, 3 do
		m:step(0, 0, 0.1)
	end
	expect(m:step(0, 0, 0).speed == 0)
end)
test("movement partitions equal straight time and snapshots profile", function()
	local input = table.clone(profile)
	input.camera = table.clone(profile.camera)
	local a, b = Movement.new(input), Movement.new(profile)
	input.speed = 999
	input.camera.fieldOfView = 120
	for _ = 1, 5 do
		a:step(0, 1, 0.1)
	end
	for _ = 1, 10 do
		b:step(0, 1, 0.05)
	end
	expect(math.abs(a.z - b.z) < 1e-9 and a:camera().fieldOfView == 70)
	local camera = a:camera()
	camera.height = 999
	expect(a:camera().height == 6)
end)
test("movement rejects nonfinite dt and large timestep", function()
	local m = Movement.new(profile)
	expect(not pcall(function()
		m:step(0 / 0, 1, 0.1)
	end))
	expect(not pcall(function()
		m:step(0, 1, 1)
	end))
	expect(not pcall(function()
		Movement.new({ speed = true })
	end))
end)
print("Creator audio/movement: " .. passed .. " passed")
