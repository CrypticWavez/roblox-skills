--!strict
-- Neutral native UI primitives. No purchase prompting, game loop or asset dependency.
local UI = {}
UI.defaults = table.freeze({
	title = "UI component inspection",
	status = "Status",
	open = "Open menu",
	close = "Close",
	inventory = "Inventory",
	shop = "Shop",
	settings = "Settings",
	loading = "Loading",
	empty = "No items",
	error = "Unable to load",
	ready = "Ready",
	unavailable = "Unavailable",
	pricePending = "Price unavailable",
	previewOnly = "Preview only",
	volume = "Volume",
	reducedMotion = "Reduced motion",
	on = "On",
	off = "Off",
	retry = "Retry",
	selected = "Selected",
})

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function text(value, maximum)
	if type(value) ~= "string" or value:match("^%s*$") or value:find("[%z\1-\8\11\12\14-\31]") then
		return false
	end
	local length = utf8.len(value)
	return length ~= nil and length <= maximum
end

function UI.validateStrings(strings, required)
	local errors = {}
	if type(strings) ~= "table" then
		return false, { "strings must be a table" }
	end
	local count = 0
	for key, value in strings do
		count += 1
		if not text(key, 64) or not text(value, 512) then
			table.insert(errors, "invalid localized string")
		end
	end
	if count > 256 then
		table.insert(errors, "localization exceeds 256 keys")
	end
	for _, key in required or {} do
		if not text(key, 64) or not text(strings[key], 512) then
			table.insert(errors, "missing or invalid localization key: " .. tostring(key))
		end
	end
	return #errors == 0, errors
end

function UI.localize(provider, keys)
	assert(provider == nil or type(provider) == "function", "locale provider must be a function")
	local result, errors = {}, {}
	for _, key in keys do
		assert(text(key, 64), "invalid localization key")
		local ok, value = true, UI.defaults[key]
		if provider then
			ok, value = pcall(provider, key)
		end
		if not ok or not text(value, 512) then
			table.insert(errors, key)
			value = UI.defaults[key] or ("[missing: " .. key .. "]")
		end
		result[key] = value
	end
	return result, errors
end

function UI.validateItems(items)
	if type(items) ~= "table" or #items > 100 then
		return false, "items must be an array of at most 100 records"
	end
	local seen = {}
	local count = 0
	for index, item in items do
		count += 1
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #items then
			return false, "items must be a dense array"
		end
		if
			type(item) ~= "table"
			or not text(item.id, 64)
			or not item.id:match("^[a-z][a-z0-9_-]*$")
			or seen[item.id]
		then
			return false, "invalid or duplicate item id"
		end
		seen[item.id] = true
		if
			not text(item.labelKey, 64) or (item.descriptionKey ~= nil and not text(item.descriptionKey, 64))
		then
			return false, "items require localization keys"
		end
		if
			item.count ~= nil
			and (not finite(item.count) or item.count % 1 ~= 0 or item.count < 0 or item.count > 1000000000)
		then
			return false, "invalid item count"
		end
	end
	if count ~= #items then
		return false, "items must be a dense array"
	end
	return true, nil
end

function UI.validateSettings(volume, reducedMotion)
	return finite(volume) and volume >= 0 and volume <= 1 and type(reducedMotion) == "boolean"
end

function UI.guard(onDestroy)
	assert(onDestroy == nil or type(onDestroy) == "function", "cleanup must be a function")
	local api = { closed = false, busy = false, failures = 0 }
	function api:invoke(callback, ...)
		assert(type(callback) == "function", "callback required")
		if self.closed then
			return false, "closed"
		end
		if self.busy then
			return false, "busy"
		end
		self.busy = true
		local ok = pcall(callback, ...)
		self.busy = false
		if not ok then
			self.failures += 1
			return false, "callback_failed"
		end
		return not self.closed, if self.closed then "closed_during_callback" else nil
	end
	function api:destroy()
		if self.closed then
			return
		end
		self.closed = true
		if onDestroy then
			local ok = pcall(onDestroy)
			if not ok then
				self.failures += 1
			end
		end
	end
	return api
