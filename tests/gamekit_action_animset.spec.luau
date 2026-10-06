--!strict
-- G2 AnimSet: clips/1 validation (the runtime-kits example included), the marker contract,
-- states to slots, layers (locomotion replaces itself, actions overlay), the 8-track Animator
-- cap, seeded weighted variants and marker delivery through FakeAnimator.
local AnimSet = require("../packages/GameKit/AnimSet")
local FakeAnimator = require("./fakes/FakeAnimator")
local FakeEnv = require("./fakes/FakeEnv")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function clip(
	name: string,
	slot: string?,
	last: number,
	loop: boolean,
	markers: { any }?,
	extra: { [string]: any }?
)
	local c: { [string]: any } = {
		name = name,
		slot = slot,
		start = 0,
		["end"] = last,
		loop = loop,
		root_motion = false,
		markers = markers or {},
	}
	for k, value in extra or {} do
		c[k] = value
	end
	return c
end

-- A neutral clip sheet: every standard locomotion slot used here, two idle variants, footsteps,
-- eight one-shot action slots with a "hit" marker, and one unslotted pose.
local function sheet(): any
	local clips = {
		clip("idle", "idle", 59, true, nil, { priority = "Idle", weight = 3 }),
		clip("idle_b", "idle", 89, true, nil, { weight = 1 }),
		clip("walk", "walk", 29, true, {
			{ name = "footstep", frame = 7, param = "left" },
			{ name = "footstep", frame = 22, param = "right" },
		}),
		clip("run", "run", 19, true, {
			{ name = "footstep", frame = 5, param = "left" },
			{ name = "footstep", frame = 15, param = "right" },
		}),
		clip("jump", "jump", 9, false),
		clip("fall", "fall", 19, true),
		clip("land", "land", 5, false),
		clip("pose_ref", nil, 0, false),
	}
	for index = 1, 8 do
		table.insert(
			clips,
			clip("action_" .. index, "action_" .. index, 15, false, { { name = "hit", frame = 6 } })
		)
	end
	return {
		schema = "clips/1",
		asset = "rig_test",
		rig = "r15_pose",
		fps = 30,
		files = { glb = "rig_test_clips.glb", fbx = { idle = "rig_test_idle.fbx" } },
		clips = clips,
	}
end

local SLOTS = {
	walk = { markers = { "footstep" } },
	run = { markers = { "footstep" }, speed = 1.2 },
	action_1 = { markers = { "hit" }, fadeIn = 0.05 },
}
local STATES = { idle = "idle", moving = "walk", sprinting = "run", airborne = "fall", jumping = "jump" }

local function rig(seed: any?)
	local set = AnimSet.define({ clips = sheet(), slots = SLOTS :: any, states = STATES })
	local animator = FakeAnimator.new()
	local player = AnimSet.player(set, animator, {
		animation = function(c: any, s: any)
			local markers = {}
			for _, marker in c.markers do
				table.insert(
					markers,
					{ name = marker.name, time = AnimSet.markerTime(c, marker, s.fps), param = marker.param }
				)
			end
			return { name = c.name, length = AnimSet.duration(c, s.fps), looped = c.loop, markers = markers }
		end,
		configure = function(track: any, priority: string, looped: boolean)
			track.Priority = priority
			track.Looped = looped
		end,
		seed = seed,
	}, FakeEnv.new())
	return player, animator, set
end

