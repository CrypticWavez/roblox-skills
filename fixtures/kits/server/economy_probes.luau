--!strict
-- G3 economy probe registry (prefix economy_). Server-side probes for the T3 economy adapters and
-- the parts of the economy kit that need the engine's scheduler or real players:
--   economy_followers_formation  FollowersRoblox constraints pull parts into a grid formation and
--                                a far leader jump teleports them (BindToSimulation or fallback)
--   economy_outfits_apply        OutfitsRoblox applies scales and colors (no asset ids) to an R15
--                                rig made by Players:CreateHumanoidModelFromDescription and reads
--                                them back; records which apply method the engine offers
--   economy_plots_claim_race     deferred claim threads racing for one plot resolve in order
--   economy_trade_two_client     a trade between the first two real players (Server and Clients
--                                test mode with two clients), in memory only: no DataStore
-- No requires: kits come from ctx.kit, the Env from ctx.env. Run on the unpublished diagnostic
-- place built from fixtures/kits.project.json (runners: tests/engine/economy_<probe>.luau); every
-- probe refuses any other place (Env.assertDiagnostic), builds what it needs far above the place's
-- content (y = 800, a convention) and removes it, also when the probe raises.
-- In Lune the same registry runs against FakeEnv and tests/fakes/FakeEconomyEngine.luau
-- (tests/gamekit_economy_probes.spec.luau), which proves wiring, not the engine.
local probes = {}

local STAGING_Y = 800 -- above the place's content (the G2 probes' convention)

type Defer = (fn: () -> ()) -> ()

-- A folder in Workspace for the probe's parts, destroyed by the probe's cleanups.
local function folder(ctx: any, name: string, defer: Defer): any
	local r = ctx.env.roblox
	local made = r.Instance.new("Folder")
	made.Name = name
	defer(function()
		made:Destroy()
	end)
	made.Parent = ctx.env.services.Workspace
	return made
end

-- Wraps a probe body: refuses a non-diagnostic place first, then always runs the body's deferred
-- cleanups (in reverse, each pcall-protected), so a probe that raises leaves nothing built or
-- bound. The error is re-raised for Probe.runAll to record as check "error".
local function guarded(body: (ctx: any, defer: Defer) -> ...any)
	return function(ctx: any)
		ctx.kit("GameKit/Env").assertDiagnostic(ctx.env, ctx.probe)
		local cleanups = {}
		local ok, err = pcall(body, ctx, function(fn: () -> ())
			table.insert(cleanups, fn)
		end)
		for index = #cleanups, 1, -1 do
			pcall(cleanups[index])
		end
		if not ok then
			error(err, 0)
		end
	end
end

probes.economy_followers_formation = guarded(function(ctx: any, defer: Defer)
	local Followers = ctx.kit("GameKit/Followers")
	local FollowersRoblox = ctx.kit("GameKit/FollowersRoblox")
	local env = ctx.env
	local r = env.roblox
	local root = folder(ctx, "EconomyProbeFollowers", defer)
	local leader = r.Instance.new("Part")
	leader.Name = "Leader"
	leader.Anchored = true
	leader.CFrame = r.CFrame.new(0, STAGING_Y, 0)
	leader.Parent = root
	local core = Followers.new({ formation = "grid", spacing = 3, distance = 5, columns = 2 })
	local handles = {}
	for index = 1, 3 do
		local part = r.Instance.new("Part")
		part.Name = "Follower" .. index
		part.Size = r.Vector3.new(1, 1, 1)
		part.CanCollide = false
		part.Position = r.Vector3.new(index * 8, STAGING_Y, 20)
		part.Parent = root
		local id = "f" .. index
		core:add(id, { x = part.Position.X, y = part.Position.Y, z = part.Position.Z })
		handles[id] = FollowersRoblox.attach(part, nil, env)
	end
	ctx.check(
		"constraints_created",
		handles.f1.align:IsA("AlignPosition") and handles.f1.orient:IsA("AlignOrientation"),
		{ align = handles.f1.align.ClassName, orient = handles.f1.orient.ClassName }
	)
	local runService = env.services.RunService
	local hasBind = pcall(function(): any
		return runService.BindToSimulation
	end) and runService.BindToSimulation ~= nil
	ctx.check("bind_to_simulation_present", true, { present = hasBind })
	local stop = FollowersRoblox.start(core, handles, function(): any
		return leader.CFrame
	end, env)
	defer(stop)
	env.wait(3)
	local leaderState = FollowersRoblox.leaderFrom(leader.CFrame)
	local targets = core:targets(leaderState)
	local worst = 0
	for id, handle in handles do
		local target = targets[id]
		local p = handle.part.Position
		local gap = math.sqrt((p.X - target.x) ^ 2 + (p.Y - target.y) ^ 2 + (p.Z - target.z) ^ 2)
		worst = math.max(worst, gap)
	end
	ctx.check("followers_reach_slots", worst < 1.5, { worstGap = math.floor(worst * 100) / 100 })
	leader.CFrame = r.CFrame.new(500, STAGING_Y, 0)
	env.wait(0.5)
	local jumped = handles.f1.part.Position
	ctx.check("far_leader_teleports", math.abs(jumped.X - 500) < 20, { x = math.floor(jumped.X) })
end)

