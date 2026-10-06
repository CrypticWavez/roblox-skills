--!strict
-- @tier T0
-- probe: ui_ease_parity
-- Ease: easing curves that mirror Enum.EasingStyle and Enum.EasingDirection, by name and by
-- enum value, so Lune plans and TweenService agree: Ease.get("Quad", "Out", alpha) is meant to
-- equal TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out). The
-- formulas are the common (Penner) ones with Back s = 1.70158, Elastic period 0.3 (0.45 for
-- InOut) and the 7.5625/2.75 Bounce; whether Roblox uses the same constants is UNVERIFIED until
-- probe ui_ease_parity compares 101 samples per curve in Studio. Endpoints are exact (0 -> 0,
-- 1 -> 1) and alpha is clamped to 0-1. Ease.spring is a closed-form damped spring (damping
-- ratio and frequency in Hz, the Feel/Spring parameterisation) for interruptible UI tracks:
-- it is a function of time, so the result never depends on the frame rate.
local Ease = {}

-- Enum.EasingStyle and Enum.EasingDirection values (checked against @lune/roblox in the spec).
Ease.STYLES = table.freeze({
	Linear = 0,
	Sine = 1,
	Back = 2,
	Quad = 3,
	Quart = 4,
	Quint = 5,
	Bounce = 6,
	Elastic = 7,
	Exponential = 8,
	Circular = 9,
	Cubic = 10,
})
Ease.DIRECTIONS = table.freeze({ In = 0, Out = 1, InOut = 2 })
Ease.STYLE_NAMES = table.freeze({
	"Linear",
	"Sine",
	"Back",
	"Quad",
	"Quart",
	"Quint",
	"Bounce",
	"Elastic",
	"Exponential",
	"Circular",
	"Cubic",
})
Ease.DIRECTION_NAMES = table.freeze({ "In", "Out", "InOut" })

local BACK = 1.70158
local PI = math.pi

local function bounceOut(t: number): number
	if t < 1 / 2.75 then
		return 7.5625 * t * t
	elseif t < 2 / 2.75 then
		local u = t - 1.5 / 2.75
		return 7.5625 * u * u + 0.75
	elseif t < 2.5 / 2.75 then
		local u = t - 2.25 / 2.75
		return 7.5625 * u * u + 0.9375
	end
	local u = t - 2.625 / 2.75
	return 7.5625 * u * u + 0.984375
end

-- The In curve of each style (Out and InOut derive from it), for 0 < t < 1.
local IN: { [string]: (t: number) -> number } = {
	Linear = function(t)
		return t
	end,
	Sine = function(t)
		return 1 - math.cos(t * PI / 2)
	end,
	Back = function(t)
		return t * t * ((BACK + 1) * t - BACK)
	end,
	Quad = function(t)
		return t * t
	end,
	Cubic = function(t)
		return t * t * t
	end,
	Quart = function(t)
		return t * t * t * t
	end,
	Quint = function(t)
		return t * t * t * t * t
	end,
	Bounce = function(t)
		return 1 - bounceOut(1 - t)
	end,
	Elastic = function(t)
		local period = 0.3
		local shift = period / 4
		return -(2 ^ (10 * (t - 1))) * math.sin((t - 1 - shift) * (2 * PI) / period)
	end,
	Exponential = function(t)
		return 2 ^ (10 * (t - 1))
	end,
	Circular = function(t)
		return 1 - math.sqrt(1 - t * t)
	end,
}

-- InOut curves that are not the mirrored In curve (Back and Elastic widen their constants).
local IN_OUT: { [string]: (t: number) -> number } = {
	Back = function(t)
		local s = BACK * 1.525
		local u = t * 2
		if u < 1 then
			return 0.5 * (u * u * ((s + 1) * u - s))
		end
		u -= 2
		return 0.5 * (u * u * ((s + 1) * u + s) + 2)
	end,
	Elastic = function(t)
		local period = 0.45
		local shift = period / 4
		local u = t * 2 - 1
		if u < 0 then
			return -0.5 * (2 ^ (10 * u)) * math.sin((u - shift) * (2 * PI) / period)
		end
		return 0.5 * (2 ^ (-10 * u)) * math.sin((u - shift) * (2 * PI) / period) + 1
	end,
}

local function resolveStyle(style: any): string?
	if type(style) == "number" then
		return Ease.STYLE_NAMES[style + 1]
	elseif type(style) == "string" and Ease.STYLES[style] ~= nil then
		return style
	elseif typeof(style) == "EnumItem" then
		return (style :: any).Name
	end
	return nil
end

local function resolveDirection(direction: any): string?
	if type(direction) == "number" then
		return Ease.DIRECTION_NAMES[direction + 1]
	elseif type(direction) == "string" and Ease.DIRECTIONS[direction] ~= nil then
		return direction
	elseif typeof(direction) == "EnumItem" then
		return (direction :: any).Name
	end
	return nil
end

-- The eased value of alpha (clamped to 0-1). style and direction are names ("Quad", "Out"),
-- enum values (3, 1) or EnumItems. Raises on unknown names.
function Ease.get(style: any, direction: any, alpha: number): number
	local s = resolveStyle(style)
	local d = resolveDirection(direction)
	if s == nil then
		error("Ease.get: unknown EasingStyle " .. tostring(style), 2)
	end
	if d == nil then
		error("Ease.get: unknown EasingDirection " .. tostring(direction), 2)
	end
	if type(alpha) ~= "number" or alpha ~= alpha then
		error("Ease.get: alpha must be a number", 2)
	end
	if alpha <= 0 then
		return 0
	elseif alpha >= 1 then
		return 1
	end
	local fn = IN[s :: string]
	if d == "In" then
		return fn(alpha)
	elseif d == "Out" then
		return 1 - fn(1 - alpha)
	end
	local special = IN_OUT[s :: string]
	if special then
		return special(alpha)
	end
	if alpha < 0.5 then
		return fn(alpha * 2) / 2
	end
	return 1 - fn((1 - alpha) * 2) / 2
