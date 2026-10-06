--!strict
-- @tier T3
-- probe: av_audiograph_wires
-- probe: av_audio_master_level
-- AudioGraphRoblox: runs an audio-graph/1 mix on the Audio API in Studio. It builds the graph
-- (AudioGraph.plan/build), admits voices through AudioCues, plays AudioPlayers wired into bus
-- faders (spatial cues through an AudioEmitter on the target and the world bus's camera
-- AudioListener), writes fader automation every frame (AudioGraph.runtime: settings/1 volumes
-- and ducking), schedules music through Music (Play(atTime)/Stop(atTime) on the mixer clock) and
-- reads the master AudioAnalyzer. It also implements the AudioDirector backend
-- ({ play(key, def) -> boolean, stop(key) }), so AudioDirector's trace and missing_asset stay.
--   AudioGraphRoblox.new(env, options) -> mix
--   mix:play(cueId, where?) -> (voice?, reason?)  where: the Attachment, BasePart or Model a
--       spatial cue sounds from
--   mix:stop(voiceId), mix:stopCue(cueId)
--   mix:playMusic(trackId, options?) -> (plan?, reason?), mix:stopMusic(fade?)
--   mix:step(dt, effective?, mixerGains?)  call every frame; never yields
--   mix:levels() -> { peak, rms } on master; mix:inspect(); mix:backend(); mix:destroy()
-- Assets: options.assets maps cue/track slots to approved content strings; nothing here holds an
-- id. 3D note: for emitters to pass through the master fader, SoundService.DefaultListenerLocation
-- should be None (ReadOnly to scripts; set in Studio); inspect() reports it (behaviour UNVERIFIED).
-- options.engine overrides the engine calls (play, stop, isPlaying, mixerTime, levels, connected)
-- for Lune specs, where AudioPlayer methods and Wire.Connected do not exist.
local AudioCues = require("./AudioCues")
local AudioGraph = require("./AudioGraph")
local Music = require("./Music")

local AudioGraphRoblox = {}

AudioGraphRoblox.IDLE_PER_CONTENT = 4 -- convention: idle AudioPlayers kept per content string
AudioGraphRoblox.FINISH_GRACE = 0.1 -- seconds before a non-looping voice may count as finished

export type Options = {
	parent: any,
	graph: any?,
	cues: { [string]: any }?,
	music: any?,
	assets: { [string]: string }?,
	camera: any?,
	effective: any?,
	seed: (number | string)?,
	silent: boolean?,
	engine: any?,
}

