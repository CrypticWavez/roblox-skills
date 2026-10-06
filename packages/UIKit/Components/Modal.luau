--!strict
-- @tier T1
-- Modal: a dialog over a scrim. The title comes from textKey/text, an optional body from
-- bodyKey/body; custom children go in handle.parts.content and buttons in handle.parts.actions.
-- The dialog is at most tokens.size.panelMax px wide (convention) and as tall as its content.
-- It opens with a fade of every part (Build.fadeTree, not a full-screen CanvasGroup, which costs
-- texture memory) plus a small scale spring, and closes with a quicker fade; rapid open/close
-- reverses smoothly from wherever the motion is. Reduced motion keeps only short fades.
-- dismissable modals close on a scrim click (onDismiss("scrim")) and on ui.back through
-- UIKit/Nav (handle.state.screen(id) gives the Nav.modal screen, with these transitions). The
-- root is a SelectionGroup that stops gamepad selection at its edges. Mount it in a ScreenGui
-- on the modal layer (Build.screenGui(ctx, name, "modal", true)). Tree:
--   Modal (Frame) > Scrim (TextButton), Dialog (Frame) > Corner, Stroke, Padding, Layout, Size
--   (UISizeConstraint), Scale (UIScale), Title, Body?, Content (Frame), Actions (Frame) > Layout
local Build = require("../Build")
local Transitions = require("../Transitions")

