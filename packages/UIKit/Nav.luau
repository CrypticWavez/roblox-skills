--!strict
-- @tier T1
-- probe: ui_nav_keyboard
-- Nav: the screen stack (docs/uikit.md "Navigation"). push, pop, replace and modal; back()
-- answers the reserved ui.back action (GameKit/InputMap): a dismissable modal closes, a screen
-- with onBack decides, a deeper screen pops, the root screen is left to the game. Focus
-- restore: the selection when a screen is covered is saved and restored when it is uncovered
-- (the NativeUI pattern), falling back to the screen's focus target for gamepads. Roots become
-- SelectionGroups; modals also stop selection at their edges (SelectionBehavior* = Stop) so a
-- gamepad cannot wander behind them. Selection and preferred input arrive as functions
-- (GuiService.SelectedObject and UserInputService.PreferredInput in the adapter wiring), so the
-- stack logic runs in Lune with real @lune/roblox Instances. Engine selection behaviour
-- (GuiService:Select, SelectionBehavior) is proven only by probe ui_nav_keyboard.
local Check = require("../GameKit/Check")
local Signal = require("../GameKit/Signal")
local Transitions = require("./Transitions")

local Nav = {}

export type Screen = {
	id: string,
	root: any,
	focus: any?,
	dismissable: boolean?,
	onEnter: ((nav: any) -> ())?,
	onExit: ((nav: any) -> ())?,
	onBack: ((nav: any) -> boolean)?,
	transitions: { enter: Transitions.Plan?, exit: Transitions.Plan?, bindings: { [string]: any }? }?,
}
export type Selection = { get: () -> any, set: (target: any) -> () }
export type Options = {
	selection: Selection,
	preferredInput: (() -> string)?,
	runner: Transitions.Runner?,
	motion: { reducedMotion: boolean? }?,
	maxDepth: number?,
}

type Entry = { screen: Screen, modal: boolean, restore: any, generation: number }

local function isInstance(value: any): boolean
	return typeof(value) == "Instance"
end

local function alive(target: any): boolean
	if target == nil then
		return false
	end
	if isInstance(target) then
		return target.Parent ~= nil
	end
	return true
end

local function setShown(root: any, shown: boolean)
	if isInstance(root) and root:IsA("LayerCollector") then
		root.Enabled = shown
	else
		root.Visible = shown
	end
end

local function contains(root: any, target: any): boolean
	if target == nil then
		return false
	end
	if target == root then
		return true
	end
	if isInstance(root) and isInstance(target) then
		return target:IsDescendantOf(root)
	end
	return false
end

-- The first Selectable, visible GuiObject under root in LayoutOrder then name order.
function Nav.firstSelectable(root: any): any
	if not isInstance(root) then
		return nil
	end
	local best, bestOrder, bestName = nil, math.huge, ""
	for _, item in root:GetDescendants() do
		if item:IsA("GuiObject") and item.Selectable and item.Visible then
			local order = item.LayoutOrder
			if best == nil or order < bestOrder or (order == bestOrder and item:GetFullName() < bestName) then
				best, bestOrder, bestName = item, order, item:GetFullName()
			end
		end
	end
	return best
end

-- Problems with a screen table (empty when valid).
function Nav.validateScreen(screen: any): { string }
	if type(screen) ~= "table" then
		return { "screen must be a table" }
	end
	local problems = {}
	if not Check.label(screen.id) then
		table.insert(problems, "screen.id must be a lower_snake label")
	end
	if screen.root == nil then
		table.insert(problems, "screen.root is required")
	end
	for _, hook in { "onEnter", "onExit", "onBack" } do
		if screen[hook] ~= nil and type(screen[hook]) ~= "function" then
			table.insert(problems, "screen." .. hook .. " must be a function")
		end
	end
	if screen.dismissable ~= nil and type(screen.dismissable) ~= "boolean" then
		table.insert(problems, "screen.dismissable must be a boolean")
	end
	return problems
end