function AudioGraphRoblox.new(env: any, options: Options)
	assert(type(options) == "table" and options.parent ~= nil, "AudioGraphRoblox: options.parent is required")
	local lib = if env.roblox then env.roblox else env
	local services = env.services or {}
	local soundService = services.SoundService
	local report = env.report or function(_message: string) end
	local engine: any = {
		play = function(player: any, at: number?)
			if at ~= nil then
				player:Play(at)
			else
				player:Play()
			end
		end,
		stop = function(player: any, at: number?)
			if at ~= nil then
				player:Stop(at)
			else
				player:Stop()
			end
		end,
		isPlaying = function(player: any): boolean
			return player.IsPlaying
		end,
		mixerTime = function(): number
			if soundService ~= nil then
				return soundService:GetMixerTime()
			end
			return env.clock()
		end,
		levels = function(analyzer: any): (number, number)
			return analyzer.PeakLevel, analyzer.RmsLevel
		end,
		connected = function(wire: any): boolean
			return wire.Connected
		end,
	}
	for key, fn in options.engine or {} do
		engine[key] = fn
	end

	local graph = options.graph or AudioGraph.default()
	local plan = AudioGraph.plan(graph, { silent = options.silent })
	local built = AudioGraph.build(plan, env, { parent = options.parent, camera = options.camera })
	local runtime = AudioGraph.runtime(graph)
	local cues = AudioCues.new(
		options.cues or AudioCues.defaults(),
		{ graph = graph, assets = options.assets or {}, seed = options.seed }
	)
	local music = if options.music then Music.new(options.music) else nil
	local effective: any = options.effective or {}
	local voices: { [number]: any } = {}
	local idle: { [string]: { any } } = {}
	local musicPlayers: { [string]: any } = {}
	local elapsed = 0
	local closed = false

	local function wire(from: any, to: any, name: string): any
		local instance = lib.Instance.new("Wire")
		instance.Name = name
		instance.SourceInstance = from
		instance.TargetInstance = to
		instance.Parent = from
		return instance
	end

	local function acquire(content: string): any
		local list = idle[content]
		if list and #list > 0 then
			return table.remove(list)
		end
		local player = lib.Instance.new("AudioPlayer")
		player.Asset = content
		return player
	end

	local function recycle(player: any, content: string)
		for _, child in player:GetChildren() do
			child:Destroy() -- its output Wire (an emitter is parented to the target, see stopVoice)
		end
		player.Parent = nil
		local list = idle[content] or {}
		idle[content] = list
		if #list < AudioGraphRoblox.IDLE_PER_CONTENT and not closed then
			table.insert(list, player)
		else
			player:Destroy()
		end
	end

	local function stopVoice(id: number, alreadyReleased: boolean?)
		local record = voices[id]
		if record == nil then
			return
		end
		voices[id] = nil
		if not alreadyReleased then
			cues:release(id)
		end
		pcall(engine.stop, record.player)
		if record.emitter then
			record.emitter:Destroy()
		end
		recycle(record.player, record.content)
	end

	local api: any = {}

	function api:play(cueId: string, where: any?): (any?, string?)
		if closed then
			return nil, "closed"
		end
		local definition = cues:cue(cueId)
		if definition and definition.spatial and where == nil then
			return nil, "no_emitter_target"
		end
		local voice, stolen = cues:request(cueId, elapsed)
		if voice == nil then
			return nil, stolen
		end
		for _, victim in stolen do
			stopVoice(victim.id, true)
		end
		local player = acquire(voice.content :: string)
		player.Name = "Voice_" .. voice.id .. "_" .. cueId
		player.Volume = voice.volume
		player.PlaybackSpeed = voice.speed
		player.Looping = voice.loop
		player.Parent = built.folder
		local record = { player = player, content = voice.content, voice = voice, started = elapsed }
		if voice.spatial then
			local emitter = lib.Instance.new("AudioEmitter")
			emitter.Name = "Emitter_" .. voice.id
			emitter.Parent = where
			wire(player, emitter, "Out")
			record.emitter = emitter
		else
			wire(player, built.nodes[plan.inputs[voice.bus]], "Out")
		end
		voices[voice.id] = record
		local ok, err = pcall(engine.play, player)
		if not ok then
			report("AudioGraphRoblox: play " .. cueId .. " failed: " .. tostring(err))
			stopVoice(voice.id)
			return nil, "play_failed"
		end
		return voice, nil
	end

	function api:stop(voiceId: number): boolean
		if voices[voiceId] == nil then
			return false
		end
		stopVoice(voiceId)
		return true
	end

	function api:stopCue(cueId: string): number
		local ids = {}
		for id, record in voices do
			if record.voice.cue == cueId then
				table.insert(ids, id)
			end
		end
		table.sort(ids)
		for _, id in ids do
			stopVoice(id)
		end
		return #ids
	end

	function api:playMusic(trackId: string, playOptions: any?): (any?, string?)
		assert(music ~= nil, "AudioGraphRoblox: options.music is required for music")
		local track = options.music.tracks[trackId]
		local content = track and (options.assets or {})[track.slot]
		if track ~= nil and (type(content) ~= "string" or content == "") then
			return nil, "missing_asset"
		end
		local now = engine.mixerTime()
		local schedule, reason = music:play(trackId, now, playOptions)
		if schedule == nil then
			return nil, reason
		end
		local player = musicPlayers[trackId]
		if player == nil then
			player = lib.Instance.new("AudioPlayer")
			player.Name = "Music_" .. trackId
			player.Asset = content
			player.Looping = true
			if track.loopRegion then
				player.LoopRegion = lib.NumberRange.new(track.loopRegion[1], track.loopRegion[2])
			end
			player.Parent = built.folder
			wire(player, built.nodes[plan.inputs.music], "Out")
			musicPlayers[trackId] = player
		end
		player.Volume = 0
		engine.play(player, schedule.at)
		if schedule.previous and musicPlayers[schedule.previous] then
			engine.stop(musicPlayers[schedule.previous], schedule.stopAt)
		end
		return schedule, nil
	end

	function api:stopMusic(fade: number?): any?
		if music == nil then
			return nil
		end
		local schedule = music:stop(engine.mixerTime(), fade)
		if schedule and schedule.previous and musicPlayers[schedule.previous] then
			engine.stop(musicPlayers[schedule.previous], schedule.stopAt)
		end
		return schedule
	end

	-- Fader automation, finished-voice cleanup and music gains. Returns the fader volumes.
	function api:step(dt: number, newEffective: any?, mixerGains: { [string]: number }?): { [string]: number }
		if closed then
			return {}
		end
		elapsed += dt
		if newEffective ~= nil then
			effective = newEffective
		end
		local ids = {}
		for id in voices do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local record = voices[id]
			if
				not record.voice.loop
				and elapsed - record.started >= AudioGraphRoblox.FINISH_GRACE
				and not engine.isPlaying(record.player)
			then
				stopVoice(id)
			end
		end
		local faders = runtime:step(dt, cues:activity(), effective, mixerGains)
		for bus, volume in faders do
			built.nodes[plan.inputs[bus]].Volume = volume
		end
		if music ~= nil then
			local gains = music:gains(engine.mixerTime())
			for trackId, player in musicPlayers do
				player.Volume = gains[trackId] or 0
			end
		end
		return faders
	end

	function api:levels(): { peak: number, rms: number }
		local peak, rms = engine.levels(built.nodes.Analyzer_master)
		return { peak = peak, rms = rms }
	end

	function api:inspect(): any
		local total, connected = 0, 0
		local broken = {}
		for name, instance in built.wires do
			total += 1
			if engine.connected(instance) then
				connected += 1
			else
				table.insert(broken, name)
			end
		end
		table.sort(broken)
		local listener = nil
		if soundService ~= nil then
			local ok, value = pcall(function()
				return tostring(soundService.DefaultListenerLocation)
			end)
			listener = if ok then value else nil
		end
		return {
			schema = AudioGraph.SCHEMA,
			buses = table.clone(plan.buses),
			wires = total,
			connected = connected,
			broken = broken,
			defaultListenerLocation = listener,
			voices = cues:stats(),
			hearing = "NOT_VERIFIED",
		}
	end

	function api:activity(): { [string]: number }
		return cues:activity()
	end

	-- AudioDirector backend: an event key is a cue id; def.gain scales the cue volume.
	function api:backend(): any
		return {
			play = function(key: string, definition: any): boolean
				local voice = api:play(key)
				if voice and definition and type(definition.gain) == "number" then
					local record = voices[voice.id]
					record.player.Volume = voice.volume * definition.gain
				end
				return voice ~= nil
			end,
			stop = function(key: string)
				api:stopCue(key)
			end,
		}
	end

	function api:graph(): any
		return built
	end

	function api:destroy()
		if closed then
			return
		end
		closed = true
		local ids = {}
		for id in voices do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			stopVoice(id)
		end
		for _, player in musicPlayers do
			pcall(engine.stop, player)
			player:Destroy()
		end
		for _, list in idle do
			for _, player in list do
				player:Destroy()
			end
		end
		table.clear(idle)
		for _, node in built.nodes do
			if node.Parent ~= built.folder then
				node:Destroy() -- the camera listener
			end
		end
		built.folder:Destroy()
	end

	return api
end

return AudioGraphRoblox
