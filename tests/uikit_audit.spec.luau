--!strict
-- G4 specs: UIKit/Audit and UIKit/AuditRoblox. Seeded bad Instance trees, one per rule, must be
-- flagged with exactly that rule id and path (and nothing else); a clean tree passes; snapshots
-- validate; duplicate sibling names get unique paths; the AuditRoblox adapter runs in Lune with
-- injected measure, class and TextFits (pseudo-localisation pass and text restore included).
-- Every gallery story passes the layout-free rules on phone and desktop; layout rules need the
-- engine and are probe ui_gallery_audit.
local roblox = require("@lune/roblox")

local Audit = require("../packages/UIKit/Audit")
local AuditRoblox = require("../packages/UIKit/AuditRoblox")
local Breakpoints = require("../packages/UIKit/Breakpoints")
local Build = require("../packages/UIKit/Build")
local Localize = require("../packages/UIKit/Localize")
local Stories = require("../packages/UIKit/Gallery/Stories")
local FakeEnv = require("./fakes/FakeEnv")
local FakeUIEvents = require("./fakes/FakeUIEvents")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local PHONE = Breakpoints.classify({
	viewport = { 844, 390 },
	input = "Touch",
	insets = { left = 47, top = 0, right = 47, bottom = 21 },
})
local DESKTOP = Breakpoints.classify({ viewport = { 1920, 1080 } })
local GOOD_FONT = roblox.Font.new("rbxasset://fonts/families/BuilderSans.json")

-- A ScreenGui with a dark full-screen Root frame (inside the safe area).
local function screen(): (any, any)
	local gui = roblox.Instance.new("ScreenGui")
	gui.Name = "Gui"
	gui.ScreenInsets = roblox.Enum.ScreenInsets.CoreUISafeInsets
	local root = roblox.Instance.new("Frame")
	root.Name = "Root"
	root.Size = roblox.UDim2.fromScale(1, 1)
	root.BackgroundColor3 = roblox.Color3.fromRGB(18, 18, 18)
	root.Parent = gui
	return gui, root
end

-- A well-formed text object (readable, built-in font, 18 px) at x, y with size w x h.
local function text(class: string, name: string, parent: any, x: number, y: number, w: number, h: number): any
	local item = roblox.Instance.new(class)
	item.Name = name
	item.Text = name
	item.FontFace = GOOD_FONT
	item.TextSize = 18
	item.TextColor3 = roblox.Color3.fromRGB(246, 246, 246)
	item.BackgroundTransparency = 1
	item.Position = roblox.UDim2.fromOffset(x, y)
	item.Size = roblox.UDim2.fromOffset(w, h)
	item.Parent = parent
	return item
end

local function audit(root: any, class: any, extra: { [string]: any }?): any
	local measure = Audit.staticMeasure(class.viewport, class.safe)
	local nodes = Audit.fromInstances(root, { measure = measure })
	local options: any = { device = class.device, touch = class.touch, safe = class.safe }
	for key, value in extra or {} do
		options[key] = value
	end
	return Audit.run(nodes, options)
end

test("a clean screen passes every rule", function(t)
	local _, root = screen()
	text("TextButton", "Confirm", root, 0, 0, 160, 48)
	text("TextButton", "Cancel", root, 200, 0, 160, 48)
	text("TextLabel", "Title", root, 0, 80, 300, 30)
	local report = audit(root, PHONE)
	t.eq(report.findings, {})
	t.ok(report.ok)
	t.eq(report.schema, Audit.SCHEMA)
	t.eq(report.device, "phone")
	t.eq(report.checked, 4)
end)

