--!strict
-- @tier T0
-- InputMap: the game's input contexts and actions as data, for the Input Action System
-- (docs/uikit.md "Input map"; docs/runtime-kits.md section 6: only adapters read input, and only
-- through IAS actions). Contexts gameplay (priority 100), ui (200) and cinematic (300, sinks,
-- off until a cutscene plays). Every action has at least one binding for each device:
-- KeyboardAndMouse, Gamepad and Touch (the IAS docs ask for all three). A binding is a KeyCode
-- name ("Space", "ButtonA", "MouseLeftButton"), "Mod+Key" for a modifier chord, a directional
-- table { up, down, left, right } for Direction1D/2D, "ui:<key>" for an on-screen GuiButton
-- (InputBinding.UIButton, e.g. a UIKit TouchActionButton) or "system:<key>" for input the
-- default PlayerScripts already provide (the touch thumbstick and jump button).
-- ui.back, ui.confirm and cinematic.skip are reserved: other kits use them by name and
-- rebinding can never leave them without a binding on any device. Keys the Roblox client
-- uses itself (Escape menu, Tab player list, F9 console, ButtonStart, ButtonSelect) are refused
-- as defaults and rebinds. Rebinds are stored as overrides (plain data a key store can save)
-- and re-applied with applyOverrides, which drops anything invalid. InputMapRoblox builds the
-- InputContext/InputAction/InputBinding instances. Glyph text is neutral (Xbox or PlayStation
-- names); device images come from UserInputService:GetImageForKeyCode in the adapter.
local Check = require("./Check")

local InputMap = {}
InputMap.SCHEMA = "inputmap/1"
InputMap.OVERRIDES_SCHEMA = "inputmap-overrides/1"

InputMap.DEVICES = table.freeze({ "KeyboardAndMouse", "Gamepad", "Touch" })
InputMap.TYPES = table.freeze({ "Bool", "Direction1D", "Direction2D" })
InputMap.RESERVED = table.freeze({ "ui.back", "ui.confirm", "cinematic.skip" })

-- Keys the Roblox client binds itself (UNVERIFIED whether an IAS context with Sink can take
-- them over; refused so a game never fights the system menu, player list or dev console).
InputMap.SYSTEM_KEYS = table.freeze({
	Escape = "Roblox menu",
	Tab = "player list",
	F9 = "developer console",
	ButtonStart = "Roblox menu",
	ButtonSelect = "gamepad UI selection",
})

-- KeyCode names a binding may use (a subset of Enum.KeyCode; the spec checks each name exists
-- in the engine enum through @lune/roblox).
local KEYS: { string } = {
	"A",
	"B",
	"C",
	"D",
	"E",
	"F",
	"G",
	"H",
	"I",
	"J",
	"K",
	"L",
	"M",
	"N",
	"O",
	"P",
	"Q",
	"R",
	"S",
	"T",
	"U",
	"V",
	"W",
	"X",
	"Y",
	"Z",
	"Zero",
	"One",
	"Two",
	"Three",
	"Four",
	"Five",
	"Six",
	"Seven",
	"Eight",
	"Nine",
	"F1",
	"F2",
	"F3",
	"F4",
	"F5",
	"F6",
	"F7",
	"F8",
	"F9",
	"F10",
	"F11",
	"F12",
	"Space",
	"Return",
	"KeypadEnter",
	"Escape",
	"Backspace",
	"Tab",
	"Delete",
	"Insert",
	"Home",
	"End",
	"PageUp",
	"PageDown",
	"Up",
	"Down",
	"Left",
	"Right",
	"LeftShift",
	"RightShift",
	"LeftControl",
	"RightControl",
	"LeftAlt",
	"RightAlt",
	"Comma",
	"Period",
	"Slash",
	"Semicolon",
	"Quote",
	"LeftBracket",
	"RightBracket",
	"BackSlash",
	"Minus",
	"Equals",
	"Backquote",
	"MouseLeftButton",
	"MouseRightButton",
	"MouseMiddleButton",
	"ButtonA",
	"ButtonB",
	"ButtonX",
	"ButtonY",
	"ButtonL1",
	"ButtonR1",
	"ButtonL2",
	"ButtonR2",
	"ButtonL3",
	"ButtonR3",
	"ButtonStart",
	"ButtonSelect",
	"DPadUp",
	"DPadDown",
	"DPadLeft",
	"DPadRight",
	"Thumbstick1",
	"Thumbstick2",
}
InputMap.KEYS = table.freeze(KEYS)
local KEY_SET: { [string]: boolean } = {}
for _, key in KEYS do
	KEY_SET[key] = true
