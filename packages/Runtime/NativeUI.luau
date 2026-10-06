--!strict
-- Native Roblox UI architecture: one owned ScreenGui, scoped connections, no globals at load.
-- Inherited first-pass panel (title, status, card grid, primary button) kept for
-- fixtures/runtime/Diagnostic.client.luau and Creator/UI; new UI uses packages/UIKit. Text uses
-- FontFace (Builder Sans), never the legacy Font enum. Everything engine-bound comes through
-- options at call time, so the module loads in Lune and the panel runs there with fakes:
--   env      { roblox = datatypes, services = { GuiService } } (default: the Roblox globals)
--   on       (instance, event, fn) -> connection (default instance[event]:Connect(fn))
--   onChanged (instance, property, fn) -> connection (default GetPropertyChangedSignal)
--   measure  (instance) -> { x, y, w, h } (default AbsolutePosition/AbsoluteSize)
-- Themes are RGB triples (UI.color turns one into a Color3). Same API as before otherwise:
-- panel(parent, options) -> { setState, setCards, setTheme, activate, focus, inspect, destroy }.
local UI = {}
UI.themes = table.freeze({
	slate = table.freeze({
		background = { 18, 25, 38 },
		surface = { 30, 41, 58 },
		text = { 240, 246, 255 },
		muted = { 180, 196, 217 },
		accent = { 68, 105, 181 },
	}),
	daylight = table.freeze({
		background = { 241, 239, 230 },
		surface = { 255, 255, 250 },
		text = { 25, 41, 38 },
		muted = { 75, 91, 83 },
		accent = { 36, 105, 79 },
	}),
})
UI.tokens = table.freeze({ spacing = 12, touchTarget = 48, cornerRadius = 10, textSize = 18, maxWidth = 760 })
-- Builder Sans, a built-in family (rbxasset), regular and bold.
UI.FONT_FAMILY = "rbxasset://fonts/families/BuilderSans.json"
UI.STATES = table.freeze({ "loading", "ready", "empty", "error", "disabled" })
UI.MAX_CARDS = 100

-- The Color3 for a theme slot (roblox = datatypes; default the Color3 global).
function UI.color(themeName: string, slot: string, roblox: any?): any
	local theme = UI.themes[themeName]
	assert(theme, "unknown theme")
	local rgb = (theme :: any)[slot]
	assert(rgb, "unknown theme slot " .. tostring(slot))
	local color3 = if roblox then roblox.Color3 else Color3 :: any
	return color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function globalsEnv(): any
	return {
		roblox = {
			Instance = Instance,
			Color3 = Color3,
			Vector2 = Vector2,
			UDim = UDim,
			UDim2 = UDim2,
			Font = Font,
			Enum = Enum,
		},
		services = { GuiService = (game :: any):GetService("GuiService") },
	}
end

