--!strict
-- @tier T1
-- KeybindPrompt: "[E] Interact" for the current device. The glyph comes from GameKit/InputMap
-- (InputMap.glyph: key caps for KeyboardAndMouse, pad names in the xbox or playstation style for
-- Gamepad, a "Tap" cap for Touch where the action is an on-screen button). When ctx.glyphImage
-- returns an image for the key (the adapter wraps UserInputService:GetImageForKeyCode), it is
-- shown instead of the text cap. The action label is labelKey, else the action's own labelKey
-- (input.<action>). hold = true adds a progress bar under the prompt (progress 0-1) for
-- hold-to-confirm. update({ device }) swaps the glyph when PreferredInput changes. The map comes
-- from props.map or ctx.inputMap. Tree:
--   KeybindPrompt (Frame) > Layout, Glyph (Frame) > Corner, Stroke, Padding, Key (TextLabel),
--   Image (ImageLabel), Size, Hold? (Frame) > Corner, Fill (Frame) > Corner; Label (TextLabel)
local Build = require("../Build")
local InputMap = require("../../GameKit/InputMap")

local CAP = 28 -- px, convention

local function mapOf(props: { [string]: any }, ctx: Build.Context): any
	local map = props.map or ctx.inputMap
	if map == nil then
		map = InputMap.defaults()
	end
	return map
end

local function deviceOf(props: { [string]: any }, ctx: Build.Context): string
	return props.device or ctx.class.input
end

local function glyphFor(props: { [string]: any }, ctx: Build.Context): any
	return InputMap.glyph(mapOf(props, ctx), props.action, deviceOf(props, ctx), props.style)
end

local function paintGlyph(cap: any, props: { [string]: any }, ctx: Build.Context)
	local r = ctx.env.roblox
	local glyph = glyphFor(props, ctx)
	local key = cap:FindFirstChild("Key")
	local image = cap:FindFirstChild("Image")
	local url = if glyph.key and ctx.glyphImage then ctx.glyphImage(glyph.key) else nil
	if type(url) == "string" and url ~= "" then
		image.Image = url
		image.Visible = true
		key.Visible = false
		cap.BackgroundTransparency = 1
	else
		image.Visible = false
		key.Visible = true
		key.Text = if glyph.kind == "touch" then ctx.text("uikit.keybind.tap") else glyph.text
		cap.BackgroundTransparency = 0
	end
	cap:FindFirstChild("Corner").CornerRadius = if glyph.kind == "pad"
		then r.UDim.new(0.5, 0)
		else r.UDim.new(0, ctx.tokens.radius.sm)
	cap:SetAttribute("GlyphKind", glyph.kind)
	cap:SetAttribute("GlyphKey", glyph.key or "")
end

local KeybindPrompt = Build.component({
	name = "KeybindPrompt",
	schema = Build.schema({
		action = { kind = "string", maxLength = 64, required = true },
		map = { kind = "table" },
		device = { kind = "enum", choices = { "KeyboardAndMouse", "Gamepad", "Touch" } },
		style = { kind = "enum", choices = { "xbox", "playstation" }, default = "xbox" },
		labelKey = { kind = "key" },
		hold = { kind = "boolean", default = false },
		progress = { kind = "number", min = 0, max = 1, default = 0 },
	}),
	-- With props.map the action is checked here; with ctx.inputMap (which check cannot see) build
	-- checks it and raises.
	check = function(props: any): { string }
		if props.map == nil then
			return {}
		end
		local problems = InputMap.validate(props.map, { allowUnbound = true })
		if #problems > 0 then
			return { "map: " .. problems[1] }
		end
		if props.map.actions[props.action] == nil then
			return { "action " .. tostring(props.action) .. " is not in the input map" }
		end
		return {}
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local map = mapOf(props, ctx)
		local action = map.actions[props.action]
		if action == nil then
			error("KeybindPrompt: action " .. props.action .. " is not in ctx.inputMap", 3)
		end
		local root = Build.frame(ctx, "KeybindPrompt", {
			Size = r.UDim2.fromOffset(0, CAP + (if props.hold then 6 else 0)),
			AutomaticSize = r.Enum.AutomaticSize.X,
		})
		Build.tag(root, "KeybindPrompt")
		Build.list(ctx, root, "Horizontal", { gap = "xs", valign = "Top" })
		local cap = Build.surface(ctx, "Glyph", "fill", {
			Size = r.UDim2.fromOffset(CAP, CAP),
			AutomaticSize = r.Enum.AutomaticSize.X,
			LayoutOrder = 1,
		})
		cap.Parent = root
		Build.corner(ctx, cap, "sm")
		Build.stroke(ctx, cap, "borderStrong", "hairline")
		Build.padding(ctx, cap, { "none", "xs" })
		Build.label(ctx, "Key", "label", "", "textInverse", {
			Size = r.UDim2.new(0, 0, 1, 0),
			AutomaticSize = r.Enum.AutomaticSize.X,
			TextWrapped = false,
			TextXAlignment = r.Enum.TextXAlignment.Center,
		}, cap)
		Build.make(ctx, "ImageLabel", {
			Name = "Image",
			BackgroundTransparency = 1,
			Size = r.UDim2.fromOffset(CAP - 4, CAP - 4),
			ScaleType = r.Enum.ScaleType.Fit,
			Visible = false,
		}, cap)
		Build.make(ctx, "UISizeConstraint", { Name = "Size", MinSize = r.Vector2.new(CAP, CAP) }, cap)
		Build.label(ctx, "Label", "label", ctx.text(props.labelKey or action.labelKey), nil, {
			Size = r.UDim2.new(0, 0, 0, CAP),
			AutomaticSize = r.Enum.AutomaticSize.X,
			TextWrapped = false,
			LayoutOrder = 2,
		}, root)
		local parts: { [string]: any } = { cap = cap }
		if props.hold then
			local bar = Build.surface(ctx, "Hold", "track", {
				Position = r.UDim2.new(0, 0, 1, -3),
				Size = r.UDim2.new(1, 0, 0, 3),
				LayoutOrder = 3,
			})
			Build.corner(ctx, bar, "pill")
			local fill =
				Build.surface(ctx, "Fill", "fill", { Size = r.UDim2.fromScale(props.progress, 1) }, bar)
			Build.corner(ctx, fill, "pill")
			-- Along the bottom edge of the glyph cap (the cap has no layout, so it stays put).
			bar.Parent = cap
			parts.hold, parts.fill = bar, fill
		end
		paintGlyph(cap, props, ctx)
		root:SetAttribute("Action", props.action)
		return root, parts
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		local p = handle.props
		if patch.device ~= nil or patch.style ~= nil or patch.map ~= nil then
			paintGlyph(handle.parts.cap, p, ctx)
		end
		if patch.progress ~= nil and handle.parts.fill then
			handle.parts.fill.Size = ctx.env.roblox.UDim2.fromScale(p.progress, 1)
		end
	end,
})

KeybindPrompt.glyphFor = glyphFor

return KeybindPrompt
