--!strict
-- @tier T0
-- AnimSet: animation slots as data. It reads clips/1 sidecars (docs/runtime-kits.md 9.4, written
-- by the Blender pipeline), binds clips to the standard slots (idle, walk, run, jump, fall,
-- climb, swim, sit, land, action_1..action_8), maps game or Humanoid states to slots, and checks
-- the marker contract: every marker a slot's code listens for exists in every clip bound to it.
--   * AnimSet.define({ clips = <clips/1 table>, slots = { [slot] = { priority?, fadeIn?,
--     fadeOut?, looped?, speed?, markers? = { names } } }, states = { [state] = slot } })
--   * AnimSet.player(set, animator, { animation = fn(clip) -> Animation, configure?, seed? }, env)
--     drives an Animator-like object (LoadAnimation -> track with Play, Stop, AdjustSpeed,
--     GetMarkerReachedSignal, Length): tracks load once, variants pick by weight with a seeded
--     Rng, a slot replaces the others of its layer, and at most 8 tracks play at once (the
--     Animator limit; the oldest lowest-priority track stops first).
--   * The animation hook comes from AnimSetRoblox (Animation instances with ids the game
--     supplies, or Studio-only temporary ids for preview). Nothing here uploads anything.
local Check = require("./Check")

local AnimSet = {}
AnimSet.FORMAT = "clips/1"
AnimSet.MAX_PLAYING = 8 -- tracks per Animator (Server Authority rule)
AnimSet.RIGS = table.freeze({ r15_pose = true, r15_avatar = true, custom = true })
AnimSet.PRIORITIES = table.freeze({ "Core", "Idle", "Movement", "Action", "Action2", "Action3", "Action4" })
AnimSet.FADE = 0.1 -- seconds; AnimationTrack:Play's default fadeTime
local SLOT_LIST = { "idle", "walk", "run", "jump", "fall", "climb", "swim", "sit", "land" }
for index = 1, 8 do
	table.insert(SLOT_LIST, "action_" .. index)
end
AnimSet.SLOTS = table.freeze(SLOT_LIST)
local IS_SLOT = {}
for _, slot in SLOT_LIST do
	IS_SLOT[slot] = true
end
-- Default priority by slot when the clip and slot config give none.
AnimSet.DEFAULT_PRIORITY = table.freeze({
	idle = "Idle",
	sit = "Idle",
	walk = "Movement",
	run = "Movement",
	jump = "Movement",
	fall = "Movement",
	climb = "Movement",
	swim = "Movement",
	land = "Movement",
})

export type Marker = { name: string, frame: number, param: string? }
export type Clip = {
	name: string,
	slot: string?,
	start: number,
	["end"]: number,
	loop: boolean,
	root_motion: boolean,
	priority: string?,
	weight: number?,
	markers: { Marker },
}
export type Clips = {
	schema: string,
	asset: string,
	rig: string,
	fps: number,
	files: { glb: string?, fbx: { [string]: string }? },
	clips: { Clip },
}
export type SlotConfig = {
	priority: string?,
	fadeIn: number?,
	fadeOut: number?,
	looped: boolean?,
	speed: number?,
	markers: { string }?,
	layer: string?,
}
export type Set = {
	asset: string,
	fps: number,
	slots: {
		[string]: { config: SlotConfig, clips: { Clip }, priority: string, looped: boolean, layer: string },
	},
	states: { [string]: string },
	clips: { [string]: Clip },
}

local function priorityRank(name: string): number
	return table.find(AnimSet.PRIORITIES, name) or 0
end
AnimSet.priorityRank = priorityRank

function AnimSet.isSlot(value: any): boolean
	return type(value) == "string" and IS_SLOT[value] == true
end

