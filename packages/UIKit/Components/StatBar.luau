--!strict
-- @tier T1
-- StatBar: a labelled value bar (any stat: a resource, a meter, a gauge) with value / max text,
-- optional segment ticks and a trail: when the value drops, the fill moves at once and a lighter
-- trail holds the old value for tokens.motion.duration.slow s before easing down, so the size of
-- the change stays readable; when it rises the trail jumps and the fill grows. Reduced motion
-- jumps both. Colours are slots (fill, track, textMuted for the trail), so a game themes it per
-- stat with token overrides. StatBar.fraction (pure) clamps value / max. Tree:
--   StatBar (Frame) > Header? (Frame) > Label, Value; Track (Frame) > Corner, Trail (Frame) >
--   Corner, Fill (Frame) > Corner, Ticks? (Frame) > Tick_<i>
local Build = require("../Build")
local Transitions = require("../Transitions")

local HEIGHTS = { sm = 6, md = 10, lg = 16 } -- px, convention

local function fraction(value: number, max: number): number
	if max <= 0 then
		return 0
	end
	return math.clamp(value / max, 0, 1)
end

local function valueText(value: number, max: number): string
	return string.format("%d / %d", math.round(value), math.round(max))
end

local StatBar = Build.component({
	name = "StatBar",
	schema = Build.schema({
		value = { kind = "number", required = true },
		max = { kind = "number", min = 0, required = true },
		showValue = { kind = "boolean", default = true },
		segments = { kind = "integer", min = 0, max = 20, default = 0 },
		trail = { kind = "boolean", default = true },
		size = { kind = "enum", choices = { "sm", "md", "lg" }, default = "md" },
		width = { kind = "number", min = 0, max = 4096 },
	}, true),
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local hasHeader = props.textKey ~= nil or props.text ~= nil or props.showValue
		local header = if hasHeader then ctx.tokens.text.label.size + ctx.tokens.space.xs else 0
		local h = HEIGHTS[props.size]
		local root = Build.frame(ctx, "StatBar", {
			Size = if props.width
				then r.UDim2.fromOffset(props.width, header + h)
				else r.UDim2.new(1, 0, 0, header + h),
		})
		Build.tag(root, "StatBar")
		local parts: { [string]: any } = {}
		if hasHeader then
			local head = Build.frame(ctx, "Header", { Size = r.UDim2.new(1, 0, 0, header) }, root)
			Build.label(ctx, "Label", "label", Build.text(ctx, props), nil, {
				Size = r.UDim2.new(0.6, 0, 1, 0),
				TextWrapped = false,
				TextTruncate = r.Enum.TextTruncate.AtEnd,
			}, head)
			parts.value = Build.label(
				ctx,
				"Value",
				"label",
				if props.showValue then valueText(props.value, props.max) else "",
				"textMuted",
				{
					AnchorPoint = r.Vector2.new(1, 0),
					Position = r.UDim2.fromScale(1, 0),
					Size = r.UDim2.new(0.4, 0, 1, 0),
					TextXAlignment = r.Enum.TextXAlignment.Right,
					TextWrapped = false,
				},
				head
			)
		end
		local f = fraction(props.value, props.max)
		local track = Build.surface(ctx, "Track", "track", {
			Position = r.UDim2.fromOffset(0, header),
			Size = r.UDim2.new(1, 0, 0, h),
		}, root)
		Build.corner(ctx, track, "pill")
		local trail = Build.surface(ctx, "Trail", "textMuted", {
			Size = r.UDim2.fromScale(f, 1),
			Visible = props.trail,
		}, track)
		Build.corner(ctx, trail, "pill")
		local fill = Build.surface(ctx, "Fill", "fill", { Size = r.UDim2.fromScale(f, 1) }, track)
		Build.corner(ctx, fill, "pill")
		if props.segments > 1 then
			local ticks = Build.frame(ctx, "Ticks", { Size = r.UDim2.fromScale(1, 1), ZIndex = 2 }, track)
			for index = 1, props.segments - 1 do
				Build.surface(ctx, "Tick_" .. index, "background", {
					AnchorPoint = r.Vector2.new(0.5, 0),
					Position = r.UDim2.fromScale(index / props.segments, 0),
					Size = r.UDim2.new(0, 2, 1, 0),
					ZIndex = 2,
				}, ticks)
			end
		end
		root:SetAttribute("Value", props.value)
		root:SetAttribute("Max", props.max)
		parts.track, parts.trail, parts.fill = track, trail, fill
		return root, parts
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		handle.state.fraction = fraction(handle.props.value, handle.props.max)
		function handle.state.show(value: number, max: number)
			local p = handle.props
			local target = fraction(value, max)
			local before = handle.state.fraction
			handle.state.fraction = target
			if handle.parts.value then
				handle.parts.value.Text = if p.showValue then valueText(value, max) else ""
			end
			handle.root:SetAttribute("Value", value)
			handle.root:SetAttribute("Max", max)
			local motion = ctx.tokens.motion
			local size = { target, 0, 1, 0 }
			local tracks = {
				Transitions.track("fill", "Size", nil, size, { spring = motion.spring.gentle }),
			}
			if p.trail then
				if target < before then
					table.insert(
						tracks,
						Transitions.track("trail", "Size", nil, size, {
							delay = motion.duration.slow,
							duration = motion.duration.slow,
							ease = "Quad.InOut",
						})
					)
				else
					table.insert(tracks, Transitions.track("trail", "Size", nil, size, { duration = 0 }))
				end
			end
			Build.play(
				ctx,
				Transitions.make("statBar", "in", tracks),
				{ fill = handle.parts.fill, trail = handle.parts.trail }
			)
		end
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		local p = handle.props
		if patch.textKey ~= nil or patch.text ~= nil then
			local head = handle.root:FindFirstChild("Header")
			if head then
				head:FindFirstChild("Label").Text = Build.text(ctx, p)
			end
		end
		if patch.value ~= nil or patch.max ~= nil or patch.showValue ~= nil then
			handle.state.show(p.value, p.max)
		end
	end,
})

StatBar.fraction = fraction
StatBar.valueText = valueText

return StatBar
