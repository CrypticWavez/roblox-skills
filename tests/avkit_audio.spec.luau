--!strict
-- AVKit audio: AudioGraph (audio-graph/1 validation, plan, build on @lune/roblox, fader
-- automation and ducking), AudioCues (admission: cooldown, maxConcurrent, voice caps with
-- priority stealing, missing assets, seeded variation), Music (quantized starts, equal-power
-- crossfades) and AudioGraphRoblox driven with injected engine calls (Lune has no AudioPlayer
-- methods or Wire.Connected), plus AudioDirector on the AudioGraphRoblox backend.
local roblox = require("@lune/roblox")
local AudioCues = require("../packages/AVKit/AudioCues")
local AudioDirector = require("../packages/AVKit/AudioDirector")
local AudioGraph = require("../packages/AVKit/AudioGraph")
local AudioGraphRoblox = require("../packages/AVKit/AudioGraphRoblox")
local AudioMixer = require("../packages/AVKit/AudioMixer")
local Music = require("../packages/AVKit/Music")
local RuntimeMixer = require("../packages/Runtime/AudioMixer")
local CreatorDirector = require("../packages/Creator/AudioDirector")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(list: { string }, needle: string): boolean
	for _, text in list do
		if string.find(text, needle, 1, true) then
			return true
		end
	end
	return false
end

local function graphWith(edit: (any) -> ()): any
	local graph = AudioGraph.default()
	edit(graph)
	return graph
end

test("the moved modules are re-exported by the inherited shims", function(t)
	t.eq(RuntimeMixer, AudioMixer)
	t.eq(CreatorDirector, AudioDirector)
end)

test("the default graph validates with the seven standard buses", function(t)
	local problems, warnings = AudioGraph.validate(AudioGraph.default())
	t.eq(problems, {})
	t.eq(warnings, {})
	for _, bus in AudioGraph.BUSES do
		t.ok(AudioGraph.default().buses[bus], bus)
	end
end)

test("a parent cycle is rejected", function(t)
	local problems = AudioGraph.validate(graphWith(function(graph)
		graph.buses.music.parent = "sfx"
		graph.buses.sfx.parent = "music"
	end))
	t.ok(has(problems, "bus music is in a parent cycle"), table.concat(problems, "; "))
	t.ok(has(problems, "bus sfx is in a parent cycle"))
end)

test("an orphan bus is rejected, as is a missing parent or standard bus", function(t)
	local problems = AudioGraph.validate(graphWith(function(graph)
		graph.buses.footsteps = { volume = 1 }
	end))
	t.ok(has(problems, "bus footsteps has no parent"), table.concat(problems, "; "))
	problems = AudioGraph.validate(graphWith(function(graph)
		graph.buses.footsteps = { parent = "foley" }
	end))
	t.ok(has(problems, "parent foley does not exist"))
	problems = AudioGraph.validate(graphWith(function(graph)
		graph.buses.dialogue = nil
		graph.buses.music.duck = nil
		graph.buses.ambience.duck = nil
	end))
	t.ok(has(problems, "standard bus dialogue is missing"))
	problems = AudioGraph.validate(graphWith(function(graph)
		graph.buses.master.parent = "sfx"
	end))
	t.ok(has(problems, "master is the root"))
	t.eq(
		AudioGraph.validate(graphWith(function(graph)
			graph.buses.footsteps = { parent = "sfx", volume = 0.7 }
		end)),
		{},
		"a child bus under a standard bus is fine"
	)
end)

test("ranges, ducks and voice caps are checked", function(t)
	local problems, warnings = AudioGraph.validate(graphWith(function(graph)
		graph.buses.sfx.volume = 4
		graph.buses.ui.effects = { { class = "AudioCompressor", ratio = 80 } }
		graph.buses.world.effects = { { class = "AudioChorus" } }
		graph.buses.music.duck.by = { "master" }
		graph.buses.ambience.duck = { by = { "dialogue" }, amount = 0.5, mode = "sidechain" }
		graph.buses.dialogue.duck = { by = { "dialogue" }, amount = 2 }
		graph.voices.total = 48
	end))
	t.ok(has(problems, "bus sfx.volume must be within 0..3"))
	t.ok(has(problems, "ratio must be within 1..50"))
	t.ok(has(problems, "class must be AudioCompressor, AudioEqualizer or AudioReverb"))
	t.ok(has(problems, "duck.by master is an ancestor"))
	t.ok(has(problems, "sidechain needs an AudioCompressor"))
	t.ok(has(problems, "cannot duck itself"))
	t.ok(has(problems, "duck.amount must be a gain"))
	t.ok(has(warnings, "voices.total 48 above the 32-voice budget"))
	problems = AudioGraph.validate(graphWith(function(graph)
		graph.voices.total = 65
	end))
	t.ok(has(problems, "above 64"))
	t.eq((AudioGraph.validate({ schema = "audio-graph/1" })), { "buses must be a table" })
end)

