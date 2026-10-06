--!strict
-- G4 specs: UIKit/Gallery/Browser, the story browser of the gallery fixture. Mounting lists every
-- story and mounts the initial one; choosing another (a click through FakeUIEvents) replaces
-- the stage and releases the old context; theme, reduced motion, pseudo-loc and device changes
-- rebuild the story with matching settings; the stage takes the device viewport and fits the
-- area; bad settings and unknown stories are refused; destroy leaves nothing connected. The
-- live fixture (ui_Gallery.client.luau) and its audits run in Studio (probe ui_gallery_audit).
local roblox = require("@lune/roblox")

local Audit = require("../packages/UIKit/Audit")
local Browser = require("../packages/UIKit/Gallery/Browser")
local Build = require("../packages/UIKit/Build")
local Localize = require("../packages/UIKit/Localize")
local Stories = require("../packages/UIKit/Gallery/Stories")
local Style = require("../packages/UIKit/Style")
local Tokens = require("../packages/UIKit/Tokens")
local FakeEnv = require("./fakes/FakeEnv")
local FakeUIEvents = require("./fakes/FakeUIEvents")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

export type Fixture = {
	env: any,
	hub: any,
	gui: any,
	browser: any,
	contexts: { any },
	released: number,
	selected: { string },
}

local function fixture(extra: { [string]: any }?): Fixture
	local env = FakeEnv.new({ roblox = roblox })
	local hub = FakeUIEvents.new()
	local desktop = Browser.class("desktop")
	local measure = Audit.staticMeasure(desktop.viewport, desktop.safe)
	local chrome = Build.context({
		env = env,
		on = hub.on,
		onChanged = hub.onChanged,
		class = desktop,
		measure = measure,
	})
	local gui = roblox.Instance.new("ScreenGui")
	gui.Name = "Gui"
	local f: any = { env = env, hub = hub, gui = gui, contexts = {}, released = 0, selected = {} }
	local options: { [string]: any } = {
		chrome = chrome,
		context = function(settings: any): (any, () -> ())
			local ctx = Build.context({
				env = env,
				on = hub.on,
				onChanged = hub.onChanged,
				measure = measure,
				theme = settings.theme,
				class = Browser.class(settings.device),
				motion = { reducedMotion = settings.reducedMotion },
				text = Localize.new({ pseudo = settings.pseudo }):fn(),
			})
			table.insert(f.contexts, { ctx = ctx, settings = settings })
			return ctx, function()
				f.released += 1
			end
		end,
		onSelected = function(name: string)
			table.insert(f.selected, name)
		end,
		initial = "Button",
	}
	for key, value in extra or {} do
		options[key] = value
	end
	f.browser = Browser.mount(gui, options :: any)
	return f
end

local function findButton(parent: any, text: string): any
	for _, item in parent:GetDescendants() do
		if item:IsA("TextButton") then
			local label = item:FindFirstChild("Label")
			if label and label.Text == text then
				return item
			end
		end
	end
	return nil
end