probes.economy_outfits_apply = guarded(function(ctx: any, defer: Defer)
	local Outfits = ctx.kit("GameKit/Outfits")
	local OutfitsRoblox = ctx.kit("GameKit/OutfitsRoblox")
	local env = ctx.env
	local r = env.roblox
	local players = env.services.Players
	local root = folder(ctx, "EconomyProbeOutfits", defer)
	local base = OutfitsRoblox.toInstance(Outfits.toDescription({ scales = { height = 1 } }), env)
	local made, model = pcall(function(): any
		return players:CreateHumanoidModelFromDescription(base, r.Enum.HumanoidRigType.R15)
	end)
	ctx.check("rig_created", made, if made then nil else tostring(model))
	if not made then
		return
	end
	if model.PrimaryPart then
		model.PrimaryPart.Anchored = true
	end
	model:PivotTo(r.CFrame.new(0, STAGING_Y, 0))
	model.Parent = root
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	ctx.check("rig_has_humanoid", humanoid ~= nil)
	local outfit = {
		schema = "outfit/1",
		scales = { height = 1.05, width = 0.8, head = 0.95 },
		colors = { head = "#C08040", torso = { r = 10, g = 20, b = 30 } },
	}
	local ok, method, problems = OutfitsRoblox.apply(humanoid, outfit, nil, env)
	ctx.check("outfit_applied", ok, { method = method, problems = problems })
	local worn = OutfitsRoblox.read(humanoid)
	local scales = worn.scales or {}
	ctx.check(
		"scales_round_trip",
		math.abs((scales.height or 0) - 1.05) < 1e-3 and math.abs((scales.width or 0) - 0.8) < 1e-3,
		{ height = scales.height, width = scales.width }
	)
	local torso = (worn.colors or {}).torso or {}
	ctx.check("color_round_trip", torso.r == 10 and torso.g == 20 and torso.b == 30, torso)
	local refused = OutfitsRoblox.apply(humanoid, { scales = { height = 9 } }, nil, env)
	ctx.check("out_of_range_refused", refused == false)
end)

probes.economy_plots_claim_race = guarded(function(ctx: any)
	local Plots = ctx.kit("GameKit/Plots")
	local env = ctx.env
	local list = {}
	for index = 1, 4 do
		local x = (index - 1) * 100
		table.insert(list, {
			id = "plot_" .. index,
			bounds = { min = { x = x, y = 0, z = 0 }, max = { x = x + 80, y = 50, z = 80 } },
		})
	end
	local plots = Plots.new({ plots = list }, env)
	local results = {}
	for index = 1, 6 do
		env.defer(function()
			local ok, id = plots:claim("p" .. index, "plot_1")
			results[index] = if ok then id else "none:" .. tostring(id)
		end)
	end
	env.wait(0.2)
	ctx.check("all_claims_resolved", #results == 6, results)
	ctx.check(
		"claims_in_call_order",
		results[1] == "plot_1" and results[4] == "plot_4" and results[5] == "none:full",
		results
	)
	local owners, shared = {}, false
	for _, owner in plots:snapshot() do
		shared = shared or owners[owner] == true
		owners[owner] = true
	end
	ctx.check("no_plot_shared", not shared, plots:snapshot())
end)

probes.economy_trade_two_client = guarded(function(ctx: any)
	local ItemDefs = ctx.kit("GameKit/ItemDefs")
	local Inventory = ctx.kit("GameKit/Inventory")
	local Wallet = ctx.kit("GameKit/Wallet")
	local Trade = ctx.kit("GameKit/Trade")
	local env = ctx.env
	local players = env.services.Players:GetPlayers()
	local ready = ctx.check(
		"two_players",
		#players >= 2,
		{ count = #players, needs = "Server and Clients test mode with two clients" }
	)
	if not ready then
		return
	end
	local items =
		ItemDefs.registry({ { id = "material_a", kind = "material", stackable = true, maxStack = 50 } })
	local function party(player: any): any
		local key = tostring(player.UserId)
		local inventory = Inventory.new({ items = items, owner = key, capacity = 5 }, env)
		local wallet = Wallet.new({ currencies = { currency_a = {} }, player = key }, env)
		return { key = key, inventory = inventory, wallet = wallet }
	end
	local a, b = party(players[1]), party(players[2])
	a.inventory:add("material_a", 10)
	b.wallet:credit("currency_a", 40, "Gameplay")
	local book = Trade.book()
	local trade, busy =
		book:open({ id = "probe_trade", a = a, b = b, countdown = 1, currencies = { "currency_a" } }, env)
	ctx.check("book_opens", trade ~= nil, busy)
	if trade == nil then
		return
	end
	local _, second = book:open({ id = "probe_trade_2", a = b, b = a }, env)
	ctx.check("one_open_trade_per_player", second == "party_busy", second)
	trade:addStack("a", "material_a", 4)
	trade:setCurrency("b", "currency_a", 15)
	trade:accept("a", trade:revision())
	trade:accept("b", trade:revision())
	env.wait(1.1)
	trade:confirm("a")
	trade:confirm("b")
	ctx.check("trade_committed", trade:state() == "committed", trade:state())
	ctx.check(
		"items_and_currency_moved",
		a.inventory:count("material_a") == 6
			and b.inventory:count("material_a") == 4
			and a.wallet:balance("currency_a") == 15
			and b.wallet:balance("currency_a") == 25
	)
	local again, note = trade:commit()
	ctx.check(
		"double_commit_is_noop",
		again == true and note == "already_committed" and b.inventory:count("material_a") == 4,
		note
	)
end)

return probes