test("validateClips: the runtime-kits example passes; every broken field is reported", function(t)
	local example = {
		schema = "clips/1",
		asset = "pet_follower",
		rig = "custom",
		fps = 30,
		files = {
			glb = "pet_follower_clips.glb",
			fbx = { idle = "pet_follower_idle.fbx", walk = "pet_follower_walk.fbx" },
		},
		clips = {
			{
				name = "idle",
				slot = "idle",
				start = 0,
				["end"] = 59,
				loop = true,
				root_motion = false,
				priority = "Idle",
				markers = {},
			},
			{
				name = "walk",
				slot = "walk",
				start = 0,
				["end"] = 29,
				loop = true,
				root_motion = false,
				markers = {
					{ name = "footstep", frame = 7, param = "left" },
					{ name = "footstep", frame = 22, param = "right" },
				},
			},
		},
	}
	t.eq(AnimSet.validateClips(example), {})
	t.eq(#AnimSet.validateClips(sheet()), 0)
	local broken = {
		schema = "clips/2",
		asset = "Rig Test",
		rig = "r6",
		fps = 29.97,
		files = { fbx = { idle = 5 } },
		clips = {
			clip("Idle", "idle", 10, true),
			clip("walk", "stroll", 10, true),
			clip("walk", "walk", -1, "yes" :: any),
			clip("a", "idle", 10, true, { { name = "hit", frame = 11 } }, { priority = "Highest" }),
			clip("b", nil, 10, false, { { name = "Bad Name", frame = 1 } }, { weight = 0 }),
		},
	}
	local problems = AnimSet.validateClips(broken)
	for _, needle in
		{
			"schema",
			"asset",
			"rig",
			"fps",
			"files.fbx",
			"clips[1].name",
			"clips[2].slot",
			'clips[3].name "walk" is duplicated',
			"clips[3].end must be >= start",
			"clips[3].loop",
			"clips[4].priority",
			"clips[4].markers[1].frame",
			"clips[5].weight",
			"clips[5].markers[1].name",
			"slot idle has several clips; each needs weight > 0",
		}
	do
		t.ok(has(problems, needle), needle)
	end
	t.eq(AnimSet.validateClips(nil)[1], "clips/1 must be a table")
	t.ok(has(
		AnimSet.validateClips({
			schema = "clips/1",
			asset = "a",
			rig = "custom",
			fps = 30,
			files = {},
			clips = {},
		}),
		"non-empty"
	))
	t.near(AnimSet.duration(example.clips[2] :: any, 30), 29 / 30, 1e-12)
end)

test("marker contract: listened markers must exist in every clip of the slot", function(t)
	t.eq(AnimSet.validate({ clips = sheet(), slots = SLOTS, states = STATES }), {})
	local missing = sheet()
	missing.clips[3].markers = { { name = "footstep", frame = 7, param = "left" } }
	missing.clips[4].markers = {}
	local problems = AnimSet.validate({ clips = missing, slots = SLOTS, states = STATES })
	t.eq(#problems, 1)
	t.ok(has(problems, 'marker contract: clip run (slot run) has no marker "footstep"'))
	local unbound = AnimSet.validate({
		clips = sheet(),
		slots = { swim = {} },
		states = { diving = "swim", bad = "nap" },
	})
	t.ok(has(unbound, "slots.swim has no clip"))
	t.ok(has(unbound, "states.diving uses slot swim, which has no clip"))
	t.ok(has(unbound, "states.bad must name a standard slot"))
	t.ok(has(
		AnimSet.validate({
			clips = sheet(),
			slots = { walk = { priority = "Top", fadeIn = -1, layer = "Bad Layer" } },
		}),
		"slots.walk.priority"
	))
	t.ok(not pcall(AnimSet.define, { clips = missing, slots = SLOTS } :: any))
	t.eq(#AnimSet.SLOTS, 17)
end)

test("player: states map to slots; locomotion replaces itself; tracks load once", function(t)
	local player, animator = rig(1)
	t.ok(player:setState("moving"))
	t.eq(player:playing(), { "walk" })
	t.eq(select(2, player:setState("moving")), "same_state")
	player:setState("sprinting")
	t.eq(player:playing(), { "run" })
	player:setState("moving")
	t.eq(animator.loads, { "walk", "run" }, "the walk track is reused")
	t.eq(animator:playing(), { "walk" })
	t.eq(animator.tracks[1].Priority, "Movement", "slot default priority")
	t.eq(animator.tracks[2].Speed, 1.2, "slot speed")
	t.eq(select(2, player:play("walk")), "already_playing", "a looped slot is not restarted")
	t.eq(select(2, player:setState("swimming")), "unknown_state")
	t.eq(select(2, player:play("swim")), "unknown_slot")
	t.ok(player:play("action_1"))
	t.eq(player:playing(), { "action_1", "walk" }, "actions overlay locomotion")
	t.ok(player:play("action_1"), "one-shots restart")
	t.ok(string.find(animator.log[#animator.log], "fade=0.05", 1, true) ~= nil, "slot fadeIn")
end)

test("player: never more than 8 playing tracks; the oldest lowest-priority one stops", function(t)
	local player, animator = rig(1)
	player:setState("moving")
	for index = 1, 8 do
		t.ok(player:play("action_" .. index))
	end
	t.eq(animator.maxPlaying, 8)
	t.eq(#player:playing(), 8)
	t.eq(player:clip("walk"), nil, "walk (Movement) is below Action and was oldest")
	player:setState("idle")
	t.eq(animator.maxPlaying, 8)
	t.eq(player:clip("action_1"), nil, "then the oldest Action goes")
	player:stopAll()
	t.eq(#animator:playing(), 0)
end)

test("markers: footsteps and hits arrive with their params at the clip's frame times", function(t)
	local player, animator = rig(1)
	local log = {}
	local disconnect = player:onMarker("footstep", function(slot: string, param: any)
		table.insert(log, slot .. ":" .. tostring(param))
	end)
	player:onMarker("hit", function(slot: string)
		table.insert(log, slot .. ":hit")
	end)
	player:setState("moving")
	animator:advance(0.2)
	t.eq(log, {}, "frame 7 is at 0.233 s")
	animator:advance(0.1)
	t.eq(log, { "walk:left" })
	animator:advance(0.7)
	t.eq(log, { "walk:left", "walk:right" }, "the loop wraps at 29/30 s without a duplicate")
	player:play("action_1")
	animator:advance(0.25)
	t.eq(log[3], "walk:left", "the walk loop keeps stepping")
	t.eq(log[4], "action_1:hit", "frame 6 of 30 fps is 0.2 s into the action")
	animator:advance(1)
	t.ok(not animator.tracks[2].IsPlaying, "the one-shot ended on the animator")
	t.eq(player:playing(), { "walk" }, "and left the playing set through Stopped")
	disconnect()
	local before = #log
	animator:advance(1)
	t.eq(#log, before, "a disconnected handler hears nothing")
	player:destroy()
	t.eq(#animator:playing(), 0)
end)

test("variants: idle picks by weight from a seeded Rng; the same seed picks the same", function(t)
	local function picks(seed: any): { string }
		local player = rig(seed)
		local out = {}
		for _ = 1, 400 do
			player:stop("idle", 0)
			player:play("idle")
			table.insert(out, player:clip("idle") :: string)
		end
		return out
	end
	local a = picks(7)
	t.eq(a, picks(7))
	t.ok(table.concat(a) ~= table.concat(picks(8)), "another seed picks differently")
	local main = 0
	for _, name in a do
		main += if name == "idle" then 1 else 0
	end
	t.ok(main > 250 and main < 350, "3:1 weights: " .. main .. " of 400")
end)

return cases