-- Problems with a decoded clips/1 table (empty when valid).
function AnimSet.validateClips(doc: any): { string }
	if type(doc) ~= "table" then
		return { "clips/1 must be a table" }
	end
	local problems = {}
	local function need(ok: boolean, message: string)
		if not ok then
			table.insert(problems, message)
		end
	end
	need(doc.schema == AnimSet.FORMAT, 'schema must be "clips/1"')
	need(Check.label(doc.asset), "asset must be a label")
	need(AnimSet.RIGS[doc.rig] == true, "rig must be r15_pose, r15_avatar or custom")
	need(Check.integer(doc.fps) and doc.fps > 0, "fps must be an integer > 0")
	local files = doc.files
	if type(files) ~= "table" then
		table.insert(problems, "files must be a table { glb, fbx }")
	else
		need(files.glb == nil or type(files.glb) == "string", "files.glb must be a file name")
		if files.fbx ~= nil then
			local ok = type(files.fbx) == "table"
			if ok then
				for clip, name in files.fbx do
					ok = ok and type(clip) == "string" and type(name) == "string"
				end
			end
			need(ok, "files.fbx must map clip names to file names")
		end
	end
	if type(doc.clips) ~= "table" or #doc.clips == 0 then
		table.insert(problems, "clips must be a non-empty list")
		return problems
	end
	local names = {}
	local bySlot: { [string]: number } = {}
	for index, clip in doc.clips do
		local where = string.format("clips[%d]", index)
		if type(clip) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		local named = type(clip.name) == "string"
			and string.match(clip.name, "^[a-z][a-z0-9_]*$") ~= nil
			and #clip.name <= 48
		need(named, where .. ".name must match ^[a-z][a-z0-9_]{0,47}$")
		if named then
			need(not names[clip.name], string.format("%s.name %q is duplicated", where, clip.name))
			names[clip.name] = true
		end
		if clip.slot ~= nil then
			need(
				IS_SLOT[clip.slot] == true,
				where .. ".slot must be a standard slot (idle ... land, action_1..action_8)"
			)
			if IS_SLOT[clip.slot] then
				bySlot[clip.slot] = (bySlot[clip.slot] or 0) + 1
			end
		end
		local frames = Check.integer(clip.start) and Check.integer(clip["end"]) and clip.start >= 0
		need(frames, where .. ".start and .end must be integer frames >= 0")
		if frames then
			need(clip["end"] >= clip.start, where .. ".end must be >= start")
		end
		need(type(clip.loop) == "boolean", where .. ".loop must be a boolean")
		need(type(clip.root_motion) == "boolean", where .. ".root_motion must be a boolean")
		need(
			clip.priority == nil or priorityRank(clip.priority) > 0,
			where .. ".priority must be an AnimationPriority name"
		)
		need(
			clip.weight == nil or (Check.finite(clip.weight) and clip.weight > 0),
			where .. ".weight must be > 0"
		)
		if type(clip.markers) ~= "table" then
			table.insert(problems, where .. ".markers must be a list (may be empty)")
		else
			for mIndex, marker in clip.markers do
				local mWhere = string.format("%s.markers[%d]", where, mIndex)
				if type(marker) ~= "table" or not Check.label(marker.name) then
					table.insert(problems, mWhere .. ".name must be a label")
				elseif
					not Check.integer(marker.frame)
					or (frames and (marker.frame < clip.start or marker.frame > clip["end"]))
				then
					table.insert(problems, mWhere .. ".frame must be an integer frame within start..end")
				elseif marker.param ~= nil and type(marker.param) ~= "string" then
					table.insert(problems, mWhere .. ".param must be a string")
				end
			end
		end
	end
	-- Several clips may share a slot only as weighted variants.
	for _, clip in doc.clips do
		if
			type(clip) == "table"
			and clip.slot
			and (bySlot[clip.slot] or 0) > 1
			and not (Check.finite(clip.weight) and clip.weight > 0)
		then
			table.insert(
				problems,
				string.format(
					"slot %s has several clips; each needs weight > 0 (clip %s)",
					clip.slot,
					tostring(clip.name)
				)
			)
		end
	end
	return problems
end

-- Seconds a clip lasts: (end - start) / fps.
function AnimSet.duration(clip: Clip, fps: number): number
	return (clip["end"] - clip.start) / fps
end

-- Seconds from the clip start to a marker.
function AnimSet.markerTime(clip: Clip, marker: Marker, fps: number): number
	return (marker.frame - clip.start) / fps
end