export type Nav = {
	push: (self: Nav, screen: Screen) -> (boolean, string?),
	modal: (self: Nav, screen: Screen) -> (boolean, string?),
	replace: (self: Nav, screen: Screen) -> (boolean, string?),
	pop: (self: Nav) -> (boolean, string?),
	back: (self: Nav) -> boolean,
	handleAction: (self: Nav, action: string, pressed: boolean?) -> boolean,
	inputChanged: (self: Nav, input: string) -> (),
	top: (self: Nav) -> Screen?,
	ids: (self: Nav) -> { string },
	depth: (self: Nav) -> number,
	destroy: (self: Nav) -> (),
	changed: any,
}

-- A navigator. env (optional) supplies roblox (Enum, for SelectionBehavior), report and
-- defer for the changed Signal.
function Nav.new(options: Options, env: any?): Nav
	if type(options) ~= "table" or type(options.selection) ~= "table" then
		error("Nav.new: needs { selection = { get, set } }", 2)
	end
	local selection = options.selection
	assert(
		type(selection.get) == "function" and type(selection.set) == "function",
		"Nav.new: selection needs get and set"
	)
	local preferredInput = options.preferredInput or function(): string
		return "KeyboardAndMouse"
	end
	local maxDepth = options.maxDepth or 16
	local stack: { Entry } = {}
	local generation = 0
	local destroyed = false
	local nav: any = { changed = Signal.new(env) }
	local roblox = env and env.roblox

	local function configure(root: any, modal: boolean)
		if not isInstance(root) or not root:IsA("GuiObject") then
			return
		end
		root.SelectionGroup = true
		if modal and roblox then
			local stop = roblox.Enum.SelectionBehavior.Stop
			root.SelectionBehaviorUp = stop
			root.SelectionBehaviorDown = stop
			root.SelectionBehaviorLeft = stop
			root.SelectionBehaviorRight = stop
		end
	end

	local function play(entry: Entry, which: string, onDone: ((state: string) -> ())?)
		local runner = options.runner
		local set = entry.screen.transitions
		local plan = set and (set :: any)[which]
		if runner == nil or plan == nil then
			if onDone then
				onDone("completed")
			end
			return
		end
		if options.motion and options.motion.reducedMotion then
			plan = Transitions.reduce(plan)
		end
		runner:play(plan, (set :: any).bindings or { root = entry.screen.root }, { onComplete = onDone })
	end

	local function focusEntry(entry: Entry)
		if preferredInput() ~= "Gamepad" then
			return
		end
		local target = entry.screen.focus
		if not alive(target) then
			target = Nav.firstSelectable(entry.screen.root)
		end
		if target ~= nil then
			selection.set(target)
		end
	end

	local function enter(entry: Entry)
		configure(entry.screen.root, entry.modal)
		setShown(entry.screen.root, true)
		play(entry, "enter", nil)
		if entry.screen.onEnter then
			entry.screen.onEnter(nav)
		end
		focusEntry(entry)
	end

	local function leave(entry: Entry, hide: boolean)
		if entry.screen.onExit then
			entry.screen.onExit(nav)
		end
		local mark = entry.generation
		play(entry, "exit", function(state: string)
			-- Hide only if the exit finished and the screen was not shown again meanwhile.
			if hide and state == "completed" and entry.generation == mark then
				setShown(entry.screen.root, false)
			end
		end)
		if hide and options.runner == nil then
			setShown(entry.screen.root, false)
		end
		local current = selection.get()
		if contains(entry.screen.root, current) then
			selection.set(nil)
		end
	end

	local function add(screen: Screen, modal: boolean): (boolean, string?)
		if destroyed then
			return false, "destroyed"
		end
		local problems = Nav.validateScreen(screen)
		if #problems > 0 then
			error("Nav: " .. table.concat(problems, "; "), 3)
		end
		if #stack >= maxDepth then
			return false, "too_deep"
		end
		for _, entry in stack do
			if entry.screen.id == screen.id then
				return false, "duplicate"
			end
		end
		local top = stack[#stack]
		if top and top.modal and not modal then
			return false, "modal_open"
		end
		if top then
			top.restore = selection.get()
			if not modal then
				leave(top, true)
			end
		end
		generation += 1
		local entry: Entry = { screen = screen, modal = modal, restore = nil, generation = generation }
		table.insert(stack, entry)
		enter(entry)
		nav.changed:Fire(if modal then "modal" else "push", screen.id)
		return true, nil
	end

	function nav.push(_self: any, screen: Screen): (boolean, string?)
		return add(screen, false)
	end

	function nav.modal(_self: any, screen: Screen): (boolean, string?)
		local s: any = table.clone(screen)
		if s.dismissable == nil then
			s.dismissable = true
		end
		return add(s, true)
	end

	local function removeTop(restore: boolean): Entry?
		local entry = table.remove(stack)
		if entry == nil then
			return nil
		end
		leave(entry, true)
		local below = stack[#stack]
		if below then
			if not entry.modal then
				generation += 1
				below.generation = generation
				setShown(below.screen.root, true)
				play(below, "enter", nil)
			end
			if restore then
				if alive(below.restore) then
					selection.set(below.restore)
				else
					focusEntry(below)
				end
				below.restore = nil
			end
		end
		return entry
	end

	function nav.pop(_self: any): (boolean, string?)
		if destroyed then
			return false, "destroyed"
		end
		local entry = removeTop(true)
		if entry == nil then
			return false, "empty"
		end
		nav.changed:Fire("pop", entry.screen.id)
		return true, nil
	end

	function nav.replace(_self: any, screen: Screen): (boolean, string?)
		if destroyed then
			return false, "destroyed"
		end
		local problems = Nav.validateScreen(screen)
		if #problems > 0 then
			error("Nav: " .. table.concat(problems, "; "), 2)
		end
		local top = stack[#stack]
		if top == nil then
			return add(screen, false)
		end
		for index = 1, #stack - 1 do
			if stack[index].screen.id == screen.id then
				return false, "duplicate"
			end
		end
		table.remove(stack)
		leave(top, true)
		generation += 1
		local entry: Entry = { screen = screen, modal = top.modal, restore = nil, generation = generation }
		table.insert(stack, entry)
		enter(entry)
		nav.changed:Fire("replace", screen.id)
		return true, nil
	end

	function nav.back(self: any): boolean
		if destroyed then
			return false
		end
		local top = stack[#stack]
		if top == nil then
			return false
		end
		if top.screen.onBack then
			local ok, handled = pcall(top.screen.onBack :: any, nav)
			if ok and handled == true then
				return true
			end
		end
		if top.modal then
			if top.screen.dismissable ~= false then
				self:pop()
			end
			-- A modal always consumes back, so it never reaches the screen behind it.
			return true
		end
		if #stack > 1 then
			self:pop()
			return true
		end
		return false
	end

	function nav.handleAction(self: any, action: string, pressed: boolean?): boolean
		if action == "ui.back" and pressed ~= false then
			return self:back()
		end
		return false
	end

	-- Call when PreferredInput changes: switching to a gamepad selects the top screen's focus.
	function nav.inputChanged(_self: any, input: string)
		local top = stack[#stack]
		if top == nil then
			return
		end
		if input == "Gamepad" then
			if not contains(top.screen.root, selection.get()) then
				focusEntry(top)
			end
		end
	end

	function nav.top(_self: any): Screen?
		local top = stack[#stack]
		return top and top.screen
	end

	function nav.ids(_self: any): { string }
		local out = {}
		for _, entry in stack do
			table.insert(out, entry.screen.id)
		end
		return out
	end

	function nav.depth(_self: any): number
		return #stack
	end

	function nav.destroy(_self: any)
		if destroyed then
			return
		end
		destroyed = true
		table.clear(stack)
		nav.changed:Destroy()
	end

	return nav
end

-- Selection functions over a GuiService (or a fake with SelectedObject).
function Nav.guiSelection(guiService: any): Selection
	return {
		get = function(): any
			return guiService.SelectedObject
		end,
		set = function(target: any)
			guiService.SelectedObject = target
		end,
	}
end

return Nav
