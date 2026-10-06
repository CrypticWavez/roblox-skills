--!strict
-- G1 platform probe registry (prefix platform_), a server ModuleScript in the kits place
-- (ServerScriptService.KitFixtures). Run each probe in a play session on the unpublished
-- diagnostic place through its tests/engine/platform_*.luau entry; they stay pending until the
-- owner's run prints ENGINE_DONE. No requires: modules come from ctx.kit, services from
-- ctx.env.services, datatypes from ctx.env.roblox. tests/gamekit_platform_probes.spec.luau runs
-- this registry in Lune against fakes, which proves it loads and its logic holds, not Studio.
-- Every probe refuses to run outside the diagnostic place (Env.check) and cleans up what it made.
local probes = {}

local function diagnostic(ctx: any): boolean
	local Env = ctx.kit("GameKit/Env")
	local ok, reason = Env.check(ctx.env.place)
	ctx.check("place_is_diagnostic", ok, { reason = reason })
	return ok
end

local function firstPlayer(ctx: any): any
	local players = ctx.env.services.Players
	local player = players and players:GetPlayers()[1]
	ctx.check("player_present", player ~= nil, "start a play session (Play or Server & Clients) first")
	return player
end

-- RemoteGuardRoblox on real remotes: build, bind, a 1000-call flood through the bound handler,
-- a NaN vector, extra arguments, an unguarded remote refused, unbind and cleanup.
function probes.platform_remoteguard_flood(ctx: any)
	if not diagnostic(ctx) then
		return
	end
	local player = firstPlayer(ctx)
	if player == nil then
		return
	end
	local RemoteGuard = ctx.kit("GameKit/RemoteGuard")
	local RemoteGuardRoblox = ctx.kit("GameKit/RemoteGuardRoblox")
	local Schema = ctx.kit("GameKit/Schema")
	local env = ctx.env
	local roblox = env.roblox
	local guard = RemoteGuard.new({
		schemas = {
			probe_flood = {
				kind = "event",
				args = { Schema.vector3({ maxMagnitude = 1000 }) },
				rate = { capacity = 10, refillPerSec = 0 },
			},
			probe_unreliable = { kind = "unreliable", args = { Schema.number({ min = 0, max = 1 }) } },
			probe_invoke = { kind = "function", args = { Schema.string({ maxLen = 16 }) } },
		},
	}, env)
	local folder = roblox.Instance.new("Folder")
	folder.Name = "PlatformProbeRemotes"
	folder.Parent = env.services.ReplicatedStorage
	local ok, err = pcall(function()
		local created = RemoteGuardRoblox.build(folder, guard, roblox)
		ctx.check("remotes_built", #created == 3, created)
		ctx.check(
			"remote_classes",
			folder:FindFirstChild("probe_unreliable"):IsA("UnreliableRemoteEvent")
				and folder:FindFirstChild("probe_invoke"):IsA("RemoteFunction")
		)
		local received = 0
		local binding = RemoteGuardRoblox.bind(folder, guard, {
			probe_flood = function()
				received += 1
			end,
			probe_unreliable = function() end,
			probe_invoke = function(_player: any, text: string): string
				return string.upper(text)
			end,
		}, { players = env.services.Players })
		local vector = roblox.Vector3.new(1, 2, 3)
		for _ = 1, 1000 do
			binding.handlers.probe_flood(player, vector)
		end
		ctx.check("flood_accepts_capacity", received == 10, { received = received })
		local stats = guard:stats(player)
		ctx.check("flood_rejects_by_rate", (stats.reasons.rate or 0) == 990, stats.reasons)
		local nanOk, nanReason = guard:check("probe_unreliable", player, 0 / 0)
		ctx.check("nan_rejected", nanOk == false and nanReason == "schema", nanReason)
		local extraOk, extraReason = guard:check("probe_unreliable", player, 0.5, "extra")
		ctx.check("extra_args_rejected", extraOk == false and extraReason == "arity", extraReason)
		ctx.check("invoke_returns", binding.handlers.probe_invoke(player, "ok") == "OK")
		ctx.check(
			"invoke_reject_returns_nil",
			binding.handlers.probe_invoke(player, string.rep("x", 17)) == nil
		)
		binding.unbind()
		local stray = roblox.Instance.new("RemoteEvent")
		stray.Name = "probe_unguarded"
		stray.Parent = folder
		local refused = not pcall(RemoteGuardRoblox.bind, folder, guard, {})
		ctx.check("unguarded_remote_refused", refused)
	end)
	folder:Destroy()
	if not ok then
		error(err, 0)
	end
end

-- PlayerData on the real task scheduler with the memory backend (never DataStores): a v1 to v2
-- migration, an update, a second server refused while the session is held, a durable save, the
-- autosave scheduler, a receipt granted once, release and re-load on the other server, then
-- PlayerDataRoblox.bind loading the play session's player and the BindToClose-style flush.
function probes.platform_playerdata_memory(ctx: any)
	if not diagnostic(ctx) then
		return
	end
	local player = firstPlayer(ctx)
	if player == nil then
		return
	end
	local PlayerData = ctx.kit("GameKit/PlayerData")
	local PlayerDataRoblox = ctx.kit("GameKit/PlayerDataRoblox")
	local env = ctx.env
	-- PlayerData.MemoryShared: stored documents and session locks by key ("player_<userId>").
	local shared: { values: { [string]: any }, locks: { [string]: string } } = { values = {}, locks = {} }
	local function options(serverId: string, sharedStore: any): any
		return {
			template = { visits = 0, flags = {} },
			version = 2,
			migrations = {
				[1] = function(data: any): any
					data.visits = data.count
					data.count = nil
					return data
				end,
			},
			backend = PlayerData.memoryBackend({ serverId = serverId, shared = sharedStore }),
			autosave = { interval = 1, jitter = 0, seed = 1 },
		}
	end
	local storeA = PlayerData.new(options("probe_a", shared), env)
	local storeB = PlayerData.new(options("probe_b", shared), env)
	local userId = 1 -- a synthetic user for the core checks; the real player is used by bind below
	shared.values.player_1 = { schemaVersion = 1, count = 4 }

	local session, reason = storeA:load(userId)
	ctx.check(
		"load_migrates_v1",
		session ~= nil
			and session:get("visits") == 4
			and session:get("count") == nil
			and session:get("schemaVersion") == 2,
		reason
	)
	if session == nil then
		return
	end
	ctx.check("update_commits", session:update(function(data: any)
		data.visits += 1
		return nil
	end) and session:get("visits") == 5)
	local _, conflict = storeB:load(userId)
	ctx.check("second_server_locked", conflict == "locked", conflict)
	local saved = session:saveAsync()
	ctx.check("save_durable", saved and shared.values.player_1.visits == 5)
	env.wait(1.5)
	local due = storeA:tick()
	ctx.check("autosave_due", #due == 1 and due[1] == userId, due)
	local first = session:grantReceipt("probe_receipt_1", function(data: any)
		data.visits += 10
		return nil
	end)
	local again = session:grantReceipt("probe_receipt_1", function(data: any)
		data.visits += 10
		return nil
	end)
	ctx.check(
		"receipt_granted_once",
		first == "granted" and again == "granted" and session:get("visits") == 15,
		{ first = first, again = again, visits = session:get("visits") }
	)
	ctx.check("release_unlocks", session:release() and shared.locks.player_1 == nil)
	local other = storeB:load(userId)
	ctx.check("other_server_loads_after_release", other ~= nil and other:get("visits") == 15)
	if other then
		other:release()
	end

	local storeC = PlayerData.new(options("probe_c", { values = {}, locks = {} }), env)
	local binding = PlayerDataRoblox.bind(
		storeC,
		{ players = env.services.Players, bindToClose = false, kickOnFailure = false, autosaveStep = 0.5 },
		env
	)
	local bound = binding:waitForSession(player, 5)
	ctx.check("bind_loads_player", bound ~= nil and bound.userId == player.UserId)
	binding:unbind()
	local summary = storeC:releaseAll({ deadline = 5 })
	ctx.check(
		"release_all_flushes",
		#summary.released == 1 and #summary.failed == 0 and #summary.timedOut == 0,
		summary
	)
	local _, closed = storeC:load(player.UserId)
	ctx.check("closed_store_refuses_loads", closed == "closed", closed)
end

-- Telemetry through the Studio recorder: one event of each category for the play session's
-- player, TELEMETRY_JSON lines stamped synthetic, order and limit rejects, the AnalyticsService
-- argument mapping with the engine's Enum, and forPlace choosing the recorder in Studio. Never
-- calls AnalyticsService (Studio cannot send; live sending is the owner's published-game step).
function probes.platform_telemetry_recorder(ctx: any)
	if not diagnostic(ctx) then
		return
	end
	local player = firstPlayer(ctx)
	if player == nil then
		return
	end
	local Events = ctx.kit("GameKit/Events")
	local Telemetry = ctx.kit("GameKit/Telemetry")
	local TelemetryRoblox = ctx.kit("GameKit/TelemetryRoblox")
	local env = ctx.env
	local lines = {}
	local sink = TelemetryRoblox.recorder(function(line: string)
		table.insert(lines, line)
	end)
	local telemetry = Telemetry.new({
		sink = sink,
		budget = false,
		envelope = { synthetic = true, environment = "studio" },
		catalog = {
			custom = { probe_custom = { fields = { "slot" } } },
			onboarding = { "probe_start", "probe_done" },
			funnels = { probe_funnel = { steps = { "probe_a", "probe_b" } } },
			economy = { currencies = { "currency_a" } },
			progression = { probe_path = true },
		},
	}, env)
	ctx.check("custom", telemetry:custom(player, "probe_custom", 1, { slot = "a" }))
	ctx.check("economy", telemetry:economy(player, "source", "currency_a", 5, 5, "Gameplay"))
	ctx.check("progression", telemetry:progression(player, "probe_path", "complete", 1))
	local session = telemetry:funnelStart(player, "probe_funnel")
	ctx.check("funnel", session ~= nil and telemetry:funnelStep(player, "probe_funnel", session, "probe_b"))
	ctx.check(
		"onboarding",
		telemetry:onboarding(player, "probe_start") and telemetry:onboarding(player, "probe_done")
	)
	ctx.check("purchase_intent", telemetry:purchase(player, "offer_viewed", "product_a", "devproduct"))
	local prefixed = #lines == 8
	for _, line in lines do
		prefixed = prefixed
			and string.sub(line, 1, #TelemetryRoblox.PREFIX) == TelemetryRoblox.PREFIX
			and string.find(line, '"synthetic":true', 1, true) ~= nil
			and string.find(line, '"environment":"studio"', 1, true) ~= nil
	end
	ctx.check("recorder_lines", prefixed, { lines = #lines })
	local _, repeatReason = telemetry:onboarding(player, "probe_start")
	ctx.check("onboarding_order_enforced", repeatReason == "onboarding_out_of_order", repeatReason)
	local _, fieldReason =
		telemetry:custom(player, "probe_custom", nil, { a = "1", b = "2", c = "3", d = "4" })
	ctx.check("field_limit_enforced", fieldReason == "invalid", fieldReason)
	local Enum = env.roblox.Enum
	local method, args = TelemetryRoblox.toCall(
		Events.economy(
			"x",
			{ flow = "source", currency = "currency_a", amount = 1, balance = 1, transaction_type = "Shop" }
		),
		{ enums = Enum, player = player }
	)
	ctx.check(
		"economy_mapping",
		method == "LogEconomyEvent" and args[2] == Enum.AnalyticsEconomyFlowType.Source and args[6] == "Shop"
	)
	local progressionMethod, progressionArgs = TelemetryRoblox.toCall(
		Events.progression("x", { path = "probe_path", status = "fail", level = 2 }),
		{ enums = Enum, player = player }
	)
	ctx.check(
		"progression_mapping",
		progressionMethod == "LogProgressionEvent"
			and progressionArgs[3] == Enum.AnalyticsProgressionType.Fail
	)
	local fields = TelemetryRoblox.customFields({ slot = "a" }, nil, Enum)
	ctx.check(
		"custom_field_key",
		fields ~= nil and fields[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] == "a"
	)
	local placeSink, envelope = TelemetryRoblox.forPlace(env, { print = function() end })
	ctx.check("for_place_studio_recorder", placeSink.kind == "recorder" and envelope.synthetic == true)
end

-- PolicyGate against the real PolicyService for the play session's player. Run it once per
-- Player Emulator region (Test > Player Emulator > Enable Test Profile) and compare the logged
-- matrices: the gate must agree with the emulated info field by field, never allow external or
-- social links, and fail closed when the fetch fails.
function probes.platform_policy_emulator(ctx: any)
	if not diagnostic(ctx) then
		return
	end
	local player = firstPlayer(ctx)
	if player == nil then
		return
	end
	local PolicyGate = ctx.kit("GameKit/PolicyGate")
	local PolicyGateRoblox = ctx.kit("GameKit/PolicyGateRoblox")
	local env = ctx.env
	local fetch = PolicyGateRoblox.fetcher(env.services.PolicyService, {
		voiceChatService = env.services.VoiceChatService,
	})
	local read, info = pcall(fetch, player)
	ctx.check("policy_info_read", read and type(info) == "table", if read then nil else tostring(info))
	if not read then
		return
	end
	local typed = true
	for _, field in PolicyGateRoblox.FIELDS do
		typed = typed and type(info[field]) == "boolean"
	end
	ctx.check("policy_fields_boolean", typed, info)
	local gate = PolicyGate.new({ fetch = fetch, retry = { attempts = 2, base = 0.1 } }, env)
	ctx.check("gate_loaded", gate:load(player))
	local agrees = true
	local matrix = {}
	for _, feature in PolicyGate.FEATURES do
		local allowed = gate:allows(player, feature)
		matrix[feature] = allowed
		agrees = agrees and allowed == (PolicyGate.evaluate(info, feature))
	end
	ctx.check("gate_matches_info", agrees, matrix)
	ctx.check(
		"links_never_allowed",
		not gate:allows(player, "externalLinks") and not gate:allows(player, "socialLinks")
	)
	ctx.check("unknown_feature_denied", not gate:allows(player, "probe_unknown_feature"))
	local failing = PolicyGate.new({
		fetch = function(): any
			error("probe: forced failure")
		end,
		retry = { attempts = 1 },
	}, env)
	local loaded = failing:load(player)
	local anyAllowed = false
	for _, feature in PolicyGate.FEATURES do
		anyAllowed = anyAllowed or failing:allows(player, feature)
	end
	ctx.check("fails_closed", not loaded and not anyAllowed)
	local bound = PolicyGate.new({ fetch = fetch, retry = { attempts = 2, base = 0.1 } }, env)
	local disconnect = PolicyGateRoblox.bind(bound, env.services.Players, env)
	local deadline = env.clock() + 10
	while bound:info(player) == nil and env.clock() < deadline do
		env.wait(0.1)
	end
	disconnect()
	ctx.check("bind_loads_present_player", bound:info(player) ~= nil)
end

-- PartyRoblox against the Party Simulator (Studio beta): start Server & Clients with at least two
-- clients and put them in one simulated party first. Checks PartyId values, that
-- GetPlayersByPartyId agrees with the PartyIds, that GetPartyAsync lists the local members (its
-- support in the simulator is UNVERIFIED: this check is the evidence either way), and that a
-- party ticket is accepted by GameKit/Queue.
function probes.platform_party_simulator(ctx: any)
	if not diagnostic(ctx) then
		return
	end
	local player = firstPlayer(ctx)
	if player == nil then
		return
	end
	local PartyRoblox = ctx.kit("GameKit/PartyRoblox")
	local Queue = ctx.kit("GameKit/Queue")
	local env = ctx.env
	local social = env.services.SocialService
	local players = env.services.Players:GetPlayers()
	local parties: { [string]: { number } } = {}
	local typed = true
	for _, member in players do
		typed = typed and type(member.PartyId) == "string"
		local id = PartyRoblox.partyId(member)
		if id ~= nil then
			parties[id] = parties[id] or {}
			table.insert(parties[id], member.UserId)
		end
	end
	ctx.check("party_ids_are_strings", typed)
	local partyId = next(parties)
	ctx.check(
		"simulated_party_present",
		partyId ~= nil,
		"put two or more clients in one party in the Party Simulator, then run again"
	)
	if partyId == nil then
		return
	end
	local expected = parties[partyId]
	table.sort(expected)
	local here = {}
	for _, member in PartyRoblox.membersHere(social, partyId) do
		table.insert(here, member.UserId)
	end
	ctx.check("members_here_match_party_ids", table.concat(here, ",") == table.concat(expected, ","), {
		here = here,
		expected = expected,
	})
	local ok, members = PartyRoblox.members(social, partyId, env)
	local listed = {}
	if ok then
		for _, member in members do
			listed[member.userId] = true
		end
	end
	local all = ok
	for _, userId in expected do
		all = all and listed[userId] == true
	end
	ctx.check("party_async_lists_local_members", all, if ok then members else tostring(members))
	local leader = env.services.Players:GetPlayerByUserId(expected[1])
	local ticket = PartyRoblox.ticket(social, leader, { at = env.clock() })
	ctx.check("ticket_holds_party", #ticket.players == #expected and ticket.id == "party:" .. partyId, ticket)
	local queue = Queue.new({ teams = 1, teamSize = math.max(#expected, 1), skill = false }, env)
	local added, why = queue:add(ticket)
	ctx.check("queue_accepts_party_ticket", added, why)
	local plan = queue:take(env.clock())
	ctx.check("party_forms_one_match", #plan.matches == 1 and plan.matches[1].players == #expected, plan)
end

return probes
