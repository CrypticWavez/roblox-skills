--!strict
-- G9b probe registry (prefixes kitsmoke_, perf_), server side of the kits diagnostic place.
-- No requires: kit and non-kit modules come through ctx.kit, the Env through ctx.env. Lune runs it
-- against fakes (tools/lune/kit_smoke.luau, tests/pipeline_kitsmoke.spec.luau, golden kit-smoke);
-- Studio runs it through tests/engine/kitsmoke_all.luau, tests/engine/perf_capture.luau or the
-- kitsmoke fixture runner. Details are counts and flags only: no paths, ids or raw error text.
local probes = {}

-- GameKit/DebugCommands is active on the unpublished diagnostic place and inert elsewhere.
function probes.kitsmoke_debug_commands(ctx: any)
	local DebugCommands = ctx.kit("GameKit/DebugCommands")
	local status = DebugCommands.status(ctx.env)
	ctx.check("active_on_diagnostic_place", status.active == true, status)
	local commands = DebugCommands.new(ctx.env)
	commands:register("kitsmoke_echo", {
		description = "Returns its argument (kit smoke).",
		args = { { name = "value", kind = "integer", min = 0, max = 10 } },
		run = function(_ctx: any, args: any): any
			return args.value
		end,
	})
	local ok, result = commands:run("kitsmoke_echo 7")
	ctx.check("runs_a_command", ok == true and result == 7, { ok = ok, result = result })
	local rejected, reason = commands:run("kitsmoke_echo 11")
	ctx.check("rejects_bad_args", rejected == false and reason == "bad_arg: value must be at most 10", reason)
	local published = DebugCommands.status({ place = { isStudio = true, gameId = 1, placeId = 1 } })
	ctx.check("inert_when_published", published.active == false, published)
end

-- The Creator inspectors share one target check (Studio, GameId 0, PlaceId 0) and now accept a
-- server session: new(nil) must fail on its options, not on the target.
function probes.kitsmoke_inspector_target(ctx: any)
	for _, case in
		{
			{ "Creator/Observation", "observation options need a stable id" },
			{ "Creator/AnimationInspector", "animation options required" },
			{ "Creator/WorldInspector", "world inspection options required" },
		}
	do
		local module = ctx.kit(case[1])
		local ok, err = pcall(module.new, nil)
		local message = tostring(err)
		local refused = string.find(message, "refused", 1, true) ~= nil
		local options = string.find(message, case[2], 1, true) ~= nil
		ctx.check(
			string.gsub(case[1], "^Creator/", "") .. "_target_accepted",
			not ok and options and not refused,
			{ refused = refused, reached_options_check = options }
		)
	end
end

-- Diagnostics/PerfProbeRoblox reads Stats, a world walk and (in a running session) Heartbeat into
-- perf/1. The perf/1 table is the detail of perf1_valid, so the engine report carries the numbers.
function probes.perf_capture(ctx: any)
	local PerfProbe = ctx.kit("Diagnostics/PerfProbe")
	local PerfProbeRoblox = ctx.kit("Diagnostics/PerfProbeRoblox")
	local runService = ctx.env.services.RunService
	local okRunning, running = pcall(function()
		return runService:IsRunning()
	end)
	local sampling = okRunning and running == true
	local stats = PerfProbeRoblox.capture(ctx.env, {
		deviceClass = "desktop",
		place = "kits-diagnostic",
		frames = if sampling then 30 else 0,
		timeout = 5,
	})
	local problems = PerfProbe.validate(stats)
	ctx.check("perf1_valid", #problems == 0, if #problems > 0 then problems else stats)
	local memory = stats.memory_mb or {}
	local counts = stats.counts or {}
	ctx.check("memory_total_read", memory.total ~= nil)
	ctx.check("instance_count_read", counts.instances ~= nil)
	ctx.check("world_walk_counted", counts.parts ~= nil)
	ctx.check("frame_timing", (stats.frame_ms ~= nil) == sampling, { running = sampling })
end

return probes