function UI.panel(parent: any, options: any)
	local themeName = options.theme or "slate"
	assert(UI.themes[themeName], "unknown theme")
	local env = options.env or globalsEnv()
	local r = env.roblox
	local guiService = env.services.GuiService
	local on = options.on
		or function(instance: any, event: string, fn: (...any) -> ()): any
			return instance[event]:Connect(fn)
		end
	local onChanged = options.onChanged
		or function(instance: any, property: string, fn: () -> ()): any
			return instance:GetPropertyChangedSignal(property):Connect(fn)
		end
	local measure = options.measure
		or function(instance: any): any
			local p, s = instance.AbsolutePosition, instance.AbsoluteSize
			return { x = p.X, y = p.Y, w = s.X, h = s.Y }
		end
	local regular = r.Font.new(UI.FONT_FAMILY, r.Enum.FontWeight.Regular)
	local bold = r.Font.new(UI.FONT_FAMILY, r.Enum.FontWeight.Bold)
	local function color(slot: string): any
		return UI.color(themeName, slot, r)
	end
	local function make(className: string, props: { [string]: any }, owner: any?): any
		local object = r.Instance.new(className)
		for key, value in props do
			object[key] = value
		end
		object.Parent = owner
		return object
	end

	local connections, cardConnections, buttons = {}, {}, {}
	local previousFocus = guiService.SelectedObject
	local screen = make("ScreenGui", {
		Name = options.name or "WorkbenchPanel",
		ResetOnSpawn = false,
		ScreenInsets = r.Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = r.Enum.ZIndexBehavior.Sibling,
	}, parent)
	local panel = make("Frame", {
		Name = "Panel",
		AnchorPoint = r.Vector2.new(0.5, 0.5),
		Position = r.UDim2.fromScale(0.5, 0.5),
		Size = r.UDim2.new(1, -24, 1, -24),
		BackgroundColor3 = color("background"),
		BorderSizePixel = 0,
		SelectionGroup = true,
	}, screen)
	make(
		"UISizeConstraint",
		{ MaxSize = r.Vector2.new(UI.tokens.maxWidth, 620), MinSize = r.Vector2.new(240, 240) },
		panel
	)
	make("UICorner", { CornerRadius = r.UDim.new(0, UI.tokens.cornerRadius) }, panel)
	local title = make("TextLabel", {
		Name = "Title",
		Position = r.UDim2.fromOffset(16, 12),
		Size = r.UDim2.new(1, -32, 0, 52),
		BackgroundTransparency = 1,
		Text = options.title or "Panel",
		TextColor3 = color("text"),
		TextSize = 23,
		FontFace = bold,
		TextWrapped = true,
		TextXAlignment = r.Enum.TextXAlignment.Left,
	}, panel)
	local status = make("TextLabel", {
		Name = "Status",
		Position = r.UDim2.fromOffset(16, 68),
		Size = r.UDim2.new(1, -32, 0, 68),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = color("muted"),
		TextSize = UI.tokens.textSize,
		FontFace = regular,
		TextWrapped = true,
		TextXAlignment = r.Enum.TextXAlignment.Left,
		TextYAlignment = r.Enum.TextYAlignment.Top,
	}, panel)
	local grid = make("ScrollingFrame", {
		Name = "Cards",
		Position = r.UDim2.fromOffset(16, 142),
		Size = r.UDim2.new(1, -32, 1, -218),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutomaticCanvasSize = r.Enum.AutomaticSize.Y,
		CanvasSize = r.UDim2.new(),
		ScrollBarThickness = 6,
		ScrollingDirection = r.Enum.ScrollingDirection.Y,
	}, panel)
	local layout = make("UIGridLayout", {
		CellPadding = r.UDim2.fromOffset(12, 12),
		CellSize = r.UDim2.fromOffset(200, 112),
		SortOrder = r.Enum.SortOrder.LayoutOrder,
	}, grid)
	local primary = make("TextButton", {
		Name = "Primary",
		Position = r.UDim2.new(0, 16, 1, -64),
		Size = r.UDim2.new(1, -32, 0, UI.tokens.touchTarget),
		Text = options.actionText or "Continue",
		TextColor3 = r.Color3.new(1, 1, 1),
		BackgroundColor3 = color("accent"),
		BorderSizePixel = 0,
		TextSize = UI.tokens.textSize,
		FontFace = bold,
		TextWrapped = true,
		Selectable = true,
	}, panel)
	make("UICorner", { CornerRadius = r.UDim.new(0, 8) }, primary)
	local api: any = {
		root = screen,
		panel = panel,
		primary = primary,
		state = "loading",
		activations = 0,
		reducedMotion = guiService.ReducedMotionEnabled == true,
	}
	local busy, destroyed = false, false
	-- One to three columns of at least 200 px (convention).
	local function updateGrid()
		local rect = measure(grid)
		local width = math.max((if rect then rect.w else 0) - 8, 1)
		local columns = math.clamp(math.floor((width + 12) / 212), 1, 3)
		layout.CellSize = r.UDim2.fromOffset(math.floor((width - (columns - 1) * 12) / columns), 112)
	end
	table.insert(connections, onChanged(grid, "AbsoluteSize", updateGrid))
	table.insert(
		connections,
		onChanged(guiService, "ReducedMotionEnabled", function()
			api.reducedMotion = guiService.ReducedMotionEnabled == true
		end)
	)
	function api.setState(_self: any, state: string, message: string?)
		assert(table.find(UI.STATES, state) ~= nil, "invalid UI state")
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
	function api.setCards(_self: any, cards: { any })
		assert(#cards <= UI.MAX_CARDS, "card count exceeds bounded UI capacity")
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
				TextColor3 = color("text"),
				BackgroundColor3 = color("surface"),
				FontFace = regular,
				TextWrapped = true,
				BorderSizePixel = 0,
				Selectable = interactive,
				Active = interactive,
				AutoButtonColor = interactive,
			}, grid)
			make("UIPadding", {
				PaddingLeft = r.UDim.new(0, 12),
				PaddingRight = r.UDim.new(0, 12),
				PaddingTop = r.UDim.new(0, 8),
				PaddingBottom = r.UDim.new(0, 8),
			}, button)
			make("UICorner", { CornerRadius = r.UDim.new(0, 8) }, button)
			table.insert(buttons, button)
			if interactive then
				table.insert(
					cardConnections,
					on(button, "Activated", function()
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
	function api.setTheme(_self: any, name: string)
		assert(UI.themes[name], "unknown theme")
		themeName = name
		panel.BackgroundColor3, title.TextColor3, status.TextColor3 =
			color("background"), color("text"), color("muted")
		primary.BackgroundColor3 = color("accent")
		for _, button in buttons do
			button.BackgroundColor3, button.TextColor3 = color("surface"), color("text")
		end
	end
	function api.activate(_self: any): boolean
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
		on(primary, "Activated", function()
			api:activate()
		end)
	)
	function api.focus(_self: any): boolean
		local rect = measure(primary)
		if primary.Selectable and rect and rect.w > 0 and rect.h > 0 then
			guiService.SelectedObject = primary
			return guiService.SelectedObject == primary
		end
		return false
	end
	function api.inspect(_self: any): any
		local bounds = {}
		for _, object in { panel, title, status, grid, primary } do
			local rect = measure(object) or { x = 0, y = 0, w = 0, h = 0 }
			local textFits = nil
			if object:IsA("TextLabel") or object:IsA("TextButton") then
				local ok, fits = pcall(function(): any
					return object.TextFits
				end)
				textFits = if ok then fits else nil
			end
			table.insert(bounds, {
				name = object.Name,
				x = rect.x,
				y = rect.y,
				width = rect.w,
				height = rect.h,
				textFits = textFits,
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
	function api.destroy(_self: any)
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
