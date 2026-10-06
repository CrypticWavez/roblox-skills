--!strict
-- @tier T3
-- probe: inputmap_contexts
-- InputMapRoblox: builds Input Action System instances from a GameKit/InputMap map
-- (docs/uikit.md "Input map"). One InputContext per map context (Name, Priority, Sink,
-- Enabled), one InputAction per action (Name = the action's short name, attribute Action = the
-- full name, Type from the map) and one InputBinding per binding: KeyCode for keys, KeyCode +
-- PrimaryModifier for "Mod+Key" chords, Up/Down/Left/Right for directional tables, UIButton for
-- "ui:<key>" (the GuiButton whose InputMapKey attribute is "ui:<key>", such as a UIKit
-- TouchActionButton; buttons that appear later attach with bindButton) and nothing for
-- "system:<key>" (the default touch controls already provide those). Rebinds: rebuild from
-- InputMap.applyOverrides output. Where an InputContext must live is not documented; callers
-- choose the parent (the player's PlayerScripts or PlayerGui are the usual picks), and probe
-- inputmap_contexts checks construction and property round trips in Studio. Nothing here reads
-- input: game code connects to the returned actions (Pressed, Released, StateChanged).
local InputMap = require("./InputMap")

local InputMapRoblox = {}

export type Built = {
	folder: any,
	contexts: { [string]: any },
	actions: { [string]: any },
	pending: { { action: string, key: string } },
	bindButton: (self: Built, button: any) -> number,
	setEnabled: (self: Built, context: string, enabled: boolean) -> (),
	destroy: (self: Built) -> (),
}

local function shortName(name: string): string
	return string.match(name, "%.(.+)$") or name
end

local function keyCode(r: any, name: string): any
	local ok, value = pcall(function()
		return r.Enum.KeyCode[name]
	end)
	if not ok or value == nil then
		error("InputMapRoblox: unknown KeyCode " .. tostring(name), 3)
	end
	return value
end

-- Every GuiButton under root with an InputMapKey attribute, by key.
local function buttonsUnder(root: any?): { [string]: any }
	local out = {}
	if root == nil then
		return out
	end
	for _, item in root:GetDescendants() do
		if item:IsA("GuiButton") then
			local key = item:GetAttribute("InputMapKey")
			if type(key) == "string" and out[key] == nil then
				out[key] = item
			end
		end
	end
	return out
end

local function binding(
	r: any,
	action: any,
	spec: any,
	device: string,
	buttons: { [string]: any },
	pending: any
)
	local instance
	if type(spec) == "table" then
		instance = r.Instance.new("InputBinding")
		for _, side in { "Up", "Down", "Left", "Right" } do
			local key = spec[string.lower(side)]
			if key then
				instance[side] = keyCode(r, key)
			end
		end
	else
		local prefix = string.match(spec, "^(%a+):.+$")
		if prefix == "system" then
			return nil
		elseif prefix == "ui" then
			local button = buttons[spec]
			if button == nil then
				table.insert(pending, { action = action:GetAttribute("Action"), key = spec })
				return nil
			end
			instance = r.Instance.new("InputBinding")
			instance.UIButton = button
		else
			instance = r.Instance.new("InputBinding")
			local modifier, key = string.match(spec, "^(%a+)%+(%w+)$")
			if modifier then
				instance.KeyCode = keyCode(r, key :: string)
				instance.PrimaryModifier = keyCode(r, modifier)
			else
				instance.KeyCode = keyCode(r, spec)
			end
		end
	end
	instance.Name = device .. "_" .. (#action:GetChildren() + 1)
	instance:SetAttribute("Device", device)
	instance.Parent = action
	return instance
end

export type Options = { parent: any?, buttons: any?, name: string? }

-- Builds the contexts, actions and bindings for a valid map (raises on an invalid one) under a
-- Folder in options.parent. options.buttons is searched for UIButton targets.
function InputMapRoblox.build(map: InputMap.Map, env: any, options: Options?): Built
	local problems = InputMap.validate(map)
	if #problems > 0 then
		error("InputMapRoblox.build: " .. table.concat(problems, "; "), 2)
	end
	local r = env and env.roblox
	assert(r, "InputMapRoblox.build: env.roblox is required")
	local o: Options = options or {}
	local folder = r.Instance.new("Folder")
	folder.Name = o.name or "InputMap"
	local buttons = buttonsUnder(o.buttons)
	local built: any = { folder = folder, contexts = {}, actions = {}, pending = {} }
	local contextNames = {}
	for name in map.contexts do
		table.insert(contextNames, name)
	end
	table.sort(contextNames)
	for _, name in contextNames do
		local spec = map.contexts[name]
		local context = r.Instance.new("InputContext")
		context.Name = name
		context.Priority = spec.priority
		context.Sink = spec.sink
		context.Enabled = spec.enabled
		context.Parent = folder
		built.contexts[name] = context
	end
	local actionNames = {}
	for name in map.actions do
		table.insert(actionNames, name)
	end
	table.sort(actionNames)
	for _, name in actionNames do
		local spec = map.actions[name]
		local action = r.Instance.new("InputAction")
		action.Name = shortName(name)
		action.Type = r.Enum.InputActionType[spec.type]
		action:SetAttribute("Action", name)
		action:SetAttribute("LabelKey", spec.labelKey)
		action:SetAttribute("Reserved", spec.reserved)
		action.Parent = built.contexts[spec.context]
		for _, device in InputMap.DEVICES do
			local items: { InputMap.Binding } = spec.bindings[device] or {}
			for _, item in items do
				binding(r, action, item, device, buttons, built.pending)
			end
		end
		built.actions[name] = action
	end
	folder.Parent = o.parent

	-- Binds a button that appeared after build (a TouchActionButton mounted later) to every
	-- action waiting for its InputMapKey; returns how many bindings it made.
	function built.bindButton(self: any, button: any): number
		local key = button:GetAttribute("InputMapKey")
		local made = 0
		local remaining = {}
		for _, item in self.pending do
			if item.key == key then
				local action = self.actions[item.action]
				local instance = r.Instance.new("InputBinding")
				instance.UIButton = button
				instance.Name = "Touch_" .. (#action:GetChildren() + 1)
				instance:SetAttribute("Device", "Touch")
				instance.Parent = action
				made += 1
			else
				table.insert(remaining, item)
			end
		end
		self.pending = remaining
		return made
	end

	function built.setEnabled(self: any, context: string, enabled: boolean)
		local instance = self.contexts[context]
		assert(instance, "InputMapRoblox: unknown context " .. tostring(context))
		instance.Enabled = enabled
	end

	function built.destroy(self: any)
		self.folder:Destroy()
	end

	return built
end

return InputMapRoblox
