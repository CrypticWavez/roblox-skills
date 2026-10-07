--!strict
-- @tier T1
-- OfferPopup: a purchase offer in a Modal (the "starter pack" or "limited offer" popup that
-- GameKit/Offers decides to show): a title, an optional body, the product as a ShopCard (with
-- its ribbon), an optional time-left line and two buttons, "Get it" and "Not now". Like
-- ShopCard it never buys: onSelect(productKey) tells the game the player chose the product,
-- and the game runs its own guarded prompt (GameKit/CommerceRoblox.prompt). It is always
-- dismissable (scrim, ui.back and the "Not now" button: there is no prop to turn that off,
-- because an offer the player cannot close is a dark pattern); onDismiss(reason) reports
-- "later", "scrim", "back" or "expired". secondsLeft (from Offers expiresAt minus now) shows a
-- Timer and closes the popup with "expired" when an update brings it to 0. The "Get it" button
-- acts only when the card is selectable (enabled, priced, not owned, not setup mode). Each
-- answer runs once per open. Tree: the Modal tree with
--   Content > Card (ShopCard), TimeLeft (Timer)?; Actions > Later (Button), Get (Button)
local Build = require("../Build")
local Button = require("./Button")
local Modal = require("./Modal")
local ShopCard = require("./ShopCard")
local Timer = require("./Timer")

local function modalProps(props: { [string]: any }): { [string]: any }
	return {
		textKey = props.textKey,
		text = props.text,
		textArgs = props.textArgs,
		bodyKey = props.bodyKey,
		body = props.body,
		bodyArgs = props.bodyArgs,
		dismissable = true,
		open = props.open,
		maxWidth = props.maxWidth,
	}
end

local function cardProps(props: { [string]: any }): { [string]: any }
	return {
		catalog = props.catalog,
		productKey = props.productKey,
		price = props.price,
		owned = props.owned,
		imageFor = props.imageFor,
		ribbon = props.ribbon,
		width = props.cardWidth,
		name = "Card",
		layoutOrder = 1,
	}
end