end

-- (style, direction) for a name such as "Quad.Out" or "Linear"; nil when unknown.
function Ease.parse(name: any): (string?, string?)
	if type(name) ~= "string" then
		return nil, nil
	end
	local style, direction = string.match(name, "^(%a+)%.(%a+)$")
	if style == nil then
		style, direction = name, "In"
	end
	if Ease.STYLES[style :: string] == nil or Ease.DIRECTIONS[direction :: string] == nil then
		return nil, nil
	end
	return style, direction
end

function Ease.valid(name: any): boolean
	return (Ease.parse(name)) ~= nil
end

-- A curve function for a name ("Back.Out"); raises on unknown names.
function Ease.curve(name: string): (alpha: number) -> number
	local style, direction = Ease.parse(name)
	if style == nil then
		error("Ease.curve: unknown ease " .. tostring(name) .. " (use Style.Direction, e.g. Quad.Out)", 2)
	end
	return function(alpha: number): number
		return Ease.get(style, direction, alpha)
	end
end

-- n + 1 evenly spaced samples (alpha 0, 1/n, ..., 1) of a named curve.
function Ease.sample(name: string, n: number): { number }
	assert(type(n) == "number" and n >= 1 and n % 1 == 0, "Ease.sample: n must be an integer >= 1")
	local curve = Ease.curve(name)
	local out = table.create(n + 1)
	for index = 0, n do
		out[index + 1] = curve(index / n)
	end
	return out
end

-- True when a curve stays within 0-1 (no overshoot), so it is safe for transparency.
function Ease.bounded(name: string): boolean
	local style = Ease.parse(name)
	return style ~= "Back" and style ~= "Elastic"
end

-- ------------------------------------------------------------------ spring

export type SpringParams = { dampingRatio: number, frequency: number }
export type Spring = {
	dampingRatio: number,
	frequency: number,
	-- displacement and velocity at time t for a unit step from 0 to 1 starting with velocity v0
	at: (t: number, v0: number?) -> (number, number),
	-- seconds until |1 - x| and |v| stay under epsilon (bounded search)
	settle: (v0: number?, epsilon: number?) -> number,
}

local function validSpring(params: any): boolean
	return type(params) == "table"
		and type(params.dampingRatio) == "number"
		and params.dampingRatio > 0
		and params.dampingRatio == params.dampingRatio
		and params.dampingRatio < math.huge
		and type(params.frequency) == "number"
		and params.frequency > 0
		and params.frequency < math.huge
end
Ease.validSpring = validSpring

-- A damped harmonic oscillator released at x = 0 toward the target 1 with initial velocity v0
-- (units per second). dampingRatio < 1 overshoots, 1 is critical, > 1 is sluggish; frequency is
-- the undamped natural frequency in Hz. Closed form, so at(t) is exact for any t.
function Ease.spring(params: SpringParams): Spring
	if not validSpring(params) then
		error("Ease.spring: needs dampingRatio > 0 and frequency > 0", 2)
	end
	local zeta = params.dampingRatio
	local omega = 2 * PI * params.frequency
	local function at(t: number, v0: number?): (number, number)
		local v = v0 or 0
		if t <= 0 then
			return 0, v
		end
		-- y = x - 1 (offset from target): y(0) = -1, y'(0) = v.
		local y0 = -1
		local y, dy
		if math.abs(zeta - 1) < 1e-9 then
			local c2 = v + omega * y0
			local e = math.exp(-omega * t)
			y = (y0 + c2 * t) * e
			dy = (c2 - omega * (y0 + c2 * t)) * e
		elseif zeta < 1 then
			local wd = omega * math.sqrt(1 - zeta * zeta)
			local a = y0
			local b = (v + zeta * omega * y0) / wd
			local e = math.exp(-zeta * omega * t)
			local c, s = math.cos(wd * t), math.sin(wd * t)
			y = e * (a * c + b * s)
			dy = e * ((b * wd - zeta * omega * a) * c - (a * wd + zeta * omega * b) * s)
		else
			local root = omega * math.sqrt(zeta * zeta - 1)
			local r1 = -zeta * omega + root
			local r2 = -zeta * omega - root
			local c2 = (v - r1 * y0) / (r2 - r1)
			local c1 = y0 - c2
			local e1, e2 = math.exp(r1 * t), math.exp(r2 * t)
			y = c1 * e1 + c2 * e2
			dy = c1 * r1 * e1 + c2 * r2 * e2
		end
		return y + 1, dy
	end
	local function settle(v0: number?, epsilon: number?): number
		local eps = epsilon or 1e-3
		local step = 1 / 120
		local quiet = 0
		local t = 0
		-- 10 s cap: a spring that has not settled by then is a configuration error.
		while t < 10 do
			t += step
			local x, dx = at(t, v0)
			if math.abs(1 - x) < eps and math.abs(dx) < eps * omega then
				quiet += 1
				if quiet >= 6 then
					return t - step * 5
				end
			else
				quiet = 0
			end
		end
		return 10
	end
	return table.freeze({ dampingRatio = zeta, frequency = params.frequency, at = at, settle = settle })
end

return Ease
