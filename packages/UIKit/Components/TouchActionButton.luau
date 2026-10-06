--!strict
-- @tier T1
-- TouchActionButton: a round on-screen button for a gameplay action on touch devices (72 px,
-- 56 px small; conventions above the 44 px minimum). It is the GuiButton behind an InputMap
-- touch binding "ui:<uiKey>": the InputMapKey attribute ("ui:<uiKey>") lets InputMapRoblox find
-- it and bind InputBinding.UIButton, so the action fires through the Input Action System like
-- any key. Without IAS wiring it still works: onPressed(true / false) on press and release (hold
-- actions) and onActivated() on a tap. cooldown (0-1) dims the button from the top with a hard
-- gradient edge so the remaining time reads at a glance; a cooling button still reports presses
-- (the action decides). Hidden unless the device class is touch (alwaysVisible overrides, for the
-- gallery). Place several in a cluster in the bottom-right safe area. Tree:
--   TouchActionButton (TextButton) > Corner, Stroke, Glyph (TextLabel) | Image (ImageLabel),
--   Cooldown (Frame) > Corner, Gradient (UIGradient); Scale, FocusRing
local Build = require("../Build")
local Style = require("../Style")

local function sizeOf(props: { [string]: any }, ctx: Build.Context): number
	local size = ctx.tokens.size
	return math.max(if props.size == "sm" then size.actionButtonSmall else size.actionButton, size.touchMin)
end

-- Transparency keypoints for a cooldown fraction: dim (0.35) over the top `fraction`, clear below.
local function cooldownKeypoints(fraction: number): { { number } }
	local f = math.clamp(fraction, 0, 1)
	if f <= 0 then
		return { { 0, 1 }, { 1, 1 } }
	elseif f >= 1 then
		return { { 0, 0.35 }, { 1, 0.35 } }
	end
	local edge = math.max(f - 0.001, 0.0005)
	return { { 0, 0.35 }, { edge, 0.35 }, { f, 1 }, { 1, 1 } }
end

local function paintCooldown(root: any, fraction: number, ctx: Build.Context)
	local r = ctx.env.roblox
	local overlay = root:FindFirstChild("Cooldown")
	local points = {}
	for _, point in cooldownKeypoints(fraction) do
		table.insert(points, r.NumberSequenceKeypoint.new(point[1], point[2]))
	end
	overlay:FindFirstChild("Gradient").Transparency = r.NumberSequence.new(points)
	overlay.Visible = fraction > 0
	root:SetAttribute("Cooldown", fraction)
end

local TouchActionButton = Build.component({
	name = "TouchActionButton",
	schema = Build.schema({
		action = { kind = "string", maxLength = 64, required = true },
		uiKey = { kind = "label", required = true },
		labelKey = { kind = "key", required = true },
		glyph = { kind = "string", maxLength = 8 },
		image = { kind = "string", maxLength = 256 },
		size = { kind = "enum", choices = { "sm", "md" }, default = "md" },
		cooldown = { kind = "number", min = 0, max = 1, default = 0 },
		alwaysVisible = { kind = "boolean", default = false },
		disabled = { kind = "boolean", default = false },
		onPressed = { kind = "function" },
		onActivated = { kind = "function" },
	}),
	check = function(props: any): { string }
		if (props.glyph == nil) == (props.image == nil) then
			return { "needs exactly one of glyph or image" }
		end
		if props.image ~= nil and not string.match(props.image, "^rbx%w*://") then
			return { "image must be a content id" }
		end
		if not string.match(props.action, "^[%a_]+%.[%w_]+$") then
			return { "action must be an InputMap action name (context.action)" }
		end
		return {}
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local px = sizeOf(props, ctx)
		local root = Build.make(ctx, "TextButton", {
			Name = "TouchActionButton",
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			BackgroundColor3 = Style.color(ctx.tokens, "surfaceRaised", ctx.env),
			BackgroundTransparency = ctx.tokens.alpha.glass * 2,
			Size = r.UDim2.fromOffset(px, px),
			Visible = props.alwaysVisible or ctx.class.touch,
		})
		Build.tag(root, "TouchActionButton")
		Build.corner(ctx, root, "pill")
		Build.stroke(ctx, root, "borderStrong", "thin")
		local icon = math.floor(px * 0.45 + 0.5)
		if props.glyph then
			local glyph = Build.label(ctx, "Glyph", "title", props.glyph, nil, {
				AnchorPoint = r.Vector2.new(0.5, 0.5),
				Position = r.UDim2.fromScale(0.5, 0.5),
				Size = r.UDim2.fromOffset(icon, icon),
				TextWrapped = false,
				TextXAlignment = r.Enum.TextXAlignment.Center,
			}, root)
			glyph.TextSize = icon
		else
			Build.make(ctx, "ImageLabel", {
				Name = "Image",
				Image = props.image,
				BackgroundTransparency = 1,
				AnchorPoint = r.Vector2.new(0.5, 0.5),
				Position = r.UDim2.fromScale(0.5, 0.5),
				Size = r.UDim2.fromOffset(icon, icon),
				ScaleType = r.Enum.ScaleType.Fit,
			}, root)
		end
		local overlay = Build.surface(ctx, "Cooldown", "scrim", {
			Size = r.UDim2.fromScale(1, 1),
			ZIndex = 2,
			Visible = false,
		}, root)
		Build.corner(ctx, overlay, "pill")
		Build.make(ctx, "UIGradient", { Name = "Gradient", Rotation = 90 }, overlay)
		Build.feedback(ctx, root, "pill")
		root:SetAttribute("InputMapKey", "ui:" .. props.uiKey)
		root:SetAttribute("Action", props.action)
		root:SetAttribute("UIKitLabel", ctx.text(props.labelKey))
		paintCooldown(root, props.cooldown, ctx)
		Build.setEnabled(root, not props.disabled)
		return root, {}
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local root = handle.root
		local pressed = false
		local function report(state: boolean)
			if pressed == state then
				return
			end
			pressed = state
			local fn = handle.props.onPressed
			if fn then
				fn(state)
			end
		end
		handle.state.isPressed = function(): boolean
			return pressed
		end
		handle.scope:Add(ctx.on(root, "InputBegan", function(input: any)
			local kind = input.UserInputType.Name
			if root.Interactable and (kind == "Touch" or kind == "MouseButton1") then
				report(true)
			end
		end))
		handle.scope:Add(ctx.on(root, "InputEnded", function(input: any)
			local kind = input.UserInputType.Name
			if kind == "Touch" or kind == "MouseButton1" then
				report(false)
			end
		end))
		-- Sliding off releases too, so a hold never sticks (which events a touch drag fires when it
		-- leaves the button is UNVERIFIED on devices; destroy also releases).
		handle.scope:Add(ctx.on(root, "MouseLeave", function()
			report(false)
		end))
		Build.pressable(handle, root, function()
			local fn = handle.props.onActivated
			if fn then
				fn()
			end
		end, ctx)
		handle.scope:Add(function()
			report(false)
		end)
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		local p = handle.props
		if patch.cooldown ~= nil then
			paintCooldown(handle.root, p.cooldown, ctx)
		end
		if patch.disabled ~= nil then
			Build.setEnabled(handle.root, not p.disabled)
		end
		if patch.alwaysVisible ~= nil then
			handle.root.Visible = p.alwaysVisible or ctx.class.touch
		end
	end,
})

TouchActionButton.cooldownKeypoints = cooldownKeypoints

return TouchActionButton
