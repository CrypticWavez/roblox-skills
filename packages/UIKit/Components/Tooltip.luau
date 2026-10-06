--!strict
-- @tier T1
-- Tooltip: a short label for a target control, shown after tokens.motion.tooltipDelay s
-- (0.4, convention) of hover (MouseEnter) or at once on gamepad selection (SelectionGained),
-- hidden on MouseLeave, SelectionLost or activation. Touch has no hover, so on touch the target
-- needs a visible label instead (audits flag icon-only buttons through the UIKitLabel attribute).
-- Tooltip.place (pure) puts the tip above the target, below when there is no room, and keeps it
-- inside the safe rectangle. The tooltip lives in a fullscreen ScreenGui on the tooltip layer
-- (Build.screenGui(ctx, name, "tooltip", true)) so measured rectangles share one origin; the
-- target and the tip are measured with ctx.measure (AbsolutePosition/AbsoluteSize in Roblox).
-- Text comes from textKey/text, else the target's UIKitLabel attribute. Tree:
--   Tooltip (Frame) > Corner, Padding, Size (UISizeConstraint), Label
local Build = require("../Build")

export type Rect = { x: number, y: number, w: number, h: number }

-- Top-left corner and side ("above" or "below") for a tip of size inside safe, gap px from the
-- target, centred on it horizontally.
local function place(
	target: Rect,
	size: { w: number, h: number },
	safe: Rect,
	gap: number?
): (number, number, string)
	local g = gap or 8
	local x = target.x + target.w / 2 - size.w / 2
	x = math.clamp(x, safe.x, math.max(safe.x, safe.x + safe.w - size.w))
	local above = target.y - g - size.h
	if above >= safe.y then
		return x, above, "above"
	end
	local below = target.y + target.h + g
	return x, math.min(below, math.max(safe.y, safe.y + safe.h - size.h)), "below"
end

local Tooltip = Build.component({
	name = "Tooltip",
	schema = Build.schema({
		target = { kind = "instance" },
		maxWidth = { kind = "number", min = 80, max = 800, default = 280 },
		delay = { kind = "number", min = 0, max = 5 },
	}, true),
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local text = Build.text(ctx, props)
		if text == "" and props.target then
			text = props.target:GetAttribute("UIKitLabel") or ""
		end
		local root = Build.surface(ctx, "Tooltip", "fill", {
			AutomaticSize = r.Enum.AutomaticSize.XY,
			Size = r.UDim2.new(),
			Visible = false,
			ZIndex = 10,
		})
		Build.corner(ctx, root, "sm")
		Build.padding(ctx, root, { "xs", "sm" })
		Build.make(ctx, "UISizeConstraint", {
			Name = "Size",
			MaxSize = r.Vector2.new(props.maxWidth, math.huge),
		}, root)
		Build.label(ctx, "Label", "caption", text, "textInverse", {
			AutomaticSize = r.Enum.AutomaticSize.XY,
			Size = r.UDim2.new(),
			ZIndex = 10,
		}, root)
		return root, { label = root:FindFirstChild("Label") }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local r = ctx.env.roblox
		local root = handle.root
		local target = handle.props.target
		local cancel: (() -> ())? = nil
		handle.state.shown = false

		local function show()
			if handle.state.shown or target == nil then
				return
			end
			local text = Build.text(ctx, handle.props)
			if text == "" then
				text = target:GetAttribute("UIKitLabel") or ""
			end
			if text == "" then
				return
			end
			handle.parts.label.Text = text
			local rect = ctx.measure(target)
			local own = ctx.measure(root)
			local host = root.Parent and ctx.measure(root.Parent)
			if rect and own and host then
				local x, y, side = place(rect, own, ctx.class.safe)
				root.Position = r.UDim2.fromOffset(x - host.x, y - host.y)
				root:SetAttribute("Side", side)
			end
			handle.state.shown = true
			root.Visible = true
			local tree = Build.fadeTree(root)
			local fade, bindings = tree:plan("in", { duration = ctx.tokens.motion.duration.fast })
			Build.play(ctx, fade, bindings)
		end

		local function hide()
			if cancel then
				cancel()
				cancel = nil
			end
			if handle.state.shown then
				handle.state.shown = false
				root.Visible = false
			end
		end

		local function later(seconds: number)
			if cancel or handle.state.shown then
				return
			end
			if seconds <= 0 then
				show()
				return
			end
			cancel = Build.after(ctx, seconds, function()
				cancel = nil
				show()
			end)
		end
		handle.state.show = show
		handle.state.hide = hide
		if target == nil then
			return
		end
		local delay = handle.props.delay or ctx.tokens.motion.tooltipDelay
		handle.scope:Add(ctx.on(target, "MouseEnter", function()
			later(delay)
		end))
		handle.scope:Add(ctx.on(target, "SelectionGained", function()
			later(0)
		end))
		for _, event in { "MouseLeave", "SelectionLost", "Activated" } do
			handle.scope:Add(ctx.on(target, event, hide))
		end
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.textKey ~= nil or patch.text ~= nil or patch.textArgs ~= nil then
			handle.parts.label.Text = Build.text(ctx, handle.props)
		end
	end,
})

Tooltip.place = place

return Tooltip
