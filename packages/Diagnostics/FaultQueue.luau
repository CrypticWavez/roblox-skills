--!strict
-- Caller-driven synthetic impairment for bounded diagnostic packets; no transport or game state.
local FaultQueue = {}
FaultQueue.__index = FaultQueue

export type Packet = { sequence: number, sentAt: number, label: string }
export type Options = {
	seed: number,
	capacity: number,
	minDelay: number,
	maxDelay: number,
	lossProbability: number,
	duplicateProbability: number,
}
type Entry = { due: number, order: number, packet: Packet }
type Counters = {
	submitted: number,
	accepted: number,
	lost: number,
	rejected: number,
	saturated: number,
	duplicates: number,
	delivered: number,
	discarded: number,
	peakQueued: number,
}
export type Queue = typeof(setmetatable({
	_options = {} :: Options,
	_entries = {} :: { Entry },
	_counters = {} :: Counters,
	_state = 1,
	_order = 0,
	_now = 0,
	_closed = false,
}, FaultQueue))

local OPTION_KEYS = {
	seed = true,
	capacity = true,
	minDelay = true,
	maxDelay = true,
	lossProbability = true,
	duplicateProbability = true,
}
local PACKET_KEYS = { sequence = true, sentAt = true, label = true }
local function finite(value: any, minimum: number, maximum: number, name: string): number
	assert(
		type(value) == "number" and value == value and value >= minimum and value <= maximum,
		name .. " out of bounds"
	)
	return value
end
local function integer(value: any, minimum: number, maximum: number, name: string): number
	local result = finite(value, minimum, maximum, name)
	assert(result % 1 == 0, name .. " must be an integer")
	return result
end
local function copyPacket(packet: Packet): Packet
	return { sequence = packet.sequence, sentAt = packet.sentAt, label = packet.label }
end
local function validatePacket(packet: Packet)
	assert(type(packet) == "table", "packet must be a table")
	for key in pairs(packet :: any) do
		assert(PACKET_KEYS[key] == true, "unknown packet field")
	end
	integer(packet.sequence, 1, 1000000000, "sequence")
	finite(packet.sentAt, 0, 1000000000, "sentAt")
	assert(type(packet.label) == "string" and #packet.label <= 64, "label must be at most 64 bytes")
end
local function random(self: Queue): number
	local state = self._state
	state = bit32.bxor(state, bit32.lshift(state, 13))
	state = bit32.bxor(state, bit32.rshift(state, 17))
	state = bit32.bxor(state, bit32.lshift(state, 5))
	self._state = state
	return state / 4294967296
end
function FaultQueue.new(options: Options): Queue
	assert(type(options) == "table", "explicit impairment options required")
	for key in pairs(options :: any) do
		assert(OPTION_KEYS[key] == true, "unknown impairment option")
	end
	local checked: Options = {
		seed = integer(options.seed, 1, 4294967295, "seed"),
		capacity = integer(options.capacity, 1, 1024, "capacity"),
		minDelay = finite(options.minDelay, 0, 30, "minDelay"),
		maxDelay = finite(options.maxDelay, 0, 30, "maxDelay"),
		lossProbability = finite(options.lossProbability, 0, 1, "lossProbability"),
		duplicateProbability = finite(options.duplicateProbability, 0, 1, "duplicateProbability"),
	}
	assert(checked.maxDelay >= checked.minDelay, "maxDelay must be at least minDelay")
	return setmetatable({
		_options = checked,
		_entries = {},
		_counters = {
			submitted = 0,
			accepted = 0,
			lost = 0,
			rejected = 0,
			saturated = 0,
			duplicates = 0,
			delivered = 0,
			discarded = 0,
			peakQueued = 0,
		},
		_state = checked.seed,
		_order = 0,
		_now = 0,
		_closed = false,
	}, FaultQueue)
end
function FaultQueue.enqueue(self: Queue, packet: Packet): (boolean, string?, number)
	validatePacket(packet)
	if self._closed then
		return false, "closed", 0
	end
	local counters = self._counters
	counters.submitted += 1
	if random(self) < self._options.lossProbability then
		counters.lost += 1
		return false, "loss", 0
	end
	local copies = if random(self) < self._options.duplicateProbability then 2 else 1
	-- An original and its duplicate are admitted atomically; saturation never grows the queue.
	if #self._entries + copies > self._options.capacity then
		counters.rejected += 1
		counters.saturated += 1
		return false, "capacity", 0
	end
	if self._now + self._options.maxDelay > 86400 then
		counters.rejected += 1
		return false, "horizon", 0
	end
	for _ = 1, copies do
		local delay = self._options.minDelay
			+ random(self) * (self._options.maxDelay - self._options.minDelay)
		self._order += 1
		table.insert(
			self._entries,
			{ due = self._now + delay, order = self._order, packet = copyPacket(packet) }
		)
	end
	counters.accepted += 1
	counters.duplicates += copies - 1
	counters.peakQueued = math.max(counters.peakQueued, #self._entries)
	return true, nil, copies
end
function FaultQueue.advance(self: Queue, delta: number): { Packet }
	finite(delta, 0, 60, "delta")
	assert(self._now + delta <= 86400, "diagnostic time horizon exceeded")
	if self._closed then
		return {}
	end
	self._now += delta
	table.sort(self._entries, function(a, b)
		return if a.due == b.due then a.order < b.order else a.due < b.due
	end)
	local delivered: { Packet } = {}
	local pending: { Entry } = {}
	for _, entry in self._entries do
		if entry.due <= self._now then
			table.insert(delivered, entry.packet)
		else
			table.insert(pending, entry)
		end
	end
	self._entries = pending
	self._counters.delivered += #delivered
	return delivered
end
function FaultQueue.clear(self: Queue): number
	local count = #self._entries
	self._entries = {}
	self._counters.discarded += count
	return count
end
function FaultQueue.destroy(self: Queue)
	if self._closed then
		return
	end
	self._closed = true
	self:clear()
end
function FaultQueue.stats(self: Queue)
	local result = table.clone(self._counters)
	return {
		submitted = result.submitted,
		accepted = result.accepted,
		lost = result.lost,
		rejected = result.rejected,
		saturated = result.saturated,
		duplicates = result.duplicates,
		delivered = result.delivered,
		discarded = result.discarded,
		peakQueued = result.peakQueued,
		queued = #self._entries,
		now = self._now,
		closed = self._closed,
		capacity = self._options.capacity,
	}
end
return FaultQueue
