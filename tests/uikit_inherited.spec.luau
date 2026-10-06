--!strict
-- G4 specs: the inherited Runtime/NativeUI panel after the G4 fixes (FontFace, injected env,
-- events and measure). It loads in Lune and runs on @lune/roblox Instances with FakeUIEvents, a
-- GuiService table and a fixed measure: the state machine gates activation, cards chain
-- gamepad selection and stay bounded, callbacks are guarded, themes repaint, focus is restored on
-- destroy and nothing stays connected; every text object passes UIKit's legacy_font rule.
-- Creator/UI's pure helpers (catalog/1 entry.id) are in tests/creator/ui.luau; its UI.new and
-- this panel's real layout run in Studio (fixtures/creator/UI.client.luau,
-- fixtures/runtime/Diagnostic.client.luau).
local roblox = require("@lune/roblox")

local Audit = require("../packages/UIKit/Audit")
local FakeEnv = require("./fakes/FakeEnv")
local FakeUIEvents = require("./fakes/FakeUIEvents")
local NativeUI = require("../packages/Runtime/NativeUI")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

export type Fixture = { panel: any, hub: any, gui: any, events: { any }, parent: any }

local function fixture(options: { [string]: any }?): Fixture
	local env = FakeEnv.new({ roblox = roblox })
	local guiService = { SelectedObject = nil, ReducedMotionEnabled = false }
	env:register("GuiService", guiService)
	local hub = FakeUIEvents.new()
	local parent = roblox.Instance.new("Folder")
	local events = {}
	local o: { [string]: any } = {
		env = env,
		on = hub.on,
		onChanged = hub.onChanged,
		measure = function(instance: any): any
			return { x = 0, y = 0, w = if instance.Name == "Cards" then 680 else 200, h = 48 }
		end,
		title = "Panel title",
		onActivated = function()
			table.insert(events, "activated")
		end,
		onCardActivated = function(id: any)
			table.insert(events, "card:" .. tostring(id))
			if id == "broken" then
				error("card callback failed")
			end
		end,
	}
	for key, value in options or {} do
		o[key] = value
	end
	return { panel = NativeUI.panel(parent, o), hub = hub, gui = guiService, events = events, parent = parent }
end

test("NativeUI loads in Lune; themes are RGB data and UI.color makes Color3s", function(t)
	t.eq(NativeUI.themes.slate.background, { 18, 25, 38 })
	t.eq(NativeUI.color("daylight", "accent", roblox), roblox.Color3.fromRGB(36, 105, 79))
	t.throws(function()
		NativeUI.color("neon", "accent", roblox)
	end, "unknown theme")
	t.throws(function()
		NativeUI.color("slate", "glow", roblox)
	end, "unknown slot")
	t.ok(table.isfrozen(NativeUI.themes.slate), "themes are frozen")
end)

test("panel: FontFace text, safe insets, and the state machine gates activation", function(t)
	local f = fixture()
	local p = f.panel
	t.eq(p.root.ScreenInsets, roblox.Enum.ScreenInsets.CoreUISafeInsets)
	for _, item in p.root:GetDescendants() do
		if item:IsA("TextLabel") or item:IsA("TextButton") then
			t.eq(item.FontFace.Family, NativeUI.FONT_FAMILY, item.Name .. " uses Builder Sans")
		end
	end
	t.eq(p.state, "loading")
	t.eq(p:activate(), false, "loading blocks activation")
	t.eq(f.hub:fire(p.primary, "Activated"), 1)
	t.eq(p.activations, 0)
	for _, state in { "empty", "disabled" } do
		p:setState(state)
		t.eq(p.primary.Active, false, state .. " is not interactive")
	end
	p:setState("ready", "Custom message")
	t.eq(p.panel.Status.Text, "Custom message")
	t.eq(p:activate(), true)
	t.eq(f.events, { "activated" })
	t.throws(function()
		p:setState("celebrating")
	end, "unknown states are refused")
	local failing = fixture({
		onActivated = function()
			error("primary callback failed")
		end,
	}).panel
	failing:setState("ready")
	t.eq(failing:activate(), false)
	t.eq(failing.state, "error", "a failing callback shows the error state")
	t.eq(failing.primary.Active, true, "error permits retry")
end)

