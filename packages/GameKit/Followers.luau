--!strict
-- @tier T0
-- Followers: pets, companions and squad members that trail a leader. Pure geometry in studs:
-- formation offsets (line, grid, arc, ring) in the leader's frame, stable slots (a follower keeps
-- its slot until removed; the lowest free slot is reused), and a non-yielding step(dt, leader)
-- that moves each follower toward its slot at `speed`, multiplied by `catchUpMultiplier` beyond
-- `catchUpDistance`, and snaps (teleports) beyond `teleportDistance` or on first placement.
-- Leader frame: yaw in degrees about +Y with yaw 0 facing -Z (CFrame.Angles convention, so the
-- slot behind the leader is +Z); a leader may pass lookVector instead of yaw. Arc and ring
-- spread over the highest slot in use, so adding a follower may shift them; line and grid
-- offsets depend on the slot alone. FollowersRoblox (T3) drives AlignPosition and
-- AlignOrientation from step results. Default distances and speeds are conventions, not tuning.
local Check = require("./Check")
local Vec = require("../SceneKit/Vec")

local Followers = {}
Followers.__index = Followers
Followers.FORMATIONS = table.freeze({ "line", "grid", "arc", "ring" })
Followers.DEFAULTS = table.freeze({
	formation = "line",
	spacing = 4, -- studs between neighbours (convention)
	distance = 6, -- studs from the leader to the first slot (convention)
	columns = 3, -- grid columns (convention)
	arc = 120, -- arc width in degrees (convention)
	height = 0, -- vertical offset of every slot
	speed = 16, -- studs per second; the engine's default Humanoid.WalkSpeed
	catchUpDistance = 12, -- beyond this the follower moves faster (convention)
	catchUpMultiplier = 2, -- (convention)
	teleportDistance = 80, -- beyond this the follower snaps to its slot (convention)
	settleDistance = 0.05, -- closer than this counts as settled
	maxStep = 0.25, -- longest dt applied in one step, seconds (convention)
	maxFollowers = 64,
})

export type V3 = Vec.V3
export type Leader = { position: V3, yaw: number?, lookVector: V3? }
export type Options = {
	formation: string?,
	spacing: number?,
	distance: number?,
	columns: number?,
	arc: number?,
	height: number?,
	speed: number?,
	catchUpDistance: number?,
	catchUpMultiplier: number?,
	teleportDistance: number?,
	settleDistance: number?,
	maxStep: number?,
	maxFollowers: number?,
}
export type Frame = {
	id: string,
	slot: number,
	position: V3,
	target: V3,
	yaw: number,
	distance: number,
	teleported: boolean,
	catchingUp: boolean,
	settled: boolean,
}

type FollowerState = { slot: number, position: V3?, yaw: number }
type FollowersFields = {
	_options: { [string]: any },
	_slots: { [number]: string },
	_byId: { [string]: FollowerState },
}
export type Followers = typeof(setmetatable({} :: FollowersFields, Followers))

local POSITIVE = { "spacing", "distance", "speed", "catchUpMultiplier", "teleportDistance", "maxStep" }
local NON_NEGATIVE = { "catchUpDistance", "settleDistance" }

-- Problems with options (empty when valid).
function Followers.validate(options: any): { string }
	if options == nil then
		return {}
	end
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	local problems = {}
	for key in options do
		if Followers.DEFAULTS[key] == nil then
			table.insert(problems, "unknown option " .. Check.describe(key))
		end
	end
	if options.formation ~= nil and not table.find(Followers.FORMATIONS, options.formation) then
		table.insert(problems, "formation must be line, grid, arc or ring")
	end
	for _, key in POSITIVE do
		local value = options[key]
		if value ~= nil and not (Check.finite(value) and value > 0) then
			table.insert(problems, key .. " must be a finite number > 0")
		end
	end
	for _, key in NON_NEGATIVE do
		local value = options[key]
		if value ~= nil and not (Check.finite(value) and value >= 0) then
			table.insert(problems, key .. " must be a finite number >= 0")
		end
	end
	if options.height ~= nil and not Check.finite(options.height) then
		table.insert(problems, "height must be a finite number")
	end
	if options.columns ~= nil and not (Check.integer(options.columns) and options.columns >= 1) then
		table.insert(problems, "columns must be an integer >= 1")
	end
	if options.arc ~= nil and not (Check.finite(options.arc) and options.arc > 0 and options.arc <= 360) then
		table.insert(problems, "arc must be in (0, 360] degrees")
	end
	if
		options.maxFollowers ~= nil
		and not (Check.integer(options.maxFollowers) and options.maxFollowers >= 1)
	then
		table.insert(problems, "maxFollowers must be an integer >= 1")
	end
	local catchUp = options.catchUpDistance or Followers.DEFAULTS.catchUpDistance
	local teleport = options.teleportDistance or Followers.DEFAULTS.teleportDistance
	if Check.finite(catchUp) and Check.finite(teleport) and catchUp >= teleport then
		table.insert(problems, "catchUpDistance must be below teleportDistance")
	end
	return problems
