--!strict
-- Stage 0 probe registry (prefix foundation_). foundation_env_studio checks the Env a runner
-- passes as ctx.env: in Studio that is GameKit/EnvRoblox.studio() (tier T3 until this probe
-- has run in a play session on the unpublished diagnostic place); in Lune it is FakeEnv
-- (tests/gamekit_foundation.spec.luau). No requires: kit modules come through ctx.kit.
local probes = {}

function probes.foundation_env_studio(ctx: any)
	local Env = ctx.kit("GameKit/Env")
	local Signal = ctx.kit("GameKit/Signal")
	local Rng = ctx.kit("ProcGen/Rng")
	local env = ctx.env

	local problems = Env.validate(env)
	ctx.check("env_valid", #problems == 0, problems)
	local placeOk, reason = Env.check(env.place)
	ctx.check("place_is_diagnostic", placeOk, { reason = reason, place = env.place })
	ctx.check("services_lookup", env.services.RunService ~= nil, "env.services.RunService")

	local spawned = false
	env.spawn(function()
		spawned = true
	end)
	ctx.check("spawn_runs_now", spawned)

	local order = {}
	env.defer(function()
		table.insert(order, "deferred")
	end)
	table.insert(order, "sync")
	local signal = Signal.new(env)
	local fired = 0
	signal:Connect(function()
		fired += 1
	end)
	signal:FireDeferred()
	ctx.check("fire_deferred_waits", fired == 0, fired)

	local before = env.clock()
	local waited = env.wait(0.1)
	local after = env.clock()
	ctx.check("clock_advances", after > before, { before = before, after = after, waited = waited })
	ctx.check("defer_after_sync", order[1] == "sync" and order[2] == "deferred", order)
	ctx.check("fire_deferred_ran", fired == 1, fired)

	local seeded = env.rng(7)
	ctx.check("rng_seeded", seeded:nextUInt() == Rng.new(7):nextUInt())
	local unseeded = env.rng()
	ctx.check("rng_unseeded", type(unseeded:next()) == "number")
end

return probes