test("plan wires every bus tail to its parent, master to output and the analyzer tap", function(t)
	local plan = AudioGraph.plan(AudioGraph.default())
	t.eq(plan.buses[1], "master")
	local wires = {}
	for _, wire in plan.wires do
		table.insert(wires, wire.from .. ">" .. wire.to .. (if wire.toPin then ":" .. wire.toPin else ""))
	end
	t.ok(table.find(wires, "Bus_master>Bus_master_fx1_AudioCompressor"))
	t.ok(table.find(wires, "Bus_master_fx1_AudioCompressor>Output"))
	t.ok(table.find(wires, "Bus_master_fx1_AudioCompressor>Analyzer_master"))
	t.ok(table.find(wires, "Listener_world>Bus_world"))
	for _, bus in { "music", "sfx", "ui", "ambience", "dialogue", "world" } do
		t.ok(table.find(wires, "Bus_" .. bus .. ">Bus_master"), bus .. " reaches master")
	end
	t.eq(AudioGraph.plan(AudioGraph.default()), plan, "deterministic")
	local silent = AudioGraph.plan(AudioGraph.default(), { silent = true })
	for _, wire in silent.wires do
		t.ok(wire.to ~= "Output", "silent plans leave the device output unwired")
	end
	local side = AudioGraph.plan(graphWith(function(graph)
		graph.buses.music.effects = { { class = "AudioCompressor", threshold = -30, ratio = 4 } }
		graph.buses.music.duck = { by = { "dialogue" }, amount = 0.5, mode = "sidechain" }
	end))
	local found = false
	for _, wire in side.wires do
		if
			wire.from == "Bus_dialogue"
			and wire.to == "Bus_music_fx1_AudioCompressor"
			and wire.toPin == "Sidechain"
		then
			found = true
		end
	end
	t.ok(found, "the sidechain duck targets the compressor's Sidechain pin")
	t.throws(function()
		AudioGraph.plan(graphWith(function(graph)
			graph.buses.sfx.parent = nil
		end))
	end)
end)