local Modal = Build.component({
	name = "Modal",
	schema = Build.schema({
		bodyKey = { kind = "key" },
		body = { kind = "string", maxLength = 2048 },
		bodyArgs = { kind = "table" },
		dismissable = { kind = "boolean", default = true },
		open = { kind = "boolean", default = false },
		onDismiss = { kind = "function" },
		maxWidth = { kind = "number", min = 120, max = 2048 },
	}, true),
	check = function(props: any): { string }
		if props.textKey == nil and props.text == nil then
			return { "needs a title (textKey or text)" }
		end
		if props.bodyKey ~= nil and props.body ~= nil then
			return { "bodyKey and body are exclusive" }
		end
		return {}
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local stop = r.Enum.SelectionBehavior.Stop
		local root = Build.frame(ctx, "Modal", {
			Size = r.UDim2.fromScale(1, 1),
			Visible = props.open,
			SelectionGroup = true,
			SelectionBehaviorUp = stop,
			SelectionBehaviorDown = stop,
			SelectionBehaviorLeft = stop,
			SelectionBehaviorRight = stop,
		})
		local scrim = Build.make(ctx, "TextButton", {
			Name = "Scrim",
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			BackgroundColor3 = r.Color3.fromRGB(table.unpack(ctx.tokens.color.scrim)),
			BackgroundTransparency = ctx.tokens.alpha.scrim,
			Size = r.UDim2.fromScale(1, 1),
			Selectable = false,
			ZIndex = 1,
		}, root)
		Build.tag(scrim, "UIKitScrim")
		local margin = ctx.class.margin
		local dialog = Build.surface(ctx, "Dialog", "surfaceRaised", {
			AnchorPoint = r.Vector2.new(0.5, 0.5),
			Position = r.UDim2.fromScale(0.5, 0.5),
			Size = r.UDim2.new(1, -2 * margin, 0, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
			ZIndex = 2,
		}, root)
		Build.corner(ctx, dialog, "lg")
		Build.stroke(ctx, dialog, "border", "hairline")
		Build.padding(ctx, dialog, "xl")
		Build.list(ctx, dialog, "Vertical", { gap = "md" })
		Build.make(ctx, "UISizeConstraint", {
			Name = "Size",
			MaxSize = r.Vector2.new(props.maxWidth or ctx.tokens.size.panelMax, math.huge),
		}, dialog)
		Build.make(ctx, "UIScale", { Name = "Scale", Scale = 1 }, dialog)
		local wrap = {
			Size = r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
		}
		local title = Build.label(ctx, "Title", "title", Build.text(ctx, props), nil, wrap, dialog)
		title.LayoutOrder = 1
		if props.bodyKey or props.body then
			local text = if props.bodyKey then ctx.text(props.bodyKey, props.bodyArgs) else props.body
			local body = Build.label(ctx, "Body", "body", text, "textMuted", wrap, dialog)
			body.LayoutOrder = 2
		end
		local content = Build.frame(ctx, "Content", {
			Size = r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
			LayoutOrder = 3,
		}, dialog)
		Build.list(ctx, content, "Vertical", { gap = "sm" })
		local actions = Build.frame(ctx, "Actions", {
			Size = r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
			LayoutOrder = 4,
		}, dialog)
		Build.list(ctx, actions, "Horizontal", { gap = "sm", align = "Right", wraps = true })
		return root,
			{
				scrim = scrim,
				dialog = dialog,
				scale = dialog:FindFirstChild("Scale"),
				title = title,
				content = content,
				actions = actions,
			}
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local root = handle.root
		local motion = ctx.tokens.motion
		local tree = Build.fadeTree(root)
		local generation = 0
		handle.state.isOpen = handle.props.open

		local function plans(): (Transitions.Plan, Transitions.Plan, { [string]: any })
			local fadeIn, bindings = tree:plan("in", { duration = motion.duration.base, ease = "Quad.Out" })
			local fadeOut = tree:plan("out", { duration = motion.duration.fast, ease = "Quad.In" })
			bindings.scale = handle.parts.scale
			local enter = Transitions.parallel({
				fadeIn,
				Transitions.scalePop({
					phase = "in",
					from = 0.96,
					spring = motion.spring.snappy,
					fade = false,
				}),
			})
			local exit = Transitions.parallel({
				fadeOut,
				Transitions.scalePop({
					phase = "out",
					from = 0.98,
					duration = motion.duration.fast,
					fade = false,
				}),
			})
			return enter, exit, bindings
		end

		function handle.state.open()
			if handle.state.isOpen then
				return
			end
			generation += 1
			if not root.Visible then
				-- Closed and at rest: capture again so children added since are included.
				tree = Build.fadeTree(root)
			end
			handle.state.isOpen = true
			root.Visible = true
			local enter, _, bindings = plans()
			Build.play(ctx, enter, bindings)
		end

		function handle.state.close(reason: string?)
			if not handle.state.isOpen then
				return
			end
			generation += 1
			local mark = generation
			handle.state.isOpen = false
			local _, exit, bindings = plans()
			Build.play(ctx, exit, bindings, {
				onComplete = function(state: string)
					if state == "completed" and mark == generation then
						root.Visible = false
						tree:restore()
					end
				end,
			})
			handle.state.lastReason = reason
		end

		-- The UIKit/Nav modal screen for this dialog (Nav shows, hides and plays the motion).
		function handle.state.screen(id: string): any
			local enter, exit, bindings = plans()
			return {
				id = id,
				root = root,
				dismissable = handle.props.dismissable,
				focus = nil,
				onBack = function(): boolean
					local fn = handle.props.onDismiss
					if handle.props.dismissable and fn then
						fn("back")
					end
					return false
				end,
				transitions = { enter = enter, exit = exit, bindings = bindings },
			}
		end

		handle.scope:Add(ctx.on(handle.parts.scrim, "Activated", function()
			if not handle.props.dismissable or not handle.state.isOpen then
				return
			end
			handle.state.close("scrim")
			local fn = handle.props.onDismiss
			if fn then
				fn("scrim")
			end
		end))
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.textKey ~= nil or patch.text ~= nil or patch.textArgs ~= nil then
			handle.parts.title.Text = Build.text(ctx, handle.props)
		end
		local body = handle.parts.dialog:FindFirstChild("Body")
		if body and (patch.bodyKey ~= nil or patch.body ~= nil or patch.bodyArgs ~= nil) then
			local p = handle.props
			body.Text = if p.bodyKey then ctx.text(p.bodyKey, p.bodyArgs) else p.body or ""
		end
		if patch.open == true then
			handle.state.open()
		elseif patch.open == false then
			handle.state.close("update")
		end
	end,
})

return Modal
