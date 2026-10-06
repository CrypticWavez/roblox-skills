--!strict
-- @tier T1
-- ProgressBar: a determinate bar (value 0-1) or an indeterminate one (a segment sweeping across,
-- looping; reduced motion shows a still segment instead). An optional label (textKey/text) and
-- percentage (showValue) sit above it, so progress is readable as text as well. Value changes
-- ease the fill with the gentle spring (reduced motion jumps). Tree:
--   ProgressBar (Frame) > Header? (Frame) > Label, Value; Track (Frame) > Corner, Fill (Frame) > Corner
local Build = require("../Build")
local Transitions = require("../Transitions")

local TRACK_H = 8 -- px, convention
local SEGMENT = 0.3 -- indeterminate segment width (scale)

local function percent(value: number): string
	return string.format("%d%%", math.round(math.clamp(value, 0, 1) * 100))
end

local ProgressBar = Build.component({
	name = "ProgressBar",
	schema = Build.schema({
		value = { kind = "number", min = 0, max = 1, default = 0 },
		indeterminate = { kind = "boolean", default = false },
		showValue = { kind = "boolean", default = false },
		width = { kind = "number", min = 0, max = 4096 },
	}, true),
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local hasHeader = props.textKey ~= nil or props.text ~= nil or props.showValue
		local header = if hasHeader then ctx.tokens.text.label.size + ctx.tokens.space.xs else 0
		local root = Build.frame(ctx, "ProgressBar", {
			Size = if props.width
				then r.UDim2.fromOffset(props.width, header + TRACK_H)
				else r.UDim2.new(1, 0, 0, header + TRACK_H),
		})
		Build.tag(root, "ProgressBar")
		local parts: { [string]: any } = {}
		if hasHeader then
			local head = Build.frame(ctx, "Header", { Size = r.UDim2.new(1, 0, 0, header) }, root)
			Build.label(ctx, "Label", "label", Build.text(ctx, props), nil, {
				Size = r.UDim2.new(0.75, 0, 1, 0),
				TextWrapped = false,
				TextTruncate = r.Enum.TextTruncate.AtEnd,
			}, head)
			parts.value = Build.label(
				ctx,
				"Value",
				"label",
				if props.showValue and not props.indeterminate then percent(props.value) else "",
				"textMuted",
				{
					AnchorPoint = r.Vector2.new(1, 0),
					Position = r.UDim2.fromScale(1, 0),
					Size = r.UDim2.new(0.25, 0, 1, 0),
					TextXAlignment = r.Enum.TextXAlignment.Right,
					TextWrapped = false,
				},
				head
			)
		end
		local track = Build.surface(ctx, "Track", "track", {
			Position = r.UDim2.fromOffset(0, header),
			Size = r.UDim2.new(1, 0, 0, TRACK_H),
			ClipsDescendants = true,
		}, root)
		Build.corner(ctx, track, "pill")
		local fill = Build.surface(ctx, "Fill", "fill", {
			Size = if props.indeterminate
				then r.UDim2.fromScale(SEGMENT, 1)
				else r.UDim2.fromScale(props.value, 1),
		}, track)
		Build.corner(ctx, fill, "pill")
		parts.track, parts.fill = track, fill
		root:SetAttribute("Value", props.value)
		return root, parts
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local generation = 0
		local function sweep()
			generation += 1
			local mark = generation
			local fill = handle.parts.fill
			fill.Size = ctx.env.roblox.UDim2.fromScale(SEGMENT, 1)
			if ctx.motion.reducedMotion then
				fill.Position = ctx.env.roblox.UDim2.fromScale((1 - SEGMENT) / 2, 0)
				return
			end
			local plan = Transitions.make("progressSweep", "in", {
				Transitions.track("fill", "Position", { -SEGMENT, 0, 0, 0 }, { 1, 0, 0, 0 }, {
					duration = 1.2,
					ease = "Sine.InOut",
				}),
			})
			ctx.runner:play(plan, { fill = fill }, {
				onComplete = function(state: string)
					if
						state == "completed"
						and mark == generation
						and handle.props.indeterminate
						and not handle.destroyed
					then
						sweep()
					end
				end,
			})
		end
		local function show(value: number)
			generation += 1
			local fill = handle.parts.fill
			fill.Position = ctx.env.roblox.UDim2.new()
			if handle.parts.value then
				handle.parts.value.Text = if handle.props.showValue then percent(value) else ""
			end
			handle.root:SetAttribute("Value", value)
			Build.play(
				ctx,
				Transitions.make("progress", "in", {
					Transitions.track(
						"fill",
						"Size",
						nil,
						{ value, 0, 1, 0 },
						{ spring = ctx.tokens.motion.spring.gentle }
					),
				}),
				{ fill = fill }
			)
		end
		handle.state.sweep = sweep
		handle.state.show = show
		if handle.props.indeterminate then
			sweep()
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
		if p.indeterminate then
			if patch.indeterminate == true then
				handle.state.sweep()
			end
		elseif patch.value ~= nil or patch.indeterminate == false or patch.showValue ~= nil then
			handle.state.show(p.value)
		end
	end,
})

ProgressBar.percent = percent

return ProgressBar
