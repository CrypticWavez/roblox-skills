--!strict
-- G4 specs: GameKit/InputMap (inputmap/1) and GameKit/InputMapRoblox. Every default action has a
-- binding for every device; the reserved actions (ui.back, ui.confirm, cinematic.skip) can never
-- be unbound or rebound away (unbind refuses, applyOverrides keeps their defaults, and a seeded
-- run of random edits never leaves one unbound); validate rejects each malformed field with its
-- message; Roblox client keys are refused; same-context conflicts are refused unless swapped;
-- overrides survive a JSON round trip; glyph text per device and style; every KEYS entry is a
-- real Enum.KeyCode. InputMapRoblox.build runs here on @lune/roblox IAS instances (contexts,
-- priorities, bindings, UIButton binding, bindButton, setEnabled, destroy); input firing through
-- them is probe inputmap_contexts.
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Check = require("../packages/GameKit/Check")
local FakeEnv = require("./fakes/FakeEnv")
local InputMap = require("../packages/GameKit/InputMap")
local InputMapRoblox = require("../packages/GameKit/InputMapRoblox")
local Json = require("../packages/GameKit/Json")
local Rng = require("../packages/ProcGen/Rng")

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

-- A mutable copy of the defaults, patched.
local function patched(patch: (any) -> ()): any
	local map = Check.copy(InputMap.defaults())
	patch(map)
	return map
end

local function reservedBound(map: any): (boolean, string?)
	for _, name in InputMap.RESERVED do
		for _, device in InputMap.DEVICES do
			local list = map.actions[name].bindings[device]
			if list == nil or #list == 0 then
				return false, name .. " / " .. device
			end
		end
	end
	return true, nil
end

-- ---------------------------------------------------------------- defaults

