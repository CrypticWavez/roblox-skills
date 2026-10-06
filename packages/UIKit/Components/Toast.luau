--!strict
-- @tier T1
-- Toast: short, non-blocking notices. Three parts:
--   Toast.queue(options)  pure queue: at most maxVisible shown (default 3), at most maxQueued
--                         waiting (default 20; beyond that the oldest waiting toast is dropped);
--                         a toast whose dedupe key (key, else kind + text) is already showing
--                         bumps its count instead of stacking a copy.
--   Toast (component)     one card: a kind word (Info, Done, Warning, Error keys), the message,
--                         an accent bar and a "x2" count; kind never relies on colour alone.
--   ToastHost (Toast.Host) a column in the safe area that shows the queue: new toasts slide
--                         and fade in, leave after duration (tokens.motion.toastDuration s,
--                         convention; a bump restarts it) or when clicked, and the next waiting
--                         toast takes the free place. Timers run on the transition runner clock.
-- Trees: Toast (Frame) > Corner, Stroke, Padding, Accent, Kind, Message, Count;
--        ToastHost (Frame) > Layout, Slot_<id> (Frame) > Toast
local Build = require("../Build")
local Transitions = require("../Transitions")

local KINDS = { "info", "success", "warning", "error" }
local KIND_SLOT = { info = "info", success = "success", warning = "warning", error = "danger" }

export type Item = {
	id: number,
	kind: string,
	textKey: string?,
	text: string?,
	textArgs: { [any]: any }?,
	key: string,
	count: number,
	duration: number?,
}
export type Event = { type: "show" | "hide" | "bump" | "drop", id: number }

local Toast = {}
Toast.KINDS = table.freeze(KINDS)

-- ------------------------------------------------------------------ queue (pure)

export type QueueOptions = { maxVisible: number?, maxQueued: number? }

function Toast.queue(options: QueueOptions?): any
	local o: QueueOptions = options or {}
	local maxVisible = o.maxVisible or 3
	local maxQueued = o.maxQueued or 20
	assert(maxVisible >= 1 and maxVisible <= 10, "Toast.queue: maxVisible must be 1-10")
	assert(maxQueued >= 0 and maxQueued <= 200, "Toast.queue: maxQueued must be 0-200")
	local visible: { Item } = {}
	local waiting: { Item } = {}
	local nextId = 0
	local q: any = {}

	local function promote(events: { Event })
		while #visible < maxVisible and #waiting > 0 do
			local item = table.remove(waiting, 1) :: Item
			table.insert(visible, item)
			table.insert(events, { type = "show", id = item.id })
		end
	end

	-- Adds a toast; returns (id, events). Raises on a malformed item.
	function q.push(_self: any, input: any): (number, { Event })
		assert(type(input) == "table", "Toast.queue: push needs a table")
		assert(
			table.find(KINDS, input.kind or "info"),
			"Toast.queue: kind must be info, success, warning or error"
		)
		assert(input.textKey ~= nil or input.text ~= nil, "Toast.queue: needs textKey or text")
		local kind = input.kind or "info"
		local key = input.key or (kind .. "\0" .. tostring(input.textKey or input.text))
		local events: { Event } = {}
		for _, list in { visible, waiting } do
			for _, item in list do
				if item.key == key then
					item.count += 1
					table.insert(events, { type = "bump", id = item.id })
					return item.id, events
				end
			end
		end
		nextId += 1
		local item: Item = {
			id = nextId,
			kind = kind,
			textKey = input.textKey,
			text = input.text,
			textArgs = input.textArgs,
			key = key,
			count = 1,
			duration = input.duration,
		}
		if #visible < maxVisible then
			table.insert(visible, item)
			table.insert(events, { type = "show", id = item.id })
		else
			table.insert(waiting, item)
			if #waiting > maxQueued then
				local dropped = table.remove(waiting, 1) :: Item
				table.insert(events, { type = "drop", id = dropped.id })
			end
		end
		return item.id, events
	end

	-- Removes a toast (visible or waiting); returns the events (hide, then any show).
	function q.dismiss(_self: any, id: number): { Event }
		local events: { Event } = {}
		for index, item in visible do
			if item.id == id then
				table.remove(visible, index)
				table.insert(events, { type = "hide", id = id })
				promote(events)
				return events
			end
		end
		for index, item in waiting do
			if item.id == id then
				table.remove(waiting, index)
				table.insert(events, { type = "drop", id = id })
				return events
			end
		end
		return events
	end

	function q.get(_self: any, id: number): Item?
		for _, list in { visible, waiting } do
			for _, item in list do
				if item.id == id then
					return item
				end
			end
		end
		return nil
	end

	function q.visible(_self: any): { number }
		local out = {}
		for _, item in visible do
			table.insert(out, item.id)
		end
		return out
	end

	function q.waiting(_self: any): { number }
		local out = {}
		for _, item in waiting do
			table.insert(out, item.id)
		end
		return out
	end

	return q