-- Each seeded tree breaks one rule: { rule, severity, paths, build(root), device, options? }.
local SEEDS = {
	{
		rule = "touch_target",
		severity = "error",
		paths = { "Root.Tiny" },
		build = function(root: any)
			text("TextButton", "Tiny", root, 0, 0, 30, 30)
		end,
	},
	{
		rule = "contrast",
		severity = "error",
		paths = { "Root.Faint" },
		build = function(root: any)
			local faint = text("TextLabel", "Faint", root, 0, 0, 200, 30)
			faint.TextColor3 = roblox.Color3.fromRGB(60, 60, 60)
		end,
	},
	{
		rule = "text_size",
		severity = "error",
		paths = { "Root.Small" },
		build = function(root: any)
			text("TextLabel", "Small", root, 0, 0, 200, 30).TextSize = 8
		end,
	},
	{
		rule = "safe_area",
		severity = "error",
		paths = { "Root.Notch" },
		build = function(root: any)
			-- Root sits at the safe rectangle; -60 px pushes the button under the notch.
			text("TextButton", "Notch", root, -60, 100, 120, 48)
		end,
	},
	{
		rule = "overlap",
		severity = "error",
		paths = { "Root.Left" },
		build = function(root: any)
			text("TextButton", "Left", root, 0, 0, 120, 48)
			text("TextButton", "Right", root, 100, 0, 120, 48)
		end,
	},
	{
		rule = "gamepad_reachable",
		severity = "error",
		paths = { "Root.Behind" },
		build = function(root: any)
			local dialog = roblox.Instance.new("Frame")
			dialog.Name = "Dialog"
			dialog.BackgroundTransparency = 1
			dialog.Size = roblox.UDim2.fromOffset(400, 100)
			dialog.SelectionGroup = true
			local stop = roblox.Enum.SelectionBehavior.Stop
			dialog.SelectionBehaviorUp = stop
			dialog.SelectionBehaviorDown = stop
			dialog.SelectionBehaviorLeft = stop
			dialog.SelectionBehaviorRight = stop
			dialog.Parent = root
			text("TextButton", "Yes", dialog, 0, 0, 120, 48)
			text("TextButton", "No", dialog, 200, 0, 120, 48)
			text("TextButton", "Behind", root, 0, 200, 120, 48)
		end,
		options = { entry = "Root.Dialog.Yes" },
	},
	{
		rule = "legacy_font",
		severity = "error",
		paths = { "Root.Old", "Root.Unset" },
		build = function(root: any)
			text("TextLabel", "Old", root, 0, 0, 200, 30).FontFace =
				roblox.Font.fromEnum(roblox.Enum.Font.GothamBold)
			-- Never given a FontFace: reads LegacyArial.
			local unset = roblox.Instance.new("TextLabel")
			unset.Name = "Unset"
			unset.Text = "Unset"
			unset.TextSize = 18
			unset.TextColor3 = roblox.Color3.fromRGB(246, 246, 246)
			unset.BackgroundTransparency = 1
			unset.Position = roblox.UDim2.fromOffset(0, 40)
			unset.Size = roblox.UDim2.fromOffset(200, 30)
			unset.Parent = root
		end,
	},
	{
		rule = "text_scaled",
		severity = "warn",
		paths = { "Root.Scaled" },
		build = function(root: any)
			text("TextLabel", "Scaled", root, 0, 0, 200, 30).TextScaled = true
		end,
	},
	{
		rule = "canvas_group_size",
		severity = "warn",
		paths = { "Root.Group" },
		build = function(root: any)
			local group = roblox.Instance.new("CanvasGroup")
			group.Name = "Group"
			group.Size = roblox.UDim2.fromOffset(100, 100)
			group.AutomaticSize = roblox.Enum.AutomaticSize.Y
			group.BackgroundTransparency = 1
			group.Parent = root
		end,
	},
	{
		rule = "text_fit",
		severity = "warn",
		paths = { "Root.Tight" },
		build = function(root: any)
			-- Fits in English, overflows once pseudo-localised.
			local tight = text("TextLabel", "Tight", root, 0, 0, 72, 22)
			tight.Text = "Settings"
		end,
		options = { pseudo = true },
	},
}

