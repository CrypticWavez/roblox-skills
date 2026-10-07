--!strict
-- G4 specs: every UIKit component builds real @lune/roblox Instances with stable names (two
-- builds give the same tree), tags its root, rejects bad and unknown props with exact messages
-- and leaves no connection, track or Instance behind after destroy. Then behaviour per
-- component, driven through tests/fakes/FakeUIEvents and runner:step: activation guards, value
-- controls, tabs and gamepad links, list windowing, dialogs that answer once, the toast queue,
-- tooltips, counters, dialogue reveal, the settings panel on Stage 0 GameKit/Settings, the
-- ShopCard on Stage 0 GameKit/Catalog (no purchase call, no purchase prop, setup watermark),
-- the require-free LoadingScreen and TeleportTransition state machines, the gallery stories
-- and the UIKit facade. Layout and engine events are probes (ui_gallery_audit, ui_nav_keyboard).
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Build = require("../packages/UIKit/Build")
local Catalog = require("../packages/GameKit/Catalog")
local InputMap = require("../packages/GameKit/InputMap")
local Settings = require("../packages/GameKit/Settings")
local Stories = require("../packages/UIKit/Gallery/Stories")
local UIKit = require("../packages/UIKit/UIKit")
local FakeEnv = require("./fakes/FakeEnv")
local FakeUIEvents = require("./fakes/FakeUIEvents")

local C = UIKit.Components

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

local PHONE = UIKit.Breakpoints.classify({ viewport = { 844, 390 }, input = "Touch" })

-- A context with a fake event hub; measure returns rects[instance] or a 400 x 300 box.
local function fixture(options: { [string]: any }?): any
	local hub = FakeUIEvents.new()
	local env = FakeEnv.new({ roblox = roblox })
	local rects: { [any]: any } = {}
	local opts: any = {
		env = env,
		on = hub.on,
		onChanged = hub.onChanged,
		measure = function(instance: any): any
			return rects[instance] or { x = 0, y = 0, w = 400, h = 300 }
		end,
	}
	for key, value in options or {} do
		opts[key] = value
	end
	local ctx = Build.context(opts)
	local function step(seconds: number?)
		local frames = math.round((seconds or 1) * 60)
		for _ = 1, frames do
			ctx.runner:step(1 / 60)
		end
	end
	return { ctx = ctx, hub = hub, env = env, rects = rects, step = step }
end

-- "Path:Class" for every Instance under root (children sorted by name, then class).
local function tree(root: any): { string }
	local out = {}
	local function walk(item: any, path: string)
		table.insert(out, path .. ":" .. item.ClassName)
		local children = item:GetChildren()
		table.sort(children, function(a: any, b: any): boolean
			if a.Name ~= b.Name then
				return a.Name < b.Name
			end
			return a.ClassName < b.ClassName
		end)
		for _, child in children do
			walk(child, path .. "." .. child.Name)
		end
	end
	walk(root, root.Name)
	return out
end

local function has(list: { string }, entry: string): boolean
	return table.find(list, entry) ~= nil
end

local SAMPLE_CATALOG = Stories.CATALOG
local GAME_CATALOG = Catalog.define({
	schema = "catalog/1",
	mode = "game",
	products = {
		{
			key = "sample_pass",
			kind = "gamepass",
			id = 1,
			grants = { { type = "entitlement", entitlement = "sample_entitlement" } },
			display = {
				nameKey = "uikit.shop.unavailable",
				descriptionKey = "uikit.empty",
				iconKey = "icon.sample",
			},
			enabled = true,
			ownershipVerified = true,
		},
		{
			key = "sample_off",
			kind = "devproduct",
			id = 2,
			grants = { { type = "currency", currency = "sample_currency", amount = 1 } },
			display = { nameKey = "uikit.shop.unavailable" },
			enabled = false,
			ownershipVerified = false,
		},
	},
})

