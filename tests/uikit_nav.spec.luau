--!strict
-- G4 specs: UIKit/Nav, the screen stack. Focus restore when a covered screen comes back, modal
-- back handling (dismissable or not, onBack first, a modal always consumes back), gamepad focus
-- on push and on input change, SelectionGroup and edge stops, refusals (duplicate, modal_open,
-- too_deep, invalid screens) and exit transitions that hide only when they finish. Uses real
-- @lune/roblox Instances and a plain selection table; the engine selection itself is probe
-- ui_nav_keyboard.
local roblox = require("@lune/roblox")

local Build = require("../packages/UIKit/Build")
local Modal = require("../packages/UIKit/Components/Modal")
local Nav = require("../packages/UIKit/Nav")
local Transitions = require("../packages/UIKit/Transitions")
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

-- A screen root Frame with count selectable buttons (LayoutOrder 1..count), parented under gui.
local function screen(gui: any, name: string, count: number): (any, { any })
	local root = roblox.Instance.new("Frame")
	root.Name = name
	root.Visible = false
	root.Parent = gui
	local buttons = {}
	for index = 1, count do
		local button = roblox.Instance.new("TextButton")
		button.Name = name .. "_" .. index
		button.LayoutOrder = index
		button.Selectable = true
		button.Parent = root
		table.insert(buttons, button)
	end
	return root, buttons
end

-- A navigator over a plain selection holder; input is switchable.
local function fixture(options: { [string]: any }?): any
	local holder = { SelectedObject = nil :: any, input = "Gamepad" }
	local env = FakeEnv.new({ roblox = roblox })
	local opts: any = {
		selection = Nav.guiSelection(holder),
		preferredInput = function(): string
			return holder.input
		end,
	}
	for key, value in options or {} do
		opts[key] = value
	end
	local nav = Nav.new(opts, env)
	local gui = roblox.Instance.new("ScreenGui")
	return { nav = nav, holder = holder, gui = gui, env = env }
end

test("push focuses the first selectable for gamepads and back restores the covered focus", function(t)
	local f = fixture()
	local rootA, a = screen(f.gui, "A", 3)
	local rootB, b = screen(f.gui, "B", 2)
	t.eq({ f.nav:push({ id = "screen_a", root = rootA }) }, { true })
	t.ok(rootA.Visible and rootA.SelectionGroup, "shown and grouped")
	t.eq(f.holder.SelectedObject, a[1], "gamepad focus on push")
	f.holder.SelectedObject = a[3] -- the player moved
	f.nav:push({ id = "screen_b", root = rootB })
	t.ok(not rootA.Visible, "the covered screen hides (no runner: at once)")
	t.eq(f.holder.SelectedObject, b[1])
	t.eq(f.nav:ids(), { "screen_a", "screen_b" })
	t.eq(f.nav:back(), true)
	t.ok(rootA.Visible and not rootB.Visible)
	t.eq(f.holder.SelectedObject, a[3], "focus restored to where the player left it")
	t.eq(f.nav:back(), false, "the root screen is left to the game")
	t.eq(f.nav:depth(), 1)
end)

test("an explicit focus target wins, and keyboard users get no forced selection", function(t)
	local f = fixture()
	local rootA, a = screen(f.gui, "A", 3)
	f.nav:push({ id = "screen_a", root = rootA, focus = a[2] })
	t.eq(f.holder.SelectedObject, a[2])
	local g = fixture()
	g.holder.input = "KeyboardAndMouse"
	local rootK = screen(g.gui, "K", 2)
	g.nav:push({ id = "keyboard", root = rootK })
	t.eq(g.holder.SelectedObject, nil, "no selection ring for mouse and keyboard")
	g.holder.input = "Gamepad"
	g.nav:inputChanged("Gamepad")
	t.ok(
		g.holder.SelectedObject ~= nil and g.holder.SelectedObject:IsDescendantOf(rootK),
		"picked up on switch"
	)
end)

