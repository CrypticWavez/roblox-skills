--!strict
-- @tier T1
-- Slider: a labelled value control. Pointer: press or drag on the track (InputBegan,
-- InputChanged and InputEnded with MouseButton1, MouseMovement or Touch) sets the value from the
-- pointer's x inside the track rectangle (ctx.measure). Gamepad and keyboard: while the track is
-- selected, DPadLeft/DPadRight or the Left/Right arrows step it; handle.state.nudge(n) is the
-- same step for an IAS ui.navigate binding the game wires. Values snap to step and clamp to
-- min..max (Slider.quantize, pure). onChanged(value) fires on every change and onCommitted(value)
-- when a drag ends or a step lands. Fill and knob follow a snappy spring (reduced motion jumps).
-- The value is also printed as text (format number or percent), never shown by position alone.
-- Tree:
--   Slider (Frame) > Header (Frame) > Label, Value; Track (TextButton) > Rail (Frame) > Corner,
--   Fill (Frame) > Corner; Knob (Frame) > Corner, Stroke; FocusRing
local Build = require("../Build")
local Check = require("../../GameKit/Check")
local Transitions = require("../Transitions")

local RAIL_H, KNOB = 6, 20 -- px, convention

-- Decimal places of a step (0.05 -> 2, 1 -> 0), capped at 6.
local function decimals(step: number): number
	for places = 0, 6 do
		local scaled = step * 10 ^ places
		if math.abs(scaled - math.round(scaled)) < 1e-9 then
			return places
		end
	end
	return 6
end

-- value clamped to min..max and snapped to the nearest step counted from min.
local function quantize(value: number, min: number, max: number, step: number): number
	local clamped = math.clamp(value, min, max)
	if step <= 0 then
		return clamped
	end
	local snapped = min + math.round((clamped - min) / step) * step
	local places = decimals(step)
	local factor = 10 ^ places
	snapped = math.round(snapped * factor) / factor
	return math.clamp(snapped, min, max)
end

-- The value under pointer x for a track rectangle.
local function fromPosition(
	x: number,
	rect: { x: number, w: number },
	min: number,
	max: number,
	step: number
): number
	if rect.w <= 0 then
		return min
	end
	local alpha = math.clamp((x - rect.x) / rect.w, 0, 1)
	return quantize(min + alpha * (max - min), min, max, step)
end

local function alphaOf(value: number, min: number, max: number): number
	if max <= min then
		return 0
	end
	return math.clamp((value - min) / (max - min), 0, 1)
end

local function format(value: number, props: { [string]: any }): string
	if props.format == "percent" then
		return string.format("%d%%", math.round(alphaOf(value, props.min, props.max) * 100))
	elseif props.format == "none" then
		return ""
	end
	return string.format("%." .. decimals(props.step) .. "f", value)
end

local function trackHeight(ctx: Build.Context): number
	return if ctx.class.touch then ctx.tokens.size.touchMin else ctx.tokens.size.controlSmall
end