test("cards: bounded, chained for gamepad, guarded callbacks", function(t)
	local f = fixture()
	local p = f.panel
	p:setCards({
		{ id = "first", label = "First" },
		{ id = "off", label = "Off", disabled = true },
		{ id = "broken", label = "Broken" },
	})
	local grid = p.panel.Cards
	local first, off, broken = grid.Card1, grid.Card2, grid.Card3
	t.eq(off.Selectable, false, "disabled cards are skipped")
	t.eq(p.primary.NextSelectionDown, first)
	t.eq(first.NextSelectionDown, broken)
	t.eq(broken.NextSelectionDown, p.primary, "the chain returns to the primary button")
	t.eq(grid.UIGridLayout.CellSize, roblox.UDim2.fromOffset(216, 112), "three columns in 680 px")
	f.hub:fire(first, "Activated")
	t.eq(f.events, {}, "cards wait for the ready state")
	p:setState("ready")
	f.hub:fire(first, "Activated")
	t.eq(f.events, { "card:first" })
	f.hub:fire(broken, "Activated")
	t.eq(p.state, "error", "a failing card callback shows the error state")
	t.eq(f.hub:count(off), 0, "disabled cards have no handler")
	local many = {}
	for index = 1, NativeUI.MAX_CARDS + 1 do
		table.insert(many, { id = index, label = "Card" })
	end
	t.throws(function()
		p:setCards(many)
	end, "more than MAX_CARDS is refused")
	p:setCards({ { id = "only", label = "Only" } })
	t.eq(#grid:GetChildren(), 2, "replacing cards destroys the old ones (layout + 1 card)")
end)

test("theme repaint, focus, reduced motion, inspect and destroy", function(t)
	local f = fixture()
	local p = f.panel
	p:setCards({ { id = "a", label = "A" } })
	p:setTheme("daylight")
	t.eq(p.panel.BackgroundColor3, NativeUI.color("daylight", "background", roblox))
	t.eq(p.panel.Cards.Card1.TextColor3, NativeUI.color("daylight", "text", roblox))
	t.throws(function()
		p:setTheme("neon")
	end)
	p:setState("ready")
	t.eq(p:focus(), true)
	t.eq(f.gui.SelectedObject, p.primary)
	f.gui.ReducedMotionEnabled = true
	f.hub:changed(f.gui, "ReducedMotionEnabled")
	t.eq(p.reducedMotion, true, "follows GuiService.ReducedMotionEnabled")
	local report = p:inspect()
	t.eq(report.state, "ready")
	t.eq(report.cards, 1)
	t.eq(report.focus, "Primary")
	t.eq(#report.bounds, 5)
	t.eq(report.bounds[4].width, 680)
	p:destroy()
	t.eq(f.gui.SelectedObject, nil, "focus leaves the destroyed panel")
	t.eq(f.hub:count(), 0, "nothing stays connected")
	t.eq(p.root.Parent, nil)
	t.eq(p:activate(), false, "destroyed panels do nothing")
	p:destroy()
end)

test("every panel text object passes the UIKit legacy_font and text_scaled rules", function(t)
	local f = fixture()
	f.panel:setCards({ { id = "a", label = "A" } })
	local nodes = Audit.fromInstances(f.panel.root, {
		measure = function(): any
			return { x = 0, y = 0, w = 200, h = 48 }
		end,
	})
	local report = Audit.run(nodes, { rules = { "legacy_font", "text_scaled" } })
	t.eq(report.counts, {}, "no legacy fonts")
end)

return cases