end

-- A follower group. Raises on invalid options.
function Followers.new(options: Options?, _env: any?): Followers
	local problems = Followers.validate(options)
	if #problems > 0 then
		error("Followers.new: " .. table.concat(problems, "; "), 2)
	end
	local merged: { [string]: any } = table.clone(Followers.DEFAULTS) -- clones are not frozen
	for key, value in (options or {}) :: any do
		merged[key] = value
	end
	return setmetatable({ _options = merged, _slots = {}, _byId = {} }, Followers)
end

local function token(value: any): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64
end

-- Adds a follower in the lowest free slot. (slot) or (nil, reason) with invalid_id, duplicate
-- or full. A position places it there (else it appears at its slot on the next step).
function Followers.add(self: Followers, id: string, position: V3?): (number?, string?)
	if not token(id) then
		return nil, "invalid_id"
	end
	if self._byId[id] then
		return nil, "duplicate"
	end
	local slot = 1
	while self._slots[slot] ~= nil do
		slot += 1
	end
	if slot > self._options.maxFollowers then
		return nil, "full"
	end
	self._slots[slot] = id
	self._byId[id] = {
		slot = slot,
		position = if position then Vec.new(position.x, position.y, position.z) else nil,
		yaw = 0,
	}
	return slot, nil
end

-- Removes a follower; other followers keep their slots. Returns whether it was present.
function Followers.remove(self: Followers, id: string): boolean
	local state = self._byId[id]
	if state == nil then
		return false
	end
	self._slots[state.slot] = nil
	self._byId[id] = nil
	return true
end

-- Re-packs slots 1..n in current slot order (call when the game wants no gaps).
function Followers.compact(self: Followers)
	local ids = self:ids()
	self._slots = {}
	for index, id in ids do
		self._slots[index] = id
		self._byId[id].slot = index
	end
end

function Followers.slotOf(self: Followers, id: string): number?
	local state = self._byId[id]
	return if state then state.slot else nil
end

-- Follower ids in slot order.
function Followers.ids(self: Followers): { string }
	local slots = {}
	for slot in self._slots do
		table.insert(slots, slot)
	end
	table.sort(slots)
	local out = {}
	for _, slot in slots do
		table.insert(out, self._slots[slot])
	end
	return out
end

function Followers.count(self: Followers): number
	return #self:ids()
end

local function highestSlot(self: Followers): number
	local high = 0
	for slot in self._slots do
		high = math.max(high, slot)
	end
	return high
end

-- Local offset of slot (1-based) in the leader's frame (+X right, +Z behind). n is the slot
-- count arc and ring spread over (defaults to the highest slot in use).
function Followers.offset(self: Followers, slot: number, n: number?): V3
	local o = self._options
	local count = math.max(n or highestSlot(self), slot, 1)
	local index = slot - 1
	if o.formation == "grid" then
		local row = index // o.columns
		local column = index % o.columns
		return Vec.new((column - (o.columns - 1) / 2) * o.spacing, o.height, o.distance + row * o.spacing)
	elseif o.formation == "arc" then
		-- Radius grows so neighbours stay at least `spacing` apart along the arc.
		local width = math.rad(o.arc)
		local radius = if count > 1 then math.max(o.distance, o.spacing * (count - 1) / width) else o.distance
		local angle = if count > 1 then -width / 2 + index * width / (count - 1) else 0
		return Vec.new(math.sin(angle) * radius, o.height, math.cos(angle) * radius)
	elseif o.formation == "ring" then
		local radius = math.max(o.distance, o.spacing * count / (2 * math.pi))
		local angle = index * 2 * math.pi / count
		return Vec.new(math.sin(angle) * radius, o.height, math.cos(angle) * radius)
	end
	return Vec.new(0, o.height, o.distance + index * o.spacing)