for _, seed in SEEDS do
	test("seeded bad tree is flagged exactly: " .. seed.rule, function(t)
		local _, root = screen()
		seed.build(root)
		local report = audit(root, PHONE, seed.options)
		t.eq(Audit.paths(report, seed.rule), seed.paths, seed.rule .. " paths")
		t.eq(report.counts, { [seed.rule] = #seed.paths }, seed.rule .. " is the only rule that fires")
		t.eq(report.findings[1].severity, seed.severity)
		t.eq(report.ok, seed.severity ~= "error")
	end)
end

test("text_fit is an error when the engine says TextFits is false", function(t)
	local _, root = screen()
	text("TextLabel", "Clipped", root, 0, 0, 200, 30)
	local nodes = Audit.fromInstances(root, {
		measure = Audit.staticMeasure(PHONE.viewport, PHONE.safe),
		textFits = function(instance: any): boolean?
			return instance.Name ~= "Clipped"
		end,
	})
	local report = Audit.run(nodes, { device = "phone", safe = PHONE.safe })
	t.eq(Audit.paths(report, "text_fit"), { "Root.Clipped" })
	t.eq(report.findings[1].severity, "error")
end)

test("rules, touch and shadow options are honoured", function(t)
	local _, root = screen()
	text("TextButton", "Tiny", root, 0, 0, 30, 30)
	text("TextLabel", "Small", root, 0, 40, 200, 30).TextSize = 8
	local only = audit(root, PHONE, { rules = { "text_size" } })
	t.eq(only.counts, { text_size = 1 })
	t.eq(audit(root, DESKTOP).counts, { text_size = 1 }, "no touch targets without touch")
	t.eq(audit(root, DESKTOP, { touch = true }).counts.touch_target, 1)
	local shadows = Audit.run({}, { shadows = 101 })
	t.eq(Audit.paths(shadows, "shadow_budget"), { "<root>" })
	t.eq(Audit.run({}, { shadows = 100 }).findings, {})
end)

test("disabled text is exempt from contrast and explicit links make nodes reachable", function(t)
	local _, root = screen()
	local off = text("TextButton", "Off", root, 0, 0, 160, 48)
	off.TextColor3 = roblox.Color3.fromRGB(60, 60, 60)
	off.Interactable = false
	t.eq(audit(root, PHONE).counts, {}, "disabled text exempt")
	local _, root2 = screen()
	local dialog = roblox.Instance.new("Frame")
	dialog.Name = "Dialog"
	dialog.BackgroundTransparency = 1
	dialog.Size = roblox.UDim2.fromOffset(400, 100)
	dialog.SelectionGroup = true
	local stop = roblox.Enum.SelectionBehavior.Stop
	dialog.SelectionBehaviorDown = stop
	dialog.SelectionBehaviorUp = stop
	dialog.SelectionBehaviorLeft = stop
	dialog.SelectionBehaviorRight = stop
	dialog.Parent = root2
	local yes = text("TextButton", "Yes", dialog, 0, 0, 120, 48)
	local behind = text("TextButton", "Behind", root2, 0, 200, 120, 48)
	yes.NextSelectionDown = behind
	t.eq(audit(root2, PHONE, { entry = "Root.Dialog.Yes" }).counts, {}, "an explicit link escapes the group")
end)

test("text that is not drawn is exempt from contrast; half-faded text is blended and checked", function(t)
	local _, root = screen()
	local hidden = text("TextLabel", "Hidden", root, 0, 0, 160, 48)
	hidden.TextTransparency = 1
	t.eq(audit(root, PHONE).counts, {}, "TextTransparency 1: nothing drawn, nothing to check")
	local faded = text("TextLabel", "Faded", root, 0, 60, 160, 48)
	faded.TextTransparency = 0.8
	local report = audit(root, PHONE)
	t.eq(report.counts, { contrast = 1 }, "0.8 transparent light text on dark is too faint")
	t.eq(report.findings[1].path, "Root.Faded")
end)

test("snapshots validate and duplicate sibling names get unique paths", function(t)
	t.eq(Audit.validateSnapshot(nil), { "snapshot must be a list of nodes" })
	local problems = Audit.validateSnapshot({
		{ path = "A", class = "Frame" },
		{ path = "A", class = "Frame" },
		{ path = "B" },
		{ path = "C", class = "Frame", rect = { x = 0, y = 0, w = 0 / 0, h = 1 } },
		{ class = "Frame" },
	})
	t.eq(problems, {
		"nodes[2]: duplicate path A",
		"B: needs a class",
		"C: rect needs finite x, y, w, h",
		"nodes[5]: needs a path",
	})
	t.throws(function()
		Audit.run({ { path = "A", class = "Frame" }, { path = "A", class = "Frame" } })
	end)
	local _, root = screen()
	local first = text("TextButton", "Button", root, 0, 0, 120, 48)
	local second = text("TextButton", "Button", root, 0, 60, 120, 48)
	local third = text("TextButton", "Button", root, 0, 120, 120, 48)
	third.LayoutOrder = -1
	t.eq(Audit.pathOf(root, third), "Root.Button", "LayoutOrder first")
	t.eq(Audit.pathOf(root, first), "Root.Button#2")
	t.eq(Audit.pathOf(root, second), "Root.Button#3")
	local paths = {}
	for _, node in Audit.fromInstances(root, { measure = Audit.staticMeasure(PHONE.viewport, PHONE.safe) }) do
		table.insert(paths, node.path)
	end
	t.eq(paths, { "Root", "Root.Button", "Root.Button#2", "Root.Button#3" })
	t.throws(function()
		Audit.fromInstances(root, {} :: any)
	end)
end)

test("staticMeasure folds scale, offset, anchor, padding and ScreenGui insets", function(t)
	local gui, root = screen()
	local padding = roblox.Instance.new("UIPadding")
	padding.PaddingLeft = roblox.UDim.new(0, 10)
	padding.PaddingTop = roblox.UDim.new(0, 20)
	padding.Parent = root
	local child = roblox.Instance.new("Frame")
	child.AnchorPoint = roblox.Vector2.new(0.5, 0.5)
	child.Position = roblox.UDim2.new(0.5, 0, 0.5, 0)
	child.Size = roblox.UDim2.new(0, 100, 0.5, 0)
	child.Parent = root
	local measure = Audit.staticMeasure(PHONE.viewport, PHONE.safe)
	t.eq(measure(root), { x = 47, y = 0, w = 750, h = 369 }, "inside the safe area")
	local inner = measure(child) :: any
	t.near(inner.w, 100)
	t.near(inner.h, (369 - 20) / 2)
	t.near(inner.x, 47 + 10 + (750 - 10) / 2 - 50)
	gui.ScreenInsets = roblox.Enum.ScreenInsets.None
	local full = Audit.staticMeasure(PHONE.viewport, PHONE.safe)
	t.eq(full(root), { x = 0, y = 0, w = 844, h = 390 }, "full-bleed ScreenGui ignores insets")
end)

test("AuditRoblox audits a live tree in Lune with injected measure, class and TextFits", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local _, root = screen()
	local label = text("TextLabel", "Caption", root, 0, 0, 72, 22)
	label.Text = "Settings"
	text("TextButton", "Tiny", root, 0, 40, 30, 30).Text = "" -- an icon-only hit area
	local seenTexts = {}
	local report
	env.spawn(function()
		report = AuditRoblox.audit(root, env, {
			class = PHONE,
			measure = Audit.staticMeasure(PHONE.viewport, PHONE.safe),
			textFits = function(instance: any): boolean?
				table.insert(seenTexts, instance.Text)
				return Localize.estimateWidth(instance.Text, instance.TextSize) <= instance.Size.X.Offset
			end,
		})
	end)
	for _ = 1, 4 do
		env:advance(1 / 60)
	end
	t.ok(report ~= nil, "audit finished")
	t.eq(Audit.paths(report, "touch_target"), { "Root.Tiny" })
	t.eq(Audit.paths(report, "text_fit"), { "Root.Caption" }, "overflow found by the pseudo pass")
	t.eq(label.Text, "Settings", "pseudo text restored")
	t.ok(table.find(seenTexts, Localize.pseudo("Settings")) ~= nil, "TextFits read while pseudo text showed")
	t.eq(report.ok, false)
	local quiet
	env.spawn(function()
		quiet = AuditRoblox.audit(root, env, {
			class = PHONE,
			measure = Audit.staticMeasure(PHONE.viewport, PHONE.safe),
			textFits = function()
				return true
			end,
			pseudo = false,
			rules = { "text_fit" },
		})
	end)
	env:advance(1 / 60)
	t.eq(quiet.findings, {}, "pseudo = false skips the pass")
end)

test("every gallery story passes the layout-free rules on phone and desktop", function(t)
	local layoutFree = { "contrast", "text_size", "legacy_font", "text_scaled", "canvas_group_size" }
	for _, class in { PHONE, DESKTOP } do
		local hub = FakeUIEvents.new()
		local measure = Audit.staticMeasure(class.viewport, class.safe)
		local ctx = Build.context({
			env = FakeEnv.new({ roblox = roblox }),
			class = class,
			on = hub.on,
			onChanged = hub.onChanged,
			measure = measure,
		})
		for _, story in Stories.list(ctx) do
			local gui = roblox.Instance.new("ScreenGui")
			local frame = roblox.Instance.new("Frame")
			frame.Name = story.name
			frame.BackgroundTransparency = 1
			frame.Size = roblox.UDim2.fromScale(1, 1)
			frame.Parent = gui
			local cleanup = story.build(frame)
			for _ = 1, 30 do
				ctx.runner:step(1 / 30)
			end
			local report = Audit.run(Audit.fromInstances(frame, { measure = measure }), {
				device = class.device,
				touch = class.touch,
				rules = layoutFree,
			})
			t.eq(report.counts, {}, class.device .. " " .. story.name)
			cleanup()
			t.eq(#frame:GetChildren(), 0, story.name .. " cleanup leaves nothing")
		end
		t.eq(hub:count(), 0, "no connections left")
		t.eq(ctx.runner:count(), 0, "no tracks left")
	end
end)

return cases
