--!strict
-- @tier T1
-- IconButton: a square button showing a glyph (short text such as "+" or "x") or an image asset,
-- with a required labelKey naming the action. Roblox has no screen-reader label, so the localised
-- label is kept in the UIKitLabel attribute for tooltips, audits and the gallery. Variants
-- primary, secondary and ghost; sizes sm, md and lg (controlSmall, control, controlLarge tokens),
-- never under the 44 px touch minimum on touch devices (convention). Press feedback, the focus
-- ring and the activation guard come from Build.pressable. Tree:
--   IconButton (TextButton) > Corner, Stroke, Glyph (TextLabel) | Image (ImageLabel), Scale, FocusRing
local Build = require("../Build")
local Style = require("../Style")

local VARIANTS = {
	primary = { fill = "accent", text = "accentText", stroke = false, transparent = false },
	secondary = { fill = "surfaceRaised", text = "text", stroke = true, transparent = false },
	ghost = { fill = "surface", text = "text", stroke = false, transparent = true },
}

local function side(props: { [string]: any }, ctx: Build.Context): number
	local size = ctx.tokens.size
	local px = if props.size == "sm"
		then size.controlSmall
		elseif props.size == "lg" then size.controlLarge
		else size.control
	if ctx.class.touch then
		px = math.max(px, size.touchMin)
	end
	return px
end

local function paint(root: any, props: { [string]: any }, ctx: Build.Context)
	local variant = VARIANTS[props.variant]
	local disabled = props.disabled == true
	root.BackgroundColor3 = Style.color(ctx.tokens, variant.fill, ctx.env)
	root.BackgroundTransparency = if variant.transparent
		then 1
		elseif disabled then ctx.tokens.alpha.disabled
		else 0
	local color = Style.color(ctx.tokens, if disabled then "textDisabled" else variant.text, ctx.env)
	local glyph = root:FindFirstChild("Glyph")
	if glyph then
		glyph.TextColor3 = color
	end
	local image = root:FindFirstChild("Image")
	if image then
		image.ImageColor3 = color
		image.ImageTransparency = if disabled then ctx.tokens.alpha.disabled else 0
	end
	root:FindFirstChild("Stroke").Enabled = variant.stroke
	Build.setEnabled(root, not disabled)
	root:SetAttribute("UIKitLabel", ctx.text(props.labelKey))
end

local IconButton = Build.component({
	name = "IconButton",
	schema = Build.schema({
		labelKey = { kind = "key", required = true },
		glyph = { kind = "string", maxLength = 8 },
		image = { kind = "string", maxLength = 256 },
		variant = { kind = "enum", choices = { "primary", "secondary", "ghost" }, default = "secondary" },
		size = { kind = "enum", choices = { "sm", "md", "lg" }, default = "md" },
		round = { kind = "boolean", default = false },
		disabled = { kind = "boolean", default = false },
		onActivated = { kind = "function" },
	}),
	check = function(props: any): { string }
		if (props.glyph == nil) == (props.image == nil) then
			return { "needs exactly one of glyph or image" }
		end
		if props.image ~= nil and not string.match(props.image, "^rbx%w*://") then
			return { "image must be an rbxassetid:// (or rbxasset://) content id" }
		end
		return {}
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local px = side(props, ctx)
		local root = Build.make(ctx, "TextButton", {
			Name = "IconButton",
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			Size = r.UDim2.fromOffset(px, px),
		})
		Build.tag(root, "IconButton")
		local radius = if props.round then "pill" else "md"
		Build.corner(ctx, root, radius)
		Build.stroke(ctx, root, "border", "thin")
		local icon = math.floor(px * 0.55 + 0.5)
		local centre = {
			AnchorPoint = r.Vector2.new(0.5, 0.5),
			Position = r.UDim2.fromScale(0.5, 0.5),
			Size = r.UDim2.fromOffset(icon, icon),
		}
		if props.glyph then
			local glyph = Build.label(ctx, "Glyph", "button", props.glyph, nil, centre, root)
			glyph.TextSize = icon
			glyph.TextWrapped = false
			glyph.TextXAlignment = r.Enum.TextXAlignment.Center
		else
			local image = Build.make(ctx, "ImageLabel", {
				Name = "Image",
				Image = props.image,
				BackgroundTransparency = 1,
				ScaleType = r.Enum.ScaleType.Fit,
			}, root)
			for key, value in centre do
				image[key] = value
			end
		end
		Build.feedback(ctx, root, radius)
		paint(root, props, ctx)
		return root, {}
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		Build.pressable(handle, handle.root, function()
			local fn = handle.props.onActivated
			if fn then
				fn()
			end
		end, ctx)
	end,
	update = function(handle: Build.Handle, _patch: { [string]: any }, ctx: Build.Context)
		paint(handle.root, handle.props, ctx)
	end,
})

return IconButton
