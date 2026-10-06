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

return probes