local Slider = Build.component({
	name = "Slider",
	schema = Build.schema({
		min = { kind = "number", default = 0 },
		max = { kind = "number", default = 1 },
		step = { kind = "number", min = 0, default = 0.05 },
		value = { kind = "number" },
		format = { kind = "enum", choices = { "number", "percent", "none" }, default = "number" },
		disabled = { kind = "boolean", default = false },
		onChanged = { kind = "function" },
		onCommitted = { kind = "function" },
		width = { kind = "number", min = 0, max = 4096 },
	}, true),
	check = function(props: any): { string }
		local problems = {}
		local min, max = props.min or 0, props.max or 1
		if not (min < max) then
			table.insert(problems, "min must be below max")
		end
		if props.step ~= nil and props.step > max - min then
			table.insert(problems, "step must not exceed max - min")
		end
		if props.textKey == nil and props.text == nil then
			table.insert(problems, "needs textKey or text")
		end
		return problems
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local value = quantize(props.value or props.min, props.min, props.max, props.step)
		local header = ctx.tokens.text.label.size + ctx.tokens.space.xs
		local th = trackHeight(ctx)
		local root = Build.frame(ctx, "Slider", {
			Size = if props.width
				then r.UDim2.fromOffset(props.width, header + th)
				else r.UDim2.new(1, 0, 0, header + th),
		})
		Build.tag(root, "Slider")
		local head = Build.frame(ctx, "Header", { Size = r.UDim2.new(1, 0, 0, header) }, root)
		Build.label(ctx, "Label", "label", Build.text(ctx, props), nil, {
			Size = r.UDim2.new(0.7, 0, 1, 0),
			TextTruncate = r.Enum.TextTruncate.AtEnd,
			TextWrapped = false,
		}, head)
		Build.label(ctx, "Value", "label", format(value, props), "textMuted", {
			AnchorPoint = r.Vector2.new(1, 0),
			Position = r.UDim2.fromScale(1, 0),
			Size = r.UDim2.new(0.3, 0, 1, 0),
			TextXAlignment = r.Enum.TextXAlignment.Right,
			TextWrapped = false,
		}, head)
		local track = Build.make(ctx, "TextButton", {
			Name = "Track",
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = r.UDim2.fromOffset(0, header),
			Size = r.UDim2.new(1, 0, 0, th),
		}, root)
		local rail = Build.surface(ctx, "Rail", "track", {
			AnchorPoint = r.Vector2.new(0, 0.5),
			Position = r.UDim2.new(0, KNOB / 2, 0.5, 0),
			Size = r.UDim2.new(1, -KNOB, 0, RAIL_H),
		}, track)
		Build.corner(ctx, rail, "pill")
		local alpha = alphaOf(value, props.min, props.max)
		local fill = Build.surface(ctx, "Fill", if props.disabled then "textDisabled" else "fill", {
			Size = r.UDim2.fromScale(alpha, 1),
		}, rail)
		Build.corner(ctx, fill, "pill")
		local knob = Build.surface(ctx, "Knob", if props.disabled then "textDisabled" else "fill", {
			AnchorPoint = r.Vector2.new(0.5, 0.5),
			Position = r.UDim2.new(alpha, 0, 0.5, 0),
			Size = r.UDim2.fromOffset(KNOB, KNOB),
		}, rail)
		Build.corner(ctx, knob, "pill")
		Build.stroke(ctx, knob, "background", "thick")
		Build.feedback(ctx, track, "md", false)
		Build.setEnabled(track, not props.disabled)
		root:SetAttribute("Value", value)
		return root,
			{ track = track, rail = rail, fill = fill, knob = knob, value = head:FindFirstChild("Value") }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local props = handle.props
		local parts = handle.parts
		handle.state.value = quantize(props.value or props.min, props.min, props.max, props.step)
		local dragging = false

		local function show(value: number)
			local p = handle.props
			parts.value.Text = format(value, p)
			handle.root:SetAttribute("Value", value)
			local alpha = alphaOf(value, p.min, p.max)
			local spring = ctx.tokens.motion.spring.snappy
			Build.play(
				ctx,
				Transitions.make("slider", "in", {
					Transitions.track("fill", "Size", nil, { alpha, 0, 1, 0 }, { spring = spring }),
					Transitions.track("knob", "Position", nil, { alpha, 0, 0.5, 0 }, { spring = spring }),
				}),
				{ fill = parts.fill, knob = parts.knob }
			)
		end

		local function set(value: number, notify: boolean): boolean
			local p = handle.props
			local snapped = quantize(value, p.min, p.max, p.step)
			if snapped == handle.state.value then
				return false
			end
			handle.state.value = snapped
			show(snapped)
			if notify and p.onChanged then
				p.onChanged(snapped)
			end
			return true
		end
		handle.state.set = set

		local function commit()
			local fn = handle.props.onCommitted
			if fn then
				fn(handle.state.value)
			end
		end

		-- n steps (negative for down); a step of 0 moves by a twentieth of the range.
		function handle.state.nudge(n: number): boolean
			if handle.props.disabled or not Check.finite(n) then
				return false
			end
			local p = handle.props
			local step = if p.step > 0 then p.step else (p.max - p.min) / 20
			local moved = set(handle.state.value + n * step, true)
			if moved then
				commit()
			end
			return moved
		end

		local function pointer(input: any)
			local rect = ctx.measure(parts.rail)
			if rect == nil then
				return
			end
			local p = handle.props
			set(fromPosition(input.Position.X, rect, p.min, p.max, p.step), true)
		end

		local track = parts.track
		handle.scope:Add(ctx.on(track, "InputBegan", function(input: any)
			if handle.props.disabled then
				return
			end
			local kind = input.UserInputType.Name
			if kind == "MouseButton1" or kind == "Touch" then
				dragging = true
				pointer(input)
			elseif kind == "Keyboard" or string.match(kind, "^Gamepad") then
				local key = input.KeyCode.Name
				if key == "DPadLeft" or key == "Left" then
					handle.state.nudge(-1)
				elseif key == "DPadRight" or key == "Right" then
					handle.state.nudge(1)
				end
			end
		end))
		handle.scope:Add(ctx.on(track, "InputChanged", function(input: any)
			local kind = input.UserInputType.Name
			if dragging and (kind == "MouseMovement" or kind == "Touch") then
				pointer(input)
			end
		end))
		handle.scope:Add(ctx.on(track, "InputEnded", function(input: any)
			local kind = input.UserInputType.Name
			if dragging and (kind == "MouseButton1" or kind == "Touch") then
				dragging = false
				commit()
			end
		end))
		Build.pressable(handle, track, nil, ctx)
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		local p = handle.props
		if patch.textKey ~= nil or patch.text ~= nil or patch.textArgs ~= nil then
			handle.root:FindFirstChild("Header"):FindFirstChild("Label").Text = Build.text(ctx, p)
		end
		if patch.disabled ~= nil then
			Build.setEnabled(handle.parts.track, not p.disabled)
			local slot = if p.disabled then "textDisabled" else "fill"
			handle.parts.fill.BackgroundColor3 =
				ctx.env.roblox.Color3.fromRGB(table.unpack(ctx.tokens.color[slot]))
			handle.parts.knob.BackgroundColor3 = handle.parts.fill.BackgroundColor3
		end
		if patch.value ~= nil then
			handle.state.set(patch.value, false)
		else
			handle.parts.value.Text = format(handle.state.value, p)
		end
	end,
})

Slider.quantize = quantize
Slider.fromPosition = fromPosition
Slider.decimals = decimals
Slider.format = format

return Slider
