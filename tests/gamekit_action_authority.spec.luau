--!strict
-- The authority fixture core (fixtures/kits/shared/authority_Arena.luau) in Lune: joins, the
-- round cycle and spawns, untrusted input (malformed, oversized, flooded), lag-compensated hit
-- claims and their exploit refusals, zones applied through Vitals, the attribute budget and
-- determinism. The Studio scripts around it (authority_Sim.server, authority_Input.client) are
-- build-checked by rojo only; their engine wiring is pending a Studio run.
local Arena = require("../fixtures/kits/shared/authority_Arena")
local AuthorityRoblox = require("../packages/GameKit/AuthorityRoblox")
local FakeEnv = require("./fakes/FakeEnv")
local Hitbox = require("../packages/GameKit/Hitbox")
local Json = require("../packages/GameKit/Json")
local Vec = require("../packages/SceneKit/Vec")

local KITS = {
	["SceneKit/Vec"] = Vec,
	["GameKit/Hitbox"] = Hitbox,
	["GameKit/Zones"] = require("../packages/GameKit/Zones"),
	["GameKit/Vitals"] = require("../packages/GameKit/Vitals"),
	["GameKit/Cooldowns"] = require("../packages/GameKit/Cooldowns"),
	["GameKit/Movement"] = require("../packages/GameKit/Movement"),
	["GameKit/RoundLoop"] = require("../packages/GameKit/RoundLoop"),
}
local function kit(path: string): any
	return assert(KITS[path], "unlisted kit module " .. path)
end

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local DT = 1 / 60
local SHORT = { intermission = 1, active = 30, results = 1 }

local function arena(options: any?): (any, any)
	local env = FakeEnv.new({ seed = 7 })
	local opts = options or {}
	opts.durations = opts.durations or SHORT
	return Arena.new(kit, env, opts), env
end

-- Steps the arena for seconds at 60 Hz; returns every event.
local function run(a: any, env: any, seconds: number, each: ((k: number) -> ())?): { any }
	local events = {}
	for k = 1, math.floor(seconds / DT + 0.5) do
		env:advance(DT)
		if each then
			each(k)
		end
		for _, event in a:step() do
			table.insert(events, event)
		end
	end
	return events
end

local function kinds(events: { any }, kind: string): { any }
	local out = {}
	for _, event in events do
		if event.kind == kind then
			table.insert(out, event)
		end
	end
	return out
end

-- Two bodies in an active round.
local function duel(options: any?): (any, any)
	local a, env = arena(options or { minPlayers = 2 })
	a:join(1)
	a:join(2)
	run(a, env, 1.1)
	assert(a.loop:phase() == "active", "the round started")
	return a, env
end

-- A claim from shooter at target as the shooter's client saw it at time t.
local function claimAt(a: any, shooter: any, target: any, t: number): any
	local from = Hitbox.center(a:poseAt(shooter, t))
	local to = Hitbox.center(a:poseAt(target, t))
	local direction = Vec.unit(Vec.sub(to, from))
	local _, _, point = Hitbox.segment(a:poseAt(target, t), from, Vec.scale(direction, 60))
	return { target = target, time = t, origin = from, direction = direction, hitPoint = point }
end

test("Arena: joins refuse bad and duplicate ids; leave removes the body", function(t)
	local a = arena()
	t.eq({ a:join(1) }, { true, "waiting" })
	t.eq({ a:join("bot_2") }, { true, "waiting" })
	t.eq({ a:join(1) }, { false, "already_joined" })
	for _, bad in { 1.5, 0 / 0, "a b", "", {}, true } do
		t.eq({ a:join(bad) }, { false, "bad_id" }, tostring(bad))
	end
	t.eq(a:bodies(), { 1, "bot_2" })
	t.eq({ a:leave(3) }, { false, "unknown_body" })
	t.eq({ a:leave("bot_2") }, { true, nil })
	t.eq(a:bodies(), { 1 })
	for id = 2, Arena.CONFIG.maxBodies do
		a:join(id)
	end
	t.eq({ a:join(999) }, { false, "full" })
end)

