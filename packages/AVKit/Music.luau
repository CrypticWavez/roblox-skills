--!strict
-- @tier T0
-- Music: scheduled music transitions for the audio-graph/1 music bus. Tracks are data
-- ({ slot, bpm?, beatsPerBar?, loopRegion?, volume? }); a transition starts the next track on
-- the next beat or bar of the playing track (quantize) and crossfades with equal-power curves.
-- The plan's `at` times are mixer-clock seconds: AVKit/AudioGraphRoblox passes them to
-- AudioPlayer:Play(atTime)/Stop(atTime), which schedule against SoundService:GetMixerTime()
-- (docs classes/AudioPlayer; sample-accurate scheduling is T3 until probed). Pure and
-- deterministic: the caller supplies `now`.
--   Music.new(config) -> music
--   music:play(id, now, options?) -> (plan?, reason?)   reasons: unknown_track, already_playing
--   music:stop(now, fade?) -> plan?
--   music:gains(now) -> { [trackId] = 0..1 } (track volume x crossfade curve)
--   Music.boundary(now, startedAt, bpm, beatsPerBar, quantize, lead) -> next start time
local Music = {}

Music.LEAD = 0.05 -- convention: seconds of scheduling headroom before a quantized start
Music.QUANTIZE = table.freeze({ "none", "beat", "bar" })

