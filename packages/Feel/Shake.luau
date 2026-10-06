--!strict
-- @tier T0
-- Shake: trauma-based camera shake. Hits add trauma (0..1); trauma decays linearly per second;
-- the offset is trauma^power x the per-axis maximum x smooth noise, so small hits barely move
-- the view and big ones shake hard. The noise is internal hashed value noise (an integer hash
-- per lattice point, smoothstep between points), seeded and identical in Lune and Studio; it
-- never leaves [-1, 1], so offsets never exceed the configured maxima.
-- settings/1: step(dt, scale) takes Settings.effective(...).shakeScale, which is 0 under reduced
-- motion; trauma still decays, so nothing is stored up for later.
--   Shake.new(options?) -> shake;  shake:add(traumaOrPreset);  shake:step(dt, scale?) -> offsets
--   offsets = { x, y, z (studs), pitch, yaw, roll (degrees) };  Shake.noise(seed, channel, t)
local Shake = {}

-- Presets by function (conventions; tune per game).
Shake.PRESETS = table.freeze({
	hit_light = 0.2,
	hit_heavy = 0.45,
	blast = 0.8,
	land = 0.15,
	rumble = 0.3,
})

Shake.DEFAULTS = table.freeze({
	maxOffset = table.freeze({ x = 0.35, y = 0.35, z = 0 }), -- studs
	maxAngle = table.freeze({ pitch = 1.5, yaw = 1.5, roll = 2.5 }), -- degrees
	frequency = 18, -- noise lattice points per second
	decay = 1.4, -- trauma per second
	power = 2,
})

local CHANNELS = { "x", "y", "z", "pitch", "yaw", "roll" }

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Exact 32-bit multiply (doubles keep 53 bits, so split one operand into 16-bit halves).
local function mul32(a: number, b: number): number
	local hi = bit32.rshift(a, 16)
	local lo = bit32.band(a, 0xFFFF)
	return ((hi * b) % 4294967296 * 65536 + lo * b) % 4294967296
end

local function seedOf(seed: any): number
	if type(seed) == "number" then
		return math.floor(seed) % 4294967296
	end
	local text = tostring(seed)
	local hash = 2166136261
	for index = 1, #text do
		hash = mul32(bit32.bxor(hash, string.byte(text, index)), 16777619)
	end
	return hash
end

-- 32-bit integer hash of (seed, channel, lattice index) mapped to [-1, 1].
local function lattice(seed: number, channel: number, index: number): number
	local h = bit32.bxor(seed, mul32(channel, 374761393))
	h = bit32.bxor(h, mul32(index % 4294967296, 668265263))
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 1274126177)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return (h / 4294967295) * 2 - 1
end

-- Smooth value noise in [-1, 1] at time t (in lattice units) for one channel.
function Shake.noise(seed: any, channel: number, t: number): number
	local s = seedOf(seed)
	local i = math.floor(t)
	local f = t - i
	local a = lattice(s, channel, i % 4294967296)
	local b = lattice(s, channel, (i + 1) % 4294967296)
	local w = f * f * (3 - 2 * f)
	return a + (b - a) * w
end

export type Offsets = { x: number, y: number, z: number, pitch: number, yaw: number, roll: number }

export type Options = {
	seed: any?,
	maxOffset: { x: number?, y: number?, z: number? }?,
	maxAngle: { pitch: number?, yaw: number?, roll: number? }?,
	frequency: number?,
	decay: number?,
	power: number?,
}

function Shake.new(options: Options?)
	local opts: any = options or {}
	local maxima: { [string]: number } = {}
	for _, axis in { "x", "y", "z" } do
		local value = (opts.maxOffset or {})[axis]
		maxima[axis] = if value == nil then Shake.DEFAULTS.maxOffset[axis] else value
	end
	for _, axis in { "pitch", "yaw", "roll" } do
		local value = (opts.maxAngle or {})[axis]
		maxima[axis] = if value == nil then Shake.DEFAULTS.maxAngle[axis] else value
	end
	for axis, value in maxima do
		assert(finite(value) and value >= 0, "Shake: maximum " .. axis .. " must be >= 0")
	end
	local frequency = opts.frequency or Shake.DEFAULTS.frequency
	local decay = opts.decay or Shake.DEFAULTS.decay
	local power = opts.power or Shake.DEFAULTS.power
	assert(finite(frequency) and frequency > 0, "Shake: frequency must be > 0")
	assert(finite(decay) and decay >= 0, "Shake: decay must be >= 0")
	assert(finite(power) and power >= 1, "Shake: power must be >= 1")
	local seed = seedOf(opts.seed or "shake")
	local trauma = 0
	local time = 0
	local api = {}

	function api:add(amount: number | string): number
		local value: any = amount
		if type(amount) == "string" then
			value = Shake.PRESETS[amount]
			assert(value ~= nil, "Shake: unknown preset " .. amount)
		end
		assert(finite(value) and value >= 0, "Shake: trauma must be >= 0")
		trauma = math.min(1, trauma + value)
		return trauma
	end

	function api:trauma(): number
		return trauma
	end

	function api:reset()
		trauma = 0
	end

	-- Advances time, decays trauma and returns the offsets for this frame. scale (0..1) is the
	-- settings/1 shake scale; 0 returns zero offsets.
	function api:step(dt: number, scale: number?): Offsets
		assert(finite(dt) and dt >= 0, "Shake: dt must be a finite number >= 0")
		local factor = if scale == nil then 1 else math.clamp(scale, 0, 1)
		time += dt
		local amount = trauma ^ power * factor
		local out: any = {}
		for index, channel in CHANNELS do
			if amount == 0 or maxima[channel] == 0 then
				out[channel] = 0
			else
				out[channel] = maxima[channel] * amount * Shake.noise(seed, index, time * frequency)
			end
		end
		trauma = math.max(0, trauma - decay * dt)
		return out
	end

	return api
end

return Shake
