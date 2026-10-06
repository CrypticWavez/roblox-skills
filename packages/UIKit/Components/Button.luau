--!strict
-- @tier T1
-- Button: a text button with variants primary, secondary, ghost and danger (StyleSheet tags
-- .Button.Primary ...), sizes sm, md and lg, an optional leading glyph and a disabled state
-- (Interactable = false). Height never drops below the 44 px touch minimum (convention) on
-- touch devices. Press feedback (UIScale spring), a focus ring for gamepad selection and a
-- re-entrancy guard on onActivated come from Build.pressable. Tree:
--   Button (TextButton) > Corner, Padding, Stroke, Layout, Icon?, Label, Scale, FocusRing
local Build = require("../Build")
local Style = require("../Style")

local VARIANTS = {
	primary = { fill = "accent", text = "accentText", tag = "Primary", stroke = false },
	secondary = { fill = "surfaceRaised", text = "text", tag = "Secondary", stroke = true },
	ghost = { fill = "surface", text = "text", tag = "Ghost", stroke = false },
	danger = { fill = "danger", text = "dangerText", tag = "Danger", stroke = false },
}

local function height(props: { [string]: any }, ctx: Build.Context): number
	local size = ctx.tokens.size
	local h = if props.size == "sm"
		then size.controlSmall
		elseif props.size == "lg" then size.controlLarge
		else size.control
	if ctx.class.touch then
		h = math.max(h, size.touchMin)
	end
	return h
end

local function paint(root: any, props: { [string]: any }, ctx: Build.Context)
	local variant = VARIANTS[props.variant]
	local disabled = props.disabled == true
	root.BackgroundColor3 = Style.color(ctx.tokens, variant.fill, ctx.env)
	root.BackgroundTransparency = if props.variant == "ghost"
		then 1
		elseif disabled then ctx.tokens.alpha.disabled
		else 0
	local slot = if disabled then "textDisabled" else variant.text
	local label = root:FindFirstChild("Label")
	label.TextColor3 = Style.color(ctx.tokens, slot, ctx.env)
	local icon = root:FindFirstChild("Icon")
	if icon then
		icon.TextColor3 = label.TextColor3
	end
	root:FindFirstChild("Stroke").Enabled = variant.stroke
	Build.setEnabled(root, not disabled)
end

local Button = Build.component({
	name = "Button",
	schema = Build.schema({
		variant = {
			kind = "enum",
			choices = { "primary", "secondary", "ghost", "danger" },
			default = "primary",
		},
		size = { kind = "enum", choices = { "sm", "md", "lg" }, default = "md" },
		disabled = { kind = "boolean", default = false },
		icon = { kind = "string", maxLength = 8 },
		width = { kind = "number", min = 0, max = 4096 },
		fill = { kind = "boolean", default = false },
		onActivated = { kind = "function" },
	}, true),
	check = function(props: any): { string }
		if props.textKey == nil and props.text == nil then
			return { "needs textKey or text" }
		end
		if props.width ~= nil and props.fill == true then
			return { "width and fill are exclusive" }
		end
		return {}
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local h = height(props, ctx)
		local root = Build.make(ctx, "TextButton", {
			Name = "Button",
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			Size = if props.fill then r.UDim2.new(1, 0, 0, h) else r.UDim2.new(0, props.width or 0, 0, h),
			AutomaticSize = if props.fill or props.width
				then r.Enum.AutomaticSize.None
				else r.Enum.AutomaticSize.X,
			ClipsDescendants = false,
		})
		Build.tag(root, "Button", VARIANTS[props.variant].tag)
		Build.corner(ctx, root, "md")
		local horizontal = if props.size == "sm" then "md" elseif props.size == "lg" then "xl" else "lg"
		Build.padding(ctx, root, { "none", horizontal })
		Build.stroke(ctx, root, "border", "thin")
		Build.list(ctx, root, "Horizontal", { gap = "xs", align = "Center", valign = "Center" })
		if props.icon then
			Build.label(ctx, "Icon", "button", props.icon, nil, {
				Size = r.UDim2.new(0, 0, 1, 0),
				AutomaticSize = r.Enum.AutomaticSize.X,
				TextWrapped = false,
				LayoutOrder = 1,
				TextXAlignment = r.Enum.TextXAlignment.Center,
			}, root)
		end
		Build.label(ctx, "Label", "button", Build.text(ctx, props), nil, {
			Size = if props.fill or props.width then r.UDim2.new(1, 0, 1, 0) else r.UDim2.new(0, 0, 1, 0),
			AutomaticSize = if props.fill or props.width
				then r.Enum.AutomaticSize.None
				else r.Enum.AutomaticSize.X,
			TextWrapped = false,
			TextTruncate = r.Enum.TextTruncate.AtEnd,
			TextXAlignment = r.Enum.TextXAlignment.Center,
			LayoutOrder = 2,
		}, root)
		Build.feedback(ctx, root, "md")
		paint(root, props, ctx)
		return root, { label = root:FindFirstChild("Label") }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		Build.pressable(handle, handle.root, function()
			local fn = handle.props.onActivated
			if fn then
				fn()
			end
		end, ctx)
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.textKey ~= nil or patch.text ~= nil or patch.textArgs ~= nil then
			handle.parts.label.Text = Build.text(ctx, handle.props)
		end
		paint(handle.root, handle.props, ctx)
	end,
})

return Button