end
local MODIFIERS = {
	LeftShift = true,
	RightShift = true,
	LeftControl = true,
	RightControl = true,
	LeftAlt = true,
	RightAlt = true,
}

local GAMEPAD_KEYS: { [string]: boolean } = {}
for _, key in KEYS do
	if string.match(key, "^Button") or string.match(key, "^DPad") or string.match(key, "^Thumbstick") then
		GAMEPAD_KEYS[key] = true
	end
end

export type Binding = string | { up: string?, down: string?, left: string?, right: string? }
export type Action = {
	name: string,
	context: string,
	type: string,
	reserved: boolean,
	bindings: { [string]: { Binding } },
	labelKey: string,
}
export type Context = { name: string, priority: number, sink: boolean, enabled: boolean }
export type Map = {
	schema: string,
	contexts: { [string]: Context },
	actions: { [string]: Action },
}

local function arrows(up: string, down: string, left: string, right: string): Binding
	return { up = up, down = down, left = left, right = right }
end

local function action(
	name: string,
	kind: string,
	kbm: { Binding },
	pad: { Binding },
	touch: { Binding }
): Action
	local context = string.match(name, "^([%a_]+)%.") :: string
	return {
		name = name,
		context = context,
		type = kind,
		reserved = table.find(InputMap.RESERVED, name) ~= nil,
		bindings = { KeyboardAndMouse = kbm, Gamepad = pad, Touch = touch },
		labelKey = "input." .. name,
	}
end

-- The neutral default map (function names only; a game adds its own actions with define).
function InputMap.defaults(): Map
	local list = {
		action(
			"gameplay.move",
			"Direction2D",
			{ arrows("W", "S", "A", "D"), arrows("Up", "Down", "Left", "Right") },
			{ "Thumbstick1" },
			{ "system:thumbstick" }
		),
		action("gameplay.jump", "Bool", { "Space" }, { "ButtonA" }, { "system:jump_button" }),
		action("gameplay.primary", "Bool", { "MouseLeftButton" }, { "ButtonR2" }, { "ui:primary_button" }),
		action(
			"gameplay.secondary",
			"Bool",
			{ "MouseRightButton" },
			{ "ButtonL2" },
			{ "ui:secondary_button" }
		),
		action("gameplay.interact", "Bool", { "E" }, { "ButtonX" }, { "ui:interact_button" }),
		action("gameplay.sprint", "Bool", { "LeftShift" }, { "ButtonL3" }, { "ui:sprint_button" }),
		action("gameplay.action_1", "Bool", { "Q" }, { "ButtonY" }, { "ui:action_1_button" }),
		action("gameplay.action_2", "Bool", { "R" }, { "ButtonR1" }, { "ui:action_2_button" }),
		action("gameplay.action_3", "Bool", { "F" }, { "ButtonL1" }, { "ui:action_3_button" }),
		action("ui.confirm", "Bool", { "Return", "KeypadEnter" }, { "ButtonA" }, { "ui:confirm_button" }),
		-- Backspace, not Escape: Escape opens the Roblox menu (SYSTEM_KEYS).
		action("ui.back", "Bool", { "Backspace" }, { "ButtonB" }, { "ui:back_button" }),
		action(
			"ui.navigate",
			"Direction2D",
			{ arrows("Up", "Down", "Left", "Right") },
			{ arrows("DPadUp", "DPadDown", "DPadLeft", "DPadRight") },
			{ "system:direct_touch" }
		),
		action("ui.tab_next", "Bool", { "RightBracket" }, { "ButtonR1" }, { "system:direct_touch" }),
		action("ui.tab_prev", "Bool", { "LeftBracket" }, { "ButtonL1" }, { "system:direct_touch" }),
		action("cinematic.skip", "Bool", { "Space", "Return" }, { "ButtonA" }, { "ui:skip_button" }),
	}
	local actions = {}
	for _, item in list do
		actions[item.name] = item
	end
	return {
		schema = InputMap.SCHEMA,
		contexts = {
			gameplay = { name = "gameplay", priority = 100, sink = false, enabled = true },
			ui = { name = "ui", priority = 200, sink = false, enabled = true },
			cinematic = { name = "cinematic", priority = 300, sink = true, enabled = false },
		},
		actions = actions,
	}
