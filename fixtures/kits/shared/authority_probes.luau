--!strict
-- G2 probe registry (prefix authority_): Server Authority facts the action adapters rely on.
--   authority_simulation_bind  RunService:BindToSimulation binds, steps with a numeric dt, and
--                              unbinds through AuthorityRoblox.bindStep (its return shape is
--                              UNVERIFIED; this probe settles it).
--   authority_mode             Workspace.AuthorityMode is readable and set to Server on the kits
--                              place (it is not scriptable: the owner sets it in Studio).
--   authority_attribute_budget writeAttributes stops at 64 attributes per Instance.
--   authority_input_actions    raw IAS InputContext/InputAction/InputBinding build from data
--                              and expose Pressed (G4's InputMap replaces the raw build later).
-- No requires: modules come from ctx.kit. In Lune (tests/gamekit_action_adapters.spec.luau)
-- the registry runs against FakeEnv + FakeWorld; only a Studio run on the unpublished
-- diagnostic place is evidence.
local probes = {}

local function waitFor(ctx: any, predicate: () -> boolean, seconds: number): boolean
	local env = ctx.env
	local started = env.clock()
	while not predicate() do
		if env.clock() - started > seconds then
			return false
		end
		env.wait(1 / 30)
	end
	return true
end

function probes.authority_simulation_bind(ctx: any)
	local Env = ctx.kit("GameKit/Env")
	local AuthorityRoblox = ctx.kit("GameKit/AuthorityRoblox")
	local env = ctx.env
	Env.assertDiagnostic(env, "authority_simulation_bind")
	local calls, lastDt = 0, nil
	local stop, how = AuthorityRoblox.bindStep(env.services.RunService, function(dt: number)
		calls += 1
		lastDt = dt
	end)
	ctx.check("bind_to_simulation_available", how == "simulation", { how = how })
	if stop == nil then
		return
	end
	local started = env.clock()
	local stepped = waitFor(ctx, function()
		return calls >= 3
	end, 2)
	stop()
	local afterStop = calls
	ctx.check("step_called", stepped, { calls = calls })
	ctx.check("dt_is_positive", type(lastDt) == "number" and lastDt > 0 and lastDt < 1, { dt = lastDt })
	ctx.check("clock_advances", env.clock() > started, { started = started, now = env.clock() })
	env.wait(0.2)
	ctx.check("unbind_stops_steps", calls == afterStop, { calls = calls, afterStop = afterStop })
end

function probes.authority_mode(ctx: any)
	local AuthorityRoblox = ctx.kit("GameKit/AuthorityRoblox")
	local mode = AuthorityRoblox.mode(ctx.env.services.Workspace)
	ctx.check("authority_mode_readable", mode ~= "unknown", { mode = mode })
	ctx.check("authority_mode_server", mode == "Server", {
		mode = mode,
		fix = "set Workspace.AuthorityMode to Server in Studio on the kits place (not scriptable)",
	})
end

function probes.authority_attribute_budget(ctx: any)
	local AuthorityRoblox = ctx.kit("GameKit/AuthorityRoblox")
	local roblox = ctx.env.roblox
	local folder = roblox.Instance.new("Folder")
	folder.Name = "SETUP_ONLY_AttributeProbe"
	local values = {}
	for index = 1, AuthorityRoblox.MAX_ATTRIBUTES + 6 do
		values[string.format("Probe%02d", index)] = index
	end
	local written, problems = AuthorityRoblox.writeAttributes(folder, values)
	ctx.check("writes_up_to_budget", written == AuthorityRoblox.MAX_ATTRIBUTES, { written = written })
	ctx.check("refuses_past_budget", #problems == 6, { problems = #problems })
	ctx.check("count_matches", AuthorityRoblox.count(folder) == AuthorityRoblox.MAX_ATTRIBUTES)
	local again = AuthorityRoblox.writeAttributes(folder, { Probe01 = 1, Probe02 = 99 })
	ctx.check("writes_only_changes", again == 1, { written = again })
	local bad, badProblems = AuthorityRoblox.writeAttributes(folder, { ["bad name"] = 1, RBXName = 2 })
	ctx.check("refuses_bad_names", bad == 0 and #badProblems == 2, badProblems)
	folder:Destroy()
end

-- The shape of AuthorityRoblox.ActionsSpec (kit modules come from ctx.kit, so no type import). A
-- binding is one keyCode, or up/down/left/right key codes for a Direction2D composite.
type Binding = { keyCode: string?, up: string?, down: string?, left: string?, right: string? }
type ActionsSpec = {
	context: string,
	priority: number,
	actions: { { name: string, type: string, bindings: { Binding } } },
}

function probes.authority_input_actions(ctx: any)
	local AuthorityRoblox = ctx.kit("GameKit/AuthorityRoblox")
	local roblox = ctx.env.roblox
	local spec: ActionsSpec = {
		context = "SETUP_ONLY_AuthorityProbe",
		priority = 1,
		actions = {
			{
				name = "gameplay.primary",
				type = "Bool",
				bindings = { { keyCode = "Space" }, { keyCode = "ButtonR2" } },
			},
			{
				name = "gameplay.move",
				type = "Direction2D",
				bindings = { { up = "W", down = "S", left = "A", right = "D" }, { keyCode = "Thumbstick1" } },
			},
		},
	}
	local context, actions = AuthorityRoblox.buildActions(spec, roblox, nil)
	local primary, move = actions["gameplay.primary"], actions["gameplay.move"]
	ctx.check("context_built", context.ClassName == "InputContext" and context.Priority == 1)
	ctx.check("action_types", primary.Type.Name == "Bool" and move.Type.Name == "Direction2D")
	ctx.check("bindings_built", #primary:GetChildren() == 2 and #move:GetChildren() == 2)
	-- A fresh action's state is read through pcall: an engine without defaults is a failed
	-- check, not a raised probe.
	local boolRead, boolValue = pcall(AuthorityRoblox.readAction, primary)
	ctx.check("bool_reads_false", boolRead and boolValue == false, { value = tostring(boolValue) })
	local moveRead, direction = pcall(AuthorityRoblox.readAction, move)
	ctx.check(
		"direction_reads_zero",
		moveRead and type(direction) == "table" and direction.x == 0 and direction.y == 0,
		{ value = if type(direction) == "table" then direction else tostring(direction) }
	)
	local hasPressed = pcall(function()
		return primary.Pressed
	end)
	ctx.check("pressed_signal", hasPressed, "InputAction.Pressed exists (engine only)")
	context:Destroy()
end

return probes