test("Arena: the round starts, spawns on the ring and replicates within the attribute budget", function(t)
	local a, env = arena()
	a:join(1)
	a:join(2)
	local events = run(a, env, 1.1)
	local phases = {}
	for _, event in kinds(events, "phase") do
		table.insert(phases, event.phase)
	end
	t.eq(phases, { "intermission", "active" })
	local spawns = kinds(events, "spawn")
	t.eq(#spawns, 2)
	for _, spawn in spawns do
		t.near(math.sqrt(spawn.x * spawn.x + spawn.z * spawn.z), Arena.CONFIG.spawnRadius, 1e-2)
	end
	local round = a:roundAttributes()
	t.eq(round.RoundPhase, "active")
	t.eq(round.RoundState, "fsm/1:round:active")
	local body = a:bodyAttributes(1)
	t.eq(body.Health, 100)
	t.eq(body.Active, true)
	t.eq(a:bodyAttributes(99), nil)
	for _, values in { round, body } do
		local n = 0
		for name in values do
			n += 1
			t.ok(AuthorityRoblox.validName(name), name)
		end
		t.ok(n <= AuthorityRoblox.MAX_ATTRIBUTES)
	end
	-- Late joiners spectate this round.
	t.eq({ a:join(3) }, { true, "spectator" })
	t.eq(a:isActive(3), false)
end)

test("Arena: input is untrusted (bad payloads, unknown bodies, floods); long moves are clamped", function(t)
	local a, env = duel()
	t.eq({ a:input(99, {}) }, { false, "unknown_body" })
	t.eq({ a:input(1, nil) }, { false, "bad_input" })
	t.eq({ a:input(1, { move = { x = 0 / 0, z = 0 } }) }, { false, "bad_input" })
	t.eq({ a:input(1, { move = { x = math.huge, z = 0 } }) }, { false, "bad_input" })
	t.eq({ a:input(1, { sprint = "yes" }) }, { false, "bad_input" })
	t.eq({ a:input(1, { move = "fast" }) }, { false, "bad_input" })
	local start = a:position(1)
	-- A speed hack: a 50x move vector moves at walk speed, not 50x.
	t.eq({ a:input(1, { move = { x = 50, z = 0 } }) }, { true, nil })
	run(a, env, 1)
	local moved = a:position(1).x - start.x
	t.ok(moved > 0, "moved +x")
	t.near(moved, math.min(16, Arena.CONFIG.half - 1 - start.x), 1e-6, "walk speed for one second")
	t.eq(a:stats().clamped, 1)
	-- Flood: the bucket allows a burst of inputBurst, then refuses.
	local refused = 0
	for _ = 1, 30 do
		local ok = a:input(2, { move = { x = 0, z = 0 } })
		refused += if ok then 0 else 1
	end
	t.eq(refused, 30 - Arena.CONFIG.inputBurst)
	t.eq(a:stats().inputRejected.rate_limited, refused)
	t.eq(a:stats().inputRejected.bad_input, 5)
	-- The bucket refills with time.
	env:advance(0.5)
	t.eq({ a:input(2, { move = { x = 0, z = 1 } }) }, { true, nil })
	-- Sequenced input: a late, older message never overrides a newer one.
	t.eq({ a:input(2, { move = { x = 1, z = 0 }, seq = 5 }) }, { true, nil })
	t.eq({ a:input(2, { move = { x = -1, z = 0 }, seq = 4 }) }, { false, "stale" })
	t.eq({ a:input(2, { move = { x = -1, z = 0 }, seq = 5 }) }, { false, "stale" })
	t.eq({ a:input(2, { seq = 1.5 }) }, { false, "bad_input" })
	t.eq({ a:input(2, { seq = -1 }) }, { false, "bad_input" })
	local before = a:position(2)
	run(a, env, 0.5)
	t.ok(a:position(2).x > before.x, "the newest input (+x) is the one applied")
	t.eq(a:stats().inputRejected.stale, 2)
end)

test("Arena: a lag-compensated claim is accepted; rapid fire and stale or forged claims are not", function(t)
	local a, env = duel()
	-- Clear of the zones: the hazard pad is x 10..18, z -4..4.
	t.ok(a:place(1, -10, -10) and a:place(2, 6, -10), "placed")
	a:setLatency(1, 0.05)
	-- Body 2 strafes along +z; body 1 shoots at where its client saw body 2 0.15 s ago.
	a:input(2, { move = { x = 0, z = 1 } })
	run(a, env, 0.5)
	local now = env.clock()
	local seen = now - 0.15
	local claim = claimAt(a, 1, 2, seen)
	local current = Hitbox.center(a:poseAt(2, now))
	local past = Hitbox.center(a:poseAt(2, seen))
	t.ok(current.z - past.z > 2, "the target has moved on since (no rewind would miss)")
	local ok, reason, record = a:claim(1, claim)
	t.eq({ ok, reason }, { true, nil })
	t.eq(record.applied, 20)
	t.eq(a:bodyAttributes(2).Health, 80)
	-- The same shot again at once: the server's rate of fire refuses it.
	t.eq({ a:claim(1, claimAt(a, 1, 2, seen)) }, { false, "cooldown" })
	env:advance(0.3)
	a:step()
	now = env.clock()
	-- Older than the 200 ms rewind window.
	t.eq({ a:claim(1, claimAt(a, 1, 2, now - 0.25)) }, { false, "too_old" })
	env:advance(0.3)
	a:step()
	now = env.clock()
	local future = claimAt(a, 1, 2, now)
	future.time = now + 1
	t.eq({ a:claim(1, future) }, { false, "future_time" })
	env:advance(0.3)
	a:step()
	now = env.clock()
	local forged = claimAt(a, 1, 2, now - 0.05)
	forged.origin = Vec.add(forged.origin, Vec.new(12, 0, 0)) -- shooting from where it is not
	t.eq({ a:claim(1, forged) }, { false, "origin_mismatch" })
	env:advance(0.3)
	a:step()
	now = env.clock()
	local wide = claimAt(a, 1, 2, now - 0.05)
	wide.hitPoint = Vec.add(wide.hitPoint, Vec.new(0, 0, 6)) -- a hit point off the target
	local _, wideReason = a:claim(1, wide)
	t.ok(wideReason == "bad_angle" or wideReason == "hitpoint_mismatch", tostring(wideReason))
	env:advance(0.3)
	a:step()
	local selfShot = { target = 1, time = env.clock(), origin = a:position(1), direction = Vec.new(1, 0, 0) }
	t.eq({ a:claim(1, selfShot) }, { false, "self_hit" })
	t.eq({ a:claim(1, { target = 77, time = env.clock() }) }, { false, "unknown_target" })
	t.eq({ a:claim(1, "hit") }, { false, "bad_claim" })
	t.eq({ a:claim(55, claim) }, { false, "unknown_body" })
	t.eq(a:bodyAttributes(2).Health, 80, "no refused claim did damage")
	local stats = a:stats()
	t.eq(stats.accepted, 1)
	t.eq(stats.claimRejected.cooldown, 1)
	t.eq(stats.claimRejected.too_old, 1)
end)

test("Arena: impossible distance is out of range; claims outside the active phase are refused", function(t)
	local a, env = duel()
	t.ok(a:place(1, -31, -31) and a:place(2, 31, 31), "placed in opposite corners")
	env:advance(DT)
	a:step()
	local far = claimAt(a, 1, 2, env.clock())
	local accepted, why = a:claim(1, far)
	t.eq(accepted, false)
	t.eq(why, "out_of_range", tostring(why))
	t.eq({ a:place(1, 0 / 0, 0) }, { false, "bad_position" })
	local b, benv = arena()
	b:join(1)
	b:join(2)
	t.eq({ b:claim(1, { target = 2, time = benv.clock() }) }, { false, "not_active" })
end)

test("Arena: hazard ticks damage, the kill volume eliminates, last standing ends the round", function(t)
	local a, env = duel({ minPlayers = 2, endOnAlive = 1 })
	-- The hazard pad is centred at (14, 0); ticks of 5 every 0.5 s from entry.
	t.ok(a:place(1, 14, 0), "on the pad")
	local events = run(a, env, 1.01)
	t.eq(#kinds(events, "hazard_damage"), 3, "on entry, then at 0.5 s and 1.0 s")
	t.eq(a:bodyAttributes(1).Health, 85, "immediate tick + two interval ticks")
	t.ok(a:place(1, 0, 0), "off the pad")
	-- The pit at (-14, 6) is a kill volume.
	t.ok(a:place(2, -14, 6), "into the pit")
	events = run(a, env, DT)
	local outs = kinds(events, "out")
	t.eq(#outs, 1)
	t.eq(outs[1].body, "2")
	t.eq(outs[1].cause, "kill_zone")
	local phase = kinds(events, "phase")
	t.eq(phase[1].phase, "results")
	t.eq(phase[1].reason, "last_standing")
	t.eq(a:isActive(1), false, "nobody is active between rounds")
	t.eq({ a:claim(1, { target = 2, time = env.clock() }) }, { false, "not_active" })
	-- The next round respawns both at full health.
	events = run(a, env, 2.1)
	t.eq(#kinds(events, "spawn"), 2)
	t.eq(a:bodyAttributes(2).Health, 100)
	t.eq(a:bodyAttributes(1).Health, 100)
end)

test("Arena: a lethal claim eliminates the target and credits the attacker", function(t)
	local a, env = duel()
	t.ok(a:place(1, -5, 0) and a:place(2, 5, 0), "placed")
	local out = nil
	for _ = 1, 5 do
		env:advance(0.3)
		for _, event in a:step() do
			if event.kind == "out" then
				out = event
			end
		end
		t.ok((a:claim(1, claimAt(a, 1, 2, env.clock()))), "claim accepted")
	end
	for _, event in a:step() do
		if event.kind == "out" then
			out = event
		end
	end
	t.ok(out ~= nil, "out event")
	t.eq(out.killer, "1")
	t.eq(out.cause, "primary")
	t.eq(a:isActive(2), false)
	env:advance(0.3)
	t.eq({
		a:claim(1, { target = 2, time = env.clock(), origin = a:position(1), direction = Vec.new(1, 0, 0) }),
	}, {
		false,
		"target_dead",
	})
	t.eq({ a:claim(2, claimAt(a, 1, 1, env.clock())) }, { false, "shooter_out" })
end)

test("Arena: the same seed and inputs give the same events; another seed spawns elsewhere", function(t)
	local function script(seed: number): string
		local env = FakeEnv.new({ seed = 1 })
		local a = Arena.new(kit, env, { seed = seed, durations = SHORT })
		for id = 1, 4 do
			a:join(id)
		end
		local log = run(a, env, 3, function(k: number)
			for id = 1, 4 do
				local angle = k * 0.05 + id
				a:input(id, { move = { x = math.cos(angle), z = math.sin(angle) }, sprint = id % 2 == 0 })
			end
		end)
		return Json.encode({ log = log, snapshot = a:snapshot() })
	end
	local first, again, other = script(11), script(11), script(12)
	t.eq(first, again)
	t.ok(first ~= other, "a different seed changes the spawn ring")
end)

test("authority fixture: IAS actions build in Lune; both scripts are opt-in and diagnostic-only", function(t)
	local lune = require("@lune/roblox")
	local fs = require("@lune/fs")
	local context, actions = AuthorityRoblox.buildActions(Arena.ACTIONS, lune, nil)
	t.eq(context.Name, "SETUP_ONLY_Authority")
	t.eq(actions["gameplay.primary"]:GetChildren()[1].KeyCode, lune.Enum.KeyCode.MouseLeftButton)
	t.eq(#actions["gameplay.move"]:GetChildren(), 2)
	t.eq(#AuthorityRoblox.validateActions(Arena.ACTIONS), 0)
	-- A broken spec is refused, not half built.
	local broken = table.clone(Arena.ACTIONS)
	broken.actions = { { name = "gameplay.primary", type = "Bool", bindings = { { keyCode = "NotAKey" } } } }
	t.throws(function()
		AuthorityRoblox.buildActions(broken :: any, lune, nil)
	end)
	local root = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."
	for _, path in
		{
			"fixtures/kits/server/authority_Sim.server.luau",
			"fixtures/kits/client/authority_Input.client.luau",
		}
	do
		local source = fs.readFile(root .. "/" .. path)
		local gate = string.find(source, 'GetAttribute("SETUP_ONLY_KitFixture") ~= "authority"', 1, true)
		local firstWait = string.find(source, "WaitForChild", 1, true)
		t.ok(
			gate ~= nil and firstWait ~= nil and gate < firstWait,
			path .. " gates before touching the place"
		)
		t.ok(string.find(source, "bindStep", 1, true) ~= nil, path .. " steps through bindStep")
	end
	local server = fs.readFile(root .. "/fixtures/kits/server/authority_Sim.server.luau")
	t.ok(string.find(server, "Env.assertDiagnostic", 1, true) ~= nil, "server refuses published places")
	t.ok(string.find(server, "writeAttributes", 1, true) ~= nil, "server writes through the 64 budget")
end)

return cases
