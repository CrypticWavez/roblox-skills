--!strict
-- @tier T0
-- Cinematics: data-driven cutscenes in the cinematics/1 format (docs/uikit.md "Cinematics").
-- A cutscene is plain data:
--   { schema = "cinematics/1", id, duration, space = "world" | "anchor",
--     camera = { interpolation = "catmull_rom" | "linear" | "hold", timing = "keys" | "constant_speed",
--                keys = { { t, position = { x, y, z }, lookAt = { x, y, z } | orientation =
--                           { pitch, yaw, roll } (degrees), roll?, fov, ease? } } },
--     letterbox = { { t, v, ease? } },   bar height as a fraction of the screen, 0-0.25
--     fades = { { t, v, ease? } },       black overlay opacity, 0-1
--     subtitles = { { t, duration, key } },   localisation keys, never text
--     events = { { t, name, payload?, onSkip = "fire" | "drop" } },
--     skip = { allowed, after, hold } }
-- sample(cin, t) is a pure function of time (exact at keys, the same at any frame rate);
-- eventsBetween(cin, t0, t1) returns events with t0 < t <= t1: a frame showing time t1 fires what
-- it reached, stepping (prev, t] fires each event once, and the first frame uses t0 = -huge so
-- t = 0 events fire on it. The player flushes the rest when it ends at t = duration.
-- bake(cin, hz) and digest(cin, hz) give a deterministic sample table and its hash (golden
-- tests/golden/cinematics-orbit.json). Cinematics.player is the pure playback state machine
-- (time, events, hold-to-skip) that CinematicsRoblox drives from RunService.PreRender.
-- Positions are studs; with space = "anchor" they are relative to a CFrame passed to play().
-- An ease on a key shapes the segment leaving it (UIKit/Ease names, default Linear.In).
local Check = require("../GameKit/Check")
local Ease = require("../UIKit/Ease")
local Json = require("../GameKit/Json")
local Rng = require("../ProcGen/Rng")
local Spline = require("./Spline")

local Cinematics = {}
Cinematics.SCHEMA = "cinematics/1"
Cinematics.BAKE_SCHEMA = "cinematics-bake/1"
Cinematics.LIMITS = table.freeze({
	duration = 300, -- seconds
	keys = 256,
	events = 256,
	subtitles = 256,
	channelKeys = 256,
	fovMin = 1, -- Camera.FieldOfView range
	fovMax = 120,
	letterboxMax = 0.25,
	bakeHz = 240,
})
Cinematics.DEFAULT_SKIP = table.freeze({ allowed = true, after = 0.75, hold = 0.5 }) -- convention

export type Vec = { number }
export type Key = {
	t: number,
	position: Vec,
	lookAt: Vec?,
	orientation: Vec?,
	roll: number?,
	fov: number,
	ease: string?,
}
export type ChannelKey = { t: number, v: number, ease: string? }
export type Event = { t: number, name: string, payload: any?, onSkip: string? }
export type Subtitle = { t: number, duration: number, key: string }
export type Cinematic = { [string]: any }
export type Sample = {
	t: number,
	position: Vec,
	lookAt: Vec?,
	orientation: Vec?,
	roll: number,
	fov: number,
	letterbox: number,
	fade: number,
	subtitle: string?,
}

local KEYS = {
	"schema",
	"id",
	"duration",
	"space",
	"camera",
	"letterbox",
	"fades",
	"subtitles",
	"events",
	"skip",
}

local function isVec(value: any): boolean
	return type(value) == "table"
		and #value == 3
		and Check.finite(value[1])
		and Check.finite(value[2])
		and Check.finite(value[3])
end

local function sub(a: Vec, b: Vec): Vec
	return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end

local function length(a: Vec): number
	return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3])
end