-- Problems with a set definition, including the marker contract (empty when valid).
function AnimSet.validate(def: any): { string }
	if type(def) ~= "table" then
		return { "definition must be a table" }
	end
	local problems = {}
	local clipProblems = AnimSet.validateClips(def.clips)
	for _, problem in clipProblems do
		table.insert(problems, "clips: " .. problem)
	end
	local slots = def.slots or {}
	if type(slots) ~= "table" then
		table.insert(problems, "slots must map slot names to configs")
		slots = {}
	end
	for slot, config in slots do
		local where = "slots." .. tostring(slot)
		if not IS_SLOT[slot] then
			table.insert(problems, where .. " is not a standard slot")
			continue
		end
		if type(config) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		if config.priority ~= nil and priorityRank(config.priority) == 0 then
			table.insert(problems, where .. ".priority must be an AnimationPriority name")
		end
		for _, field in { "fadeIn", "fadeOut" } do
			if
				config[field] ~= nil
				and not (Check.finite(config[field]) and config[field] >= 0 and config[field] <= 10)
			then
				table.insert(problems, string.format("%s.%s must be 0-10 seconds", where, field))
			end
		end
		if
			config.speed ~= nil
			and not (Check.finite(config.speed) and config.speed > 0 and config.speed <= 10)
		then
			table.insert(problems, where .. ".speed must be in (0, 10]")
		end
		if config.layer ~= nil and not Check.label(config.layer) then
			table.insert(problems, where .. ".layer must be a label")
		end
		if config.looped ~= nil and type(config.looped) ~= "boolean" then
			table.insert(problems, where .. ".looped must be a boolean")
		end
		if config.markers ~= nil then
			if type(config.markers) ~= "table" then
				table.insert(problems, where .. ".markers must be a list of marker names")
			else
				for _, name in config.markers do
					if not Check.label(name) then
						table.insert(problems, where .. ".markers must be a list of marker names")
						break
					end
				end
			end
		end
	end
	local states = def.states or {}
	if type(states) ~= "table" then
		table.insert(problems, "states must map state labels to slots")
		states = {}
	end
	for state, slot in states do
		if not Check.label(state) then
			table.insert(problems, string.format("state %s must be a label", tostring(state)))
		elseif not IS_SLOT[slot] then
			table.insert(problems, string.format("states.%s must name a standard slot", state))
		end
	end
	if #clipProblems > 0 then
		return problems
	end
	-- Bound slots: every state's slot and every configured slot needs a clip; every listened
	-- marker must be in every clip of that slot.
	local bound: { [string]: { any } } = {}
	for _, clip in def.clips.clips do
		if clip.slot then
			bound[clip.slot] = bound[clip.slot] or {}
			table.insert(bound[clip.slot], clip)
		end
	end
	for state, slot in states do
		if IS_SLOT[slot] and bound[slot] == nil then
			table.insert(
				problems,
				string.format("states.%s uses slot %s, which has no clip", tostring(state), slot)
			)
		end
	end
	for slot, config in slots do
		if IS_SLOT[slot] and type(config) == "table" then
			if bound[slot] == nil then
				table.insert(problems, string.format("slots.%s has no clip", slot))
			elseif type(config.markers) == "table" then
				for _, name in config.markers do
					for _, clip in bound[slot] do
						local found = false
						for _, marker in clip.markers do
							found = found or marker.name == name
						end
						if not found then
							table.insert(
								problems,
								string.format(
									"marker contract: clip %s (slot %s) has no marker %q",
									clip.name,
									slot,
									tostring(name)
								)
							)
						end
					end
				end
			end
		end
	end
	return problems
end

