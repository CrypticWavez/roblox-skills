--!strict
-- Seeded 2D value noise and fractal Brownian motion; deterministic across runtimes.
local Rng = require("./Rng")

local Noise = {}

local function lattice(seed: number, x: number, y: number): number
	local h = bit32.bxor(seed, (x * 374761393) % 4294967296, (y * 668265263) % 4294967296)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = (h * 1274126177) % 4294967296
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h / 4294967296
end

local function smooth(t: number): number
	return t * t * (3 - 2 * t)
end

-- Value noise in [0, 1).
function Noise.value(seed: number | string, x: number, y: number): number
	local numeric = if type(seed) == "string" then Rng.hash(seed) else (seed :: number) % 4294967296
	local x0, y0 = math.floor(x), math.floor(y)
	local tx, ty = smooth(x - x0), smooth(y - y0)
	local a = lattice(numeric, x0 % 65536, y0 % 65536)
	local b = lattice(numeric, (x0 + 1) % 65536, y0 % 65536)
	local c = lattice(numeric, x0 % 65536, (y0 + 1) % 65536)
	local d = lattice(numeric, (x0 + 1) % 65536, (y0 + 1) % 65536)
	local top = a + (b - a) * tx
	local bottom = c + (d - c) * tx
	return top + (bottom - top) * ty
end

-- Fractal sum of octaves normalised to [0, 1).
function Noise.fbm(
	seed: number | string,
	x: number,
	y: number,
	octaves: number?,
	lacunarity: number?,
	gain: number?
): number
	local total, amplitude, frequency, norm = 0, 1, 1, 0
	for octave = 1, octaves or 4 do
		total += Noise.value(seed, x * frequency + octave * 17.13, y * frequency - octave * 9.71) * amplitude
		norm += amplitude
		amplitude *= gain or 0.5
		frequency *= lacunarity or 2
	end
	return total / norm
end

return Noise