end

-- Yaw in degrees, in (-180, 180], of a horizontal direction (yaw 0 faces -Z).
local function yawOf(dx: number, dz: number): number
	local degrees = math.deg(math.atan2(-dx, -dz)) % 360
	return if degrees > 180 then degrees - 360 else degrees
end

-- The leader's yaw in degrees (from yaw, else lookVector, else 0).
function Followers.leaderYaw(leader: Leader): number
	if leader.yaw ~= nil then
		return leader.yaw
	end
	local look = leader.lookVector
	if look and (look.x ~= 0 or look.z ~= 0) then
		return yawOf(look.x, look.z)
	end
	return 0
end

local function checkLeader(leader: any)
	assert(
		type(leader) == "table"
			and type(leader.position) == "table"
			and Check.finite(leader.position.x)
			and Check.finite(leader.position.y)
			and Check.finite(leader.position.z),
		"Followers: leader needs a finite position"
	)
	assert(leader.yaw == nil or Check.finite(leader.yaw), "Followers: leader yaw must be finite")
end

-- World target per follower id for leader (no state change).
function Followers.targets(self: Followers, leader: Leader): { [string]: V3 }
	checkLeader(leader)
	local yaw = Followers.leaderYaw(leader)
	local n = highestSlot(self)
	local out = {}
	for id, state in self._byId do
		out[id] = Vec.add(leader.position, Vec.rotateY(self:offset(state.slot, n), yaw))
	end
	return out
end

-- Advances every follower by dt seconds (clamped to maxStep) toward its slot. Never yields.
-- Returns one Frame per follower in slot order.
function Followers.step(self: Followers, dt: number, leader: Leader): { Frame }
	assert(Check.finite(dt) and dt >= 0, "Followers.step: dt must be a finite number >= 0")
	local o = self._options
	local targets = self:targets(leader)
	local leaderYaw = Followers.leaderYaw(leader)
	local seconds = math.min(dt, o.maxStep)
	local frames = {}
	for _, id in self:ids() do
		local state = self._byId[id]
		local target = targets[id]
		local teleported, catchingUp = false, false
		local current = state.position
		local position: V3
		if current == nil or Vec.length(Vec.sub(target, current)) > o.teleportDistance then
			position = target
			teleported = true
		else
			position = current
			local delta = Vec.sub(target, position)
			local gap = Vec.length(delta)
			if gap > o.settleDistance then
				catchingUp = gap > o.catchUpDistance
				local speed = o.speed * (if catchingUp then o.catchUpMultiplier else 1)
				local move = math.min(gap, speed * seconds)
				position = Vec.add(position, Vec.scale(delta, move / gap))
				if delta.x ~= 0 or delta.z ~= 0 then
					state.yaw = yawOf(delta.x, delta.z)
				end
			end
		end
		local remaining = Vec.length(Vec.sub(target, position))
		local settled = remaining <= o.settleDistance
		if settled or teleported then
			state.yaw = leaderYaw
		end
		state.position = position
		table.insert(frames, {
			id = id,
			slot = state.slot,
			position = position,
			target = target,
			yaw = state.yaw,
			distance = remaining,
			teleported = teleported,
			catchingUp = catchingUp,
			settled = settled,
		})
	end
	return frames
end

-- Syncs a follower's position from the engine (the adapter reads the physical part back).
function Followers.place(self: Followers, id: string, position: V3): boolean
	local state = self._byId[id]
	if state == nil then
		return false
	end
	assert(
		Check.finite(position.x) and Check.finite(position.y) and Check.finite(position.z),
		"Followers.place: position must be finite"
	)
	state.position = Vec.new(position.x, position.y, position.z)
	return true
end

function Followers.positionOf(self: Followers, id: string): V3?
	local state = self._byId[id]
	return if state and state.position
		then Vec.new(state.position.x, state.position.y, state.position.z)
		else nil
end

return Followers