end

-- ------------------------------------------------------------------ validation

local function keyName(text: string): (string?, string?)
	local modifier, key = string.match(text, "^(%a+)%+(%w+)$")
	if modifier then
		return key, modifier
	end
	return text, nil
end

-- Problems with one binding for a device and action type.
function InputMap.bindingProblem(binding: any, device: string, kind: string): string?
	if type(binding) == "table" then
		if kind == "Bool" then
			return "a Bool action takes a key, not directional keys"
		end
		local sides: { string } = if kind == "Direction1D"
			then { "up", "down" }
			else { "up", "down", "left", "right" }
		for key in binding do
			if not table.find(sides, key) then
				return "directional binding key "
					.. tostring(key)
					.. " is not one of "
					.. table.concat(sides, ", ")
			end
		end
		for _, side in sides do
			local key = binding[side]
			if type(key) ~= "string" or not KEY_SET[key] then
				return "directional binding needs a KeyCode name for " .. side
			end
			if InputMap.SYSTEM_KEYS[key] then
				return key .. " is used by the Roblox client (" .. InputMap.SYSTEM_KEYS[key] .. ")"
			end
			if device == "Gamepad" and not GAMEPAD_KEYS[key] then
				return key .. " is not a gamepad input"
			elseif device == "KeyboardAndMouse" and GAMEPAD_KEYS[key] then
				return key .. " is a gamepad input"
			end
		end
		return nil
	end
	if type(binding) ~= "string" then
		return "a binding is a KeyCode name, a directional table, ui:<key> or system:<key>"
	end
	local prefix, label = string.match(binding, "^(%a+):(.+)$")
	if prefix then
		if prefix ~= "ui" and prefix ~= "system" then
			return "binding prefix must be ui: or system:"
		end
		if not Check.label(label) then
			return binding .. ": the part after " .. prefix .. ": must be a lower_snake label"
		end
		if device ~= "Touch" and prefix == "ui" then
			return "ui: (on-screen button) bindings belong to Touch"
		end
		return nil
	end
	local key, modifier = keyName(binding)
	if key == nil or not KEY_SET[key] then
		return binding .. " is not a known KeyCode name"
	end
	if modifier and not MODIFIERS[modifier] then
		return modifier .. " is not a modifier key (Shift, Control, Alt)"
	end
	if InputMap.SYSTEM_KEYS[key] then
		return key .. " is used by the Roblox client (" .. InputMap.SYSTEM_KEYS[key] .. ")"
	end
	if device == "Touch" then
		return "Touch bindings are ui:<key> or system:<key>"
	elseif device == "Gamepad" and not GAMEPAD_KEYS[key] then
		return key .. " is not a gamepad input"
	elseif device == "KeyboardAndMouse" and GAMEPAD_KEYS[key] then
		return key .. " is a gamepad input"
	end
	if kind ~= "Bool" and key ~= "Thumbstick1" and key ~= "Thumbstick2" then
		return kind .. " actions bind a thumbstick or directional keys"
	end
	return nil
end

local function bindingId(binding: Binding): string
	if type(binding) == "string" then
		return binding
	end
	local b = binding :: any
	return string.format(
		"dir(%s,%s,%s,%s)",
		tostring(b.up),
		tostring(b.down),
		tostring(b.left),
		tostring(b.right)
	)
end

-- Keys a binding presses (for conflict checks).
local function pressedKeys(binding: Binding): { string }
	if type(binding) == "string" then
		if string.find(binding, ":", 1, true) then
			return { binding }
		end
		return { binding }
	end
	local out = {}
	for _, key in binding :: any do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

export type ValidateOptions = { allowUnbound: boolean? }

