--!strict
-- @tier T1
-- Card: a surface that groups content: an optional title (textKey/text) and subtitle, then a
-- Content frame for children (handle.parts.content), stacked vertically and as tall as the
-- content. elevated uses surfaceRaised and a border; flat uses surface. With onActivated the
-- whole card is a button (press feedback, focus ring, activation guard) and must stay at least
-- 44 px tall on touch (convention); without it the card is a plain Frame. Tree:
--   Card (Frame | TextButton) > Corner, Stroke, Padding, Layout, Title?, Subtitle?, Content
--   (Frame) > Layout; Scale?, FocusRing?
local Build = require("../Build")

local Card = Build.component({
	name = "Card",
	schema = Build.schema({
		subtitleKey = { kind = "key" },
		subtitle = { kind = "string", maxLength = 512 },
		elevated = { kind = "boolean", default = true },
		padding = { kind = "any" },
		width = { kind = "number", min = 0, max = 4096 },
		onActivated = { kind = "function" },
		disabled = { kind = "boolean", default = false },
	}, true),
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local interactive = props.onActivated ~= nil
		local slot = if props.elevated then "surfaceRaised" else "surface"
		local root
		local common = {
			Size = if props.width then r.UDim2.fromOffset(props.width, 0) else r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
		}
		if interactive then
			root = Build.make(ctx, "TextButton", {
				Name = "Card",
				Text = "",
				AutoButtonColor = false,
				BorderSizePixel = 0,
				BackgroundColor3 = r.Color3.fromRGB(table.unpack(ctx.tokens.color[slot])),
			})
			Build.tag(root, "UIKitSurface")
		else
			root = Build.surface(ctx, "Card", slot)
		end
		for key, value in common do
			root[key] = value
		end
		Build.tag(root, "Card")
		Build.corner(ctx, root, "lg")
		local stroke = Build.stroke(ctx, root, "border", "hairline")
		stroke.Enabled = props.elevated
		Build.padding(ctx, root, props.padding or "lg")
		Build.list(ctx, root, "Vertical", { gap = "xs" })
		local wrap = { Size = r.UDim2.fromScale(1, 0), AutomaticSize = r.Enum.AutomaticSize.Y }
		local parts: { [string]: any } = {}
		local title = Build.text(ctx, props)
		if title ~= "" then
			parts.title = Build.label(ctx, "Title", "title", title, nil, wrap, root)
			parts.title.LayoutOrder = 1
		end
		if props.subtitleKey or props.subtitle then
			local text = if props.subtitleKey then ctx.text(props.subtitleKey) else props.subtitle
			parts.subtitle = Build.label(ctx, "Subtitle", "body", text, "textMuted", wrap, root)
			parts.subtitle.LayoutOrder = 2
		end
		local content = Build.frame(ctx, "Content", {
			Size = r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
			LayoutOrder = 3,
		}, root)
		Build.list(ctx, content, "Vertical", { gap = "sm" })
		parts.content = content
		if interactive then
			Build.feedback(ctx, root, "lg")
			Build.make(ctx, "UISizeConstraint", {
				Name = "Size",
				MinSize = r.Vector2.new(0, if ctx.class.touch then ctx.tokens.size.touchMin else 0),
			}, root)
			Build.setEnabled(root, not props.disabled)
		end
		return root, parts
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		if handle.props.onActivated == nil then
			return
		end
		Build.pressable(handle, handle.root, function()
			local fn = handle.props.onActivated
			if fn then
				fn()
			end
		end, ctx)
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		local p = handle.props
		if handle.parts.title and (patch.textKey ~= nil or patch.text ~= nil or patch.textArgs ~= nil) then
			handle.parts.title.Text = Build.text(ctx, p)
		end
		if handle.parts.subtitle and (patch.subtitleKey ~= nil or patch.subtitle ~= nil) then
			handle.parts.subtitle.Text = if p.subtitleKey then ctx.text(p.subtitleKey) else p.subtitle
		end
		if patch.disabled ~= nil and handle.root:IsA("GuiButton") then
			Build.setEnabled(handle.root, not p.disabled)
		end
	end,
})

return Card