test("build creates the planned Audio API instances and wires on @lune/roblox", function(t)
	local camera = roblox.Instance.new("Camera")
	local parent = roblox.Instance.new("Folder")
	local plan = AudioGraph.plan(AudioGraph.default())
	local built = AudioGraph.build(plan, roblox, { parent = parent, camera = camera })
	t.eq(built.folder.Parent, parent)
	t.eq(built.nodes.Bus_music.ClassName, "AudioFader")
	t.near(built.nodes.Bus_music.Volume, 0.8, 1e-5)
	t.eq(built.nodes.Output.ClassName, "AudioDeviceOutput")
	t.eq(built.nodes.Analyzer_master.ClassName, "AudioAnalyzer")
	t.eq(built.nodes.Listener_world.Parent, camera)
	t.near(built.nodes.Bus_master_fx1_AudioCompressor.Threshold, -6, 1e-5)
	local wire = built.wires.Wire_Bus_sfx_Bus_master
	t.eq(wire.SourceInstance, built.nodes.Bus_sfx)
	t.eq(wire.TargetInstance, built.nodes.Bus_master)
	local count = 0
	for _ in built.wires do
		count += 1
	end
	t.eq(count, #plan.wires)
end)

test("runtime: settings volumes per bus, a static master and linear duck envelopes", function(t)
	local runtime = AudioGraph.runtime(AudioGraph.default())
	local effective = {
		volume = {
			master = 0.5,
			music = 0.25,
			sfx = 0.5,
			ui = 0.5,
			ambience = 0.5,
			dialogue = 0.5,
			world = 0.5,
		},
	}
	local out = runtime:step(0, {}, effective)
	t.eq(out.master, 1, "master fader is the graph's; the user's master is inside each bus volume")
	t.near(out.music, 0.8 * 0.25)
	t.near(out.sfx, 0.5)
	-- dialogue starts: music ducks to 0.4 over 0.15 s (linear), ambience to 0.6 over 0.2 s
	out = runtime:step(0.075, { dialogue = 1 }, effective)
	t.near(runtime:duckGain("music"), 0.7)
	out = runtime:step(0.075, { dialogue = 1 }, effective)
	t.near(runtime:duckGain("music"), 0.4)
	t.near(out.music, 0.8 * 0.25 * 0.4)
	out = runtime:step(1, { dialogue = 1 }, effective)
	t.near(runtime:duckGain("music"), 0.4, 1e-9, "holds while dialogue plays")
	-- dialogue ends: release over 0.6 s
	runtime:step(0.3, {}, effective)
	t.near(runtime:duckGain("music"), 0.7)
	runtime:step(0.3, {}, effective)
	t.near(runtime:duckGain("music"), 1)
	-- an AudioMixer channel gain (fades, scripted ducks) multiplies in
	out = runtime:step(0, {}, effective, { sfx = 0.5 })
	t.near(out.sfx, 0.25)
	t.throws(function()
		runtime:step(-1)
	end)
end)

test("cues validate against the graph; defaults are neutral and complete", function(t)
	local graph = AudioGraph.default()
	t.eq(AudioCues.validate(AudioCues.defaults(), graph), {})
	for id, cue in AudioCues.defaults() do
		t.eq(cue.slot, "sfx_" .. id)
	end
	local problems = AudioCues.validate({
		a = { bus = "master", slot = "a" },
		b = { bus = "sfx", slot = "rbx" .. "assetid://" .. "1" },
		c = { bus = "sfx", slot = "c", volume = { 1, 3 } },
		d = { bus = "ui", slot = "d", spatial = true },
		e = { bus = "sfx", slot = "e", maxConcurrent = 0, pitchVariance = 0.9, cooldown = -1 },
		f = { bus = "nowhere", slot = "f" },
		g = { bus = "sfx", slot = "g", gain = 1 },
	}, graph)
	t.ok(has(problems, "cue a cannot play on master"))
	t.ok(has(problems, "cue b.slot must be a provenance key label"))
	t.ok(has(problems, "cue c.volume range"))
	t.ok(has(problems, "cue d is spatial"))
	t.ok(has(problems, "cue e.maxConcurrent"))
	t.ok(has(problems, "cue e.pitchVariance"))
	t.ok(has(problems, "cue e.cooldown"))
	t.ok(has(problems, "cue f.bus nowhere is not in the graph"))
	t.ok(has(problems, "gain is not a cue field"))
end)

test("cue cooldown refuses a repeat inside the window and admits after it", function(t)
	local cues = AudioCues.new({ click = { bus = "ui", slot = "click", cooldown = 0.1, maxConcurrent = 8 } })
	t.ok(cues:request("click", 0))
	local none, reason = cues:request("click", 0.05)
	t.eq(none, nil)
	t.eq(reason, "cooldown")
	t.ok(cues:request("click", 0.1))
	t.eq(cues:stats().refused, 1)
end)

test("cue maxConcurrent refuses until a voice is released", function(t)
	local cues = AudioCues.new({ hit = { bus = "sfx", slot = "hit", cooldown = 0, maxConcurrent = 2 } })
	local a = cues:request("hit", 0)
	t.ok(cues:request("hit", 0))
	local none, reason = cues:request("hit", 0)
	t.eq(none, nil)
	t.eq(reason, "max_concurrent")
	t.eq(cues:release((a :: any).id), true)
	t.ok(cues:request("hit", 0))
	t.eq(cues:release(999), false)
end)

test("bus and total voice caps steal the weakest lower-priority voice or refuse", function(t)
	local graph = graphWith(function(g)
		g.voices = { total = 3, sfx = 2 }
	end)
	local cues = AudioCues.new({
		low = { bus = "sfx", slot = "low", priority = 1, cooldown = 0, maxConcurrent = 8 },
		high = { bus = "sfx", slot = "high", priority = 8, cooldown = 0, maxConcurrent = 8 },
		ui = { bus = "ui", slot = "ui", priority = 4, cooldown = 0, maxConcurrent = 8 },
	}, { graph = graph })
	local first = cues:request("low", 0)
	cues:request("low", 0)
	local voice, stolen = cues:request("high", 0)
	t.ok(voice, "high steals on a full sfx bus")
	t.eq(#stolen, 1)
	t.eq(stolen[1].id, (first :: any).id, "the oldest of the lowest priority goes first")
	t.ok(cues:request("ui", 0))
	-- total cap 3 reached: another high steals the remaining low voice
	local again, stolenAgain = cues:request("high", 0)
	t.ok(again)
	t.eq(stolenAgain[1].cue, "low")
	local refused, reason = cues:request("low", 0)
	t.eq(refused, nil)
	t.eq(reason, "voices")
	local activity = cues:activity()
	t.eq(activity.sfx, 2)
	t.eq(activity.ui, 1)
	t.eq(activity.master, 3, "voices count on ancestor buses too")
end)

test("missing assets are reported and variation is seeded", function(t)
	local definitions = {
		hit = {
			bus = "sfx",
			slot = "hit",
			volume = { 0.5, 1 },
			pitchVariance = 0.2,
			cooldown = 0,
			maxConcurrent = 16,
		},
		miss = { bus = "sfx", slot = "miss" },
	}
	local assets = { hit = "rbxasset://sounds/example.ogg" }
	local a = AudioCues.new(definitions, { assets = assets, seed = 7 })
	local b = AudioCues.new(definitions, { assets = assets, seed = 7 })
	local none, reason = a:request("miss", 0)
	t.eq(none, nil)
	t.eq(reason, "missing_asset")
	t.eq(select(2, a:request("nope", 0)), "unknown_cue")
	for step = 1, 5 do
		local va: any = a:request("hit", step)
		local vb: any = b:request("hit", step)
		t.eq(va.volume, vb.volume)
		t.eq(va.speed, vb.speed)
		t.ok(va.volume >= 0.5 and va.volume <= 1)
		t.ok(va.speed >= 0.8 and va.speed <= 1.2)
		t.eq(va.content, assets.hit)
	end
end)

test("music starts on the next bar and crossfades with equal power", function(t)
	t.near(Music.boundary(10, nil, nil, nil, "bar", 0.05), 10.05)
	-- 120 bpm, 4/4: bars every 2 s from 1.0
	t.near(Music.boundary(4.2, 1, 120, 4, "bar", 0.05), 5)
	t.near(Music.boundary(4.2, 1, 120, 4, "beat", 0.05), 4.5)
	t.near(Music.boundary(4.96, 1, 120, 4, "bar", 0.05), 7, 1e-9, "inside the lead: the following bar")
	local music = Music.new({
		crossfade = 2,
		tracks = {
			calm = { slot = "music_calm", bpm = 120, beatsPerBar = 4 },
			tense = { slot = "music_tense", volume = 0.8 },
		},
	})
	local first = assert(music:play("calm", 0))
	t.near(first.at, 0.05)
	t.eq(first.previous, nil)
	t.eq(select(2, music:play("calm", 1)), "already_playing")
	t.eq(select(2, music:play("loud", 1)), "unknown_track")
	local second = assert(music:play("tense", 3))
	t.near(second.at, 4.05, 1e-9, "next bar of calm after 3.05")
	t.near(second.stopAt :: number, 6.05)
	local mid = music:gains(5.05)
	t.near(mid.calm, math.cos(math.pi / 4))
	t.near(mid.tense, 0.8 * math.sin(math.pi / 4))
	t.near(mid.calm ^ 2 + (mid.tense / 0.8) ^ 2, 1, 1e-9, "equal power")
	local done = music:gains(7)
	t.eq(done.calm, 0)
	t.near(done.tense, 0.8)
	local stop = assert(music:stop(8, 1))
	t.near(stop.stopAt :: number, 9)
	t.eq(music:current(), nil)
	t.ok(has(Music.validate({ tracks = { a = { slot = "a", bpm = 900 } } }), "bpm"))
end)

local function mixHarness(extra: any?)
	local calls = { play = {}, stop = {}, playing = {} }
	local clock = 0
	local engine = {
		play = function(player: any, at: number?)
			table.insert(calls.play, player.Name .. (if at then "@" .. string.format("%.2f", at) else ""))
			calls.playing[player] = true
		end,
		stop = function(player: any, _at: number?)
			table.insert(calls.stop, player.Name)
			calls.playing[player] = nil
		end,
		isPlaying = function(player: any): boolean
			return calls.playing[player] == true
		end,
		mixerTime = function(): number
			return clock
		end,
		levels = function(_analyzer: any): (number, number)
			return 0.5, 0.25
		end,
		connected = function(wire: any): boolean
			return wire.SourceInstance ~= nil and wire.TargetInstance ~= nil
		end,
	}
	local reports = {}
	local options: any = {
		parent = roblox.Instance.new("Folder"),
		camera = roblox.Instance.new("Camera"),
		assets = {
			sfx_hit_light = "rbxasset://sounds/a.ogg",
			sfx_ui_click = "rbxasset://sounds/b.ogg",
			sfx_footstep = "rbxasset://sounds/c.ogg",
			music_a = "rbxasset://sounds/m1.ogg",
			music_b = "rbxasset://sounds/m2.ogg",
		},
		music = {
			crossfade = 1,
			quantize = "none",
			tracks = { a = { slot = "music_a" }, b = { slot = "music_b" } },
		},
		seed = 1,
		engine = engine,
	}
	for key, value in extra or {} do
		options[key] = value
	end
	local env = {
		roblox = roblox,
		services = {},
		clock = function()
			return clock
		end,
		report = function(message: string)
			table.insert(reports, message)
		end,
	}
	local mix = AudioGraphRoblox.new(env, options)
	return mix, calls, function(value: number)
		clock = value
	end, reports
end

test("AudioGraphRoblox wires voices into bus faders and cleans up finished voices", function(t)
	local mix, calls = mixHarness()
	local built = mix:graph()
	local voice: any = assert(mix:play("hit_light"))
	t.eq(calls.play, { "Voice_1_hit_light" })
	local player = built.folder:FindFirstChild("Voice_1_hit_light")
	t.eq(player.ClassName, "AudioPlayer")
	local wire = player:FindFirstChildOfClass("Wire")
	t.eq(wire.TargetInstance, built.nodes.Bus_sfx)
	t.eq(mix:activity().sfx, 1)
	t.eq(select(2, mix:play("level_up")), "missing_asset")
	t.eq(select(2, mix:play("footstep")), "no_emitter_target")
	local part = roblox.Instance.new("Part")
	local step: any = assert(mix:play("footstep", part))
	local emitter = part:FindFirstChildOfClass("AudioEmitter")
	t.ok(emitter, "spatial voices sound from an AudioEmitter on the target")
	local inspect = mix:inspect()
	t.eq(inspect.wires, inspect.connected)
	t.eq(inspect.hearing, "NOT_VERIFIED")
	-- the hit finishes: the engine reports it stopped after the grace period
	calls.playing[player] = nil
	mix:step(0.05)
	t.eq(mix:activity().sfx, 1, "still inside the grace period")
	mix:step(0.1)
	t.eq(mix:activity().sfx, nil, "finished voice released")
	t.eq(player.Parent, nil, "player returned to the idle list")
	t.eq(mix:stop(step.id), true)
	t.eq(part:FindFirstChildOfClass("AudioEmitter"), nil)
	t.eq(mix:stop(voice.id), false)
	t.near(mix:levels().peak, 0.5)
end)

test("fader automation follows settings and ducking every step", function(t)
	local mix = mixHarness()
	local built = mix:graph()
	local effective =
		{ volume = { master = 1, music = 0.5, sfx = 1, ui = 1, ambience = 1, dialogue = 1, world = 1 } }
	local faders = mix:step(0.016, effective)
	t.near(faders.music, 0.4)
	t.near(built.nodes.Bus_music.Volume, 0.4, 1e-5)
end)

test("music plays through the music bus with a scheduled crossfade", function(t)
	local mix, calls, setClock = mixHarness()
	local built = mix:graph()
	local first = assert(mix:playMusic("a"))
	t.near(first.at, 0.05)
	setClock(2)
	local second = assert(mix:playMusic("b"))
	t.eq(calls.play, { "Music_a@0.05", "Music_b@2.05" })
	t.eq(calls.stop, { "Music_a" })
	setClock(2.55)
	mix:step(0.016)
	local a = built.folder:FindFirstChild("Music_a")
	local b = built.folder:FindFirstChild("Music_b")
	t.near(a.Volume, math.cos(math.pi / 4), 1e-5)
	t.near(b.Volume, math.sin(math.pi / 4), 1e-5)
	t.eq(a:FindFirstChildOfClass("Wire").TargetInstance, built.nodes.Bus_music)
	t.near(second.stopAt, 3.05)
	t.eq(select(2, mix:playMusic("b")), "already_playing")
end)

test("AudioDirector runs on the AudioGraphRoblox backend", function(t)
	local mix, calls = mixHarness()
	local director = AudioDirector.new({
		events = {
			hit_light = { channel = "sfx", looped = false, gain = 0.5, configured = true },
			level_up = { channel = "sfx", looped = false, gain = 1, configured = true },
			ui_click = { channel = "ui", looped = false, gain = 1, configured = false },
		},
		states = {},
	}, AudioMixer.new({ "sfx", "ui" }), mix:backend())
	t.eq(director:emit("hit_light"), true)
	local player = mix:graph().folder:FindFirstChild("Voice_1_hit_light")
	t.ok(player.Volume <= 0.5 + 1e-6, "event gain scales the cue volume")
	t.eq(select(2, director:emit("level_up")), "backend_rejected")
	t.eq(select(2, director:emit("ui_click")), "missing_asset")
	director:destroy()
	t.eq(calls.stop[#calls.stop], "Voice_1_hit_light")
	local parent = mix:graph().folder.Parent
	mix:destroy()
	t.eq(#parent:GetChildren(), 0)
end)

return cases
