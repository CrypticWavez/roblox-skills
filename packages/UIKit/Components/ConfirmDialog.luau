--!strict
-- @tier T1
-- ConfirmDialog: a Modal with a cancel and a confirm Button. Keys default to uikit.cancel and
-- uikit.confirm; destructive = true makes confirm the danger variant. Either button closes the
-- dialog first and then calls onConfirm() or onCancel(); a scrim click or ui.back counts as
-- cancel when dismissable. Each callback runs at most once per open (the buttons' activation
-- guard plus an answered flag), so a double tap never confirms twice. handle.state.open(),
-- close() and screen(id) come from the inner Modal. Tree: the Modal tree with
--   Actions > Cancel (Button), Confirm (Button)
local Build = require("../Build")
local Button = require("./Button")
local Modal = require("./Modal")

local function modalProps(props: { [string]: any }): { [string]: any }
	return {
		textKey = props.textKey,
		text = props.text,
		textArgs = props.textArgs,
		bodyKey = props.bodyKey,
		body = props.body,
		bodyArgs = props.bodyArgs,
		dismissable = props.dismissable,
		open = props.open,
		maxWidth = props.maxWidth,
	}
end

local ConfirmDialog = Build.component({
	name = "ConfirmDialog",
	schema = Build.schema({
		bodyKey = { kind = "key" },
		body = { kind = "string", maxLength = 2048 },
		bodyArgs = { kind = "table" },
		confirmKey = { kind = "key", default = "uikit.confirm" },
		cancelKey = { kind = "key", default = "uikit.cancel" },
		destructive = { kind = "boolean", default = false },
		dismissable = { kind = "boolean", default = true },
		open = { kind = "boolean", default = false },
		maxWidth = { kind = "number", min = 120, max = 2048 },
		onConfirm = { kind = "function" },
		onCancel = { kind = "function" },
	}, true),
	check = function(props: any): { string }
		return Modal.validate(modalProps(props))
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local root, parts = Modal.build(modalProps(props), ctx)
		local cancelProps =
			{ textKey = props.cancelKey, variant = "secondary", name = "Cancel", layoutOrder = 1 }
		local confirmProps = {
			textKey = props.confirmKey,
			variant = if props.destructive then "danger" else "primary",
			name = "Confirm",
			layoutOrder = 2,
		}
		local cancel, cancelParts = Button.build(cancelProps, ctx)
		local confirm, confirmParts = Button.build(confirmProps, ctx)
		cancel.Parent = parts.actions
		confirm.Parent = parts.actions
		local out = table.clone(parts)
		out.modal = { root = root, parts = parts }
		out.cancel = { root = cancel, parts = cancelParts, props = cancelProps }
		out.confirm = { root = confirm, parts = confirmParts, props = confirmProps }
		return root, out
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local answered = false
		local function answer(which: string)
			if answered then
				return
			end
			answered = true
			handle.state.close(which)
			local fn = if which == "confirm" then handle.props.onConfirm else handle.props.onCancel
			if fn then
				fn()
			end
		end
		local modalHandle = Modal.attach(
			handle.root,
			handle.parts.modal.parts,
			(function()
				local p = modalProps(handle.props)
				p.onDismiss = function()
					answer("cancel")
				end
				return p
			end)(),
			ctx
		)
		handle.state.modal = modalHandle
		function handle.state.open()
			answered = false
			modalHandle.state.open()
		end
		function handle.state.close(reason: string?)
			modalHandle.state.close(reason)
		end
		function handle.state.screen(id: string): any
			local screen = modalHandle.state.screen(id)
			answered = false
			return screen
		end
		for _, which in { "cancel", "confirm" } do
			local child = handle.parts[which]
			local props = table.clone(child.props)
			props.onActivated = function()
				answer(which)
			end
			Button.attach(child.root, child.parts, props, ctx)
		end
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, _ctx: Build.Context)
		if patch.open == true then
			handle.state.open()
		elseif patch.open == false then
			handle.state.close("update")
		end
	end,
})

return ConfirmDialog
