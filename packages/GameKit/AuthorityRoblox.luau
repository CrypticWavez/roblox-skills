--!strict
-- @tier T3
-- probe: authority_simulation_bind
-- AuthorityRoblox: the Server Authority plumbing the G2 adapters share.
--   * bindStep(runService, fn) binds a non-yielding step through RunService:BindToSimulation.
--     Where the method is missing (an engine without Server Authority) it refuses unless the
--     caller opts into the PostSimulation fallback, and says which it used.
--   * writeAttributes(instance, values) writes only changed values and refuses to grow an
--     Instance past 64 attributes (the Server Authority limit); call it inside the step.
--   * mode(workspace) reads Workspace.AuthorityMode ("Server", "Automatic" or "unknown").
--   * buildActions(spec, roblox, parent) creates a raw IAS InputContext with InputActions and
--     InputBindings from data (G4's GameKit/InputMap replaces this after merge; action names
--     are strings such as "gameplay.primary"); readAction(action) reads its state.
-- Datatypes come from the `roblox` argument (the Roblox globals, or @lune/roblox in specs), so
-- the builders run in Lune; signals and BindToSimulation only exist in Studio (probes
-- authority_simulation_bind, authority_input_actions, authority_mode).
local Check = require("./Check")

local AuthorityRoblox = {}
AuthorityRoblox.MAX_ATTRIBUTES = 64 -- per Instance under Server Authority
AuthorityRoblox.ACTION_TYPES = table.freeze({
	Bool = true,
	Direction1D = true,
	Direction2D = true,
	Direction3D = true,
	ViewportPosition = true,
})

-- Binds fn(dt) to the simulation step. Returns (disconnect, how) with how "simulation" or
-- "fallback", or (nil, "no_bind_to_simulation") when the engine lacks it and no fallback is
-- allowed. fn must not yield.
function AuthorityRoblox.bindStep(
	runService: any,
	fn: (dt: number) -> (),
	options: { allowFallback: boolean? }?
): ((() -> ())?, string)
	local ok, connection = pcall(function()
		return runService:BindToSimulation(fn)
	end)
	if ok then
		-- The return value's shape is not documented in the research (UNVERIFIED): disconnect
		-- it when it can be disconnected.
		return function()
			if connection ~= nil then
				pcall(function()
					connection:Disconnect()
				end)
			end
		end,
			"simulation"
	end
	if options and options.allowFallback then
		local signal = runService.PostSimulation or runService.Heartbeat
		local fallback = signal:Connect(fn)
		return function()
			fallback:Disconnect()
		end, "fallback"
	end
	return nil, "no_bind_to_simulation"
end

-- Attribute names follow Roblox rules: letters, digits and underscores, at most 100 characters,
-- not starting with "RBX".
function AuthorityRoblox.validName(name: any): boolean
	return type(name) == "string"
		and #name > 0
		and #name <= 100
		and string.match(name, "^[%w_]+$") ~= nil
		and string.sub(name, 1, 3) ~= "RBX"
end

function AuthorityRoblox.count(instance: any): number
	local n = 0
	for _ in instance:GetAttributes() do
		n += 1
	end
	return n
end

-- Writes values (name -> string, number, boolean or nil to clear) where they changed.
-- Returns (written, problems): a new name past the 64-attribute budget, a bad name or a
-- non-finite number is skipped and reported, never raised. Names are written in sorted order.
function AuthorityRoblox.writeAttributes(instance: any, values: { [string]: any }): (number, { string })
	local problems = {}
	local names = {}
	for name in values do
		table.insert(names, name)
	end
	table.sort(names)
	local count = AuthorityRoblox.count(instance)
	local written = 0
	for _, name in names do
		local value = values[name]
		if not AuthorityRoblox.validName(name) then
			table.insert(problems, string.format("bad attribute name %q", tostring(name)))
			continue
		end
		if type(value) == "number" and not Check.finite(value) then
			table.insert(problems, string.format("attribute %s is not finite", name))
			continue
		end
		local current = instance:GetAttribute(name)
		if current == value then
			continue
		end
		if current == nil and value ~= nil then
			if count >= AuthorityRoblox.MAX_ATTRIBUTES then
				table.insert(
					problems,
					string.format(
						"attribute %s would exceed %d per instance",
						name,
						AuthorityRoblox.MAX_ATTRIBUTES
					)
				)
				continue
			end
			count += 1
		elseif current ~= nil and value == nil then
			count -= 1
		end
		instance:SetAttribute(name, value)
		written += 1
	end
	return written, problems
end

