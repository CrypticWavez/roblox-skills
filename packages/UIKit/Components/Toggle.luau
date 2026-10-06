--!strict
-- @tier T1
-- Toggle: an on/off switch row: a label, a state word (On/Off keys, so state never relies on
-- colour alone) and a pill track whose knob slides on a snappy spring (reduced motion jumps and
-- the colour change becomes a short fade). The whole row is the hit target, at least 44 px tall
-- on touch (convention). props.value sets the state; activation flips it and calls
-- onChanged(value); update({ value = ... }) moves it without calling back. Tree:
--   Toggle (TextButton) > Padding, Label, State, Track (Frame) > Corner, Knob (Frame) > Corner;
--   Scale, FocusRing
local Build = require("../Build")
local Transitions = require("../Transitions")

local TRACK_W, TRACK_H, KNOB, INSET = 44, 24, 18, 3 -- px, convention
local STATE_W = 48

local function knobPosition(on: boolean): { number }
	return if on then { 1, -(INSET + KNOB), 0.5, 0 } else { 0, INSET, 0.5, 0 }
end

local function slots(on: boolean, disabled: boolean): (string, string)
	if disabled then
		return "track", "textDisabled"
	end
	return if on then "accent" else "track", if on then "accentText" else "textMuted"
end

local function rowHeight(ctx: Build.Context): number
	local h = ctx.tokens.size.control
	if ctx.class.touch then
		h = math.max(h, ctx.tokens.size.touchMin)
	end
	return h
end

local Toggle = Build.component({
	name = "Toggle",
	schema = Build.schema({
		value = { kind = "boolean", default = false },
		disabled = { kind = "boolean", default = false },
		onChanged = { kind = "function" },
		width = { kind = "number", min = 0, max = 4096 },
	}, true),
	check = function(props: any): { string }
		if props.textKey == nil and props.text == nil then
			return { "needs textKey or text" }
		end
		return {}
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local on = props.value == true
		local root = Build.make(ctx, "TextButton", {
			Name = "Toggle",
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = if props.width
				then r.UDim2.fromOffset(props.width, rowHeight(ctx))
				else r.UDim2.new(1, 0, 0, rowHeight(ctx)),
		})
		Build.tag(root, "Toggle")
		Build.label(ctx, "Label", "body", Build.text(ctx, props), nil, {
			Size = r.UDim2.new(1, -(TRACK_W + STATE_W + 2 * ctx.tokens.space.sm), 1, 0),
			TextTruncate = r.Enum.TextTruncate.AtEnd,
			TextWrapped = false,
		}, root)
		Build.label(ctx, "State", "label", ctx.text(if on then "uikit.on" else "uikit.off"), "textMuted", {
			AnchorPoint = r.Vector2.new(1, 0.5),
			Position = r.UDim2.new(1, -(TRACK_W + ctx.tokens.space.sm), 0.5, 0),
			Size = r.UDim2.new(0, STATE_W, 1, 0),
			TextXAlignment = r.Enum.TextXAlignment.Right,
			TextWrapped = false,
		}, root)
		local trackSlot, knobSlot = slots(on, props.disabled)
		local track = Build.surface(ctx, "Track", trackSlot, {
			AnchorPoint = r.Vector2.new(1, 0.5),
			Position = r.UDim2.new(1, 0, 0.5, 0),
			Size = r.UDim2.fromOffset(TRACK_W, TRACK_H),
		}, root)
		Build.corner(ctx, track, "pill")
		local p = knobPosition(on)
		local knob = Build.surface(ctx, "Knob", knobSlot, {
			AnchorPoint = r.Vector2.new(0, 0.5),
			Position = r.UDim2.new(p[1], p[2], p[3], p[4]),
			Size = r.UDim2.fromOffset(KNOB, KNOB),
		}, track)
		Build.corner(ctx, knob, "pill")
		Build.feedback(ctx, root, "md")
		Build.setEnabled(root, not props.disabled)
		root:SetAttribute("Value", on)
		return root, { track = track, knob = knob, state = root:FindFirstChild("State") }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		handle.state.value = handle.props.value == true
		local function show(on: boolean, animate: boolean)
			local parts = handle.parts
			local trackSlot, knobSlot = slots(on, handle.props.disabled)
			parts.state.Text = ctx.text(if on then "uikit.on" else "uikit.off")
			handle.root:SetAttribute("Value", on)
			local spring = ctx.tokens.motion.spring.snappy
			local plan = Transitions.make("toggle", if on then "in" else "out", {
				Transitions.track("knob", "Position", nil, knobPosition(on), { spring = spring }),
				Transitions.track("track", "BackgroundColor3", nil, Build.color01(ctx, trackSlot), {
					duration = ctx.tokens.motion.duration.fast,
					ease = "Quad.Out",
				}),
				Transitions.track("knob", "BackgroundColor3", nil, Build.color01(ctx, knobSlot), {
					duration = ctx.tokens.motion.duration.fast,
					ease = "Quad.Out",
				}),
			})
			local playing = Build.play(ctx, plan, { knob = parts.knob, track = parts.track })
			if not animate then
				playing:finish()
			end
		end
		handle.state.show = show
		function handle.state.set(on: boolean, notify: boolean?)
			if on == handle.state.value then
				return
			end
			handle.state.value = on
			show(on, true)
			if notify and handle.props.onChanged then
				handle.props.onChanged(on)
			end
		end
		Build.pressable(handle, handle.root, function()
			handle.state.set(not handle.state.value, true)
		end, ctx)
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.textKey ~= nil or patch.text ~= nil or patch.textArgs ~= nil then
			handle.root:FindFirstChild("Label").Text = Build.text(ctx, handle.props)
		end
		Build.setEnabled(handle.root, not handle.props.disabled)
		if patch.value ~= nil and patch.value ~= handle.state.value then
			handle.state.set(patch.value, false)
		elseif patch.disabled ~= nil then
			handle.state.show(handle.state.value, false)
		end
	end,
})

Toggle.TRACK = table.freeze({ width = TRACK_W, height = TRACK_H, knob = KNOB, inset = INSET })
Toggle.knobPosition = knobPosition

return Toggle