test("defaults: valid, every action bound on every device, reserved actions flagged", function(t)
	local map = InputMap.defaults()
	t.eq(InputMap.validate(map), {}, "defaults validate clean")
	local count = 0
	for name, item in map.actions do
		count += 1
		for _, device in InputMap.DEVICES do
			local list = item.bindings[device]
			t.ok(list ~= nil and #list > 0, name .. " has a " .. device .. " binding")
		end
		t.eq(item.reserved, table.find(InputMap.RESERVED, name) ~= nil, name .. " reserved flag")
		t.eq(item.labelKey, "input." .. name)
		t.ok(map.contexts[item.context] ~= nil, name .. " context exists")
	end
	t.eq(count, 15)
	for _, name in InputMap.RESERVED do
		t.ok(map.actions[name] ~= nil, name .. " is in the defaults")
	end
	t.eq(map.contexts.cinematic.enabled, false, "the cinematic context waits for a cutscene")
	t.eq(map.contexts.cinematic.sink, true)
	t.ok(map.contexts.cinematic.priority > map.contexts.ui.priority)
	t.ok(map.contexts.ui.priority > map.contexts.gameplay.priority)
	-- No default uses a key the Roblox client takes.
	for name, item in map.actions do
		for device, list in item.bindings do
			for _, binding in list do
				if type(binding) == "string" then
					t.ok(InputMap.SYSTEM_KEYS[binding] == nil, name .. " " .. device .. " " .. binding)
				end
			end
		end
	end
	-- Cross-context overlaps are notes, not errors (the higher-priority context wins).
	local overlaps = InputMap.overlaps(map)
	t.ok(contains(overlaps, "Gamepad/ButtonR1: gameplay.action_2, ui.tab_next"), "R1 overlap noted")
	t.ok(not contains(overlaps, "cinematic.skip"), "the disabled cinematic context is not an overlap")
end)

test("every action must have a binding for every device (failure cases)", function(t)
	local map = patched(function(m)
		m.actions["gameplay.interact"].bindings.Touch = {}
		m.actions["ui.back"].bindings.Gamepad = nil
	end)
	local problems = InputMap.validate(map)
	t.ok(contains(problems, "action gameplay.interact: no Touch binding"), "missing Touch")
	t.ok(contains(problems, "action ui.back: no Gamepad binding"), "missing Gamepad")
	local relaxed = InputMap.validate(map, { allowUnbound = true })
	t.ok(not contains(relaxed, "gameplay.interact"), "allowUnbound accepts an unbound normal action")
	t.ok(contains(relaxed, "action ui.back: no Gamepad binding"), "but never an unbound reserved action")
	t.throws(function()
		InputMap.define(map)
	end, "define raises")
end)

test("KEYS and SYSTEM_KEYS are real Enum.KeyCode names", function(t)
	for _, key in InputMap.KEYS do
		local ok, value = pcall(function()
			return (roblox.Enum.KeyCode :: any)[key]
		end)
		t.ok(ok and value ~= nil, "Enum.KeyCode." .. key)
	end
	for key in InputMap.SYSTEM_KEYS do
		local ok, value = pcall(function()
			return (roblox.Enum.KeyCode :: any)[key]
		end)
		t.ok(ok and value ~= nil, "Enum.KeyCode." .. key)
	end
	for _, kind in InputMap.TYPES do
		t.ok((roblox.Enum.InputActionType :: any)[kind] ~= nil, "Enum.InputActionType." .. kind)
	end
end)

-- ---------------------------------------------------------------- validation

test("validate names each malformed field", function(t)
	t.eq(InputMap.validate(nil), { "map must be a table" })
	t.eq(InputMap.validate({ schema = "inputmap/1" }), { "map needs contexts and actions tables" })
	local rows: { { any } } = {
		{
			function(m)
				m.schema = "inputmap/0"
			end,
			"schema must be inputmap/1",
		},
		{
			function(m)
				m.contexts.ui.priority = 100
			end,
			"context ui: priority also used by gameplay",
		},
		{
			function(m)
				m.contexts.ui.priority = -1
			end,
			"context ui: priority must be an integer >= 0",
		},
		{
			function(m)
				m.contexts.ui.sink = "yes"
			end,
			"context ui: sink and enabled must be booleans",
		},
		{
			function(m)
				m.contexts.ui.name = "other"
			end,
			"context ui: needs a label name matching its key",
		},
		{
			function(m)
				m.actions["gameplay.jump"].name = "gameplay.hop"
			end,
			"action gameplay.jump: names are <context>.<label> and match their key",
		},
		{
			function(m)
				local item = m.actions["gameplay.jump"]
				m.actions["Jump"] = item
				item.name = "Jump"
			end,
			"action Jump: names are <context>.<label> and match their key",
		},
		{
			function(m)
				local item = Check.copy(m.actions["gameplay.jump"])
				item.name, item.context = "vehicle.horn", "vehicle"
				item.labelKey = "input.vehicle.horn"
				m.actions["vehicle.horn"] = item
			end,
			"action vehicle.horn: context vehicle is not defined",
		},
		{
			function(m)
				m.actions["gameplay.jump"].type = "Trigger"
			end,
			"action gameplay.jump: type must be Bool, Direction1D or Direction2D",
		},
		{
			function(m)
				m.actions["ui.back"].reserved = false
			end,
			"action ui.back: reserved must be true",
		},
		{
			function(m)
				m.actions["gameplay.jump"].reserved = true
			end,
			"action gameplay.jump: reserved must be false",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.VR = { "ButtonA" }
			end,
			"action gameplay.jump: unknown device VR",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.KeyboardAndMouse = { "Space", "Space" }
			end,
			"action gameplay.jump (KeyboardAndMouse): duplicate binding Space",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.KeyboardAndMouse = { "E" }
			end,
			"E already bound to",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.KeyboardAndMouse = { "Escape" }
			end,
			"action gameplay.jump (KeyboardAndMouse): Escape is used by the Roblox client (Roblox menu)",
		},
		{
			function(m)
				m.actions["ui.back"].bindings.Gamepad = { "ButtonStart" }
			end,
			"action ui.back (Gamepad): ButtonStart is used by the Roblox client (Roblox menu)",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.KeyboardAndMouse = { "ButtonY" }
			end,
			"action gameplay.jump (KeyboardAndMouse): ButtonY is a gamepad input",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.Gamepad = { "G" }
			end,
			"action gameplay.jump (Gamepad): G is not a gamepad input",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.KeyboardAndMouse = { "ui:jump_button" }
			end,
			"ui: (on-screen button) bindings belong to Touch",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.Touch = { "Space" }
			end,
			"action gameplay.jump (Touch): Touch bindings are ui:<key> or system:<key>",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.Touch = { "web:jump" }
			end,
			"binding prefix must be ui: or system:",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.Touch = { "ui:Jump Button" }
			end,
			"ui:Jump Button: the part after ui: must be a lower_snake label",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.KeyboardAndMouse = { "Banana" }
			end,
			"Banana is not a known KeyCode name",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.KeyboardAndMouse = { "Q+Space" }
			end,
			"Q is not a modifier key (Shift, Control, Alt)",
		},
		{
			function(m)
				m.actions["gameplay.move"].bindings.KeyboardAndMouse = { "W" }
			end,
			"Direction2D actions bind a thumbstick or directional keys",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.KeyboardAndMouse = { { up = "W", down = "S" } }
			end,
			"a Bool action takes a key, not directional keys",
		},
		{
			function(m)
				m.actions["gameplay.move"].bindings.KeyboardAndMouse =
					{ { up = "W", down = "S", left = "A" } }
			end,
			"directional binding needs a KeyCode name for right",
		},
		{
			function(m)
				m.actions["gameplay.move"].bindings.KeyboardAndMouse =
					{ { up = "W", down = "S", left = "A", right = "D", forward = "F" } }
			end,
			"directional binding key forward is not one of up, down, left, right",
		},
		{
			function(m)
				m.actions["gameplay.jump"].bindings.KeyboardAndMouse = { 42 }
			end,
			"a binding is a KeyCode name, a directional table, ui:<key> or system:<key>",
		},
	}
	for index, row in rows do
		local problems = InputMap.validate(patched(row[1]))
		local expected = row[2] :: string
		t.ok(
			contains(problems, expected),
			string.format("row %d: %s (got %s)", index, expected, table.concat(problems, " | "))
		)
	end
end)

test("define deep-freezes a copy; lookups raise on unknown actions", function(t)
	local source = Check.copy(InputMap.defaults())
	local map = InputMap.define(source)
	t.ok(table.isfrozen(map.actions["gameplay.jump"].bindings.KeyboardAndMouse), "deep-frozen")
	source.actions["gameplay.jump"].bindings.KeyboardAndMouse[1] = "J"
	t.eq(map.actions["gameplay.jump"].bindings.KeyboardAndMouse[1], "Space", "a copy, not the source")
	t.throws(function()
		InputMap.action(map, "gameplay.fly")
	end)
	local names = {}
	for _, item in InputMap.actionsIn(map, "ui") do
		table.insert(names, item.name)
	end
	t.eq(names, { "ui.back", "ui.confirm", "ui.navigate", "ui.tab_next", "ui.tab_prev" })
	t.eq(InputMap.bindings(map, "ui.back", "Gamepad"), { "ButtonB" })
end)

-- ---------------------------------------------------------------- reserved actions

test("reserved actions cannot be unbound or rebound away", function(t)
	local map = InputMap.defaults()
	for _, name in InputMap.RESERVED do
		for _, device in InputMap.DEVICES do
			local list = map.actions[name].bindings[device]
			local current = map
			for index = #list, 2, -1 do
				local nextMap, problems = InputMap.unbind(current, name, device, index)
				t.eq(problems, {}, "extra bindings may go")
				current = nextMap
			end
			local same, problems = InputMap.unbind(current, name, device, 1)
			t.eq(same, current, name .. " " .. device .. ": the last binding stays")
			t.eq(problems, { name .. " is reserved: it keeps at least one " .. device .. " binding" })
		end
	end
	-- A normal action may be left unbound.
	local freed, problems = InputMap.unbind(map, "gameplay.action_3", "Gamepad", 1)
	t.eq(problems, {})
	t.eq(#freed.actions["gameplay.action_3"].bindings.Gamepad, 0)
	t.eq(InputMap.unbind(map, "gameplay.nothing", "Gamepad", 1), map)
	local _, missing = InputMap.unbind(map, "gameplay.jump", "Gamepad", 5)
	t.eq(missing, { "no binding at that index" })
	-- Rebinding a reserved action to something invalid is refused and leaves it as it was.
	local kept, refused = InputMap.rebind(map, "ui.back", "KeyboardAndMouse", 1, "Escape")
	t.eq(kept, map)
	t.eq(refused, { "Escape is used by the Roblox client (Roblox menu)" })
	local _, wrongDevice = InputMap.rebind(map, "cinematic.skip", "Gamepad", 1, "Space")
	t.eq(wrongDevice, { "Space is not a gamepad input" })
	-- Overrides that would empty a reserved action keep its defaults.
	local applied, notes = InputMap.applyOverrides(map, {
		schema = InputMap.OVERRIDES_SCHEMA,
		actions = {
			["ui.confirm"] = { Gamepad = {} },
			["ui.back"] = { KeyboardAndMouse = { "Escape", "F9" } },
			["gameplay.jump"] = { Gamepad = {} },
		},
	})
	t.eq(applied.actions["ui.confirm"].bindings.Gamepad, { "ButtonA" })
	t.eq(applied.actions["ui.back"].bindings.KeyboardAndMouse, { "Backspace" })
	t.eq(#applied.actions["gameplay.jump"].bindings.Gamepad, 0, "a normal action may be emptied")
	t.ok(contains(notes, "ui.confirm (Gamepad): reserved action keeps its defaults"))
	t.ok(contains(notes, "ui.back (KeyboardAndMouse): Escape is used by the Roblox client"))
	t.ok(contains(notes, "ui.back (KeyboardAndMouse): reserved action keeps its defaults"))
end)

test("a seeded run of random edits never leaves a reserved action unbound", function(t)
	local rng = Rng.new("inputmap-reserved")
	local base = InputMap.defaults()
	local map = base
	local names = {}
	for name in base.actions do
		table.insert(names, name)
	end
	table.sort(names)
	local pool = {
		KeyboardAndMouse = { "Space", "E", "Q", "Backspace", "Return", "LeftShift+E", "Escape", "Z", "One" },
		Gamepad = { "ButtonA", "ButtonB", "ButtonX", "ButtonY", "ButtonL1", "ButtonR1", "ButtonStart" },
		Touch = { "ui:a_button", "ui:b_button", "system:jump_button", "Space" },
	}
	local refusals = 0
	for step = 1, 600 do
		local name = rng:pick(names)
		local device = rng:pick(InputMap.DEVICES :: { string })
		local roll = rng:int(1, 4)
		local problems
		if roll == 1 then
			local list = map.actions[name].bindings[device] or {}
			map, problems = InputMap.unbind(map, name, device, rng:int(1, math.max(#list, 1)))
		elseif roll == 2 or roll == 3 then
			local list = map.actions[name].bindings[device] or {}
			local index = if #list > 0 and rng:chance(0.7) then rng:int(1, #list) else nil
			map, problems = InputMap.rebind(map, name, device, index, rng:pick(pool[device]), {
				swap = rng:chance(0.5),
			})
		else
			-- Save and reload through overrides, sometimes with junk added.
			local data = InputMap.overrides(base, map)
			if rng:chance(0.3) then
				data.actions[name] = { [device] = {} }
			end
			map, problems = InputMap.applyOverrides(base, data)
		end
		if #problems > 0 then
			refusals += 1
		end
		local ok, where = reservedBound(map)
		t.ok(ok, string.format("step %d left %s unbound", step, tostring(where)))
		t.eq(InputMap.validate(map, { allowUnbound = true }), {}, "step " .. step .. " map stays valid")
	end
	t.ok(refusals > 0, "the run exercised refusals")
end)

-- ---------------------------------------------------------------- rebinding

test("rebind: same-context conflicts are refused unless swapped; other contexts may share", function(t)
	local map = InputMap.defaults()
	local same, problems = InputMap.rebind(map, "ui.tab_next", "KeyboardAndMouse", 1, "Backspace")
	t.eq(same, map, "refused: unchanged")
	t.eq(problems, { "Backspace is already bound to ui.back" })
	local swapped, none =
		InputMap.rebind(map, "ui.tab_next", "KeyboardAndMouse", 1, "Backspace", { swap = true })
	t.eq(none, {})
	t.eq(swapped.actions["ui.tab_next"].bindings.KeyboardAndMouse, { "Backspace" })
	t.eq(swapped.actions["ui.back"].bindings.KeyboardAndMouse, { "RightBracket" }, "ui.back took the old key")
	t.ok(table.isfrozen(swapped.actions), "the result is frozen")
	local _, appendSwap =
		InputMap.rebind(map, "ui.tab_next", "KeyboardAndMouse", nil, "Backspace", { swap = true })
	t.eq(appendSwap, { "Backspace is already bound to ui.back" }, "an append has no old key to swap")
	-- gameplay.jump may use Return although ui.confirm has it (another context).
	local shared, ok = InputMap.rebind(map, "gameplay.jump", "KeyboardAndMouse", nil, "Return")
	t.eq(ok, {})
	t.eq(shared.actions["gameplay.jump"].bindings.KeyboardAndMouse, { "Space", "Return" })
	t.ok(contains(InputMap.overlaps(shared), "KeyboardAndMouse/Return: gameplay.jump, ui.confirm"))
	local chord = InputMap.rebind(map, "gameplay.interact", "KeyboardAndMouse", 1, "LeftShift+E")
	t.eq(chord.actions["gameplay.interact"].bindings.KeyboardAndMouse, { "LeftShift+E" })
	local _, unknown = InputMap.rebind(map, "gameplay.fly", "Gamepad", 1, "ButtonA")
	t.eq(unknown, { "unknown action gameplay.fly" })
	local _, device = InputMap.rebind(map, "gameplay.jump", "Wheel", 1, "ButtonA")
	t.eq(device, { "unknown device Wheel" })
	local _, range = InputMap.rebind(map, "gameplay.jump", "Gamepad", 3, "ButtonY")
	t.eq(range, { "binding index out of range" })
end)

test("overrides round-trip through JSON; junk is dropped with notes", function(t)
	local base = InputMap.defaults()
	local map = base
	local function must(nextMap: any, problems: { string })
		t.eq(problems, {}, "edit accepted")
		map = nextMap
	end
	must(InputMap.rebind(map, "gameplay.action_3", "KeyboardAndMouse", 1, "G"))
	must(InputMap.rebind(map, "gameplay.interact", "KeyboardAndMouse", 1, "F"))
	must(InputMap.rebind(map, "gameplay.jump", "Gamepad", nil, "ButtonB"))
	must(
		InputMap.rebind(
			map,
			"gameplay.move",
			"KeyboardAndMouse",
			2,
			{ up = "I", down = "K", left = "J", right = "L" }
		)
	)
	must(InputMap.unbind(map, "gameplay.sprint", "Touch", 1))
	local data = InputMap.overrides(base, map)
	t.eq(data.schema, InputMap.OVERRIDES_SCHEMA)
	local changed = {}
	for name in data.actions do
		table.insert(changed, name)
	end
	table.sort(changed)
	t.eq(
		changed,
		{ "gameplay.action_3", "gameplay.interact", "gameplay.jump", "gameplay.move", "gameplay.sprint" }
	)
	t.eq(data.actions["gameplay.sprint"].Touch, {}, "an unbind is saved as an empty list")
	local decoded = serde.decode("json", Json.encode(data))
	local restored, notes = InputMap.applyOverrides(base, decoded)
	t.eq(notes, {})
	t.eq(restored.actions, map.actions, "the same map after a save and load")
	t.eq(InputMap.overrides(base, base).actions, {}, "no changes, no overrides")
	-- A swap saves two overrides that only work together; both come back.
	local swapped = InputMap.rebind(base, "ui.tab_next", "KeyboardAndMouse", 1, "Backspace", { swap = true })
	local swapData = serde.decode("json", Json.encode(InputMap.overrides(base, swapped)))
	local swapBack, swapNotes = InputMap.applyOverrides(base, swapData)
	t.eq(swapNotes, {})
	t.eq(swapBack.actions["ui.back"].bindings.KeyboardAndMouse, { "RightBracket" })
	t.eq(swapBack.actions["ui.tab_next"].bindings.KeyboardAndMouse, { "Backspace" })
	t.ok(table.isfrozen(swapBack.actions), "frozen")
	-- Junk.
	local _, bad = InputMap.applyOverrides(base, { schema = "inputmap-overrides/0", actions = {} })
	t.eq(bad, { "overrides ignored: not inputmap-overrides/1" })
	local junk, junkNotes = InputMap.applyOverrides(base, {
		schema = InputMap.OVERRIDES_SCHEMA,
		actions = {
			["gameplay.fly"] = { Gamepad = { "ButtonA" } },
			["gameplay.jump"] = { Wheel = { "ButtonA" }, KeyboardAndMouse = { "E" } },
			["gameplay.primary"] = { Gamepad = { "ButtonR2", "Banana" } },
		},
	})
	t.ok(contains(junkNotes, "gameplay.fly: unknown action dropped"))
	t.ok(contains(junkNotes, "gameplay.jump: unknown device Wheel dropped"))
	t.ok(contains(junkNotes, "gameplay.jump (KeyboardAndMouse): dropped (action gameplay.jump"), "a conflict")
	t.ok(contains(junkNotes, "gameplay.primary (Gamepad): Banana is not a known KeyCode name"))
	t.eq(junk.actions["gameplay.jump"].bindings.KeyboardAndMouse, { "Space" }, "conflicting override dropped")
	t.eq(junk.actions["gameplay.primary"].bindings.Gamepad, { "ButtonR2" }, "the valid part kept")
end)

-- ---------------------------------------------------------------- glyphs

test("glyph text per device and pad style", function(t)
	local map = InputMap.defaults()
	t.eq(InputMap.glyph(map, "gameplay.interact", "KeyboardAndMouse"), {
		kind = "key",
		key = "E",
		text = "E",
		binding = "E",
	})
	t.eq(InputMap.glyph(map, "gameplay.interact", "Gamepad").text, "X")
	t.eq(InputMap.glyph(map, "gameplay.interact", "Gamepad", "playstation").text, "Square")
	t.eq(InputMap.glyph(map, "ui.back", "Gamepad", "playstation").text, "Circle")
	t.eq(InputMap.glyph(map, "ui.confirm", "KeyboardAndMouse").text, "Enter")
	t.eq(InputMap.glyph(map, "gameplay.primary", "KeyboardAndMouse").text, "LMB")
	local touch = InputMap.glyph(map, "gameplay.interact", "Touch")
	t.eq(touch.kind, "touch")
	t.eq(touch.key, "ui:interact_button")
	t.eq(InputMap.glyph(map, "gameplay.move", "KeyboardAndMouse").text, "W/A/S/D")
	t.eq(InputMap.glyph(map, "ui.navigate", "Gamepad").kind, "pad")
	local chord = InputMap.rebind(map, "gameplay.interact", "KeyboardAndMouse", 1, "LeftControl+E")
	t.eq(InputMap.glyph(chord, "gameplay.interact", "KeyboardAndMouse").text, "Ctrl+E")
	local unbound = InputMap.unbind(map, "gameplay.action_3", "Gamepad", 1)
	t.eq(InputMap.glyph(unbound, "gameplay.action_3", "Gamepad"), { kind = "none", text = "" })
	t.eq(InputMap.glyph(map, "gameplay.jump", "Gamepad", "unknown_style").text, "A", "unknown style: xbox")
end)

-- ---------------------------------------------------------------- InputMapRoblox

local function touchButton(key: string): any
	local button = roblox.Instance.new("TextButton")
	button.Name = key
	button:SetAttribute("InputMapKey", key)
	return button
end

test("InputMapRoblox.build makes contexts, actions and bindings from the map", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local map =
		InputMap.rebind(InputMap.defaults(), "gameplay.interact", "KeyboardAndMouse", nil, "LeftShift+E")
	local gui = roblox.Instance.new("ScreenGui")
	touchButton("ui:interact_button").Parent = gui
	touchButton("ui:back_button").Parent = gui
	local parent = roblox.Instance.new("Folder")
	local built = InputMapRoblox.build(map, env, { parent = parent, buttons = gui })
	t.eq(built.folder.Parent, parent)
	t.eq(built.folder.Name, "InputMap")
	for name, spec in map.contexts do
		local context = built.contexts[name]
		t.eq(context.ClassName, "InputContext")
		t.eq(context.Priority, spec.priority)
		t.eq(context.Sink, spec.sink)
		t.eq(context.Enabled, spec.enabled)
	end
	local count = 0
	for name, spec in map.actions do
		count += 1
		local action = built.actions[name]
		t.eq(action.ClassName, "InputAction")
		t.eq(action.Parent, built.contexts[spec.context])
		t.eq(action:GetAttribute("Action"), name)
		t.eq(action.Type, (roblox.Enum.InputActionType :: any)[spec.type])
		t.eq(action:GetAttribute("Reserved"), spec.reserved)
	end
	t.eq(count, 15)
	local jump = built.actions["gameplay.jump"]
	t.eq(jump.Name, "jump")
	local kinds = {}
	for _, child in jump:GetChildren() do
		kinds[child:GetAttribute("Device")] = child
	end
	t.eq(kinds.KeyboardAndMouse.KeyCode, roblox.Enum.KeyCode.Space)
	t.eq(kinds.Gamepad.KeyCode, roblox.Enum.KeyCode.ButtonA)
	t.eq(kinds.Touch, nil, "system:jump_button makes no binding (the default touch controls own it)")
	local chord
	for _, child in built.actions["gameplay.interact"]:GetChildren() do
		if child.PrimaryModifier == roblox.Enum.KeyCode.LeftShift then
			chord = child
		end
	end
	t.ok(chord ~= nil and chord.KeyCode == roblox.Enum.KeyCode.E, "Mod+Key chord")
	local uiBinding
	for _, child in built.actions["gameplay.interact"]:GetChildren() do
		if child:GetAttribute("Device") == "Touch" then
			uiBinding = child
		end
	end
	t.eq(uiBinding.UIButton, gui:FindFirstChild("ui:interact_button"), "ui: binds the GuiButton")
	local move = built.actions["gameplay.move"]:GetChildren()
	t.eq(#move, 3, "two directional sets and the thumbstick")
	local wasd
	for _, child in move do
		if child.Up == roblox.Enum.KeyCode.W then
			wasd = child
		end
	end
	t.ok(wasd ~= nil and wasd.Right == roblox.Enum.KeyCode.D, "directional binding")
	-- Buttons that are not there yet wait in pending until bindButton.
	t.ok(#built.pending > 0)
	local waiting = 0
	for _, item in built.pending do
		if item.key == "ui:primary_button" then
			waiting += 1
		end
	end
	t.eq(waiting, 1)
	local late = touchButton("ui:primary_button")
	t.eq(built:bindButton(late), 1)
	t.eq(built:bindButton(late), 0, "bound once")
	local lateBinding
	for _, child in built.actions["gameplay.primary"]:GetChildren() do
		if child.UIButton == late then
			lateBinding = child
		end
	end
	t.ok(lateBinding ~= nil, "late button bound")
	built:setEnabled("cinematic", true)
	t.eq(built.contexts.cinematic.Enabled, true)
	t.throws(function()
		built:setEnabled("vehicle", true)
	end)
	built:destroy()
	t.eq(built.folder.Parent, nil)
end)

test("InputMapRoblox.build refuses an invalid map and needs env.roblox", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local bad = patched(function(m)
		m.actions["ui.back"].bindings.Touch = {}
	end)
	local ok, err = pcall(InputMapRoblox.build, bad, env)
	t.ok(
		not ok and string.find(tostring(err), "action ui.back: no Touch binding", 1, true) ~= nil,
		tostring(err)
	)
	t.throws(function()
		InputMapRoblox.build(InputMap.defaults(), {})
	end, "no env.roblox")
end)

return cases