-- Workspace.AuthorityMode as a name ("Server", "Automatic") or "unknown" when unreadable.
function AuthorityRoblox.mode(workspace: any): string
	local ok, value = pcall(function()
		return workspace.AuthorityMode
	end)
	if ok and value ~= nil then
		return value.Name
	end
	return "unknown"
end

export type BindingSpec = {
	keyCode: string?,
	up: string?,
	down: string?,
	left: string?,
	right: string?,
}
export type ActionSpec = { name: string, type: string, bindings: { BindingSpec } }
export type ActionsSpec = { context: string, priority: number?, sink: boolean?, actions: { ActionSpec } }

-- Problems with an actions spec (empty when valid).
function AuthorityRoblox.validateActions(spec: any): { string }
	if type(spec) ~= "table" then
		return { "actions spec must be a table" }
	end
	local problems = {}
	if type(spec.context) ~= "string" or #spec.context == 0 then
		table.insert(problems, "context must be a name")
	end
	if spec.priority ~= nil and not Check.integer(spec.priority) then
		table.insert(problems, "priority must be an integer")
	end
	if type(spec.actions) ~= "table" or #spec.actions == 0 then
		table.insert(problems, "actions must be a non-empty list")
		return problems
	end
	local seen = {}
	for index, action in spec.actions do
		local where = string.format("actions[%d]", index)
		if
			type(action) ~= "table"
			or type(action.name) ~= "string"
			or string.match(action.name, "^[a-z][a-z0-9_]*%.[a-z][a-z0-9_]*$") == nil
		then
			table.insert(problems, where .. ".name must look like area.action (gameplay.primary)")
			continue
		end
		if seen[action.name] then
			table.insert(problems, where .. ".name is duplicated")
		end
		seen[action.name] = true
		if not AuthorityRoblox.ACTION_TYPES[action.type] then
			table.insert(problems, where .. ".type must be an InputActionType name")
		end
		if type(action.bindings) ~= "table" or #action.bindings == 0 then
			table.insert(
				problems,
				where
					.. ".bindings must list at least one binding (gamepad, keyboard and touch each want one)"
			)
		end
	end
	return problems
end

-- Creates InputContext -> InputAction -> InputBinding under parent. Returns (context,
-- actions by name). KeyCode names are Enum.KeyCode item names; directional bindings set
-- Up/Down/Left/Right. Raises on a bad spec (game data).
function AuthorityRoblox.buildActions(spec: ActionsSpec, roblox: any, parent: any?): (any, { [string]: any })
	local problems = AuthorityRoblox.validateActions(spec)
	if #problems > 0 then
		error("AuthorityRoblox.buildActions: " .. table.concat(problems, "; "), 2)
	end
	local Instance, Enum = roblox.Instance, roblox.Enum
	local context = Instance.new("InputContext")
	context.Name = spec.context
	if spec.priority ~= nil then
		context.Priority = spec.priority
	end
	if spec.sink ~= nil then
		context.Sink = spec.sink
	end
	local actions = {}
	for _, actionSpec in spec.actions do
		local action = Instance.new("InputAction")
		action.Name = actionSpec.name
		action.Type = Enum.InputActionType[actionSpec.type]
		for index, bindingSpec in actionSpec.bindings do
			local binding = Instance.new("InputBinding")
			binding.Name = string.format("%s_%d", actionSpec.name, index)
			if bindingSpec.keyCode then
				binding.KeyCode = Enum.KeyCode[bindingSpec.keyCode]
			end
			if bindingSpec.up then
				binding.Up = Enum.KeyCode[bindingSpec.up]
			end
			if bindingSpec.down then
				binding.Down = Enum.KeyCode[bindingSpec.down]
			end
			if bindingSpec.left then
				binding.Left = Enum.KeyCode[bindingSpec.left]
			end
			if bindingSpec.right then
				binding.Right = Enum.KeyCode[bindingSpec.right]
			end
			binding.Parent = action
		end
		action.Parent = context
		actions[actionSpec.name] = action
	end
	if parent ~= nil then
		context.Parent = parent
	end
	return context, actions
end

-- The state of an InputAction as plain data: boolean, number, { x, y } or { x, y, z }.
function AuthorityRoblox.readAction(action: any): any
	local kind = action.Type.Name
	if kind == "Bool" then
		return action.BoolState == true
	elseif kind == "Direction1D" then
		return action.Direction1DState
	elseif kind == "Direction2D" then
		local v = action.Direction2DState
		return { x = v.X, y = v.Y }
	elseif kind == "Direction3D" then
		local v = action.Direction3DState
		return { x = v.X, y = v.Y, z = v.Z }
	end
	local v = action.ViewportPositionState
	return { x = v.X, y = v.Y }
end

return AuthorityRoblox