end

-- ------------------------------------------------------------------ card

local function countText(count: number): string
	return if count > 1 then "x" .. math.min(count, 99) else ""
end

local Card = Build.component({
	name = "Toast",
	schema = Build.schema({
		kind = { kind = "enum", choices = KINDS, default = "info" },
		count = { kind = "integer", min = 1, max = 9999, default = 1 },
		width = { kind = "number", min = 120, max = 1200 },
		onActivated = { kind = "function" },
	}, true),
	check = function(props: any): { string }
		if props.textKey == nil and props.text == nil then
			return { "needs textKey or text" }
		end
		return {}
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local root = Build.make(ctx, "TextButton", {
			Name = "Toast",
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			BackgroundColor3 = r.Color3.fromRGB(table.unpack(ctx.tokens.color.surfaceRaised)),
			Size = r.UDim2.new(if props.width then 0 else 1, props.width or 0, 0, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
			Selectable = false,
		})
		Build.tag(root, "Toast", "UIKitSurface")
		Build.corner(ctx, root, "md")
		Build.stroke(ctx, root, "border", "hairline")
		local bar = 4
		Build.padding(ctx, root, { "sm", "md", "sm", bar + ctx.tokens.space.md })
		Build.surface(ctx, "Accent", KIND_SLOT[props.kind], {
			Position = r.UDim2.fromOffset(-(bar + ctx.tokens.space.md), -ctx.tokens.space.sm),
			Size = r.UDim2.new(0, bar, 1, 2 * ctx.tokens.space.sm),
		}, root)
		Build.label(ctx, "Kind", "caption", ctx.text("uikit.toast." .. props.kind), "textMuted", {
			Size = r.UDim2.new(1, -40, 0, ctx.tokens.text.caption.size + 2),
			TextWrapped = false,
		}, root)
		Build.label(ctx, "Message", "body", Build.text(ctx, props), nil, {
			Position = r.UDim2.fromOffset(0, ctx.tokens.text.caption.size + 4),
			Size = r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
		}, root)
		Build.label(ctx, "Count", "caption", countText(props.count), "textMuted", {
			AnchorPoint = r.Vector2.new(1, 0),
			Position = r.UDim2.fromScale(1, 0),
			Size = r.UDim2.fromOffset(40, ctx.tokens.text.caption.size + 2),
			TextXAlignment = r.Enum.TextXAlignment.Right,
			TextWrapped = false,
		}, root)
		root:SetAttribute("Kind", props.kind)
		return root, { message = root:FindFirstChild("Message"), count = root:FindFirstChild("Count") }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		handle.scope:Add(ctx.on(handle.root, "Activated", function()
			local fn = handle.props.onActivated
			if fn then
				fn()
			end
		end))
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.count ~= nil then
			handle.parts.count.Text = countText(handle.props.count)
		end
		if patch.textKey ~= nil or patch.text ~= nil or patch.textArgs ~= nil then
			handle.parts.message.Text = Build.text(ctx, handle.props)
		end
	end,
})

for key, value in Card do
	Toast[key] = value
end

-- ------------------------------------------------------------------ host

Toast.Host = Build.component({
	name = "ToastHost",
	schema = Build.schema({
		maxVisible = { kind = "integer", min = 1, max = 10, default = 3 },
		maxQueued = { kind = "integer", min = 0, max = 200, default = 20 },
		duration = { kind = "number", min = 0.5, max = 60 },
		edge = { kind = "enum", choices = { "top", "bottom" }, default = "top" },
		width = { kind = "number", min = 160, max = 1200, default = 360 },
	}),
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local top = props.edge == "top"
		local root = Build.frame(ctx, "ToastHost", {
			AnchorPoint = r.Vector2.new(0.5, if top then 0 else 1),
			Position = r.UDim2.new(
				0.5,
				0,
				if top then 0 else 1,
				if top then ctx.class.margin else -ctx.class.margin
			),
			Size = r.UDim2.new(0, props.width, 0, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
		})
		Build.tag(root, "ToastHost")
		Build.list(ctx, root, "Vertical", { gap = "sm", valign = if top then "Top" else "Bottom" })
		return root, {}
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local r = ctx.env.roblox
		local props = handle.props
		local queue = Toast.queue({ maxVisible = props.maxVisible, maxQueued = props.maxQueued })
		local cards: { [number]: { slot: any, card: any, cancel: (() -> ())?, leaving: boolean } } = {}
		local order = 0
		handle.state.queue = queue
		handle.state.cards = cards

		local apply: (events: { Event }) -> ()

		local function schedule(id: number)
			local entry = cards[id]
			local item = queue:get(id)
			if entry == nil or item == nil then
				return
			end
			if entry.cancel then
				entry.cancel()
			end
			local seconds = item.duration or props.duration or ctx.tokens.motion.toastDuration
			entry.cancel = Build.after(ctx, seconds, function()
				apply(queue:dismiss(id))
			end)
		end

		local function show(id: number)
			local item = queue:get(id) :: Item
			order += 1
			local slot = Build.frame(ctx, "Slot_" .. id, {
				Size = r.UDim2.fromScale(1, 0),
				AutomaticSize = r.Enum.AutomaticSize.Y,
				LayoutOrder = if props.edge == "top" then order else -order,
			})
			local cardProps = {
				kind = item.kind,
				textKey = item.textKey,
				text = item.text,
				textArgs = item.textArgs,
				count = item.count,
				onActivated = function()
					apply(queue:dismiss(id))
				end,
			}
			local cardRoot, cardParts = Toast.build(cardProps, ctx)
			local card = Toast.attach(cardRoot, cardParts, cardProps, ctx)
			card.root.Parent = slot
			slot.Parent = handle.root
			cards[id] = { slot = slot, card = card, cancel = nil, leaving = false }
			local tree = Build.fadeTree(card.root)
			local fade, bindings = tree:plan("in", { duration = ctx.tokens.motion.duration.base })
			bindings.card = card.root
			local from = if props.edge == "top" then -12 else 12
			Build.play(
				ctx,
				Transitions.parallel({
					fade,
					Transitions.make("toastIn", "in", {
						Transitions.track("card", "Position", { 0, 0, 0, from }, { 0, 0, 0, 0 }, {
							spring = ctx.tokens.motion.spring.snappy,
						}),
					}),
				}),
				bindings
			)
			schedule(id)
		end

		local function hide(id: number)
			local entry = cards[id]
			if entry == nil or entry.leaving then
				return
			end
			entry.leaving = true
			if entry.cancel then
				entry.cancel()
			end
			local tree = Build.fadeTree(entry.card.root)
			local fade, bindings = tree:plan("out", { duration = ctx.tokens.motion.duration.fast })
			Build.play(ctx, fade, bindings, {
				onComplete = function()
					cards[id] = nil
					entry.card:destroy()
					-- Untrack the card's scope so the host does not keep one per toast.
					pcall(handle.scope.Remove, handle.scope, entry.card.scope)
					entry.slot:Destroy()
				end,
			})
		end

		apply = function(events: { Event })
			for _, event in events do
				if event.type == "show" then
					show(event.id)
				elseif event.type == "hide" then
					hide(event.id)
				elseif event.type == "bump" then
					local entry = cards[event.id]
					local item = queue:get(event.id)
					if entry and item then
						entry.card:update({ count = item.count })
						schedule(event.id)
					end
				end
			end
		end

		-- Shows a toast { kind, textKey | text, textArgs?, key?, duration? }; returns its id.
		function handle.state.push(input: any): number
			local id, events = queue:push(input)
			apply(events)
			return id
		end
		function handle.state.dismiss(id: number)
			apply(queue:dismiss(id))
		end
		handle.scope:Add(function()
			for _, entry in cards do
				if entry.cancel then
					entry.cancel()
				end
			end
		end)
	end,
})

return Toast