-- One row per component: valid props, root class, entries the tree must contain and one bad
-- props table with the exact problem it must produce.
local COMPONENTS = {
	{
		C.Button,
		{ textKey = "uikit.confirm" },
		"TextButton",
		{
			"Button.Label:TextLabel",
			"Button.Scale:UIScale",
			"Button.FocusRing:Frame",
			"Button.Corner:UICorner",
		},
		{ variant = "loud", text = "x" },
		"Button: variant must be one of primary, secondary, ghost, danger",
	},
	{
		C.IconButton,
		{ labelKey = "uikit.close", glyph = "x" },
		"TextButton",
		{ "IconButton.Glyph:TextLabel", "IconButton.FocusRing:Frame" },
		{ labelKey = "uikit.close", glyph = "x", image = "rbxassetid://0" },
		"IconButton: needs exactly one of glyph or image",
	},
	{
		C.Toggle,
		{ textKey = "settings.subtitles", value = true },
		"TextButton",
		{ "Toggle.Track.Knob:Frame", "Toggle.State:TextLabel", "Toggle.Label:TextLabel" },
		{ value = true },
		"Toggle: needs textKey or text",
	},
	{
		C.Slider,
		{ textKey = "settings.volume.master", value = 0.5 },
		"Frame",
		{ "Slider.Track.Rail.Fill:Frame", "Slider.Track.Rail.Knob:Frame", "Slider.Header.Value:TextLabel" },
		{ text = "x", min = 2, max = 1 },
		"Slider: min must be below max",
	},
	{
		C.Tabs,
		{ items = { { id = "first", text = "One" }, { id = "second", text = "Two" } } },
		"Frame",
		{ "Tabs.Bar.Tab_first:TextButton", "Tabs.Bar.Tab_second.Label:TextLabel", "Tabs.Indicator:Frame" },
		{ items = { { id = "only", text = "One" } } },
		"Tabs: items needs 2-8 entries",
	},
	{
		C.VirtualList,
		{ count = 50, rowHeight = 30, render = function() end },
		"ScrollingFrame",
		{ "VirtualList:ScrollingFrame" },
		{ count = 50, rowHeight = 30 },
		"VirtualList: render is required",
	},
	{
		C.Grid,
		{ columns = { phone = 2, desktop = 4 } },
		"Frame",
		{ "Grid.Layout:UIGridLayout" },
		{ columns = 13 },
		"Grid: columns must be 1-12 or a table of device = 1-12",
	},
	{
		C.Modal,
		{ textKey = "uikit.confirm", bodyKey = "uikit.error" },
		"Frame",
		{
			"Modal.Scrim:TextButton",
			"Modal.Dialog.Title:TextLabel",
			"Modal.Dialog.Body:TextLabel",
			"Modal.Dialog.Actions:Frame",
		},
		{ bodyKey = "uikit.error" },
		"Modal: needs a title (textKey or text)",
	},
	{
		C.ConfirmDialog,
		{ textKey = "uikit.confirm" },
		"Frame",
		{ "Modal.Dialog.Actions.Cancel:TextButton", "Modal.Dialog.Actions.Confirm:TextButton" },
		{ textKey = "uikit.confirm", confirmKey = "not a key!" },
		"ConfirmDialog: confirmKey must be a localisation key (letters, digits, _ . -)",
	},
	{
		C.Toast,
		{ kind = "success", textKey = "uikit.toast.success" },
		"TextButton",
		{ "Toast.Accent:Frame", "Toast.Kind:TextLabel", "Toast.Message:TextLabel", "Toast.Count:TextLabel" },
		{ kind = "panic", text = "x" },
		"Toast: kind must be one of info, success, warning, error",
	},
	{
		C.Toast.Host,
		{},
		"Frame",
		{ "ToastHost.Layout:UIListLayout" },
		{ maxVisible = 0 },
		"ToastHost: maxVisible must be >= 1",
	},
	{
		C.Tooltip,
		{ text = "Hint" },
		"Frame",
		{ "Tooltip.Label:TextLabel", "Tooltip.Size:UISizeConstraint" },
		{ target = "not an instance" },
		"Tooltip: target must be an Instance",
	},
	{
		C.ProgressBar,
		{ value = 0.25, showValue = true },
		"Frame",
		{ "ProgressBar.Track.Fill:Frame", "ProgressBar.Header.Value:TextLabel" },
		{ value = 1.5 },
		"ProgressBar: value must be <= 1",
	},
	{
		C.RollingCounter,
		{ value = 1234 },
		"TextLabel",
		{ "RollingCounter.Scale:UIScale" },
		{},
		"RollingCounter: value is required",
	},
	{
		C.Badge,
		{ count = 5 },
		"Frame",
		{ "Badge.Label:TextLabel", "Badge.Corner:UICorner" },
		{ count = -1 },
		"Badge: count must be >= 0",
	},
	{
		C.Card,
		{ textKey = "uikit.empty", subtitleKey = "uikit.loading" },
		"Frame",
		{ "Card.Title:TextLabel", "Card.Subtitle:TextLabel", "Card.Content:Frame" },
		{ padding = "md", width = -5 },
		"Card: width must be >= 0",
	},
	{
		C.ShopCard,
		{ catalog = SAMPLE_CATALOG, productKey = "sample_product", price = { state = "pending" } },
		"TextButton",
		{
			"ShopCard.Name:TextLabel",
			"ShopCard.Price:TextLabel",
			"ShopCard.Status:TextLabel",
			"ShopCard.Watermark.Text:TextLabel",
		},
		{ catalog = SAMPLE_CATALOG, productKey = "missing_product" },
		"ShopCard: productKey missing_product is not in the catalog",
	},
	{
		C.OfferPopup,
		{
			textKey = "uikit.offer.get",
			catalog = SAMPLE_CATALOG,
			productKey = "sample_product",
			ribbon = "starter",
			secondsLeft = 3600,
		},
		"Frame",
		{
			"Modal.Dialog.Content.Card:TextButton",
			"Modal.Dialog.Content.Card.Ribbon.Text:TextLabel",
			"Modal.Dialog.Content.TimeLeft:TextLabel",
			"Modal.Dialog.Actions.Later:TextButton",
			"Modal.Dialog.Actions.Get:TextButton",
		},
		{ textKey = "uikit.offer.get", catalog = SAMPLE_CATALOG, productKey = "missing_product" },
		"OfferPopup: productKey missing_product is not in the catalog",
	},
	{
		C.DialogueBox,
		{ text = "Hello there.", speaker = "Speaker" },
		"Frame",
		{
			"DialogueBox.Hit:TextButton",
			"DialogueBox.Stack.Body:TextLabel",
			"DialogueBox.Stack.Speaker:TextLabel",
		},
		{ text = "x", choices = { { id = "same", text = "a" }, { id = "same", text = "b" } } },
		"DialogueBox: choices[2].id is repeated",
	},
	{
		C.SettingsPanel,
		{ values = Settings.defaults() },
		"ScrollingFrame",
		{
			"SettingsPanel.Section_audio.Row_volume_master:Frame",
			"SettingsPanel.Section_accessibility.Row_reducedMotion:TextButton",
			"SettingsPanel.Section_language.Row_language.Choice:TextButton",
		},
		{ values = Settings.defaults(), groups = { "cheats" } },
		"SettingsPanel: groups: unknown group cheats",
	},
	{
		C.StatBar,
		{ text = "Stat", value = 30, max = 100, segments = 4 },
		"Frame",
		{ "StatBar.Track.Fill:Frame", "StatBar.Track.Trail:Frame", "StatBar.Track.Ticks.Tick_3:Frame" },
		{ value = 1, max = -1 },
		"StatBar: max must be >= 0",
	},
	{
		C.Timer,
		{ seconds = 75 },
		"TextLabel",
		{ "Timer:TextLabel" },
		{ style = "sundial" },
		"Timer: style must be one of clock, hours, precise",
	},
	{
		C.Countdown,
		{ from = 3 },
		"Frame",
		{ "Countdown.Number:TextLabel", "Countdown.Number.Scale:UIScale" },
		{ from = 0 },
		"Countdown: from must be >= 1",
	},
	{
		C.LeaderboardPanel,
		{ entries = { { rank = 1, name = "Player 1", value = 10 } } },
		"Frame",
		{ "LeaderboardPanel.List.Row_1.Name:TextLabel", "LeaderboardPanel.Empty:TextLabel" },
		{ entries = { { rank = 0, name = "Player 1", value = 10 } } },
		"LeaderboardPanel: entries[1].rank must be an integer >= 1",
	},
	{
		C.KeybindPrompt,
		{ action = "gameplay.interact", device = "KeyboardAndMouse" },
		"Frame",
		{ "KeybindPrompt.Glyph.Key:TextLabel", "KeybindPrompt.Label:TextLabel" },
		{ action = "gameplay.fly", map = InputMap.defaults() },
		"KeybindPrompt: action gameplay.fly is not in the input map",
	},
	{
		C.InventoryGrid,
		{ capacity = 6, slots = { { key = "item_a", glyph = "A" } } },
		"ScrollingFrame",
		{ "InventoryGrid.Slot_1:TextButton", "InventoryGrid.Slot_6.Count:TextLabel" },
		{ capacity = 1, slots = { false, false } },
		"InventoryGrid: slots holds more entries than capacity",
	},
	{
		C.TouchActionButton,
		{ action = "gameplay.jump", uiKey = "jump_button", labelKey = "input.gameplay.jump", glyph = "^" },
		"TextButton",
		{ "TouchActionButton.Cooldown.Gradient:UIGradient", "TouchActionButton.Glyph:TextLabel" },
		{ action = "jump", uiKey = "jump_button", labelKey = "input.gameplay.jump", glyph = "^" },
		"TouchActionButton: action must be an InputMap action name (context.action)",
	},
}