function AnimSet.define(
	def: { clips: Clips, slots: { [string]: SlotConfig }?, states: { [string]: string }? }
): Set
	local problems = AnimSet.validate(def)
	if #problems > 0 then
		error("AnimSet.define: " .. table.concat(problems, "; "), 2)
	end
	local slots = {}
	local byName = {}
	for _, clip in def.clips.clips do
		byName[clip.name] = Check.copy(clip)
		if clip.slot then
			local entry = slots[clip.slot]
			if entry == nil then
				local config = (def.slots or {})[clip.slot] or {}
				-- Locomotion slots share the "base" layer (one at a time); each action slot is its
				-- own layer, so actions overlay locomotion and each other.
				local layer = config.layer
					or (if string.sub(clip.slot, 1, 7) == "action_" then clip.slot else "base")
				entry =
					{ config = Check.copy(config), clips = {}, priority = "", looped = false, layer = layer }
				slots[clip.slot] = entry
			end
			table.insert(entry.clips, byName[clip.name])
		end
	end
	for slot, entry in slots do
		local first = entry.clips[1]
		entry.priority = entry.config.priority or first.priority or AnimSet.DEFAULT_PRIORITY[slot] or "Action"
		if entry.config.looped ~= nil then
			entry.looped = entry.config.looped
		else
			entry.looped = first.loop
		end
	end
	return Check.freeze({
		asset = def.clips.asset,
		fps = def.clips.fps,
		slots = slots,
		states = Check.copy(def.states or {}),
		clips = byName,
	}) :: Set
end

-- ---------------------------------------------------------------- player

local Player = {}
Player.__index = Player

type Playing = { slot: string, clip: string, track: any, order: number, rank: number }
type Fields = {
	set: Set,
	_animator: any,
	_animation: (clip: Clip, set: Set) -> any,
	_configure: ((track: any, priority: string, looped: boolean) -> ())?,
	_rng: any,
	_tracks: { [string]: any },
	_playing: { [string]: Playing },
	_order: number,
	_state: string?,
	_markerHandlers: { [string]: { (slot: string, param: any) -> () } },
	_connections: { any },
}
export type Player = typeof(setmetatable({} :: Fields, Player))

function AnimSet.player(
	set: Set,
	animator: any,
	options: {
		animation: (clip: Clip, set: Set) -> any,
		configure: ((track: any, priority: string, looped: boolean) -> ())?,
		seed: (number | string)?,
	},
	env: any
): Player
	assert(
		type(set) == "table" and table.isfrozen(set) and set.slots,
		"AnimSet.player needs a set from AnimSet.define"
	)
	assert(animator ~= nil, "AnimSet.player needs an animator")
	assert(
		type(options) == "table" and type(options.animation) == "function",
		"AnimSet.player needs options.animation(clip)"
	)
	assert(type(env) == "table" and type(env.rng) == "function", "AnimSet.player needs env.rng")
	return setmetatable({
		set = set,
		_animator = animator,
		_animation = options.animation,
		_configure = options.configure,
		_rng = env.rng(options.seed or 0),
		_tracks = {},
		_playing = {},
		_order = 0,
		_state = nil,
		_markerHandlers = {},
		_connections = {},
	}, Player)
end

local function pick(self: Player, slot: string): Clip
	local clips = self.set.slots[slot].clips
	if #clips == 1 then
		return clips[1]
	end
	local entries = {}
	for _, clip in clips do
		table.insert(entries, { value = clip, weight = clip.weight or 1 })
	end
	return self._rng:weighted(entries)
end

local function trackFor(self: Player, slot: string, clip: Clip): any
	local track = self._tracks[clip.name]
	if track == nil then
		track = self._animator:LoadAnimation(self._animation(clip, self.set))
		local entry = self.set.slots[slot]
		if self._configure then
			-- AnimSetRoblox maps the priority name to Enum.AnimationPriority.
			self._configure(track, entry.priority, entry.looped)
		end
		self._tracks[clip.name] = track
		-- One-shots end on their own: drop them from the playing set (the 8-track count) when
		-- the track reports Stopped and is not playing again.
		local stopped = track.Stopped
		if type(stopped) == "table" or type(stopped) == "userdata" then
			table.insert(
				self._connections,
				stopped:Connect(function()
					local entry = self._playing[slot]
					if entry and entry.track == track and not track.IsPlaying then
						self._playing[slot] = nil
					end
				end)
			)
		end
		-- Marker names this clip carries, wired once per track.
		local names = {}
		for _, marker in clip.markers do
			names[marker.name] = true
		end
		for name in names do
			local connection = track:GetMarkerReachedSignal(name):Connect(function(param: any)
				local handlers: { (slot: string, param: any) -> () } = self._markerHandlers[name] or {}
				for _, handler in handlers do
					handler(slot, param)
				end
			end)
			table.insert(self._connections, connection)
		end
	end
	return track