-- Problems with a map (empty when valid): names, contexts, types, bindings per device, reserved
-- actions and same-context conflicts (one key on two actions of one context).
function InputMap.validate(map: any, options: ValidateOptions?): { string }
	if type(map) ~= "table" then
		return { "map must be a table" }
	end
	local problems = {}
	if map.schema ~= InputMap.SCHEMA then
		table.insert(problems, "schema must be " .. InputMap.SCHEMA)
	end
	if type(map.contexts) ~= "table" or type(map.actions) ~= "table" then
		table.insert(problems, "map needs contexts and actions tables")
		return problems
	end
	local priorities: { [number]: string } = {}
	local contextNames = {}
	for name in map.contexts do
		table.insert(contextNames, name)
	end
	table.sort(contextNames, function(a: any, b: any): boolean
		return tostring(a) < tostring(b)
	end)
	for _, name in contextNames do
		local context = map.contexts[name]
		local where = "context " .. tostring(name)
		if not Check.label(name) or type(context) ~= "table" or context.name ~= name then
			table.insert(problems, where .. ": needs a label name matching its key")
			continue
		end
		if not (Check.integer(context.priority) and context.priority >= 0) then
			table.insert(problems, where .. ": priority must be an integer >= 0")
		elseif priorities[context.priority] then
			table.insert(problems, where .. ": priority also used by " .. priorities[context.priority])
		else
			priorities[context.priority] = name
		end
		if type(context.sink) ~= "boolean" or type(context.enabled) ~= "boolean" then
			table.insert(problems, where .. ": sink and enabled must be booleans")
		end
	end
	local names = {}
	for name in map.actions do
		table.insert(names, name)
	end
	table.sort(names, function(a: any, b: any): boolean
		return tostring(a) < tostring(b)
	end)
	local used: { [string]: { [string]: string } } = {}
	for _, name in names do
		local item = map.actions[name]
		local where = "action " .. tostring(name)
		local context, label = string.match(tostring(name), "^([%a_][%w_]*)%.([%a_][%w_]*)$")
		if
			type(item) ~= "table"
			or item.name ~= name
			or context == nil
			or not Check.label(context)
			or not Check.label(label)
		then
			table.insert(problems, where .. ": names are <context>.<label> and match their key")
			continue
		end
		if item.context ~= context or map.contexts[context] == nil then
			table.insert(problems, where .. ": context " .. tostring(context) .. " is not defined")
		end
		if not table.find(InputMap.TYPES, item.type) then
			table.insert(problems, where .. ": type must be Bool, Direction1D or Direction2D")
			continue
		end
		local reserved = table.find(InputMap.RESERVED, name) ~= nil
		if item.reserved ~= reserved then
			table.insert(problems, where .. ": reserved must be " .. tostring(reserved))
		end
		if type(item.bindings) ~= "table" then
			table.insert(problems, where .. ": bindings must map devices to lists")
			continue
		end
		for device in item.bindings do
			if not table.find(InputMap.DEVICES, device) then
				table.insert(problems, where .. ": unknown device " .. tostring(device))
			end
		end
		for _, device in InputMap.DEVICES do
			local list = item.bindings[device]
			if list == nil or #list == 0 then
				if reserved or not (options and options.allowUnbound) then
					table.insert(problems, string.format("%s: no %s binding", where, device))
				end
				continue
			end
			local seen: { [string]: boolean } = {}
			for _, binding in list do
				local problem = InputMap.bindingProblem(binding, device, item.type)
				if problem then
					table.insert(problems, string.format("%s (%s): %s", where, device, problem))
					continue
				end
				local id = bindingId(binding)
				if seen[id] then
					table.insert(problems, string.format("%s (%s): duplicate binding %s", where, device, id))
				end
				seen[id] = true
				if type(binding) == "string" and string.sub(binding, 1, 7) == "system:" then
					continue -- the same system control may serve several actions
				end
				for _, key in pressedKeys(binding) do
					local slot = context .. "/" .. key
					used[slot] = used[slot] or {}
					local other = used[slot][device]
					if other and other ~= name then
						table.insert(
							problems,
							string.format(
								"%s (%s): %s already bound to %s in context %s",
								where,
								device,
								key,
								other,
								context
							)
						)
					end
					used[slot][device] = name
				end
			end
		end
	end
	return problems
end

-- Validates, deep-copies and deep-freezes a map. Raises with every problem listed.
function InputMap.define(map: any): Map
	local problems = InputMap.validate(map)
	if #problems > 0 then
		error("InputMap.define: " .. table.concat(problems, "; "), 2)
	end
	return Check.freeze(Check.copy(map))
end

