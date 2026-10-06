--!strict
-- @tier T1
-- RollingCounter: a number that rolls to its new value (Quint.Out over
-- tokens.motion.duration.emphasis s) with a small scale pop on increases; reduced motion jumps
-- straight to the value. The roll animates a proxy { Value } through the transition runner, so a
-- new value mid-roll continues from the number on screen. RollingCounter.format (pure) renders
-- integer ("12,345"), compact ("12.3K", rounded down so it never overstates) or fixed ("12.35",
-- decimals) with a configurable thousands separator (convention: ","; pass the locale's).
-- textKey (optional) wraps the number with {value}. Tree:
--   RollingCounter (TextLabel) > Scale (UIScale)
local Build = require("../Build")
local Transitions = require("../Transitions")

local SUFFIXES = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }

local function group(digits: string, separator: string): string
	local out = digits
	while true do
		local replaced, count = string.gsub(out, "^(%d+)(%d%d%d)", "%1" .. separator .. "%2")
		out = replaced
		if count == 0 then
			break
		end
	end
	return out
end

-- Text for n in a style: integer (rounded), compact or fixed (decimals places).
local function format(n: number, style: string?, decimals: number?, separator: string?): string
	local sep = separator or ","
	local negative = n < 0
	local a = math.abs(n)
	local text
	if style == "compact" then
		text = nil
		for _, entry in SUFFIXES do
			if a >= entry[1] then
				local scaled = math.floor(a / entry[1] * 10) / 10
				text = (
					if scaled % 1 == 0 then string.format("%d", scaled) else string.format("%.1f", scaled)
				) .. entry[2]
				break
			end
		end
		if text == nil then
			text = string.format("%d", math.round(a))
		end
	elseif style == "fixed" then
		local places = decimals or 2
		local raw = string.format("%." .. places .. "f", a)
		local whole, fraction = string.match(raw, "^(%d+)(.*)$")
		text = group(whole :: string, sep) .. (fraction or "")
	else
		text = group(string.format("%d", math.round(a)), sep)
	end
	if negative and text ~= "0" then
		return "-" .. text
	end
	return text
end

local RollingCounter = Build.component({
	name = "RollingCounter",
	schema = Build.schema({
		value = { kind = "number", required = true },
		style = { kind = "enum", choices = { "integer", "compact", "fixed" }, default = "integer" },
		decimals = { kind = "integer", min = 0, max = 6, default = 2 },
		separator = { kind = "string", maxLength = 2, default = "," },
		role = {
			kind = "enum",
			choices = { "numeric", "title", "heading", "display", "body" },
			default = "numeric",
		},
		align = { kind = "enum", choices = { "Left", "Center", "Right" }, default = "Left" },
		textKey = { kind = "key" },
	}),
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local function render(value: number): string
			local text = format(value, props.style, props.decimals, props.separator)
			return if props.textKey then ctx.text(props.textKey, { value = text }) else text
		end
		local root = Build.label(ctx, "RollingCounter", props.role, render(props.value), nil, {
			AutomaticSize = r.Enum.AutomaticSize.XY,
			Size = r.UDim2.new(),
			TextWrapped = false,
			TextXAlignment = r.Enum.TextXAlignment[props.align],
		})
		Build.make(ctx, "UIScale", { Name = "Scale", Scale = 1 }, root)
		root:SetAttribute("Value", props.value)
		return root, { scale = root:FindFirstChild("Scale") }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local root = handle.root
		local current = handle.props.value
		local function render(value: number)
			local p = handle.props
			local rounded = if p.style == "fixed" then value else math.round(value)
			local text = format(rounded, p.style, p.decimals, p.separator)
			root.Text = if p.textKey then ctx.text(p.textKey, { value = text }) else text
		end
		-- The runner writes proxy.Value each frame; reading it gives the number on screen.
		local proxy = setmetatable({}, {
			__index = function(_, key: string): any
				return if key == "Value" then current else nil
			end,
			__newindex = function(_, key: string, value: any)
				if key == "Value" then
					current = value
					render(value)
				end
			end,
		})
		handle.state.proxy = proxy
		function handle.state.current(): number
			return current
		end
		function handle.state.roll(target: number)
			local motion = ctx.tokens.motion
			local tracks = {
				Transitions.track("counter", "Value", nil, target, {
					duration = motion.duration.emphasis,
					ease = motion.ease.enter,
				}),
			}
			if target > current then
				table.insert(
					tracks,
					Transitions.track(
						"scale",
						"Scale",
						1.08,
						1,
						{ duration = motion.duration.slow, ease = "Back.Out" }
					)
				)
			end
			root:SetAttribute("Value", target)
			Build.play(ctx, Transitions.make("rollingCounter", "in", tracks), {
				counter = proxy,
				scale = handle.parts.scale,
			})
		end
		handle.scope:Add(function()
			ctx.runner:stop(proxy)
		end)
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, _ctx: Build.Context)
		if patch.value ~= nil then
			handle.state.roll(patch.value)
		end
	end,
})

RollingCounter.format = format

return RollingCounter