test("the facade lists every component and every component has a row here", function(t)
	local names = {}
	for name in C do
		table.insert(names, name)
	end
	table.sort(names)
	t.eq(#names, 28, table.concat(names, ", "))
	local covered = {}
	for _, row in COMPONENTS do
		covered[row[1].name] = true
	end
	for _, name in names do
		local module = C[name]
		if module.name then
			t.ok(covered[module.name], name .. " has no row in COMPONENTS")
		end
	end
	t.eq(UIKit.VERSION, "uikit/1")
	t.ok(table.isfrozen(UIKit))
end)

for _, row in COMPONENTS do
	local module, props, rootClass, entries, bad, message = row[1], row[2], row[3], row[4], row[5], row[6]
	test(module.name .. ": stable tree, tagged root, bad props rejected, clean destroy", function(t)
		local f = fixture()
		local first = module.build(props, f.ctx)
		local second = module.build(props, f.ctx)
		t.eq(tree(first), tree(second), "two builds give the same tree")
		t.eq(first.ClassName, rootClass)
		t.eq(first:GetAttribute("UIKitComponent"), module.name)
		t.ok(first:HasTag("UIKit") and first:HasTag(module.name), "root tags")
		local listing = tree(first)
		for _, entry in entries do
			t.ok(has(listing, entry), module.name .. " tree lacks " .. entry)
		end
		local problems = module.validate(bad)
		t.ok(contains(problems, message), module.name .. " problems: " .. table.concat(problems, " | "))
		t.throws(function()
			module.mount(bad, f.ctx)
		end, "mount refuses bad props")
		local unknown = table.clone(props)
		unknown.bogusProp = true
		t.ok(contains(module.validate(unknown), module.name .. ": unknown prop bogusProp"), "unknown prop")
		t.eq(module.validate(props), {}, "valid props")
		local named = table.clone(props)
		named.name = "Custom"
		named.layoutOrder = 7
		local handle = module.mount(named, f.ctx, roblox.Instance.new("Frame"))
		t.eq(handle.root.Name, "Custom")
		t.eq(handle.root.LayoutOrder, 7)
		f.step(2)
		handle:destroy()
		handle:destroy() -- idempotent
		t.eq(handle.root.Parent, nil, "root destroyed")
		t.eq(f.hub:count(), 0, "no connections left")
		t.eq(f.ctx.runner:count(), 0, "no tracks left")
		t.throws(function()
			handle:update({})
		end, "update after destroy")
	end)
end

-- ---------------------------------------------------------------- behaviour

test("Button: activation runs through the guard, disabled buttons do not act", function(t)
	local f = fixture()
	local calls = 0
	local button
	button = C.Button.mount({
		textKey = "uikit.confirm",
		onActivated = function()
			calls += 1
			f.hub:fire(button.root, "Activated") -- re-entry is refused by the guard
		end,
	}, f.ctx)
	f.hub:fire(button.root, "Activated")
	t.eq(calls, 1)
	button:update({ disabled = true })
	t.eq(button.root.Interactable, false)
	f.hub:fire(button.root, "Activated")
	t.eq(calls, 1)
	button:update({ disabled = false, textKey = "uikit.retry" })
	t.eq(button.parts.label.Text, "Retry")
	f.hub:fire(button.root, "MouseButton1Down")
	f.step(0.1)
	t.ok(button.root.Scale.Scale < 1, "press feedback")
	f.hub:fire(button.root, "MouseButton1Up")
	f.step(2)
	t.near(button.root.Scale.Scale, 1, 1e-6)
	f.hub:fire(button.root, "SelectionGained")
	t.ok(button.root.FocusRing.Visible, "focus ring on selection")
	button:destroy()
end)

test("Button and IconButton: touch keeps the 44 px minimum and IconButton keeps its label", function(t)
	local f = fixture({ class = PHONE })
	local small = C.Button.mount({ textKey = "uikit.confirm", size = "sm" }, f.ctx)
	t.eq(small.root.Size.Y.Offset, 44)
	local icon = C.IconButton.mount({ labelKey = "uikit.close", glyph = "x", size = "sm" }, f.ctx)
	t.eq(icon.root.Size, roblox.UDim2.fromOffset(44, 44))
	t.eq(icon.root:GetAttribute("UIKitLabel"), "Close")
	t.eq(
		C.IconButton.validate({ labelKey = "uikit.close", image = "http://example.invalid/x.png" }),
		{ "IconButton: image must be an rbxassetid:// (or rbxasset://) content id" }
	)
end)

test("Toggle: activation flips and reports, update moves without callback, knob springs", function(t)
	local f = fixture()
	local changes = {}
	local toggle = C.Toggle.mount({
		textKey = "settings.subtitles",
		onChanged = function(value)
			table.insert(changes, value)
		end,
	}, f.ctx)
	t.eq(toggle.parts.state.Text, "Off")
	f.hub:fire(toggle.root, "Activated")
	f.step(2)
	t.eq(changes, { true })
	t.eq(toggle.parts.state.Text, "On", "state shown as text, not colour alone")
	t.eq(toggle.root:GetAttribute("Value"), true)
	local p = C.Toggle.knobPosition(true)
	t.eq(toggle.parts.knob.Position, roblox.UDim2.new(p[1], p[2], p[3], p[4]))
	toggle:update({ value = false })
	f.step(2)
	t.eq(changes, { true }, "update does not call back")
	t.eq(toggle.state.value, false)
end)

test("Slider: quantize, pointer, keys, nudge and percent text", function(t)
	t.eq(C.Slider.quantize(0.333, 0, 1, 0.05), 0.35)
	t.eq(C.Slider.quantize(7.4, 0, 10, 0.5), 7.5)
	t.eq(C.Slider.quantize(-3, 0, 10, 1), 0)
	t.eq(C.Slider.quantize(0.123, 0, 1, 0), 0.123, "step 0 is continuous")
	t.eq(C.Slider.decimals(0.05), 2)
	t.eq(C.Slider.fromPosition(250, { x = 100, w = 200 }, 0, 10, 1), 8)
	t.eq(C.Slider.fromPosition(0, { x = 100, w = 0 }, 3, 10, 1), 3)
	local f = fixture()
	local changed, committed = {}, {}
	local slider = C.Slider.mount({
		textKey = "settings.volume.master",
		min = 0,
		max = 10,
		step = 1,
		value = 3,
		onChanged = function(v)
			table.insert(changed, v)
		end,
		onCommitted = function(v)
			table.insert(committed, v)
		end,
	}, f.ctx)
	f.rects[slider.parts.rail] = { x = 100, y = 0, w = 200, h = 6 }
	local Enum = roblox.Enum
	f.hub:fire(
		slider.parts.track,
		"InputBegan",
		{ UserInputType = Enum.UserInputType.MouseButton1, Position = roblox.Vector3.new(250, 0, 0) }
	)
	f.hub:fire(
		slider.parts.track,
		"InputChanged",
		{ UserInputType = Enum.UserInputType.MouseMovement, Position = roblox.Vector3.new(300, 0, 0) }
	)
	f.hub:fire(
		slider.parts.track,
		"InputEnded",
		{ UserInputType = Enum.UserInputType.MouseButton1, Position = roblox.Vector3.new(300, 0, 0) }
	)
	t.eq(changed, { 8, 10 })
	t.eq(committed, { 10 })
	f.hub:fire(slider.parts.track, "InputBegan", {
		UserInputType = Enum.UserInputType.Gamepad1,
		KeyCode = Enum.KeyCode.DPadLeft,
		Position = roblox.Vector3.new(),
	})
	t.eq(slider.state.value, 9)
	t.eq(slider.state.nudge(-100), true)
	t.eq(slider.state.value, 0)
	t.eq(slider.state.nudge(-1), false, "clamped: no move")
	f.step(2)
	t.eq(slider.parts.value.Text, "0")
	t.eq(slider.parts.fill.Size, roblox.UDim2.fromScale(0, 1))
	slider:update({ disabled = true })
	t.eq(slider.state.nudge(1), false, "disabled")
	local percent = C.Slider.mount({ text = "Vol", value = 0.8, format = "percent" }, f.ctx)
	t.eq(percent.parts.value.Text, "80%")
end)

test("Tabs: pick, step, gamepad links and the indicator", function(t)
	local f = fixture()
	local picked = {}
	local tabs = C.Tabs.mount({
		items = {
			{ id = "one", text = "One" },
			{ id = "two", text = "Two" },
			{ id = "three", text = "Three" },
		},
		onSelected = function(id)
			table.insert(picked, id)
		end,
	}, f.ctx)
	local list = tabs.parts.tabs
	t.ok(list[1].NextSelectionRight == list[2] and list[2].NextSelectionLeft == list[1])
	t.eq(list[1].NextSelectionLeft, nil, "no wrap at the edge")
	f.hub:fire(list[3], "Activated")
	f.step(2)
	t.eq(picked, { "three" })
	t.ok(list[3]:HasTag("Selected") and not list[1]:HasTag("Selected"))
	t.eq(tabs.root:GetAttribute("Selected"), "three")
	local p = C.Tabs.indicatorPosition(3, 3)
	t.eq(tabs.parts.indicator.Position, roblox.UDim2.new(p[1], p[2], p[3], p[4]))
	t.eq(tabs.state.step(1), false, "clamped at the last tab")
	t.eq(tabs.state.step(-2), true)
	t.eq(picked, { "three", "one" })
	t.ok(string.find(
		errorText(function()
			tabs:update({ items = { { id = "x", text = "X" }, { id = "y", text = "Y" } } })
		end),
		"items cannot change",
		1,
		true
	))
	t.eq(
		C.Tabs.validate({ items = { { id = "a_b", text = "x" }, { id = "c", text = "y" } }, selected = "zzz" }),
		{ "Tabs: selected names no item" }
	)
end)

test("VirtualList: windows 10 000 rows with a bounded pool and recycles on scroll", function(t)
	t.eq({ C.VirtualList.window(0, 400, 40, 10000, 0) }, { 1, 10 })
	t.eq({ C.VirtualList.window(4000, 400, 40, 10000, 3) }, { 98, 113 })
	t.eq({ C.VirtualList.window(0, 400, 40, 0, 3) }, { 1, 0 })
	t.eq({ C.VirtualList.window(990 * 40, 400, 40, 1000, 3) }, { 988, 1000 })
	local f = fixture()
	local renders = 0
	local list = C.VirtualList.mount({
		count = 10000,
		rowHeight = 40,
		render = function(row, index)
			renders += 1
			row:SetAttribute("Rendered", index)
		end,
	}, f.ctx)
	-- 300 px viewport / 40 px rows + 3 overscan rows each side: at most 8 + 6 + 1 rows.
	t.eq(#list.state.pool, 11, "at the top only the lower overscan exists")
	t.eq(list.state.first, 1)
	list.root.CanvasPosition = roblox.Vector2.new(0, 4000)
	f.hub:changed(list.root, "CanvasPosition")
	t.eq(list.state.first, 98)
	local pool = #list.state.pool
	t.eq(pool, 14, "sized to the viewport, not the 10 000 rows")
	list.root.CanvasPosition = roblox.Vector2.new(0, 200000)
	f.hub:changed(list.root, "CanvasPosition")
	t.eq(#list.state.pool, pool, "the pool stops growing once it covers the window")
	t.eq(#list.root:GetChildren(), pool, "only pooled rows exist")
	list.root.CanvasPosition = roblox.Vector2.new(0, 4000)
	f.hub:changed(list.root, "CanvasPosition")
	local shownIndices = {}
	for _, row in list.root:GetChildren() do
		if row.Visible then
			table.insert(shownIndices, row:GetAttribute("Index"))
		end
	end
	table.sort(shownIndices)
	t.eq(shownIndices[1], 98)
	local before = renders
	f.hub:changed(list.root, "CanvasPosition")
	t.eq(renders, before, "no re-render without a change")
	list.state.scrollTo(99999)
	t.eq(list.root.CanvasPosition.Y, 9999 * 40, "clamped to the last row")
	list:update({ count = 5 })
	t.eq(list.root.CanvasSize.Y.Offset, 200)
	t.eq(
		C.VirtualList.validate({ count = -1, rowHeight = 10, render = print }),
		{ "VirtualList: count must be >= 0" }
	)
	local errors = fixture()
	C.VirtualList.mount({
		count = 3,
		rowHeight = 10,
		render = function()
			error("bad row")
		end,
	}, errors.ctx)
	t.ok(contains(errors.env.reports, "VirtualList render error"), "render errors are reported")
end)

test("Grid: columns per device class", function(t)
	t.eq(C.Grid.columnsFor("phone", { phone = 2, desktop = 5 }), 2)
	t.eq(C.Grid.columnsFor("console", { phone = 2, desktop = 5 }), 5, "falls back to desktop")
	t.eq(C.Grid.columnsFor("tablet", nil), 3)
	t.eq(C.Grid.columnsFor("vr", 6), 6)
	local phone = fixture({ class = PHONE })
	local grid = C.Grid.mount({ columns = { phone = 2, desktop = 5 } }, phone.ctx)
	t.eq(grid.root:GetAttribute("Columns"), 2)
	t.eq(grid.parts.layout.FillDirectionMaxCells, 2)
	grid:update({ columns = 3 })
	t.eq(grid.root:GetAttribute("Columns"), 3)
	t.eq(
		C.Grid.validate({ columns = { watch = 1 } }),
		{ "Grid: columns must be 1-12 or a table of device = 1-12" }
	)
end)

test("Modal: opens and closes with motion, the scrim dismisses, rapid toggles settle", function(t)
	local f = fixture()
	local reasons = {}
	local modal = C.Modal.mount({
		textKey = "uikit.confirm",
		onDismiss = function(reason)
			table.insert(reasons, reason)
		end,
	}, f.ctx)
	t.eq(modal.root.Visible, false)
	t.ok(modal.root.SelectionGroup)
	modal.state.open()
	t.ok(modal.root.Visible)
	f.step(0.05)
	t.ok(modal.parts.title.TextTransparency > 0, "mid fade")
	f.step(2)
	t.eq(modal.parts.title.TextTransparency, 0)
	modal.state.close()
	modal.state.open() -- reversed mid-close
	f.step(2)
	t.ok(modal.root.Visible, "the reopen wins")
	t.eq(modal.parts.title.TextTransparency, 0)
	f.hub:fire(modal.parts.scrim, "Activated")
	f.step(2)
	t.eq(reasons, { "scrim" })
	t.eq(modal.root.Visible, false)
	t.eq(modal.parts.title.TextTransparency, 0, "resting values restored after the fade-out")
	local fixed = C.Modal.mount({ textKey = "uikit.confirm", dismissable = false, open = true }, f.ctx)
	f.hub:fire(fixed.parts.scrim, "Activated")
	t.ok(fixed.state.isOpen, "not dismissable")
end)

test("ConfirmDialog: answers once per open, destructive uses the danger variant", function(t)
	local f = fixture()
	local answers = {}
	local dialog = C.ConfirmDialog.mount({
		textKey = "uikit.confirm",
		destructive = true,
		onConfirm = function()
			table.insert(answers, "confirm")
		end,
		onCancel = function()
			table.insert(answers, "cancel")
		end,
	}, f.ctx)
	t.ok(dialog.parts.confirm.root:HasTag("Danger"))
	dialog.state.open()
	f.step(1)
	f.hub:fire(dialog.parts.confirm.root, "Activated")
	f.hub:fire(dialog.parts.confirm.root, "Activated")
	f.hub:fire(dialog.parts.cancel.root, "Activated")
	f.step(1)
	t.eq(answers, { "confirm" }, "one answer per open")
	t.eq(dialog.root.Visible, false)
	dialog.state.open()
	f.step(1)
	f.hub:fire(dialog.parts.scrim, "Activated")
	t.eq(answers, { "confirm", "cancel" }, "the scrim counts as cancel")
end)

test("Toast.queue: bounded, deduplicated and promoted in order", function(t)
	local q = C.Toast.queue({ maxVisible = 2, maxQueued = 1 })
	local a = q:push({ text = "A" })
	local b = q:push({ text = "B" })
	local c, events = q:push({ text = "C" })
	t.eq(q:visible(), { a, b })
	t.eq(q:waiting(), { c })
	t.eq(events, {})
	local _, dropped = q:push({ text = "D" })
	t.eq(dropped, { { type = "drop", id = c } }, "the oldest waiting toast is dropped")
	local same, bump = q:push({ text = "A" })
	t.eq(same, a)
	t.eq(bump, { { type = "bump", id = a } })
	t.eq(q:get(a).count, 2)
	t.eq(q:dismiss(a), { { type = "hide", id = a }, { type = "show", id = 4 } })
	t.eq(q:dismiss(999), {})
	t.throws(function()
		q:push({ kind = "shout", text = "x" })
	end)
	t.throws(function()
		q:push({ kind = "info" })
	end)
	t.throws(function()
		C.Toast.queue({ maxVisible = 0 })
	end)
end)

test("Toast host: shows, bumps, expires on the runner clock and frees its cards", function(t)
	local f = fixture()
	local host = C.Toast.Host.mount({ maxVisible = 2, duration = 1 }, f.ctx)
	local first = host.state.push({ kind = "info", textKey = "uikit.loading" })
	host.state.push({ kind = "success", textKey = "uikit.toast.success" })
	host.state.push({ kind = "error", textKey = "uikit.error" })
	t.eq(#host.state.queue:visible(), 2)
	t.eq(host.state.queue:waiting(), { 3 })
	t.ok(host.root:FindFirstChild("Slot_" .. first) ~= nil)
	f.step(0.6)
	host.state.push({ kind = "info", textKey = "uikit.loading" }) -- a bump at 0.6 s
	t.eq(host.state.cards[first].card.parts.count.Text, "x2")
	f.step(0.5)
	t.eq(
		host.state.queue:visible(),
		{ first, 3 },
		"the second expired, the bumped first stayed, the third moved up"
	)
	f.step(0.4)
	t.eq(host.state.queue:visible(), { first, 3 }, "the bump restarted the first timer")
	f.step(3)
	t.eq(host.state.queue:visible(), {})
	t.eq(#host.root:GetChildren(), 1, "only the layout is left")
	host:destroy()
	t.eq(f.hub:count(), 0)
end)

test("Tooltip: placement stays inside the safe area and hover waits for the delay", function(t)
	local safe = { x = 0, y = 0, w = 800, h = 600 }
	t.eq(
		{ C.Tooltip.place({ x = 100, y = 100, w = 40, h = 40 }, { w = 80, h = 30 }, safe) },
		{ 80, 62, "above" }
	)
	t.eq(
		{ C.Tooltip.place({ x = 100, y = 10, w = 40, h = 40 }, { w = 80, h = 30 }, safe) },
		{ 80, 58, "below" }
	)
	t.eq(
		{ C.Tooltip.place({ x = 780, y = 300, w = 40, h = 40 }, { w = 80, h = 30 }, safe) },
		{ 720, 262, "above" }
	)
	local f = fixture()
	local target = C.IconButton.mount({ labelKey = "uikit.close", glyph = "x" }, f.ctx)
	local tip = C.Tooltip.mount({ target = target.root }, f.ctx, roblox.Instance.new("ScreenGui"))
	f.hub:fire(target.root, "MouseEnter")
	f.step(0.2)
	t.eq(tip.root.Visible, false, "waits for tooltipDelay")
	f.step(0.3)
	t.ok(tip.root.Visible)
	t.eq(tip.parts.label.Text, "Close", "falls back to the target's UIKitLabel")
	f.hub:fire(target.root, "MouseLeave")
	t.eq(tip.root.Visible, false)
	f.hub:fire(target.root, "SelectionGained")
	t.ok(tip.root.Visible, "gamepad selection shows at once")
	f.hub:fire(target.root, "Activated")
	t.eq(tip.root.Visible, false)
	f.hub:fire(target.root, "MouseEnter")
	f.hub:fire(target.root, "MouseLeave")
	f.step(1)
	t.eq(tip.root.Visible, false, "leaving cancels the pending show")
end)

test("ProgressBar and StatBar: values as text, springs, trail and indeterminate loop", function(t)
	t.eq(C.ProgressBar.percent(0.456), "46%")
	t.eq(C.StatBar.fraction(150, 100), 1)
	t.eq(C.StatBar.fraction(5, 0), 0)
	t.eq(C.StatBar.valueText(49.6, 100), "50 / 100")
	local f = fixture()
	local bar = C.ProgressBar.mount({ value = 0.2, showValue = true, text = "Load" }, f.ctx)
	bar:update({ value = 0.9 })
	f.step(3)
	t.eq(bar.parts.value.Text, "90%")
	t.near(bar.parts.fill.Size.X.Scale, 0.9, 1e-3)
	local spinner = C.ProgressBar.mount({ indeterminate = true }, f.ctx)
	f.step(5)
	t.ok(f.ctx.runner:count() >= 1, "the sweep loops")
	spinner:update({ indeterminate = false, value = 0.5 })
	f.step(3)
	t.near(spinner.parts.fill.Size.X.Scale, 0.5, 1e-3)
	local calm = fixture({ motion = { reducedMotion = true } })
	local still = C.ProgressBar.mount({ indeterminate = true }, calm.ctx)
	t.eq(calm.ctx.runner:count(), 0, "reduced motion: no sweep")
	t.eq(still.parts.fill.Position, roblox.UDim2.fromScale(0.35, 0))
	local stat = C.StatBar.mount({ value = 80, max = 100 }, f.ctx)
	stat:update({ value = 30 })
	f.step(0.2)
	t.near(stat.parts.trail.Size.X.Scale, 0.8, 1e-6, "the trail holds the old value")
	f.step(3)
	t.near(stat.parts.trail.Size.X.Scale, 0.3, 1e-3)
	t.eq(stat.parts.value.Text, "30 / 100")
end)

test("RollingCounter: formats and rolls from the number on screen", function(t)
	local format = C.RollingCounter.format
	t.eq(format(1234567), "1,234,567")
	t.eq(format(-1234.6), "-1,235")
	t.eq(format(1250000, "compact"), "1.2M", "compact rounds down")
	t.eq(format(999, "compact"), "999")
	t.eq(format(12345.678, "fixed", 2), "12,345.68")
	t.eq(format(1234, "integer", nil, "."), "1.234")
	t.eq(format(-0.2), "0")
	local f = fixture()
	local counter = C.RollingCounter.mount({ value = 100 }, f.ctx)
	counter:update({ value = 200 })
	f.step(0.3)
	local mid = counter.state.current()
	t.ok(mid > 100 and mid < 200, "mid roll: " .. mid)
	counter:update({ value = 50 })
	f.step(0.016)
	t.ok(math.abs(counter.state.current() - mid) < 20, "continues from the shown number")
	f.step(2)
	t.eq(counter.root.Text, "50")
	t.eq(counter.root:GetAttribute("Value"), 50)
	local calm = fixture({ motion = { reducedMotion = true } })
	local jump = C.RollingCounter.mount({ value = 1 }, calm.ctx)
	jump:update({ value = 9 })
	t.eq(jump.root.Text, "9", "reduced motion jumps")
end)

test("Badge, Card and Timer: counts, interactivity and time text", function(t)
	t.eq(C.Badge.text(0), "")
	t.eq(C.Badge.text(120), "99+")
	t.eq(C.Badge.text(5, 3), "3+")
	local f = fixture()
	local badge = C.Badge.mount({ count = 0 }, f.ctx)
	t.eq(badge.root.Visible, false, "hidden at 0")
	badge:update({ count = 4 })
	t.ok(badge.root.Visible)
	t.eq(badge.root.Label.Text, "4")
	t.throws(function()
		badge:update({ dot = true })
	end)
	local clicks = 0
	local card = C.Card.mount({
		textKey = "uikit.empty",
		onActivated = function()
			clicks += 1
		end,
	}, f.ctx)
	t.eq(card.root.ClassName, "TextButton")
	f.hub:fire(card.root, "Activated")
	t.eq(clicks, 1)
	t.eq(C.Card.build({ textKey = "uikit.empty" }, f.ctx).ClassName, "Frame", "plain cards are Frames")
	t.eq(C.Timer.format(125), "2:05")
	t.eq(C.Timer.format(3725, "hours"), "1:02:05")
	t.eq(C.Timer.format(8.46, "precise"), "0:08.4")
	t.eq(C.Timer.format(-3), "0:00")
	t.eq(C.Timer.format(3600 * 2), "120:00", "minutes keep growing in clock style")
	local timer = C.Timer.mount({ seconds = 12, warnBelow = 10 }, f.ctx)
	t.ok(not timer.root:HasTag("Warning"))
	timer:update({ seconds = 9 })
	t.ok(timer.root:HasTag("Warning"), "warning is a tag, not colour alone")
	t.eq(timer.root.Text, "0:09")
end)

test("ShopCard: binds to Catalog entries, setup watermark, selectable only when buyable", function(t)
	local f = fixture()
	local setup = C.ShopCard.mount(
		{ catalog = SAMPLE_CATALOG, productKey = "sample_product", price = { state = "ok", text = "10" } },
		f.ctx
	)
	t.ok(setup.root:FindFirstChild("Watermark") ~= nil, "setup mode shows the watermark")
	t.eq(setup.root:GetAttribute("SetupOnly"), true)
	t.eq(setup.root:GetAttribute("Selectable"), false, "setup mode never sells")
	t.eq(setup.root.Status.Text, "Not available")
	local picks = {}
	local live = C.ShopCard.mount({
		catalog = GAME_CATALOG,
		productKey = "sample_pass",
		price = { state = "ok", text = "25" },
		imageFor = function(key)
			return if key == "icon.sample" then "rbxassetid://0" else nil
		end,
		onSelect = function(key)
			table.insert(picks, key)
		end,
	}, f.ctx)
	t.eq(live.root:FindFirstChild("Watermark"), nil)
	t.eq(live.root.Icon.ClassName, "ImageLabel")
	t.eq(live.root.Price.Text, "25")
	t.eq(live.root.Description.Text, "Nothing here yet")
	f.hub:fire(live.root, "Activated")
	t.eq(picks, { "sample_pass" }, "onSelect names the product; the game buys")
	live:update({ owned = true })
	t.eq(live.root.Status.Text, "Owned")
	f.hub:fire(live.root, "Activated")
	t.eq(picks, { "sample_pass" }, "owned products do not act")
	t.eq(
		{ C.ShopCard.status({ catalog = GAME_CATALOG, productKey = "sample_pass" }) },
		{ "uikit.price.pending", nil, false }
	)
	t.eq({
		C.ShopCard.status({
			catalog = GAME_CATALOG,
			productKey = "sample_off",
			price = { state = "ok", text = "5" },
		}),
	}, { "", "5", false }, "disabled products cannot be selected")
	t.eq({
		C.ShopCard.status({
			catalog = GAME_CATALOG,
			productKey = "sample_pass",
			price = { state = "unavailable" },
		}),
	}, { "uikit.price.unavailable", nil, false })
	t.ok(contains(
		C.ShopCard.validate({
			catalog = GAME_CATALOG,
			productKey = "sample_pass",
			price = { state = "ok" },
		}),
		"price.text is required when price.state is ok"
	))
	t.ok(contains(
		C.ShopCard.validate({
			catalog = { schema = "catalog/1", mode = "setup", products = {} },
			productKey = "x",
			price = 5,
		}),
		"price must be a table"
	))
end)

test("ShopCard: ribbons from the Offers list, localised and tagged", function(t)
	local Offers = require("../packages/GameKit/Offers")
	t.eq(C.ShopCard.RIBBONS, Offers.RIBBONS, "UIKit keeps the same ribbon list as GameKit/Offers")
	local f = fixture()
	local card =
		C.ShopCard.mount({ catalog = GAME_CATALOG, productKey = "sample_pass", ribbon = "best_value" }, f.ctx)
	t.eq(card.root.Ribbon.Text.Text, "Best value")
	t.ok(card.root.Ribbon:HasTag("ShopRibbon"))
	t.eq(card.root:GetAttribute("Ribbon"), "best_value")
	t.ok(
		contains(
			C.ShopCard.validate({ catalog = GAME_CATALOG, productKey = "sample_pass", ribbon = "huge" }),
			"ribbon"
		)
	)
	card:destroy()
end)

test("OfferPopup: always dismissable, selects only buyable products, expires", function(t)
	local f = fixture()
	local picks, dismissed = {}, {}
	local popup = C.OfferPopup.mount({
		textKey = "uikit.offer.get",
		catalog = GAME_CATALOG,
		productKey = "sample_pass",
		price = { state = "pending" },
		secondsLeft = 700,
		onSelect = function(key)
			table.insert(picks, key)
		end,
		onDismiss = function(reason)
			table.insert(dismissed, reason)
		end,
	}, f.ctx, roblox.Instance.new("Frame"))
	popup.state.open()
	local get = popup.root.Dialog.Actions.Get
	f.hub:fire(get, "Activated")
	t.eq(picks, {}, "no price yet: Get does not act")
	popup:update({ price = { state = "ok", text = "99" } })
	t.eq(popup.root.Dialog.Content.Card.Price.Text, "99")
	f.step(1)
	f.hub:fire(get, "Activated")
	t.eq(picks, { "sample_pass" }, "onSelect names the product; the game prompts")
	f.hub:fire(get, "Activated")
	t.eq(picks, { "sample_pass" }, "answers once per open")
	popup.state.open()
	f.step(1)
	f.hub:fire(popup.root.Dialog.Actions.Later, "Activated")
	t.eq(dismissed, { "later" })
	popup.state.open()
	popup:update({ secondsLeft = 599 })
	t.ok(popup.root.Dialog.Content.TimeLeft:HasTag("Warning"))
	popup:update({ secondsLeft = 0 })
	t.eq(dismissed, { "later", "expired" })
	t.eq(popup.root.Dialog.Content.TimeLeft.Text, "Ends in 0:00:00")
	for name in C.OfferPopup.schema do
		t.ok(name ~= "dismissable", "no prop turns dismissal off")
		t.ok(not string.find(string.lower(name), "purchase", 1, true), "schema field " .. name)
		t.ok(not string.find(string.lower(name), "buy", 1, true), "schema field " .. name)
	end
	local source = fs.readFile(ROOT .. "/packages/UIKit/Components/OfferPopup.luau")
	t.ok(not string.find(source, "MarketplaceService", 1, true))
	popup:destroy()
end)

test("ShopCard never takes a purchase hook and never calls a purchase API", function(t)
	for _, prop in { "onPurchase", "purchase", "onBuy", "promptPurchase", "marketplace" } do
		local props: any = { catalog = SAMPLE_CATALOG, productKey = "sample_product" }
		props[prop] = function() end
		t.ok(contains(C.ShopCard.validate(props), "ShopCard: unknown prop " .. prop), prop .. " is refused")
	end
	for name in C.ShopCard.schema do
		t.ok(not string.find(string.lower(name), "purchase", 1, true), "schema field " .. name)
		t.ok(not string.find(string.lower(name), "buy", 1, true), "schema field " .. name)
	end
	-- The source, comments stripped, names no purchase API.
	local source = fs.readFile(ROOT .. "/packages/UIKit/Components/ShopCard.luau")
	local code = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
	code = string.gsub(code, "%-%-[^\n]*", "")
	for _, needle in
		{
			"MarketplaceService",
			"PromptProductPurchase",
			"PromptGamePassPurchase",
			"PromptPurchase",
			"PromptSubscriptionPurchase",
			"ProcessReceipt",
			"PerformPurchase",
			"GetService",
		}
	do
		t.ok(not string.find(code, needle, 1, true), "ShopCard code mentions " .. needle)
	end
end)

test("DialogueBox: typewriter reveal, advance completes then continues, choices answer once", function(t)
	t.near(C.DialogueBox.revealTime("abcdefghi", 45), 0.2, 1e-12)
	t.eq(C.DialogueBox.DEFAULT_CPS, 45)
	local f = fixture()
	local continued, chosen = 0, {}
	local box = C.DialogueBox.mount({
		text = "Hello there, traveller.",
		onContinue = function()
			continued += 1
		end,
	}, f.ctx)
	t.eq(box.parts.body.MaxVisibleGraphemes, 0)
	f.step(0.2)
	t.ok(box.parts.body.MaxVisibleGraphemes > 0 and box.parts.body.MaxVisibleGraphemes < 23)
	t.eq(box.state.advance(), "revealed", "first advance completes the line")
	t.eq(box.parts.body.MaxVisibleGraphemes, -1)
	t.ok(box.parts.nextLabel.Visible)
	f.hub:fire(box.parts.hit, "Activated")
	t.eq(continued, 1)
	box:update({
		text = "Pick one.",
		choices = { { id = "yes", textKey = "uikit.confirm" }, { id = "no", textKey = "uikit.cancel" } },
		onChoice = function(id)
			table.insert(chosen, id)
		end,
	})
	f.step(1)
	t.ok(box.parts.choices.Visible)
	t.eq(box.state.advance(), "waiting_for_choice")
	local yes = box.parts.choices:FindFirstChild("Choice_yes")
	f.hub:fire(yes, "Activated")
	f.hub:fire(yes, "Activated")
	f.hub:fire(box.parts.choices:FindFirstChild("Choice_no"), "Activated")
	t.eq(chosen, { "yes" })
	local calm = fixture({ motion = { reducedMotion = true } })
	local instant = C.DialogueBox.mount({ text = "All at once." }, calm.ctx)
	t.eq(instant.parts.body.MaxVisibleGraphemes, -1, "reduced motion shows the whole line")
	t.eq(instant.state.revealed, true)
end)

test("SettingsPanel: rows from settings/1, changes go through Settings.set, refresh is silent", function(t)
	t.eq(C.SettingsPanel.rowName("volume.master"), "Row_volume_master")
	local f = fixture()
	local changes = {}
	local panel = C.SettingsPanel.mount({
		values = Settings.defaults(),
		locales = { "auto", "en-us", "pt-br" },
		onChange = function(values, path, notes)
			table.insert(changes, { path = path, value = Settings.get(values, path), notes = #notes })
		end,
	}, f.ctx)
	local rows = panel.parts.rows
	local count = 0
	for _ in rows do
		count += 1
	end
	t.eq(count, #Settings.FIELDS, "one row per field")
	local toggle = panel.state.handles.reducedMotion
	f.hub:fire(toggle.root, "Activated")
	t.eq(changes[1], { path = "reducedMotion", value = true, notes = 0 })
	t.eq(Settings.get(panel.state.values, "reducedMotion"), true)
	local slider = panel.state.handles["volume.music"]
	slider.state.nudge(-1)
	t.eq(changes[2].path, "volume.music")
	t.near(changes[2].value, 0.95, 1e-9)
	local choice = panel.state.handles.colorblindMode
	f.hub:fire(choice.root, "Activated")
	t.eq(changes[3], { path = "colorblindMode", value = "protanopia", notes = 0 })
	t.eq(choice.parts.label.Text, "Protanopia")
	f.hub:fire(choice.root, "InputBegan", { KeyCode = roblox.Enum.KeyCode.DPadLeft })
	t.eq(Settings.get(panel.state.values, "colorblindMode"), "none")
	local language = panel.state.handles.language
	f.hub:fire(language.root, "Activated")
	f.hub:fire(language.root, "Activated")
	t.eq(Settings.get(panel.state.values, "language"), "pt-br")
	t.eq(language.parts.label.Text, "pt-br", "locale ids without a key show as the id")
	local before = #changes
	local fresh = Settings.defaults()
	panel:update({ values = fresh })
	t.eq(#changes, before, "refresh does not call onChange")
	t.eq(toggle.state.value, false)
	t.eq(choice.parts.label.Text, "Off")
	t.ok(contains(C.SettingsPanel.validate({ values = { schema = "settings/0" } }), "SettingsPanel: values:"))
	t.throws(function()
		panel:update({ groups = { "audio" } })
	end)
	panel:destroy()
	t.eq(f.hub:count(), 0)
end)

test("Countdown: 3, 2, 1, go on the runner clock, cancel stops it", function(t)
	t.eq(C.Countdown.schedule(3, 1), {
		{ t = 0, value = 3 },
		{ t = 1, value = 2 },
		{ t = 2, value = 1 },
		{ t = 3, value = 0 },
	})
	local f = fixture()
	local ticks, done = {}, 0
	local countdown = C.Countdown.mount({
		from = 3,
		holdGo = 0.5,
		onTick = function(n)
			table.insert(ticks, n)
		end,
		onDone = function()
			done += 1
		end,
	}, f.ctx)
	t.eq(countdown.state.start(), true)
	t.eq(countdown.state.start(), false, "already running")
	t.eq(countdown.parts.number.Text, "3")
	f.step(3.1)
	t.eq(ticks, { 3, 2, 1, 0 })
	t.eq(countdown.parts.number.Text, "Go")
	f.step(0.5)
	t.eq(done, 1)
	t.eq(countdown.root.Visible, false)
	countdown.state.start()
	f.step(1.5)
	countdown.state.cancel()
	f.step(5)
	t.eq(done, 1, "a cancelled countdown never finishes")
	t.eq(ticks, { 3, 2, 1, 0, 3, 2 })
end)

test("LeaderboardPanel: ranks, highlight, empty state and plain-text names", function(t)
	t.eq(C.LeaderboardPanel.valueText(1234, "integer"), "1,234")
	t.eq(C.LeaderboardPanel.valueText(1500000, "compact"), "1.5M")
	t.eq(C.LeaderboardPanel.valueText(95, "time"), "1:35")
	local f = fixture()
	local panel = C.LeaderboardPanel.mount({
		entries = {
			{ rank = 1, name = "<b>Player</b>", value = 10 },
			{ rank = 2, name = "Player 2", value = 5, highlight = true },
		},
	}, f.ctx)
	local list = panel.parts.list
	t.eq(list.Row_1:FindFirstChild("Name").RichText, false, "names never render markup")
	t.ok(list.Row_2:HasTag("Highlight"))
	t.eq(panel.root.Empty.Visible, false)
	panel:update({ entries = {} })
	t.eq(panel.root.Empty.Visible, true)
	t.eq(panel.root.Empty.Text, "No entries")
	t.eq(list:FindFirstChild("Row_1"), nil)
	t.ok(
		contains(
			C.LeaderboardPanel.validate({ entries = { { rank = 1, name = string.rep("x", 65), value = 1 } } }),
			"entries[1].name must be a string of 1-64 bytes"
		)
	)
end)

test("KeybindPrompt: glyph per device, image from ctx.glyphImage, touch tap cap", function(t)
	local f = fixture({
		glyphImage = function(key)
			return if key == "ButtonX" then "rbxasset://textures/ui/Controls/xboxX.png" else nil
		end,
	})
	local kbm = C.KeybindPrompt.mount({ action = "gameplay.interact", device = "KeyboardAndMouse" }, f.ctx)
	t.eq(kbm.parts.cap.Key.Text, "E")
	t.eq(kbm.root.Label.Text, "Interact")
	kbm:update({ device = "Gamepad" })
	t.eq(kbm.parts.cap:GetAttribute("GlyphKind"), "pad")
	t.ok(kbm.parts.cap.Image.Visible and not kbm.parts.cap.Key.Visible, "engine image when available")
	local ps = C.KeybindPrompt.mount({ action = "ui.back", device = "Gamepad", style = "playstation" }, f.ctx)
	t.eq(ps.parts.cap.Key.Text, "Circle")
	local touch = C.KeybindPrompt.mount({ action = "ui.confirm", device = "Touch", hold = true }, f.ctx)
	t.eq(touch.parts.cap.Key.Text, "Tap")
	touch:update({ progress = 0.5 })
	t.eq(touch.parts.fill.Size, roblox.UDim2.fromScale(0.5, 1))
	t.ok(string.find(
		errorText(function()
			C.KeybindPrompt.mount({ action = "gameplay.fly" }, f.ctx)
		end),
		"not in ctx.inputMap",
		1,
		true
	))
end)

test("InventoryGrid: explicit layout, gamepad links, selection and empty slots", function(t)
	t.eq({ C.InventoryGrid.layout(1, 4, 64, 8) }, { 0, 0 })
	t.eq({ C.InventoryGrid.layout(6, 4, 64, 8) }, { 72, 72 })
	t.eq(C.InventoryGrid.links(1, 4, 10), { right = 2, down = 5 })
	t.eq(C.InventoryGrid.links(8, 4, 10), { left = 7, up = 4, down = 10 }, "short last row: its last slot")
	t.eq(C.InventoryGrid.links(10, 4, 10), { left = 9, up = 6 })
	local f = fixture()
	local picks = {}
	local grid = C.InventoryGrid.mount({
		capacity = 10,
		columns = 4,
		slots = {
			{ key = "item_a", glyph = "A", count = 3 },
			false,
			{ key = "item_c", image = "rbxassetid://0" },
		},
		onSelect = function(index, key)
			table.insert(picks, { index, key })
		end,
	}, f.ctx)
	local slots = grid.parts.slots
	t.ok(slots[8].NextSelectionDown == slots[10])
	t.eq(slots[1].Count.Text, "3")
	t.eq(slots[2]:GetAttribute("Empty"), true)
	t.eq(slots[2]:GetAttribute("UIKitLabel"), "Empty slot")
	t.ok(slots[3].Icon.Visible and not slots[3].Glyph.Visible)
	f.hub:fire(slots[3], "Activated")
	f.hub:fire(slots[2], "Activated")
	t.eq(picks, { { 3, "item_c" }, { 2, nil } })
	t.ok(slots[2]:HasTag("Selected") and not slots[3]:HasTag("Selected"))
	t.throws(function()
		grid:update({ capacity = 4 })
	end)
	t.ok(
		contains(
			C.InventoryGrid.validate({ capacity = 2, slots = { { key = "x", image = "http://x" } } }),
			"slots[1].image must be a content id"
		)
	)
end)

test("TouchActionButton: IAS key attribute, press and release, cooldown dimming", function(t)
	local points = C.TouchActionButton.cooldownKeypoints
	t.eq(points(0), { { 0, 1 }, { 1, 1 } })
	t.eq(points(1), { { 0, 0.35 }, { 1, 0.35 } })
	t.eq(points(0.5), { { 0, 0.35 }, { 0.499, 0.35 }, { 0.5, 1 }, { 1, 1 } })
	local desktop = fixture()
	local hidden = C.TouchActionButton.mount(
		{ action = "gameplay.jump", uiKey = "jump_button", labelKey = "input.gameplay.jump", glyph = "^" },
		desktop.ctx
	)
	t.eq(hidden.root.Visible, false, "hidden off touch")
	local f = fixture({ class = PHONE })
	local pressed = {}
	local button = C.TouchActionButton.mount({
		action = "gameplay.jump",
		uiKey = "jump_button",
		labelKey = "input.gameplay.jump",
		glyph = "^",
		onPressed = function(state)
			table.insert(pressed, state)
		end,
	}, f.ctx)
	t.ok(button.root.Visible)
	t.eq(button.root:GetAttribute("InputMapKey"), "ui:jump_button")
	t.eq(button.root:GetAttribute("Action"), "gameplay.jump")
	t.eq(button.root.Size, roblox.UDim2.fromOffset(72, 72))
	local touch = { UserInputType = roblox.Enum.UserInputType.Touch }
	f.hub:fire(button.root, "InputBegan", touch)
	f.hub:fire(button.root, "InputBegan", touch)
	f.hub:fire(button.root, "MouseLeave")
	f.hub:fire(button.root, "InputEnded", touch)
	t.eq(pressed, { true, false }, "sliding off releases once")
	button:update({ cooldown = 0.25 })
	t.ok(button.root.Cooldown.Visible)
	t.eq(button.root:GetAttribute("Cooldown"), 0.25)
	f.hub:fire(button.root, "InputBegan", touch)
	button:destroy()
	t.eq(pressed, { true, false, true, false }, "destroy releases a held press")
end)

test("LoadingScreen: validates, smooths progress forward only, fades out and destroys", function(t)
	local env = { roblox = roblox }
	t.eq(require("../packages/UIKit/Components/LoadingScreen").validate({ titleText = 5 }), {
		"LoadingScreen: titleText must be a string of at most 256 bytes",
	})
	local LoadingScreen = C.LoadingScreen
	t.eq(LoadingScreen.validate({ colour = "red" }), { "LoadingScreen: unknown prop colour" })
	t.throws(function()
		LoadingScreen.new({ reducedMotion = "yes" }, env)
	end)
	local screen = LoadingScreen.new({ titleText = "Loading", statusText = "..." }, env)
	t.eq(screen.gui.ClassName, "ScreenGui")
	t.eq(screen.gui.DisplayOrder, 90)
	t.eq(screen.parts.title.FontFace.Family, "rbxasset://fonts/families/BuilderSans.json")
	screen:setProgress(0.5)
	screen:step(0.1)
	local partial = screen:shown()
	t.ok(partial > 0 and partial < 0.5, "smoothed")
	screen:setProgress(0.2)
	for _ = 1, 120 do
		screen:step(1 / 60)
	end
	t.near(screen:shown(), 0.5, 1e-9, "never moves backwards")
	t.ok(screen.parts.spinner.Rotation ~= 0, "spinner turns")
	local finished = 0
	screen:finish(function()
		finished += 1
	end)
	t.eq(screen:state(), "finishing")
	for _ = 1, 30 do
		screen:step(1 / 60)
	end
	t.eq(screen:state(), "done")
	t.eq(finished, 1)
	t.eq(screen.gui.Parent, nil)
	screen:finish()
	t.eq(finished, 1)
	local calm = LoadingScreen.new({ reducedMotion = true }, env)
	calm:step(1)
	t.eq(calm.parts.spinner.Rotation, 0, "reduced motion: the spinner stands still")
	calm:finish()
	calm:step(0.16)
	t.eq(calm:state(), "done", "0.15 s fade")
	-- Frame-rate independence of the smoothing.
	local a, b = LoadingScreen.new({}, env), LoadingScreen.new({}, env)
	a:setProgress(1)
	b:setProgress(1)
	for _ = 1, 30 do
		a:step(1 / 30)
	end
	for _ = 1, 144 do
		b:step(1 / 144)
	end
	t.near(a:shown(), b:shown(), 1e-9)
end)

test("TeleportTransition: cover, covered, reveal, failure and adoption on arrival", function(t)
	local env = { roblox = roblox }
	local TeleportTransition = C.TeleportTransition
	t.eq(TeleportTransition.validate({ labelText = 3 }), {
		"TeleportTransition: labelText must be a string of at most 256 bytes",
	})
	local transition = TeleportTransition.new({ labelText = "Travelling" }, env)
	t.eq(transition:state(), "idle")
	t.eq(transition:reveal(), false, "cannot reveal before covering")
	local covered = 0
	t.eq(
		transition:cover(function()
			covered += 1
		end),
		true
	)
	t.eq(transition:cover(), false)
	transition:step(0.2)
	t.ok(transition:opacity() > 0 and transition:opacity() < 1)
	transition:step(0.2)
	t.eq(transition:state(), "covered")
	t.eq(covered, 1)
	t.eq(transition.gui:GetAttribute("TeleportTransitionState"), "covered")
	t.eq(transition.gui.Cover.Active, true, "swallows input while covered")
	-- Arrival: the destination adopts the same tree, covered, and reveals.
	local arrived = TeleportTransition.adopt(transition.gui)
	t.eq(arrived:state(), "covered")
	local revealed = 0
	arrived:reveal(function()
		revealed += 1
	end)
	arrived:step(0.6)
	t.eq(arrived:state(), "done")
	t.eq(revealed, 1)
	t.eq(arrived.gui.Cover.BackgroundTransparency, 1)
	t.throws(function()
		TeleportTransition.adopt(roblox.Instance.new("ScreenGui"))
	end)
	-- A failed teleport reveals the current place with a message.
	local failing = TeleportTransition.new({ reducedMotion = true }, env)
	failing:cover()
	failing:step(0.05)
	t.eq(failing:fail("Could not travel"), true)
	t.eq(failing.gui.Cover.Message.Text, "Could not travel")
	failing:step(0.15)
	t.eq(failing:state(), "done", "reduced motion: 0.15 s")
	t.eq(failing:fail(), false)
end)

test("every gallery story builds with the UI Labs (target) -> cleanup signature and cleans up", function(t)
	for _, class in
		{
			PHONE,
			UIKit.Breakpoints.classify({ viewport = { 1920, 1080 }, input = "Gamepad", tenFoot = true }),
		}
	do
		local f = fixture({ class = class })
		local names = Stories.names(f.ctx)
		t.eq(#names, 28)
		t.eq(names[1], "Button")
		for _, story in Stories.list(f.ctx) do
			local target = roblox.Instance.new("Frame")
			local cleanup = story.build(target)
			t.eq(type(cleanup), "function", story.name)
			t.ok(#target:GetDescendants() > 0, story.name .. " built nothing")
			f.step(1)
			cleanup()
			t.eq(#target:GetChildren(), 0, story.name .. " left children")
		end
		f.step(1)
		t.eq(f.hub:count(), 0, class.device .. ": no connections left")
		t.eq(f.ctx.runner:count(), 0, class.device .. ": no tracks left")
	end
	t.eq(Catalog.validate(Stories.CATALOG), {})
	t.eq(Stories.CATALOG.mode, "setup")
end)

test("Build: context and component contract errors", function(t)
	t.throws(function()
		Build.context({} :: any)
	end)
	t.throws(function()
		Build.context({ env = {} })
	end)
	local f = fixture()
	t.ok(string.find(
		errorText(function()
			Build.screenGui(f.ctx, "Gui", "basement")
		end),
		"unknown layer basement",
		1,
		true
	))
	local gui = Build.screenGui(f.ctx, "Gui", "modal", true)
	t.eq(gui.DisplayOrder, 40)
	t.eq(gui.ScreenInsets, roblox.Enum.ScreenInsets.None)
	t.eq(Build.screenGui(f.ctx, "Hud", "hud").ScreenInsets, roblox.Enum.ScreenInsets.CoreUISafeInsets)
	local guard = Build.guard()
	t.eq({ guard:invoke(function()
		error("x")
	end) }, { false, "callback_failed" })
	t.eq(guard.failures, 1)
	guard:destroy()
	t.eq({ guard:invoke(function() end) }, { false, "closed" })
	t.eq(
		Build.validate({ a = { kind = "number", required = true } }, {}, "Thing"),
		{ "Thing: a is required" }
	)
	t.eq(Build.validate({}, 5, "Thing"), { "Thing: props must be a table" })
end)

return cases