end

local function stopEntry(self: Player, slot: string, fade: number?)
	local entry = self._playing[slot]
	if entry then
		local config = self.set.slots[slot].config
		entry.track:Stop(fade or config.fadeOut or AnimSet.FADE)
		self._playing[slot] = nil
	end
end

-- Plays a slot (or the slot a state maps to). Slots in the same layer are replaced (locomotion
-- slots share "base"); when 8 tracks already play, the oldest of the lowest priority stops. (ok, reason?) with
-- unknown_slot or already_playing (a looped slot that is playing is left alone).
function Player.play(
	self: Player,
	slotOrState: string,
	options: { speed: number?, weight: number?, fade: number? }?
): (boolean, string?)
	local slot = self.set.states[slotOrState] or slotOrState
	local entry = self.set.slots[slot]
	if entry == nil then
		return false, "unknown_slot"
	end
	local current = self._playing[slot]
	if current and entry.looped then
		return false, "already_playing"
	end
	local rank = priorityRank(entry.priority)
	for other in table.clone(self._playing) do
		if other ~= slot and self.set.slots[other].layer == entry.layer then
			stopEntry(self, other)
		end
	end
	if current then
		stopEntry(self, slot, 0)
	end
	local count = 0
	for _ in self._playing do
		count += 1
	end
	while count >= AnimSet.MAX_PLAYING do
		local victim: Playing? = nil
		for _, playing in self._playing do
			if
				victim == nil
				or playing.rank < victim.rank
				or (playing.rank == victim.rank and playing.order < victim.order)
			then
				victim = playing
			end
		end
		stopEntry(self, (victim :: Playing).slot)
		count -= 1
	end
	local clip = pick(self, slot)
	local track = trackFor(self, slot, clip)
	local opts: { speed: number?, weight: number?, fade: number? } = options or {}
	local speed = opts.speed or entry.config.speed or 1
	track:Play(opts.fade or entry.config.fadeIn or AnimSet.FADE, opts.weight or 1, speed)
	self._order += 1
	self._playing[slot] = { slot = slot, clip = clip.name, track = track, order = self._order, rank = rank }
	return true, nil
end

-- Moves to a state (Humanoid.StateChanged or a game state). Same state: no-op.
function Player.setState(self: Player, state: string): (boolean, string?)
	if self._state == state then
		return true, "same_state"
	end
	local slot = self.set.states[state]
	if slot == nil then
		return false, "unknown_state"
	end
	self._state = state
	return self:play(slot)
end

function Player.stop(self: Player, slot: string, fade: number?): boolean
	if self._playing[slot] == nil then
		return false
	end
	stopEntry(self, slot, fade)
	return true
end

function Player.stopAll(self: Player, fade: number?)
	for slot in table.clone(self._playing) do
		stopEntry(self, slot, fade)
	end
	self._state = nil
end

-- Slots playing now, sorted.
function Player.playing(self: Player): { string }
	local list = {}
	for slot in self._playing do
		table.insert(list, slot)
	end
	table.sort(list)
	return list
end

-- Clip name playing in a slot (variants differ).
function Player.clip(self: Player, slot: string): string?
	local entry = self._playing[slot]
	return entry and entry.clip
end

-- Calls fn(slot, param) whenever any loaded clip reaches marker name. Returns a disconnect fn.
function Player.onMarker(self: Player, name: string, fn: (slot: string, param: any) -> ()): () -> ()
	assert(Check.label(name), "AnimSet.onMarker: name must be a label")
	self._markerHandlers[name] = self._markerHandlers[name] or {}
	table.insert(self._markerHandlers[name], fn)
	return function()
		local list = self._markerHandlers[name]
		local index = list and table.find(list, fn)
		if index then
			table.remove(list, index)
		end
	end
end

function Player.destroy(self: Player)
	self:stopAll(0)
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	for _, track in self._tracks do
		if type(track) == "table" and track.Destroy then
			track:Destroy()
		end
	end
	table.clear(self._tracks)
	table.clear(self._markerHandlers)
end

return AnimSet