test("a destroyed restore target falls back to the screen's first selectable", function(t)
	local f = fixture()
	local rootA, a = screen(f.gui, "A", 3)
	local rootB = screen(f.gui, "B", 1)
	f.nav:push({ id = "screen_a", root = rootA })
	f.holder.SelectedObject = a[3]
	f.nav:push({ id = "screen_b", root = rootB })
	a[3]:Destroy()
	f.nav:pop()
	t.eq(f.holder.SelectedObject, a[1])
end)

test("modals group and stop selection, consume back and restore focus behind them", function(t)
	local f = fixture()
	local rootA, a = screen(f.gui, "A", 2)
	local rootM, m = screen(f.gui, "M", 2)
	f.nav:push({ id = "screen_a", root = rootA })
	f.holder.SelectedObject = a[2]
	f.nav:modal({ id = "confirm", root = rootM })
	t.ok(rootA.Visible, "a modal does not hide the screen behind it")
	t.eq(f.holder.SelectedObject, m[1])
	local stop = roblox.Enum.SelectionBehavior.Stop
	t.ok(rootM.SelectionGroup)
	t.eq({
		rootM.SelectionBehaviorUp,
		rootM.SelectionBehaviorDown,
		rootM.SelectionBehaviorLeft,
		rootM.SelectionBehaviorRight,
	}, { stop, stop, stop, stop })
	t.eq({ f.nav:push({ id = "other", root = screen(f.gui, "O", 1) }) }, { false, "modal_open" })
	t.eq(f.nav:handleAction("ui.back"), true)
	t.eq(f.nav:depth(), 1)
	t.ok(not rootM.Visible)
	t.eq(f.holder.SelectedObject, a[2], "focus back where it was")
	t.eq(f.nav:handleAction("ui.back", false), false, "a release is not a back press")
	t.eq(f.nav:handleAction("ui.confirm"), false)
end)

test("a non-dismissable modal swallows back and stays; onBack can handle back first", function(t)
	local f = fixture()
	local rootA = screen(f.gui, "A", 1)
	local rootM = screen(f.gui, "M", 1)
	f.nav:push({ id = "screen_a", root = rootA })
	f.nav:modal({ id = "must_answer", root = rootM, dismissable = false })
	t.eq(f.nav:back(), true, "consumed")
	t.eq(f.nav:ids(), { "screen_a", "must_answer" }, "still open")
	f.nav:pop()
	local asked = 0
	local rootB = screen(f.gui, "B", 1)
	f.nav:push({
		id = "screen_b",
		root = rootB,
		onBack = function(): boolean
			asked += 1
			return asked == 1 -- handles the first back itself, lets the second through
		end,
	})
	t.eq(f.nav:back(), true)
	t.eq(f.nav:depth(), 2)
	t.eq(f.nav:back(), true)
	t.eq(f.nav:depth(), 1)
	t.eq(asked, 2)
end)

test("refusals: duplicate ids, too deep, invalid screens and use after destroy", function(t)
	local f = fixture({ maxDepth = 2 })
	local rootA = screen(f.gui, "A", 1)
	f.nav:push({ id = "screen_a", root = rootA })
	t.eq({ f.nav:push({ id = "screen_a", root = screen(f.gui, "A2", 1) }) }, { false, "duplicate" })
	f.nav:push({ id = "screen_b", root = screen(f.gui, "B", 1) })
	t.eq({ f.nav:push({ id = "screen_c", root = screen(f.gui, "C", 1) }) }, { false, "too_deep" })
	t.ok(string.find(
		errorText(function()
			f.nav:push({ id = "Bad Id", root = rootA })
		end),
		"screen.id must be a lower_snake label",
		1,
		true
	))
	t.ok(string.find(
		errorText(function()
			f.nav:push({ id = "no_root" } :: any)
		end),
		"screen.root is required",
		1,
		true
	))
	t.ok(string.find(
		errorText(function()
			f.nav:push({ id = "hooks", root = rootA, onBack = 3 } :: any)
		end),
		"screen.onBack must be a function",
		1,
		true
	))
	t.eq(Nav.validateScreen(nil), { "screen must be a table" })
	t.throws(function()
		Nav.new({} :: any)
	end)
	f.nav:destroy()
	t.eq({ f.nav:push({ id = "late", root = rootA }) }, { false, "destroyed" })
	t.eq(f.nav:back(), false)
end)