-- Problems with a list of timed entries: times finite, within 0..duration, strictly increasing.
local function timeline(list: any, duration: number, where: string, max: number, problems: { string })
	if type(list) ~= "table" then
		table.insert(problems, where .. " must be a list")
		return
	end
	if #list > max then
		table.insert(problems, string.format("%s holds at most %d entries", where, max))
	end
	local last = -math.huge
	for index, item in list do
		local at = where .. "[" .. index .. "]"
		if type(item) ~= "table" or not Check.finite(item.t) then
			table.insert(problems, at .. ".t must be a finite number")
			continue
		end
		if item.t < 0 or item.t > duration + 1e-9 then
			table.insert(problems, at .. ".t must be within 0..duration")
		end
		if item.t <= last then
			table.insert(problems, at .. ".t must be greater than the previous entry's (strictly increasing)")
		end
		last = item.t
		if item.ease ~= nil and not Ease.valid(item.ease) then
			table.insert(problems, at .. ".ease " .. tostring(item.ease) .. " is not Style.Direction")
		end
	end
end

local function channel(list: any, duration: number, where: string, max: number, problems: { string })
	if list == nil then
		return
	end
	timeline(list, duration, where, Cinematics.LIMITS.channelKeys, problems)
	if type(list) ~= "table" then
		return
	end
	for index, item in list do
		if type(item) == "table" and not (Check.finite(item.v) and item.v >= 0 and item.v <= max) then
			table.insert(problems, string.format("%s[%d].v must be within 0-%s", where, index, tostring(max)))
		end
	end
end