test("mount lists every story and shows the initial one", function(t)
	local f = fixture()
	local browser = f.browser
	t.eq(browser:names(), Stories.names(Build.context({ env = f.env })))
	t.eq(#browser:names(), 27)
	t.eq(browser:current(), "Button")
	t.eq(f.selected, { "Button" })
	local stage = browser:stage()
	t.eq(stage.Parent, f.gui.Browser.Main.Area)
	t.ok(stage:FindFirstChild("Button") ~= nil, "the Button story stack is on the stage")
	t.eq(stage.Size, roblox.UDim2.fromOffset(1280, 720), "desktop viewport")
	t.eq(browser:settings(), { theme = "dark", reducedMotion = false, pseudo = false, device = "desktop" })
	local list = f.gui.Browser.Sidebar.List
	t.ok(findButton(list, "Countdown") ~= nil, "a sidebar entry per story")
end)

test("choosing a story replaces the stage and releases the old context", function(t)
	local f = fixture()
	local first = f.browser:stage()
	local entry = findButton(f.gui.Browser.Sidebar.List, "Toggle")
	t.eq(f.hub:fire(entry, "Activated"), 1, "the sidebar button is wired")
	t.eq(f.browser:current(), "Toggle")
	t.eq(first.Parent, nil, "the old stage is gone")
	t.eq(f.released, 1, "the old context was released")
	t.ok(f.browser:stage():FindFirstChild("Toggle") ~= nil)
	t.eq(f.selected, { "Button", "Toggle" })
	t.eq(f.browser:select("NoSuchStory"), false, "unknown stories are refused")
	t.eq(f.browser:current(), "Toggle")
end)

test("settings rebuild the story with the theme, motion, pseudo-loc and device", function(t)
	local f = fixture()
	f.browser:set({ theme = "light" })
	local stage = f.browser:stage()
	t.eq(stage.BackgroundColor3, Style.color(Tokens.resolve("light"), "background", f.env), "light stage")
	t.eq(f.contexts[#f.contexts].settings.theme, "light")
	local reduce = findButton(f.gui.Browser.Main.Toolbar, "Reduced motion")
	t.ok(reduce ~= nil, "the reduced motion toggle")
	f.hub:fire(reduce, "Activated")
	t.eq(f.browser:settings().reducedMotion, true, "the toggle sets it")
	t.eq(f.contexts[#f.contexts].ctx.motion.reducedMotion, true)
	f.browser:set({ pseudo = true })
	local label = f.browser:stage():FindFirstChild("Button"):FindFirstChildWhichIsA("TextButton").Label
	t.ok(label.Text ~= "Confirm" and #label.Text > #"Confirm", "pseudo-localised: " .. label.Text)
	f.browser:set({ device = "console" })
	stage = f.browser:stage()
	t.eq(stage.Size, roblox.UDim2.fromOffset(1920, 1080))
	-- Area is 1280 - 240 by 720 - 56 on the desktop chrome.
	t.near(stage.Scale.Scale, math.min(1040 / 1920, 664 / 1080), 1e-6, "fits the area (float32)")
	f.browser:set({ device = "phone" })
	t.near(f.browser:stage().Scale.Scale, 1, 1e-9, "a phone fits unscaled")
	t.eq(f.contexts[#f.contexts].ctx.class.touch, true, "phone class")
	t.eq(f.released, #f.contexts - 1, "every replaced context released")
end)

test("bad settings and options are refused", function(t)
	local f = fixture()
	t.ok(string.find(
		errorText(function()
			f.browser:set({ device = "tablet" })
		end),
		"device must be phone, desktop or console",
		1,
		true
	) ~= nil)
	t.ok(string.find(
		errorText(function()
			f.browser:set({ colour = "red" })
		end),
		"unknown setting colour",
		1,
		true
	) ~= nil)
	t.ok(string.find(
		errorText(function()
			f.browser:set({ theme = "sepia" })
		end),
		"theme must be dark or light",
		1,
		true
	) ~= nil)
	t.eq(f.browser:settings().device, "desktop", "a refused change keeps the settings")
	t.throws(function()
		Browser.mount(roblox.Instance.new("ScreenGui"), {} :: any)
	end)
	t.throws(function()
		Browser.class("watch")
	end)
	t.eq(Browser.fit({ 100, 100 }, nil), 1)
	t.eq(Browser.fit({ 100, 100 }, { w = 0, h = 50 }), 1, "no area yet: unscaled")
	t.eq(Browser.fit({ 200, 100 }, { w = 100, h = 100 }), 0.5)
end)

test("destroy cleans the story, the chrome and every connection", function(t)
	local f = fixture()
	t.ok(f.hub:count() > 0)
	f.browser:destroy()
	t.eq(f.hub:count(), 0, "no handlers left")
	t.eq(#f.gui:GetChildren(), 0, "nothing left in the target")
	t.eq(f.released, 1)
	f.browser:destroy()
	t.eq(f.released, 1, "destroy twice is harmless")
end)

return cases