end

function UI.shopDisplay(entry, universeId, provider)
	local unavailable = { state = "unavailable", purchasable = false, reason = "unconfigured" }
	if
		type(entry) ~= "table"
		or not finite(universeId)
		or universeId <= 0
		or universeId % 1 ~= 0
		or entry.universeId ~= universeId
		or entry.ownershipVerified ~= true
		or entry.enabled ~= false
	then
		return unavailable
	end
	if entry.kind ~= "pass" and entry.kind ~= "developer_product" and entry.kind ~= "subscription" then
		return unavailable
	end
	local validId = if entry.kind == "subscription"
		then text(entry.productId, 64) and entry.productId:match("^EXP%-") ~= nil
		else finite(entry.productId) and entry.productId > 0 and entry.productId % 1 == 0
	if not validId or type(provider) ~= "function" then
		return unavailable
	end
	local ok, info = pcall(provider, entry.kind, entry.productId)
	if not ok or type(info) ~= "table" or info.available ~= true or not text(info.formattedPrice, 128) then
		return { state = "unavailable", purchasable = false, reason = "current_price_unavailable" }
	end
	return { state = "preview_only", purchasable = false, price = info.formattedPrice }
end

function UI.new(parent, options)
	options = options or {}
	assert(typeof(parent) == "Instance" and parent:IsA("PlayerGui"), "owned PlayerGui required")
	assert(type(options) == "table", "options must be a table")
	for _, key in { "localeProvider", "currentPriceProvider", "onSettingsChanged", "onRetry" } do
		assert(options[key] == nil or type(options[key]) == "function", key .. " must be a function")
	end
	local NativeUI = require(script.Parent.Parent.Runtime.NativeUI)
	local Lifetime = require(script.Parent.Parent.Runtime.Lifetime)
	local theme = assert(NativeUI.themes[options.theme or "slate"], "unknown theme")
	local touchTarget = NativeUI.tokens.touchTarget
	local keys = {}
	for key in UI.defaults do
		table.insert(keys, key)
	end
	table.sort(keys)
	local strings, localizationErrors = UI.localize(options.localeProvider, keys)
	local localized = {}
	local localizedCount = #keys
	local function tr(key)
		if strings[key] then
			return strings[key]
		end
		if localized[key] then
			return localized[key]
		end
		assert(localizedCount < 256, "localization cache capacity")
		localizedCount += 1
		local values, errors = UI.localize(options.localeProvider, { key })
		for _, missing in errors do
			table.insert(localizationErrors, missing)
		end
		localized[key] = values[key]
		return values[key]
	end
	local connections, contentConnections = {}, {}
	local controller = UI.guard()
	local settingsController = UI.guard()
	local lifetime = Lifetime.new(1)
	local guiService = game:GetService("GuiService")
	local inputService = game:GetService("UserInputService")
	local runService = game:GetService("RunService")
	local previousFocus = guiService.SelectedObject
	local function make(className, props, owner)
		local object = Instance.new(className)
		for key, value in props do
			object[key] = value
		end
		object.Parent = owner
		return object
	end
	local root = make("ScreenGui", {
		Name = "WorkbenchCreatorUI",
		ResetOnSpawn = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, parent)
	local hud = make("TextLabel", {
		Name = "HudStatus",
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -204, 0, 48),
		BackgroundColor3 = theme.background,
		TextColor3 = theme.text,
		TextSize = 18,
		Font = Enum.Font.Gotham,
		TextWrapped = true,
		RichText = false,
	}, root)
	local function button(name, label, owner)
		local object = make("TextButton", {
			Name = name,
			Text = label,
			TextColor3 = theme.text,
			BackgroundColor3 = theme.surface,
			TextSize = 17,
			Font = Enum.Font.Gotham,
			TextWrapped = true,
			RichText = false,
			BorderSizePixel = 0,
			Selectable = true,
		}, owner)
		make("UICorner", { CornerRadius = UDim.new(0, NativeUI.tokens.cornerRadius) }, object)
		return object
	end
	local openButton = button("OpenMenu", tr("open"), root)
	openButton.Position, openButton.Size = UDim2.new(1, -180, 0, 8), UDim2.fromOffset(168, touchTarget)
	local panel = make("Frame", {
		Name = "Menu",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.56),
		Size = UDim2.new(1, -24, 1, -144),
		BackgroundColor3 = theme.background,
		BorderSizePixel = 0,
		SelectionGroup = true,
		Visible = false,
	}, root)
	make("UISizeConstraint", { MaxSize = Vector2.new(900, 620), MinSize = Vector2.new(240, 240) }, panel)
	make("UICorner", { CornerRadius = UDim.new(0, NativeUI.tokens.cornerRadius) }, panel)
	make("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -80, 0, 44),
		BackgroundTransparency = 1,
		Text = tr("title"),
		TextColor3 = theme.text,
		TextSize = 20,
		Font = Enum.Font.GothamBold,
		TextWrapped = true,
		RichText = false,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, panel)
	local closeButton = button("CloseMenu", tr("close"), panel)
	closeButton.Position, closeButton.Size = UDim2.new(1, -60, 0, 8), UDim2.fromOffset(48, 48)
	local tabs = make("Frame", {
		Name = "Tabs",
		Position = UDim2.fromOffset(12, 64),
		Size = UDim2.new(1, -24, 0, 48),
		BackgroundTransparency = 1,
	}, panel)
	local tabButtons = {}
	for index, name in { "inventory", "shop", "settings" } do
		local tab = button(name, tr(name), tabs)
		tab.Position, tab.Size = UDim2.new((index - 1) / 3, 4, 0, 0), UDim2.new(1 / 3, -8, 0, 48)
		tabButtons[name] = tab
	end
	local body = make("ScrollingFrame", {
		Name = "Content",
		Position = UDim2.fromOffset(12, 124),
		Size = UDim2.new(1, -24, 1, -136),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, panel)
	make("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, body)
	local api = {
		root = root,
		panel = panel,
		hud = hud,
		openButton = openButton,
		closed = false,
		view = "inventory",
		opened = false,
		callbackGuard = controller,
	}
	local inventory = { state = "empty", items = {} }
	local shop = { state = "empty", items = {}, display = {} }
	local settings = { volume = 1, reducedMotion = false }
	local generation, activeSlider, slider, sliderFill, sliderLabel = 0, nil, nil, nil, nil
	local function alive()
		assert(not controller.closed, "UI scope is closed")
	end
	local function effectiveReduced()
		return settings.reducedMotion or guiService.ReducedMotionEnabled
	end
	local function connect(signal, callback, content)
		local connection = signal:Connect(callback)
		table.insert(if content then contentConnections else connections, connection)
		return connection
	end
	local function label(name, value, owner, order)
		return make("TextLabel", {
			Name = name,
			Text = value,
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			TextColor3 = theme.text,
			TextSize = 18,
			Font = Enum.Font.Gotham,
			TextWrapped = true,
			RichText = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			LayoutOrder = order or 0,
		}, owner)
	end
	local function focus(target)
		task.defer(function()
			runService.RenderStepped:Wait()
			if not controller.closed and api.opened and target.Parent and target.AbsoluteSize.X > 0 then
				guiService.SelectedObject = target
			end
		end)
	end
	local function clear()
		activeSlider, slider, sliderFill, sliderLabel = nil, nil, nil, nil
		for _, connection in contentConnections do
			connection:Disconnect()
		end
		table.clear(contentConnections)
		for _, child in body:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
	end
	local function notify()
		if options.onSettingsChanged then
			settingsController:invoke(options.onSettingsChanged, {
				volume = settings.volume,
				reducedMotion = effectiveReduced(),
				requestedReducedMotion = settings.reducedMotion,
			})
		end
	end
	function api:setVolume(volume)
		alive()
		assert(UI.validateSettings(volume, settings.reducedMotion), "invalid volume")
		settings.volume = volume
		if sliderFill and sliderFill.Parent then
			sliderFill.Size = UDim2.fromScale(volume, 1)
		end
		if sliderLabel and sliderLabel.Parent then
			sliderLabel.Text = tr("volume") .. ": " .. tostring(math.round(volume * 100)) .. "%"
		end
		notify()
	end
	function api:setReducedMotion(value)
		alive()
		assert(UI.validateSettings(settings.volume, value), "invalid reduced motion")
		settings.reducedMotion = value
		notify()
		if not controller.closed and api.view == "settings" then
			api:show("settings")
		end
	end
	local function pointVolume(position)
		if slider and slider.AbsoluteSize.X > 0 then
			api:setVolume(math.clamp((position.X - slider.AbsolutePosition.X) / slider.AbsoluteSize.X, 0, 1))
		end
	end
	function api:show(view)
		alive()
		assert(tabButtons[view] ~= nil, "unknown menu view")
		api.view = view
		generation += 1
		clear()
		body.CanvasPosition = Vector2.zero
		for name, tab in tabButtons do
			tab.BackgroundColor3 = if name == view then theme.accent else theme.surface
		end
		if view == "settings" then
			sliderLabel = label(
				"VolumeLabel",
				tr("volume") .. ": " .. tostring(math.round(settings.volume * 100)) .. "%",
				body,
				1
			)
			slider = button("VolumeSlider", "", body)
			slider.Size, slider.LayoutOrder = UDim2.new(1, -8, 0, 48), 2
			sliderFill = make("Frame", {
				Name = "Fill",
				Size = UDim2.fromScale(settings.volume, 1),
				BackgroundColor3 = theme.accent,
				BorderSizePixel = 0,
				Active = false,
			}, slider)
			connect(slider.InputBegan, function(input)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					activeSlider = input
					pointVolume(input.Position)
				end
			end, true)
			local toggle = button(
				"ReducedMotion",
				tr("reducedMotion") .. ": " .. tr(if effectiveReduced() then "on" else "off"),
				body
			)
			toggle.Size, toggle.LayoutOrder = UDim2.new(1, -8, 0, 48), 3
			connect(toggle.Activated, function()
				controller:invoke(function()
					api:setReducedMotion(not settings.reducedMotion)
				end)
			end, true)
			slider.NextSelectionDown, toggle.NextSelectionUp = toggle, slider
			tabButtons.settings.NextSelectionDown = slider
			return
		end
		local model = if view == "inventory" then inventory else shop
		local message = label("State", tr(model.state), body, 1)
		if model.state ~= "ready" or #model.items == 0 then
			if model.state == "error" and options.onRetry then
				local retry = button("Retry", tr("retry"), body)
				retry.Size, retry.LayoutOrder = UDim2.new(1, -8, 0, 48), 2
				connect(retry.Activated, function()
					controller:invoke(options.onRetry, view)
				end, true)
			end
			return
		end
		local detail =
			label("ItemInformation", tr("selected") .. ": " .. tr(model.items[1].labelKey), body, 2)
		local cards = make("Frame", {
			Name = "ItemGrid",
			Size = UDim2.new(1, -8, 0, 112),
			BackgroundTransparency = 1,
			LayoutOrder = 3,
		}, body)
		local grid = make("UIGridLayout", {
			CellPadding = UDim2.fromOffset(12, 12),
			CellSize = UDim2.fromOffset(220, 112),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, cards)
		local function layout()
			local width = math.max(cards.AbsoluteSize.X, 1)
			local columns = if width >= 460 then 2 else 1
			grid.CellSize = UDim2.fromOffset(math.floor((width - (columns - 1) * 12) / columns), 112)
			cards.Size = UDim2.new(1, -8, 0, grid.AbsoluteContentSize.Y)
		end
		connect(cards:GetPropertyChangedSignal("AbsoluteSize"), layout, true)
		connect(grid:GetPropertyChangedSignal("AbsoluteContentSize"), layout, true)
		local previous
		for index, item in model.items do
			local title = tr(item.labelKey)
			local card = button(
				item.id,
				title .. (if item.count ~= nil then " ×" .. tostring(item.count) else ""),
				cards
			)
			card.LayoutOrder = index
			if view == "shop" then
				local display = model.display[index]
				card.Text = title
					.. "\n"
					.. (display.price or tr("pricePending"))
					.. "\n"
					.. tr(if display.state == "preview_only" then "previewOnly" else "unavailable")
				card.Active, card.Selectable, card.AutoButtonColor = false, false, false
			else
				connect(card.Activated, function()
					controller:invoke(function()
						detail.Text = tr("selected")
							.. ": "
							.. title
							.. (if item.descriptionKey then "\n" .. tr(item.descriptionKey) else "")
					end)
				end, true)
				if previous then
					previous.NextSelectionDown, card.NextSelectionUp = card, previous
				end
				previous = card
				if index == 1 then
					tabButtons.inventory.NextSelectionDown = card
				end
			end
		end
		message.Text = tr("ready")
		layout()
	end
	function api:setInventory(state, items)
		alive()
		assert(
			state == "loading" or state == "empty" or state == "error" or state == "ready",
			"invalid inventory state"
		)
		local valid, reason = UI.validateItems(items)
		assert(valid, reason)
		local copy = {}
		for _, item in items do
			table.insert(copy, table.clone(item))
		end
		inventory = { state = if state == "ready" and #copy == 0 then "empty" else state, items = copy }
		if api.view == "inventory" then
			api:show("inventory")
		end
	end
	function api:setShop(state, entries)
		alive()
		assert(
			state == "loading" or state == "empty" or state == "error" or state == "ready",
			"invalid shop state"
		)
		local valid, reason = UI.validateItems(entries)
		assert(valid, reason)
		generation += 1
		local current = generation
		local copy, displays = {}, {}
		for _, entry in entries do
			local cloned = table.clone(entry)
			table.insert(copy, cloned)
			table.insert(displays, UI.shopDisplay(cloned, options.universeId, options.currentPriceProvider))
			if controller.closed or generation ~= current then
				return false, "superseded"
			end
		end
		shop = {
			state = if state == "ready" and #copy == 0 then "empty" else state,
			items = copy,
			display = displays,
		}
		if api.view == "shop" then
			api:show("shop")
		end
		return true
	end
	function api:setHud(statusKey, value)
		alive()
		assert(text(statusKey, 64) and (value == nil or text(value, 128)), "invalid HUD status")
		hud.Text = tr("status") .. ": " .. tr(statusKey) .. (if value then " · " .. value else "")
	end
	function api:open()
		alive()
		api.opened, panel.Visible = true, true
		api:show(api.view)
		focus(tabButtons[api.view])
	end
	function api:close()
		alive()
		api.opened, panel.Visible = false, false
		activeSlider = nil
		if guiService.SelectedObject and guiService.SelectedObject:IsDescendantOf(root) then
			guiService.SelectedObject = openButton
		end
	end
	connect(openButton.Activated, function()
		controller:invoke(function()
			api:open()
		end)
	end)
	connect(closeButton.Activated, function()
		controller:invoke(function()
			api:close()
		end)
	end)
	for name, tab in tabButtons do
		connect(tab.Activated, function()
			controller:invoke(function()
				api:show(name)
			end)
		end)
	end
	connect(inputService.InputChanged, function(input)
		if
			activeSlider
			and (
				(activeSlider.UserInputType == Enum.UserInputType.Touch and input == activeSlider)
				or input.UserInputType == Enum.UserInputType.MouseMovement
			)
		then
			pointVolume(input.Position)
		end
	end)
	connect(inputService.InputEnded, function(input)
		if input == activeSlider or input.UserInputType == Enum.UserInputType.MouseButton1 then
			activeSlider = nil
		end
	end)
	connect(inputService.InputBegan, function(input, processed)
		if controller.closed or not api.opened then
			return
		end
		if guiService.SelectedObject == slider then
			if input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.DPadLeft then
				api:setVolume(math.max(0, settings.volume - 0.05))
			end
			if input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.DPadRight then
				api:setVolume(math.min(1, settings.volume + 0.05))
			end
		elseif not processed and input.KeyCode == Enum.KeyCode.Escape then
			api:close()
		end
	end)
	connect(guiService:GetPropertyChangedSignal("ReducedMotionEnabled"), function()
		if not controller.closed then
			notify()
			if not controller.closed and api.view == "settings" then
				api:show("settings")
			end
		end
	end)
	function api:audit()
		alive()
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize else Vector2.zero
		local bounds = {}
		for _, object in root:GetDescendants() do
			if object:IsA("TextLabel") or object:IsA("TextButton") then
				local visible = object.Visible
				local owner = object.Parent
				local scroll
				while owner and owner ~= root do
					if owner:IsA("GuiObject") and not owner.Visible then
						visible = false
					end
					if owner:IsA("ScrollingFrame") then
						scroll = owner
					end
					owner = owner.Parent
				end
				local p, size = object.AbsolutePosition, object.AbsoluteSize
				local scrollClipped = false
				local clip
				if scroll then
					local sp, ss = scroll.AbsolutePosition, scroll.AbsoluteSize
					if p.Y + size.Y <= sp.Y or p.Y >= sp.Y + ss.Y then
						visible = false
					end
					scrollClipped = p.Y < sp.Y or p.Y + size.Y > sp.Y + ss.Y
					clip = { x = sp.X, y = sp.Y, width = ss.X, height = ss.Y }
				end
				if visible then
					table.insert(bounds, {
						name = object:GetFullName(),
						x = p.X,
						y = p.Y,
						width = size.X,
						height = size.Y,
						textFits = object.TextFits,
						scrollClipped = scrollClipped,
						clip = clip,
					})
				end
			end
		end
		local active = 0
		for _, connection in connections do
			if connection.Connected then
				active += 1
			end
		end
		for _, connection in contentConnections do
			if connection.Connected then
				active += 1
			end
		end
		return {
			mode = "SETUP_ONLY",
			method = "assisted_creator_UI_fixture",
			viewport = { width = viewport.X, height = viewport.Y },
			view = api.view,
			opened = api.opened,
			bounds = bounds,
			localizationErrors = table.clone(localizationErrors),
			settings = { volume = settings.volume, reducedMotion = effectiveReduced() },
			activeConnections = active,
			callbackFailures = controller.failures + settingsController.failures,
			focusScoped = guiService.SelectedObject == nil or guiService.SelectedObject:IsDescendantOf(root),
			purchasable = false,
		}
	end
	lifetime:add(300, 10, function()
		controller:destroy()
		settingsController:destroy()
		clear()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		if guiService.SelectedObject and guiService.SelectedObject:IsDescendantOf(root) then
			guiService.SelectedObject = if previousFocus and previousFocus.Parent then previousFocus else nil
		end
		root:Destroy()
		api.closed = true
	end)
	function api:destroy()
		lifetime:destroy()
	end
	connect(root.Destroying, function()
		api:destroy()
	end)
	api:setHud("ready")
	api:show("inventory")
	return api
end

return UI
