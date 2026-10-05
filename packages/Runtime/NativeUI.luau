--!strict
-- Native Roblox UI architecture: one owned ScreenGui, scoped connections, no globals.
local UI = {}
UI.themes = {
	slate = {
		background = Color3.fromRGB(18, 25, 38),
		surface = Color3.fromRGB(30, 41, 58),
		text = Color3.fromRGB(240, 246, 255),
		muted = Color3.fromRGB(180, 196, 217),
		accent = Color3.fromRGB(68, 105, 181),
	},
	daylight = {
		background = Color3.fromRGB(241, 239, 230),
		surface = Color3.fromRGB(255, 255, 250),
		text = Color3.fromRGB(25, 41, 38),
		muted = Color3.fromRGB(75, 91, 83),
		accent = Color3.fromRGB(36, 105, 79),
	},
}
UI.tokens = { spacing = 12, touchTarget = 48, cornerRadius = 10, textSize = 18, maxWidth = 760 }

local function make(className, props, parent)
	local object = Instance.new(className)
	for key, value in props do
		object[key] = value
	end
	object.Parent = parent
	return object
end

function UI.panel(parent, options)
	local theme = UI.themes[options.theme or "slate"]
	assert(theme, "unknown theme")
	local connections, cardConnections, buttons = {}, {}, {}
	local guiService = game:GetService("GuiService")
	local previousFocus = guiService.SelectedObject
	local screen = make("ScreenGui", {
		Name = options.name or "WorkbenchPanel",
		ResetOnSpawn = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, parent)
	local panel = make("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -24, 1, -24),
		BackgroundColor3 = theme.background,
		BorderSizePixel = 0,
		SelectionGroup = true,
	}, screen)
	make(
		"UISizeConstraint",
		{ MaxSize = Vector2.new(UI.tokens.maxWidth, 620), MinSize = Vector2.new(240, 240) },
		panel
	)
	make("UICorner", { CornerRadius = UDim.new(0, UI.tokens.cornerRadius) }, panel)
	local title = make("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(1, -32, 0, 52),
		BackgroundTransparency = 1,
		Text = options.title or "Panel",
		TextColor3 = theme.text,
		TextSize = 23,
		Font = Enum.Font.GothamBold,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, panel)
	local status = make("TextLabel", {
		Name = "Status",
		Position = UDim2.fromOffset(16, 68),
		Size = UDim2.new(1, -32, 0, 68),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = theme.muted,
		TextSize = UI.tokens.textSize,
		Font = Enum.Font.Gotham,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, panel)
	local grid = make("ScrollingFrame", {
		Name = "Cards",
		Position = UDim2.fromOffset(16, 142),
		Size = UDim2.new(1, -32, 1, -218),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 6,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, panel)
	local layout = make("UIGridLayout", {
		CellPadding = UDim2.fromOffset(12, 12),
		CellSize = UDim2.fromOffset(200, 112),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	local primary = make("TextButton", {
		Name = "Primary",
		Position = UDim2.new(0, 16, 1, -64),
		Size = UDim2.new(1, -32, 0, UI.tokens.touchTarget),
		Text = options.actionText or "Continue",
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = theme.accent,
		BorderSizePixel = 0,
		TextSize = UI.tokens.textSize,
		Font = Enum.Font.GothamBold,
		TextWrapped = true,
		Selectable = true,
	}, panel)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, primary)
	local api = {
		root = screen,
		panel = panel,
		primary = primary,
		state = "loading",
		activations = 0,
		reducedMotion = guiService.ReducedMotionEnabled,
	}
	local busy, destroyed = false, false
	local function updateGrid()
		local width = math.max(grid.AbsoluteSize.X - 8, 1)
		local columns = math.clamp(math.floor((width + 12) / 212), 1, 3)
		layout.CellSize = UDim2.fromOffset(math.floor((width - (columns - 1) * 12) / columns), 112)
	end
	table.insert(connections, grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateGrid))
	table.insert(
		connections,
		guiService:GetPropertyChangedSignal("ReducedMotionEnabled"):Connect(function()
			api.reducedMotion = guiService.ReducedMotionEnabled
		end)
	)
	function api:setState(state, message)
		assert(
			state == "loading"
				or state == "ready"
				or state == "empty"
				or state == "error"
				or state == "disabled",
			"invalid UI state"
		)
		api.state = state
		status.Text = message
			or ({
				loading = "Loading…",
				ready = "Ready",
				empty = "No items available",
				error = "Unable to load. Try again.",
				disabled = "Unavailable",
			})[state]
		primary.Active = state == "ready" or state == "error"
		primary.Selectable = primary.Active
		primary.AutoButtonColor = primary.Active
		primary.BackgroundTransparency = if primary.Active then 0 else 0.55
	end
	function api:setCards(cards)
		assert(#cards <= 100, "card count exceeds bounded UI capacity")
		for _, connection in cardConnections do
			connection:Disconnect()
		end
		table.clear(cardConnections)
		for _, button in buttons do
			button:Destroy()
		end
		table.clear(buttons)
		for index, card in cards do
			local interactive = options.onCardActivated ~= nil and card.disabled ~= true
			local button = make("TextButton", {
				Name = "Card" .. index,
				LayoutOrder = index,
				Text = card.label,
				TextSize = 18,
				TextColor3 = theme.text,
				BackgroundColor3 = theme.surface,
				Font = Enum.Font.Gotham,
				TextWrapped = true,
				BorderSizePixel = 0,
				Selectable = interactive,
				Active = interactive,
				AutoButtonColor = interactive,
			}, grid)
			make("UIPadding", {
				PaddingLeft = UDim.new(0, 12),
				PaddingRight = UDim.new(0, 12),
				PaddingTop = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 8),
			}, button)
			make("UICorner", { CornerRadius = UDim.new(0, 8) }, button)
			table.insert(buttons, button)
			if interactive then
				table.insert(
					cardConnections,
					button.Activated:Connect(function()
						if busy or destroyed or api.state ~= "ready" then
							return
						end
						busy = true
						local ok = pcall(options.onCardActivated, card.id or index, api)
						busy = false
						if not ok and not destroyed then
							api:setState("error")
						end
					end)
				)
			end
		end
		local previous = primary
		for _, button in buttons do
			if button.Selectable then
				previous.NextSelectionDown = button
				button.NextSelectionUp = previous
				previous = button
			end
		end
		previous.NextSelectionDown = primary
		primary.NextSelectionUp = previous
		updateGrid()
	end
	function api:setTheme(name)
		assert(UI.themes[name], "unknown theme")
		theme = UI.themes[name]
		panel.BackgroundColor3, title.TextColor3, status.TextColor3 =
			theme.background, theme.text, theme.muted
		primary.BackgroundColor3 = theme.accent
		for _, button in buttons do
			button.BackgroundColor3, button.TextColor3 = theme.surface, theme.text
		end
	end
	function api:activate()
		if destroyed or busy or not primary.Active then
			return false
		end
		busy = true
		api.activations += 1
		local ok = true
		if options.onActivated then
			ok = pcall(options.onActivated, api)
		end
		busy = false
		if not ok and not destroyed then
			api:setState("error")
		end
		return ok
	end
	table.insert(
		connections,
		primary.Activated:Connect(function()
			api:activate()
		end)
	)
	function api:focus()
		if primary.Selectable and primary.AbsoluteSize.X > 0 and primary.AbsoluteSize.Y > 0 then
			guiService.SelectedObject = primary
			return guiService.SelectedObject == primary
		end
		return false
	end
	function api:inspect()
		local bounds = {}
		for _, object in { panel, title, status, grid, primary } do
			table.insert(bounds, {
				name = object.Name,
				x = object.AbsolutePosition.X,
				y = object.AbsolutePosition.Y,
				width = object.AbsoluteSize.X,
				height = object.AbsoluteSize.Y,
				textFits = if object:IsA("TextLabel") or object:IsA("TextButton")
					then object.TextFits
					else nil,
			})
		end
		return {
			state = api.state,
			bounds = bounds,
			reducedMotion = api.reducedMotion,
			activations = api.activations,
			focus = if guiService.SelectedObject then guiService.SelectedObject.Name else "none",
			cards = #buttons,
		}
	end
	function api:destroy()
		if destroyed then
			return
		end
		destroyed = true
		for _, connection in connections do
			connection:Disconnect()
		end
		for _, connection in cardConnections do
			connection:Disconnect()
		end
		if guiService.SelectedObject and guiService.SelectedObject:IsDescendantOf(screen) then
			guiService.SelectedObject = if previousFocus and previousFocus.Parent then previousFocus else nil
		end
		screen:Destroy()
	end
	api:setState("loading")
	return api
end

return UI