local OfferPopup = Build.component({
	name = "OfferPopup",
	schema = Build.schema({
		bodyKey = { kind = "key" },
		body = { kind = "string", maxLength = 2048 },
		bodyArgs = { kind = "table" },
		catalog = { kind = "table", required = true },
		productKey = { kind = "string", maxLength = 64, required = true },
		price = { kind = "table" },
		owned = { kind = "boolean", default = false },
		imageFor = { kind = "function" },
		ribbon = { kind = "enum", choices = ShopCard.RIBBONS },
		secondsLeft = { kind = "number" },
		timeKey = { kind = "key", default = "uikit.offer.ends_in" },
		getKey = { kind = "key", default = "uikit.offer.get" },
		laterKey = { kind = "key", default = "uikit.offer.later" },
		cardWidth = { kind = "number", min = 120, max = 1024, default = 260 },
		open = { kind = "boolean", default = false },
		maxWidth = { kind = "number", min = 120, max = 2048 },
		onSelect = { kind = "function" },
		onDismiss = { kind = "function" },
	}, true),
	check = function(props: any): { string }
		local problems = {}
		for _, problem in Modal.validate(modalProps(props)) do
			table.insert(problems, (string.gsub(problem, "^Modal: ", "")))
		end
		for _, problem in ShopCard.validate(cardProps(props)) do
			table.insert(problems, (string.gsub(problem, "^ShopCard: ", "")))
		end
		return problems
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local root, parts = Modal.build(modalProps(props), ctx)
		local card, cardParts = ShopCard.build(cardProps(props), ctx)
		card.Parent = parts.content
		Build.list(ctx, parts.content, "Vertical", { gap = "sm", align = "Center" })
		local out = table.clone(parts)
		out.modal = { root = root, parts = parts }
		out.card = { root = card, parts = cardParts }
		if props.secondsLeft ~= nil then
			local timerProps =
				{ seconds = props.secondsLeft, style = "hours", textKey = props.timeKey, warnBelow = 600 }
			local timer, timerParts = Timer.build(timerProps, ctx)
			timer.Name = "TimeLeft"
			timer.LayoutOrder = 2
			timer.Parent = parts.content
			out.timer = { root = timer, parts = timerParts, props = timerProps }
		end
		local laterProps =
			{ textKey = props.laterKey, variant = "secondary", name = "Later", layoutOrder = 1 }
		local getProps = { textKey = props.getKey, variant = "primary", name = "Get", layoutOrder = 2 }
		local later, laterParts = Button.build(laterProps, ctx)
		local get, getParts = Button.build(getProps, ctx)
		later.Parent = parts.actions
		get.Parent = parts.actions
		out.later = { root = later, parts = laterParts, props = laterProps }
		out.get = { root = get, parts = getParts, props = getProps }
		root:SetAttribute("ProductKey", props.productKey)
		Build.tag(root, "OfferPopup")
		return root, out
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local answered = false
		local function selectable(): boolean
			local _, _, ok = ShopCard.status(cardProps(handle.props))
			return ok
		end
		local function dismiss(reason: string)
			if answered then
				return
			end
			answered = true
			handle.state.close(reason)
			local fn = handle.props.onDismiss
			if fn then
				fn(reason)
			end
		end
		local function choose()
			if answered or not selectable() then
				return
			end
			answered = true
			handle.state.close("select")
			local fn = handle.props.onSelect
			if fn then
				fn(handle.props.productKey)
			end
		end
		local modalBind = modalProps(handle.props)
		modalBind.onDismiss = function(reason: string)
			dismiss(reason)
		end
		local modalHandle = Modal.attach(handle.root, handle.parts.modal.parts, modalBind, ctx)
		handle.state.modal = modalHandle
		function handle.state.open()
			answered = false
			modalHandle.state.open()
		end
		function handle.state.close(reason: string?)
			modalHandle.state.close(reason)
		end
		function handle.state.screen(id: string): any
			answered = false
			return modalHandle.state.screen(id)
		end
		local card = cardProps(handle.props)
		card.onSelect = function()
			choose()
		end
		handle.state.card = ShopCard.attach(handle.parts.card.root, handle.parts.card.parts, card, ctx)
		if handle.parts.timer then
			local timer = handle.parts.timer
			handle.state.timer = Timer.attach(timer.root, timer.parts, timer.props, ctx)
		end
		local later = table.clone(handle.parts.later.props)
		later.onActivated = function()
			dismiss("later")
		end
		Button.attach(handle.parts.later.root, handle.parts.later.parts, later, ctx)
		local get = table.clone(handle.parts.get.props)
		get.onActivated = choose
		get.disabled = not selectable()
		handle.state.get = Button.attach(handle.parts.get.root, handle.parts.get.parts, get, ctx)
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, _ctx: Build.Context)
		if patch.catalog ~= nil or patch.productKey ~= nil then
			error("OfferPopup: catalog and productKey cannot change after mount (build a new popup)", 3)
		end
		if patch.price ~= nil or patch.owned ~= nil then
			handle.state.card:update({ price = handle.props.price, owned = handle.props.owned })
			local _, _, ok = ShopCard.status(cardProps(handle.props))
			handle.state.get:update({ disabled = not ok })
		end
		if patch.secondsLeft ~= nil and handle.state.timer then
			handle.state.timer:update({ seconds = handle.props.secondsLeft })
			if handle.props.secondsLeft <= 0 and handle.state.modal.state.isOpen then
				local fn = handle.props.onDismiss
				handle.state.close("expired")
				if fn then
					fn("expired")
				end
			end
		end
		if patch.open == true then
			handle.state.open()
		elseif patch.open == false then
			handle.state.close("update")
		end
	end,
})

return OfferPopup