-- Keys bound in two contexts that are enabled together (not errors: the higher-priority
-- context wins, and its Sink decides whether the lower one also hears it). Sorted notes.
function InputMap.overlaps(map: Map): { string }
	local byKey: { [string]: { string } } = {}
	for name, item in map.actions do
		if not map.contexts[item.context].enabled then
			continue
		end
		for device, list in item.bindings do
			for _, binding in list do
				if type(binding) == "string" and string.find(binding, ":", 1, true) then
					continue
				end
				for _, key in pressedKeys(binding) do
					local slot = device .. "/" .. key
					byKey[slot] = byKey[slot] or {}
					table.insert(byKey[slot], name)
				end
			end
		end
	end
	local notes = {}
	for slot, actions in byKey do
		local contexts: { [string]: boolean } = {}
		local count = 0
		for _, name in actions do
			local context = map.actions[name].context
			if not contexts[context] then
				contexts[context] = true
				count += 1
			end
		end
		if count > 1 then
			table.sort(actions)
			table.insert(notes, slot .. ": " .. table.concat(actions, ", "))
		end
	end
	table.sort(notes)
	return notes
end

-- ------------------------------------------------------------------ lookup

function InputMap.action(map: Map, name: string): Action
	local item = map.actions[name]
	if item == nil then
		error("InputMap: unknown action " .. tostring(name), 2)
	end
	return item
end

-- Actions of a context, sorted by name.
function InputMap.actionsIn(map: Map, context: string): { Action }
	local out = {}
	for _, item in map.actions do
		if item.context == context then
			table.insert(out, item)
		end
	end
	table.sort(out, function(a: Action, b: Action): boolean
		return a.name < b.name
	end)
	return out
end

function InputMap.bindings(map: Map, name: string, device: string): { Binding }
	return InputMap.action(map, name).bindings[device] or {}
end

-- ------------------------------------------------------------------ rebinding

local function editable(map: Map): any
	return Check.copy(map)
end

