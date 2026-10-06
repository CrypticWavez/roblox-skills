--!strict
-- @tier T1
-- Badge: a small pill with a count ("3", "99+" past max) or a dot, for unread or new markers on
-- other controls. Hidden at 0 unless showZero. The count is also kept in the Count attribute.
-- Variants accent, danger and neutral. Place it in the corner of a parent with AnchorPoint
-- (1, 0) and Position (1, 0) (anchor = "corner") or inline. Tree:
--   Badge (Frame) > Corner, Padding?, Label?
local Build = require("../Build")
local Style = require("../Style")

local FILLS = {
	accent = { fill = "accent", text = "accentText" },
	danger = { fill = "danger", text = "dangerText" },
	neutral = { fill = "surfaceRaised", text = "text" },
}
local DOT, HEIGHT = 10, 20 -- px, convention

-- The text for a count: "" at 0, the number, or "<max>+" above max.
local function text(count: number, max: number?): string
	local limit = max or 99
	if count <= 0 then
		return ""
	end
	if count > limit then
		return tostring(limit) .. "+"
	end
	return tostring(count)
end

local function paint(root: any, props: { [string]: any }, ctx: Build.Context)
	local variant = FILLS[props.variant]
	root.BackgroundColor3 = Style.color(ctx.tokens, variant.fill, ctx.env)
	root.Visible = props.dot or props.count > 0 or props.showZero
	root:SetAttribute("Count", props.count)
	local label = root:FindFirstChild("Label")
	if label then
		label.Text = if props.count <= 0 and props.showZero then "0" else text(props.count, props.max)
		label.TextColor3 = Style.color(ctx.tokens, variant.text, ctx.env)
	end
end

local Badge = Build.component({
	name = "Badge",
	schema = Build.schema({
		count = { kind = "integer", min = 0, max = 1000000000, default = 0 },
		max = { kind = "integer", min = 1, max = 99999, default = 99 },
		dot = { kind = "boolean", default = false },
		showZero = { kind = "boolean", default = false },
		variant = { kind = "enum", choices = { "accent", "danger", "neutral" }, default = "accent" },
		anchor = { kind = "enum", choices = { "corner", "inline" }, default = "inline" },
	}),
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local root = Build.make(ctx, "Frame", {
			Name = "Badge",
			BorderSizePixel = 0,
			Size = if props.dot then r.UDim2.fromOffset(DOT, DOT) else r.UDim2.fromOffset(HEIGHT, HEIGHT),
			AutomaticSize = if props.dot then r.Enum.AutomaticSize.None else r.Enum.AutomaticSize.X,
			ZIndex = 5,
		})
		if props.anchor == "corner" then
			root.AnchorPoint = r.Vector2.new(0.5, 0.5)
			root.Position = r.UDim2.new(1, -4, 0, 4)
		end
		Build.tag(root, "Badge")
		Build.corner(ctx, root, "pill")
		if not props.dot then
			Build.padding(ctx, root, { "none", "xs" })
			Build.label(ctx, "Label", "caption", "", nil, {
				Size = r.UDim2.new(0, 0, 1, 0),
				AutomaticSize = r.Enum.AutomaticSize.X,
				TextWrapped = false,
				TextXAlignment = r.Enum.TextXAlignment.Center,
				ZIndex = 5,
			}, root)
			Build.make(ctx, "UISizeConstraint", {
				Name = "Size",
				MinSize = r.Vector2.new(HEIGHT, HEIGHT),
			}, root)
		end
		paint(root, props, ctx)
		return root, {}
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.dot ~= nil then
			error("Badge: dot cannot change after mount", 3)
		end
		paint(handle.root, handle.props, ctx)
	end,
})

Badge.text = text

return Badge