local TRACK_KEYS = { slot = true, bpm = true, beatsPerBar = true, loopRegion = true, volume = true }

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function label(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function sortedKeys(map: any): { string }
	local keys = {}
	for key in map do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	return keys
end

function Music.validate(config: any): { string }
	local problems = {}
	if type(config) ~= "table" or type(config.tracks) ~= "table" then
		return { "music config needs tracks" }
	end
	for _, key in sortedKeys(config) do
		if key ~= "tracks" and key ~= "crossfade" and key ~= "quantize" then
			table.insert(problems, key .. " is not a music key")
		end
	end
	if
		config.crossfade ~= nil
		and not (finite(config.crossfade) and config.crossfade >= 0 and config.crossfade <= 10)
	then
		table.insert(problems, "crossfade must be within 0..10 s")
	end
	if config.quantize ~= nil and not table.find(Music.QUANTIZE, config.quantize) then
		table.insert(problems, "quantize must be none, beat or bar")
	end
	for _, id in sortedKeys(config.tracks) do
		local track = config.tracks[id]
		local where = "track " .. id
		if not label(id) then
			table.insert(problems, where .. ": id must be a label")
		end
		if type(track) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		for _, key in sortedKeys(track) do
			if not TRACK_KEYS[key] then
				table.insert(problems, where .. ": " .. key .. " is not a track field")
			end
		end
		if not label(track.slot) then
			table.insert(problems, where .. ".slot must be a provenance key label")
		end
		if track.bpm ~= nil and not (finite(track.bpm) and track.bpm >= 20 and track.bpm <= 300) then
			table.insert(problems, where .. ".bpm must be within 20..300")
		end
		if
			track.beatsPerBar ~= nil
			and not (
				finite(track.beatsPerBar)
				and track.beatsPerBar % 1 == 0
				and track.beatsPerBar >= 1
				and track.beatsPerBar <= 16
			)
		then
			table.insert(problems, where .. ".beatsPerBar must be a whole number 1..16")
		end
		local region = track.loopRegion
		if region ~= nil then
			if
				type(region) ~= "table"
				or not finite(region[1])
				or not finite(region[2])
				or region[1] < 0
				or region[2] <= region[1]
			then
				table.insert(problems, where .. ".loopRegion must be { start, end } seconds with end > start")
			end
		end
		if track.volume ~= nil and not (finite(track.volume) and track.volume >= 0 and track.volume <= 2) then
			table.insert(problems, where .. ".volume must be within 0..2")
		end
	end
	return problems
end

-- Next start time >= now + lead on the playing track's grid (beat or bar from startedAt).
function Music.boundary(
	now: number,
	startedAt: number?,
	bpm: number?,
	beatsPerBar: number?,
	quantize: string,
	lead: number?
): number
	local earliest = now + (lead or Music.LEAD)
	if quantize == "none" or startedAt == nil or bpm == nil then
		return earliest
	end
	local beat = 60 / bpm
	local step = if quantize == "bar" then beat * (beatsPerBar or 4) else beat
	local elapsed = earliest - startedAt
	if elapsed <= 0 then
		return startedAt
	end
	local index = math.ceil(elapsed / step - 1e-9)
	return startedAt + index * step
end

export type Fade = { track: string, at: number, duration: number, direction: "in" | "out" }
export type Plan = {
	track: string?,
	at: number,
	stopAt: number?,
	previous: string?,
	crossfade: number,
	fades: { Fade },
}
export type PlayOptions = { quantize: string?, crossfade: number? }

function Music.new(config: any)
	local problems = Music.validate(config)
	assert(#problems == 0, "Music: " .. table.concat(problems, "; "))
	local tracks = config.tracks
	local defaultCrossfade = config.crossfade or 2
	local defaultQuantize = config.quantize or "bar"
	local current: string? = nil
	local startedAt: number? = nil
	local fades: { Fade } = {}
	local api = {}

	local function prune(now: number)
		for index = #fades, 1, -1 do
			local fade = fades[index]
			if fade.direction == "out" and now >= fade.at + fade.duration then
				table.remove(fades, index)
			end
		end
	end

	function api:play(id: string, now: number, options: PlayOptions?): (Plan?, string?)
		assert(finite(now), "Music: now must be a finite number")
		if tracks[id] == nil then
			return nil, "unknown_track"
		end
		if current == id then
			return nil, "already_playing"
		end
		local opts: PlayOptions = options or {}
		local quantize = opts.quantize or defaultQuantize
		assert(table.find(Music.QUANTIZE, quantize), "Music: quantize must be none, beat or bar")
		local crossfade = if opts.crossfade ~= nil then opts.crossfade else defaultCrossfade
		assert(
			finite(crossfade) and crossfade >= 0 and crossfade <= 10,
			"Music: crossfade must be within 0..10"
		)
		prune(now)
		local playing = if current then tracks[current] else nil
		local at = Music.boundary(
			now,
			startedAt,
			playing and playing.bpm,
			playing and playing.beatsPerBar,
			quantize,
			Music.LEAD
		)
		local plan: Plan = { track = id, at = at, previous = current, crossfade = crossfade, fades = {} }
		if current ~= nil then
			plan.stopAt = at + crossfade
			for index = #fades, 1, -1 do
				if fades[index].track == current then
					table.remove(fades, index)
				end
			end
			local out: Fade = { track = current, at = at, duration = crossfade, direction = "out" }
			table.insert(plan.fades, out)
			table.insert(fades, out)
		end
		local fadeIn: Fade =
			{ track = id, at = at, duration = if current then crossfade else 0, direction = "in" }
		table.insert(plan.fades, fadeIn)
		-- a track fading back in replaces its fade-out
		for index = #fades, 1, -1 do
			if fades[index].track == id then
				table.remove(fades, index)
			end
		end
		table.insert(fades, fadeIn)
		current, startedAt = id, at
		return plan, nil
	end

	function api:stop(now: number, fade: number?): Plan?
		assert(finite(now), "Music: now must be a finite number")
		if current == nil then
			return nil
		end
		local duration = fade or defaultCrossfade
		local out: Fade = { track = current, at = now, duration = duration, direction = "out" }
		for index = #fades, 1, -1 do
			if fades[index].track == current then
				table.remove(fades, index)
			end
		end
		table.insert(fades, out)
		local plan: Plan = {
			track = nil,
			at = now,
			stopAt = now + duration,
			previous = current,
			crossfade = duration,
			fades = { out },
		}
		current, startedAt = nil, nil
		return plan
	end

	-- Equal-power curves: fade-in sin(x pi/2), fade-out cos(x pi/2), x = progress 0..1.
	function api:gains(now: number): { [string]: number }
		local result = {}
		for _, fade in fades do
			local x = if fade.duration <= 0
				then (if now >= fade.at then 1 else 0)
				else math.clamp((now - fade.at) / fade.duration, 0, 1)
			local curve = if fade.direction == "in"
				then math.sin(x * math.pi / 2)
				else math.cos(x * math.pi / 2)
			if curve < 1e-6 then
				curve = 0
			end
			local volume = tracks[fade.track].volume or 1
			result[fade.track] = math.max(result[fade.track] or 0, curve * volume)
		end
		return result
	end

	function api:current(): (string?, number?)
		return current, startedAt
	end

	return api
end

return Music