-- Problems with a cutscene (empty when valid).
function Cinematics.validate(cin: any): { string }
	if type(cin) ~= "table" then
		return { "cutscene must be a table" }
	end
	local problems = {}
	for key in cin do
		if not table.find(KEYS, key) then
			table.insert(problems, "unknown field " .. tostring(key))
		end
	end
	if cin.schema ~= Cinematics.SCHEMA then
		table.insert(problems, "schema must be " .. Cinematics.SCHEMA)
	end
	if type(cin.id) ~= "string" or not string.match(cin.id, "^[a-z][a-z0-9_]*$") or #cin.id > 64 then
		table.insert(problems, "id must be a lower_snake label")
	end
	local duration = cin.duration
	if not (Check.finite(duration) and duration > 0 and duration <= Cinematics.LIMITS.duration) then
		table.insert(
			problems,
			"duration must be within 0-" .. Cinematics.LIMITS.duration .. " s (exclusive of 0)"
		)
		return problems
	end
	if cin.space ~= nil and cin.space ~= "world" and cin.space ~= "anchor" then
		table.insert(problems, "space must be world or anchor")
	end
	local camera = cin.camera
	if type(camera) ~= "table" or type(camera.keys) ~= "table" then
		table.insert(problems, "camera.keys must be a list")
		return problems
	end
	if
		camera.interpolation ~= nil
		and not table.find({ "catmull_rom", "linear", "hold" }, camera.interpolation)
	then
		table.insert(problems, "camera.interpolation must be catmull_rom, linear or hold")
	end
	if camera.timing ~= nil and camera.timing ~= "keys" and camera.timing ~= "constant_speed" then
		table.insert(problems, "camera.timing must be keys or constant_speed")
	end
	local keys = camera.keys
	if #keys < 2 then
		table.insert(problems, "camera.keys needs at least two keys")
	end
	timeline(keys, duration, "camera.keys", Cinematics.LIMITS.keys, problems)
	local mode: string? = nil
	for index, key in keys do
		local at = "camera.keys[" .. index .. "]"
		if type(key) ~= "table" then
			continue
		end
		if not isVec(key.position) then
			table.insert(problems, at .. ".position must be { x, y, z }")
		end
		local keyMode = if key.lookAt ~= nil
			then "lookAt"
			elseif key.orientation ~= nil then "orientation"
			else nil
		if key.lookAt ~= nil and key.orientation ~= nil then
			table.insert(problems, at .. ": use lookAt or orientation, not both")
		elseif keyMode == nil then
			table.insert(problems, at .. " needs lookAt or orientation")
		elseif mode == nil then
			mode = keyMode
		elseif mode ~= keyMode then
			table.insert(problems, at .. ": every key uses the same aim (all lookAt or all orientation)")
		end
		if key.lookAt ~= nil then
			if not isVec(key.lookAt) then
				table.insert(problems, at .. ".lookAt must be { x, y, z }")
			elseif isVec(key.position) then
				local dir = sub(key.lookAt, key.position)
				local len = length(dir)
				if len < 1e-3 then
					table.insert(problems, at .. ": lookAt equals position")
				elseif math.abs(dir[2]) / len > 0.999 then
					table.insert(
						problems,
						at .. ": looking straight up or down is ambiguous (use orientation)"
					)
				end
			end
		end
		if key.orientation ~= nil and not isVec(key.orientation) then
			table.insert(problems, at .. ".orientation must be { pitch, yaw, roll } in degrees")
		end
		if key.roll ~= nil and not (Check.finite(key.roll) and math.abs(key.roll) <= 180) then
			table.insert(problems, at .. ".roll must be within -180..180 degrees")
		end
		local fov = key.fov
		if
			not (Check.finite(fov) and fov >= Cinematics.LIMITS.fovMin and fov <= Cinematics.LIMITS.fovMax)
		then
			table.insert(
				problems,
				string.format(
					"%s.fov must be within %d-%d",
					at,
					Cinematics.LIMITS.fovMin,
					Cinematics.LIMITS.fovMax
				)
			)
		end
	end
	if #keys >= 2 and type(keys[1]) == "table" and type(keys[#keys]) == "table" then
		if keys[1].t ~= 0 then
			table.insert(problems, "camera.keys must start at t = 0")
		end
		if keys[#keys].t ~= duration then
			table.insert(problems, "camera.keys must end at t = duration")
		end
	end
	channel(cin.letterbox, duration, "letterbox", Cinematics.LIMITS.letterboxMax, problems)
	channel(cin.fades, duration, "fades", 1, problems)
	if cin.subtitles ~= nil then
		timeline(cin.subtitles, duration, "subtitles", Cinematics.LIMITS.subtitles, problems)
		if type(cin.subtitles) == "table" then
			for index, item in cin.subtitles do
				local at = "subtitles[" .. index .. "]"
				if type(item) ~= "table" then
					continue
				end
				if not (Check.finite(item.duration) and item.duration > 0) then
					table.insert(problems, at .. ".duration must be > 0")
				end
				if type(item.key) ~= "string" or not string.match(item.key, "^[%w_][%w_%.%-]*$") then
					table.insert(problems, at .. ".key must be a localisation key")
				end
			end
		end
	end
	if cin.events ~= nil then
		if type(cin.events) ~= "table" then
			table.insert(problems, "events must be a list")
		else
			if #cin.events > Cinematics.LIMITS.events then
				table.insert(problems, "events holds at most " .. Cinematics.LIMITS.events .. " entries")
			end
			local last = -math.huge
			for index, event in cin.events do
				local at = "events[" .. index .. "]"
				if type(event) ~= "table" or not Check.finite(event.t) then
					table.insert(problems, at .. ".t must be a finite number")
					continue
				end
				if event.t < 0 or event.t > duration then
					table.insert(problems, at .. ".t must be within 0..duration")
				end
				if event.t < last then
					table.insert(problems, at .. ".t must not be before the previous event (sorted)")
				end
				last = event.t
				if not Check.label(event.name) then
					table.insert(problems, at .. ".name must be a lower_snake label")
				end
				if event.onSkip ~= nil and event.onSkip ~= "fire" and event.onSkip ~= "drop" then
					table.insert(problems, at .. ".onSkip must be fire or drop")
				end
				if event.payload ~= nil then
					local ok = pcall(Json.encode, event.payload)
					if not ok then
						table.insert(problems, at .. ".payload must be plain JSON data")
					end
				end
			end
		end
	end
	if cin.skip ~= nil then
		local skip = cin.skip
		if type(skip) ~= "table" then
			table.insert(problems, "skip must be a table")
		else
			if skip.allowed ~= nil and type(skip.allowed) ~= "boolean" then
				table.insert(problems, "skip.allowed must be a boolean")
			end
			for _, field in { "after", "hold" } do
				if
					skip[field] ~= nil
					and not (Check.finite(skip[field]) and skip[field] >= 0 and skip[field] <= 10)
				then
					table.insert(problems, "skip." .. field .. " must be within 0-10 s")
				end
			end
		end
	end
	return problems
end

-- A frozen copy of a valid cutscene; raises with every problem otherwise.
function Cinematics.define(cin: any): Cinematic
	local problems = Cinematics.validate(cin)
	if #problems > 0 then
		error("Cinematics.define: " .. table.concat(problems, "; "), 2)
	end
	return Check.freeze(Check.copy(cin))
end

-- ------------------------------------------------------------------ sampling

local function eased(name: string?, u: number): number
	local style, direction = Ease.parse(name or "Linear.In")
	return Ease.get(style, direction, u)
end

-- Index i with keys[i].t <= t < keys[i + 1].t (clamped to the last segment) and local u.
local function locate(list: { any }, t: number): (number, number)
	local n = #list
	if t <= list[1].t then
		return 1, 0
	end
	if t >= list[n].t then
		return n - 1, 1
	end
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if list[mid].t <= t then
			lo = mid
		else
			hi = mid
		end
	end
	local a, b = list[lo], list[lo + 1]
	return lo, (t - a.t) / (b.t - a.t)
end

-- A scalar channel at t: held before the first key and after the last; eases between keys.
local function channelAt(list: { ChannelKey }?, t: number, default: number): number
	if list == nil or #list == 0 then
		return default
	end
	if #list == 1 or t <= list[1].t then
		return list[1].v
	end
	if t >= list[#list].t then
		return list[#list].v
	end
	local index, u = locate(list, t)
	local a, b = list[index], list[index + 1]
	return a.v + (b.v - a.v) * eased(a.ease, u)
end
Cinematics.channelAt = channelAt

-- Shortest-path angle interpolation in degrees.
local function lerpAngle(a: number, b: number, u: number): number
	local delta = ((b - a + 180) % 360) - 180
	return a + delta * u
end

local function vecAt(points: { Vec }, segment: number, u: number, interpolation: string): Vec
	if interpolation == "hold" then
		return table.clone(if u >= 1 then points[segment + 1] else points[segment])
	elseif interpolation == "linear" then
		return Spline.lerp(points[segment], points[segment + 1], u)
	end
	return Spline.point(points, segment, u)
end

type Prepared = { positions: { Vec }, aims: { Vec }, arc: Spline.ArcTable? }
local prepared: { [any]: Prepared } = setmetatable({}, { __mode = "k" }) :: any

local function prepare(cin: Cinematic): Prepared
	local cached = prepared[cin]
	if cached then
		return cached
	end
	local positions, aims = {}, {}
	for index, key in cin.camera.keys do
		positions[index] = key.position
		aims[index] = key.lookAt or key.orientation
	end
	local arc = nil
	if cin.camera.timing == "constant_speed" and (cin.camera.interpolation or "catmull_rom") ~= "hold" then
		arc = Spline.arcTable(positions, 64)
	end
	local out = { positions = positions, aims = aims, arc = arc }
	-- Only frozen (defined) cutscenes are cached: a mutable table could change under the cache.
	if table.isfrozen(cin) then
		prepared[cin] = out
	end
	return out
end

-- The camera and overlay state at time t (clamped to 0..duration). Exact at key times for the
-- keys timing; constant_speed walks the position path at a constant rate from the first key
-- to the last (interior key times are ignored, aims and fov follow the same path position).
function Cinematics.sample(cin: Cinematic, t: number): Sample
	assert(Check.finite(t), "Cinematics.sample: t must be a finite number")
	local time = math.clamp(t, 0, cin.duration)
	local keys = cin.camera.keys
	local interpolation = cin.camera.interpolation or "catmull_rom"
	local data = prepare(cin)
	local segment, u
	if data.arc then
		local arc = data.arc :: Spline.ArcTable
		local first, last = keys[1].t, keys[#keys].t
		local alpha = if last > first then math.clamp((time - first) / (last - first), 0, 1) else 1
		alpha = eased(keys[1].ease, alpha)
		segment, u = Spline.atDistance(arc, alpha * arc.total)
	else
		segment, u = locate(keys, time)
		u = eased(keys[segment].ease, u)
	end
	local a, b = keys[segment], keys[segment + 1]
	local position = vecAt(data.positions, segment, u, interpolation)
	local holdU = if interpolation == "hold" then (if u >= 1 then 1 else 0) else u
	local out: Sample = {
		t = time,
		position = position,
		roll = 0,
		fov = a.fov + (b.fov - a.fov) * holdU,
		letterbox = channelAt(cin.letterbox, time, 0),
		fade = channelAt(cin.fades, time, 0),
		subtitle = nil,
	}
	if a.lookAt then
		out.lookAt = vecAt(data.aims, segment, u, interpolation)
		out.roll = lerpAngle(a.roll or 0, b.roll or 0, holdU)
	else
		local oa, ob = a.orientation :: Vec, b.orientation :: Vec
		local orientation: Vec = {
			lerpAngle(oa[1], ob[1], holdU),
			lerpAngle(oa[2], ob[2], holdU),
			lerpAngle(oa[3], ob[3], holdU),
		}
		out.orientation = orientation
		out.roll = orientation[3]
	end
	for _, line in cin.subtitles or {} do
		if time >= line.t and time < line.t + line.duration then
			out.subtitle = line.key
		end
	end
	return out
end

-- Events with t0 < t <= t1 in order (half-open, so consecutive frames never fire one twice and
-- the frame that reaches an event's time fires it).
function Cinematics.eventsBetween(cin: Cinematic, t0: number, t1: number): { Event }
	local out = {}
	if t1 <= t0 then
		return out
	end
	for _, event in cin.events or {} do
		if event.t > t0 and event.t <= t1 then
			table.insert(out, event)
		end
	end
	return out
end

-- Events a skip still fires once time t has been played (events at t already fired): those
-- after t with onSkip = "fire", in order. Before the first frame pass -math.huge.
function Cinematics.skipEvents(cin: Cinematic, t: number): { Event }
	local out = {}
	for _, event in cin.events or {} do
		if event.t > t and event.onSkip == "fire" then
			table.insert(out, event)
		end
	end
	return out
end

-- The reduced-motion form: camera moves become cuts between keys (hold); everything else stays.
function Cinematics.reduce(cin: Cinematic): Cinematic
	local copy = Check.copy(cin)
	copy.camera.interpolation = "hold"
	copy.camera.timing = "keys"
	return Check.freeze(copy)
end

-- ------------------------------------------------------------------ bake and digest

local function round(value: number): number
	local r = math.round(value * 1e6) / 1e6
	return if r == 0 then 0 else r -- no negative zero in the canonical JSON
end

-- Samples at hz frames per second from 0 to duration (inclusive), rounded to 1e-6.
function Cinematics.bake(cin: Cinematic, hz: number): { [string]: any }
	assert(
		Check.integer(hz) and hz >= 1 and hz <= Cinematics.LIMITS.bakeHz,
		"Cinematics.bake: hz must be an integer 1-" .. Cinematics.LIMITS.bakeHz
	)
	local frames = {}
	local count = math.floor(cin.duration * hz + 1e-9)
	for index = 0, count do
		local t = math.min(index / hz, cin.duration)
		local s = Cinematics.sample(cin, t)
		local aim = s.lookAt or s.orientation :: Vec
		table.insert(frames, {
			round(t),
			round(s.position[1]),
			round(s.position[2]),
			round(s.position[3]),
			round(aim[1]),
			round(aim[2]),
			round(aim[3]),
			round(s.roll),
			round(s.fov),
			round(s.letterbox),
			round(s.fade),
		})
	end
	if frames[#frames][1] ~= round(cin.duration) then
		local s = Cinematics.sample(cin, cin.duration)
		local aim = s.lookAt or s.orientation :: Vec
		table.insert(frames, {
			round(cin.duration),
			round(s.position[1]),
			round(s.position[2]),
			round(s.position[3]),
			round(aim[1]),
			round(aim[2]),
			round(aim[3]),
			round(s.roll),
			round(s.fov),
			round(s.letterbox),
			round(s.fade),
		})
	end
	return {
		schema = Cinematics.BAKE_SCHEMA,
		id = cin.id,
		hz = hz,
		columns = { "t", "x", "y", "z", "ax", "ay", "az", "roll", "fov", "letterbox", "fade" },
		frames = frames,
	}
end

-- An 8-hex FNV-1a digest of the canonical JSON of bake(cin, hz).
function Cinematics.digest(cin: Cinematic, hz: number): string
	return string.format("%08x", Rng.hash(Json.encode(Cinematics.bake(cin, hz))))
end

-- ------------------------------------------------------------------ player (pure)

export type Frame = { sample: Sample, events: { Event }, state: string, skipProgress: number }

-- Playback state for one run: playing -> finished | skipped (or stopped). step(dt, skipHeld)
-- advances time, returns the sample and the events crossed this frame and handles
-- hold-to-skip: holding skip for skip.hold s after skip.after s skips to the end, firing only
-- onSkip = "fire" events. skip() skips at once (when allowed). stop() ends without events.
function Cinematics.player(cin: Cinematic, options: { skippable: boolean? }?): any
	local skip = cin.skip or Cinematics.DEFAULT_SKIP
	local allowed = (skip.allowed ~= false) and not (options and options.skippable == false)
	local after = skip.after or Cinematics.DEFAULT_SKIP.after
	local hold = skip.hold or Cinematics.DEFAULT_SKIP.hold
	local time = 0
	local held = 0
	local state = "playing"
	local started = false
	local player: any = {}

	local function finish(events: { Event }, final: string): Frame
		state = final
		time = cin.duration
		return { sample = Cinematics.sample(cin, time), events = events, state = state, skipProgress = 0 }
	end

	function player.canSkip(_self: any): boolean
		return allowed and state == "playing" and time >= after
	end

	function player.skip(self: any): Frame?
		if not self:canSkip() then
			return nil
		end
		return finish(Cinematics.skipEvents(cin, if started then time else -math.huge), "skipped")
	end

	function player.step(self: any, dt: number, skipHeld: boolean?): Frame
		assert(Check.finite(dt) and dt >= 0, "Cinematics.player: dt must be >= 0")
		if state ~= "playing" then
			return { sample = Cinematics.sample(cin, time), events = {}, state = state, skipProgress = 0 }
		end
		if skipHeld and self:canSkip() then
			held += dt
			if held >= hold then
				return self:skip() :: Frame
			end
		else
			held = 0
		end
		local t0 = if started then time else -math.huge
		started = true
		local t1 = time + dt
		if t1 >= cin.duration then
			-- Flush everything up to and including t = duration.
			local events = Cinematics.eventsBetween(cin, t0, math.huge)
			return finish(events, "finished")
		end
		local events = Cinematics.eventsBetween(cin, t0, t1)
		time = t1
		return {
			sample = Cinematics.sample(cin, time),
			events = events,
			state = state,
			skipProgress = if hold > 0 then math.clamp(held / hold, 0, 1) else 0,
		}
	end

	function player.stop(_self: any)
		if state == "playing" then
			state = "stopped"
		end
	end

	function player.time(_self: any): number
		return time
	end

	function player.state(_self: any): string
		return state
	end

	return player
end

return Cinematics