-- (map, problems): the map with binding slot `index` of action/device set to binding (index
-- nil appends). Refused (map unchanged) for invalid bindings, unknown actions, and a key used
-- by another action of the same context unless options.swap moves that action to the old key.
function InputMap.rebind(
	map: Map,
	name: string,
	device: string,
	index: number?,
	binding: Binding,
	options: { swap: boolean? }?
): (Map, { string })
	local item = map.actions[name]
	if item == nil then
		return map, { "unknown action " .. tostring(name) }
	end
	if not table.find(InputMap.DEVICES, device) then
		return map, { "unknown device " .. tostring(device) }
	end
	local problem = InputMap.bindingProblem(binding, device, item.type)
	if problem then
		return map, { problem }
	end
	local out = editable(map)
	local list = out.actions[name].bindings[device] or {}
	out.actions[name].bindings[device] = list
	local slot = index or (#list + 1)
	if not (Check.integer(slot) and slot >= 1 and slot <= #list + 1) then
		return map, { "binding index out of range" }
	end
	local old = list[slot]
	list[slot] = Check.copy(binding)
	-- Resolve a same-context conflict.
	for otherName, other in out.actions do
		if otherName == name or other.context ~= item.context then
			continue
		end
		local otherList = other.bindings[device] or {}
		for otherIndex, otherBinding in otherList do
			for _, key in pressedKeys(otherBinding) do
				if table.find(pressedKeys(binding), key) then
					if options and options.swap and old ~= nil then
						otherList[otherIndex] = Check.copy(old)
					else
						return map, { string.format("%s is already bound to %s", key, otherName) }
					end
				end
			end
		end
	end
	local problems = InputMap.validate(out, { allowUnbound = true })
	if #problems > 0 then
		return map, problems
	end
	return Check.freeze(out), {}
end

-- (map, problems): the map without binding slot `index` of action/device. A reserved action
-- keeps at least one binding per device.
function InputMap.unbind(map: Map, name: string, device: string, index: number): (Map, { string })
	local item = map.actions[name]
	if item == nil then
		return map, { "unknown action " .. tostring(name) }
	end
	local list = item.bindings[device]
	if list == nil or list[index] == nil then
		return map, { "no binding at that index" }
	end
	if item.reserved and #list <= 1 then
		return map, { name .. " is reserved: it keeps at least one " .. device .. " binding" }
	end
	local out = editable(map)
	table.remove(out.actions[name].bindings[device], index)
	return Check.freeze(out), {}
end

export type Overrides = { schema: string, actions: { [string]: { [string]: { Binding } } } }

-- The player's changes against base as plain data (for a key store).
function InputMap.overrides(base: Map, current: Map): Overrides
	local out = {}
	for name, item in current.actions do
		local baseItem = base.actions[name]
		for _, device in InputMap.DEVICES do
			local list: { Binding } = item.bindings[device] or {}
			local baseList: { Binding } = baseItem and baseItem.bindings[device] or {}
			local same = #list == #baseList
			if same then
				for index, binding in list do
					if bindingId(binding) ~= bindingId(baseList[index]) then
						same = false
						break
					end
				end
			end
			if not same then
				out[name] = out[name] or {}
				out[name][device] = Check.copy(list)
			end
		end
	end
	return { schema = InputMap.OVERRIDES_SCHEMA, actions = out }
end

local function sortedKeys(t: { [any]: any }): { any }
	local out = {}
	for key in t do
		table.insert(out, key)
	end
	table.sort(out, function(a: any, b: any): boolean
		return tostring(a) < tostring(b)
	end)
	return out
end

-- (map, notes): base with saved overrides applied. Unknown actions, devices, invalid bindings
-- and anything that would unbind a reserved action are dropped with a note. All overrides are
-- applied together (so a saved swap, two actions trading keys, comes back); if the result has
-- conflicts, overrides are reverted to base one at a time (the latest in name order that
-- removes a problem first) until the map is valid, each with a note.
function InputMap.applyOverrides(base: Map, data: any): (Map, { string })
	local notes = {}
	if type(data) ~= "table" or data.schema ~= InputMap.OVERRIDES_SCHEMA or type(data.actions) ~= "table" then
		return base, { "overrides ignored: not " .. InputMap.OVERRIDES_SCHEMA }
	end
	local candidate = editable(base)
	local applied: { { name: string, device: string } } = {}
	for _, name in sortedKeys(data.actions) do
		local item = base.actions[name]
		local entry = data.actions[name]
		if item == nil then
			table.insert(notes, tostring(name) .. ": unknown action dropped")
			continue
		elseif type(entry) ~= "table" then
			table.insert(notes, name .. ": not a device table, dropped")
			continue
		end
		for _, device in sortedKeys(entry) do
			local list = entry[device]
			if not table.find(InputMap.DEVICES, device) or type(list) ~= "table" then
				table.insert(notes, string.format("%s: unknown device %s dropped", name, tostring(device)))
				continue
			end
			local kept = {}
			for _, binding in list do
				local problem = InputMap.bindingProblem(binding, device, item.type)
				if problem then
					table.insert(notes, string.format("%s (%s): %s", name, device, problem))
				else
					table.insert(kept, Check.copy(binding))
				end
			end
			if #kept == 0 and item.reserved then
				table.insert(
					notes,
					string.format("%s (%s): reserved action keeps its defaults", name, device)
				)
				continue
			end
			candidate.actions[name].bindings[device] = kept
			table.insert(applied, { name = name, device = device })
		end
	end
	local problems = InputMap.validate(candidate, { allowUnbound = true })
	while #problems > 0 and #applied > 0 do
		local chosen, trial, trialProblems = nil, nil, problems
		for index = #applied, 1, -1 do
			local o = applied[index]
			local attempt = Check.copy(candidate)
			attempt.actions[o.name].bindings[o.device] =
				Check.copy(base.actions[o.name].bindings[o.device] or {})
			local attemptProblems = InputMap.validate(attempt, { allowUnbound = true })
			if #attemptProblems < #problems then
				chosen, trial, trialProblems = index, attempt, attemptProblems
				break
			end
		end
		-- No single revert helps: drop every remaining override.
		local dropping: { { name: string, device: string } } = if chosen then { applied[chosen] } else applied
		for _, o in dropping do
			local reason = problems[1]
			for _, problem in problems do
				if string.find(problem, o.name, 1, true) then
					reason = problem
					break
				end
			end
			table.insert(notes, string.format("%s (%s): dropped (%s)", o.name, o.device, reason))
		end
		if chosen then
			table.remove(applied, chosen)
			candidate, problems = trial, trialProblems
		else
			return base, notes
		end
	end
	if #problems > 0 then
		return base, notes
	end
	return Check.freeze(candidate), notes
end

-- ------------------------------------------------------------------ glyphs

local KEY_TEXT: { [string]: string } = {
	Return = "Enter",
	KeypadEnter = "Enter",
	Backspace = "Backspace",
	Space = "Space",
	LeftShift = "Shift",
	RightShift = "Shift",
	LeftControl = "Ctrl",
	RightControl = "Ctrl",
	LeftAlt = "Alt",
	RightAlt = "Alt",
	MouseLeftButton = "LMB",
	MouseRightButton = "RMB",
	MouseMiddleButton = "MMB",
	Up = "Up",
	Down = "Down",
	Left = "Left",
	Right = "Right",
	LeftBracket = "[",
	RightBracket = "]",
	Comma = ",",
	Period = ".",
	Slash = "/",
	Semicolon = ";",
	Quote = "'",
	BackSlash = "\\",
	Minus = "-",
	Equals = "=",
	Backquote = "`",
	Zero = "0",
	One = "1",
	Two = "2",
	Three = "3",
	Four = "4",
	Five = "5",
	Six = "6",
	Seven = "7",
	Eight = "8",
	Nine = "9",
	PageUp = "PgUp",
	PageDown = "PgDn",
}
local PAD_TEXT: { [string]: { [string]: string } } = {
	xbox = {
		ButtonA = "A",
		ButtonB = "B",
		ButtonX = "X",
		ButtonY = "Y",
		ButtonL1 = "LB",
		ButtonR1 = "RB",
		ButtonL2 = "LT",
		ButtonR2 = "RT",
		ButtonL3 = "LS",
		ButtonR3 = "RS",
		Thumbstick1 = "L Stick",
		Thumbstick2 = "R Stick",
		DPadUp = "D-Pad Up",
		DPadDown = "D-Pad Down",
		DPadLeft = "D-Pad Left",
		DPadRight = "D-Pad Right",
	},
	playstation = {
		ButtonA = "Cross",
		ButtonB = "Circle",
		ButtonX = "Square",
		ButtonY = "Triangle",
		ButtonL1 = "L1",
		ButtonR1 = "R1",
		ButtonL2 = "L2",
		ButtonR2 = "R2",
		ButtonL3 = "L3",
		ButtonR3 = "R3",
		Thumbstick1 = "L Stick",
		Thumbstick2 = "R Stick",
		DPadUp = "D-Pad Up",
		DPadDown = "D-Pad Down",
		DPadLeft = "D-Pad Left",
		DPadRight = "D-Pad Right",
	},
}

export type Glyph = { kind: "key" | "pad" | "touch" | "none", key: string?, text: string, binding: Binding? }

-- The prompt glyph for an action on a device: the first binding's display text (style "xbox"
-- or "playstation" for pads). Touch bindings return kind "touch" with the ui:/system: key, so
-- the caller shows the on-screen button instead of a key cap.
function InputMap.glyph(map: Map, name: string, device: string, style: string?): Glyph
	local list = InputMap.bindings(map, name, device)
	local first = list[1]
	if first == nil then
		return { kind = "none", text = "" }
	end
	if type(first) == "table" then
		local b = first :: any
		local parts = {}
		for _, side in { "up", "left", "down", "right" } do
			if b[side] then
				table.insert(
					parts,
					KEY_TEXT[b[side]] or (PAD_TEXT[style or "xbox"] or PAD_TEXT.xbox)[b[side]] or b[side]
				)
			end
		end
		return {
			kind = if device == "Gamepad" then "pad" else "key",
			text = table.concat(parts, "/"),
			binding = first,
		}
	end
	local binding = first :: string
	local prefix = string.match(binding, "^(%a+):")
	if prefix then
		return { kind = "touch", key = binding, text = "", binding = first }
	end
	local key, modifier = keyName(binding)
	local k = key :: string
	if device == "Gamepad" then
		local names = PAD_TEXT[style or "xbox"] or PAD_TEXT.xbox
		return { kind = "pad", key = k, text = names[k] or k, binding = first }
	end
	local text = KEY_TEXT[k] or k
	if modifier then
		text = (KEY_TEXT[modifier] or modifier) .. "+" .. text
	end
	return { kind = "key", key = k, text = text, binding = first }
end

return InputMap