test("replace swaps the top screen without growing the stack", function(t)
	local f = fixture()
	local rootA = screen(f.gui, "A", 1)
	local rootB, b = screen(f.gui, "B", 1)
	f.nav:push({ id = "screen_a", root = rootA })
	t.eq({ f.nav:replace({ id = "screen_b", root = rootB }) }, { true })
	t.eq(f.nav:ids(), { "screen_b" })
	t.ok(rootB.Visible and not rootA.Visible)
	t.eq(f.holder.SelectedObject, b[1])
	local events = {}
	f.nav.changed:Connect(function(kind, id)
		table.insert(events, kind .. ":" .. id)
	end)
	f.nav:replace({ id = "screen_a", root = rootA })
	t.eq(events, { "replace:screen_a" })
end)

test("exit transitions hide a screen only when they finish and it was not reshown", function(t)
	local runner =
		Transitions.runner(Transitions.instanceApply({ roblox = roblox }), Transitions.instanceRead())
	local f = fixture({ runner = runner })
	local rootA = screen(f.gui, "A", 1)
	local rootB = screen(f.gui, "B", 1)
	local group = roblox.Instance.new("CanvasGroup")
	group.Parent = f.gui
	local transitions = {
		enter = Transitions.fade({ duration = 0.2 }),
		exit = Transitions.fade({ phase = "out", duration = 0.2 }),
		bindings = { root = group },
	}
	f.nav:push({ id = "screen_a", root = rootA, transitions = transitions })
	f.nav:push({ id = "screen_b", root = rootB })
	t.ok(rootA.Visible, "still visible while its exit plays")
	runner:step(0.1)
	f.nav:pop() -- reshown mid-exit
	runner:step(0.5)
	t.ok(rootA.Visible, "the interrupted exit does not hide the reshown screen")
	f.nav:push({ id = "screen_b", root = rootB })
	runner:step(0.5)
	t.ok(not rootA.Visible, "a finished exit hides")
	t.eq(group.GroupTransparency, 1)
end)

test("reduced motion shortens screen transitions to fades", function(t)
	local runner =
		Transitions.runner(Transitions.instanceApply({ roblox = roblox }), Transitions.instanceRead())
	local f = fixture({ runner = runner, motion = { reducedMotion = true } })
	local rootA = screen(f.gui, "A", 1)
	local frame = roblox.Instance.new("Frame")
	f.nav:push({
		id = "screen_a",
		root = rootA,
		transitions = {
			enter = Transitions.slide({ duration = 0.6, base = { 0, 0, 0, 0 }, fadeNode = "fade" } :: any),
			bindings = { root = frame, fade = roblox.Instance.new("CanvasGroup") },
		},
	})
	t.eq(frame.Position, roblox.UDim2.new(0, 0, 0, 0), "position jumped to rest")
	runner:step(0.15)
	t.eq(runner:count(), 0, "done after the reduced fade")
end)

test("a Modal component's screen plugs into Nav: back dismisses it with its own motion", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local hub = FakeUIEvents.new()
	local ctx = Build.context({ env = env, on = hub.on, onChanged = hub.onChanged })
	local reasons = {}
	local modal = Modal.mount({
		textKey = "uikit.confirm",
		onDismiss = function(reason)
			table.insert(reasons, reason)
		end,
	}, ctx)
	local f = fixture({ runner = ctx.runner })
	local rootA = screen(f.gui, "A", 1)
	f.nav:push({ id = "screen_a", root = rootA })
	f.nav:modal(modal.state.screen("dialog"))
	t.ok(modal.root.Visible)
	t.eq(f.nav:back(), true)
	t.eq(reasons, { "back" })
	for _ = 1, 30 do
		ctx.runner:step(1 / 30)
	end
	t.ok(not modal.root.Visible, "hidden once its exit finished")
	modal:destroy()
	t.eq(hub:count(), 0)
end)

return cases
