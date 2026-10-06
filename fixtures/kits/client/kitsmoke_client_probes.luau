--!strict
-- G9b probe registry (prefixes kitsmoke_, perf_), client side of the kits diagnostic place. Run by
-- fixtures/kits/client/kitsmoke_Runner.client.luau in a play session (attribute
-- SETUP_ONLY_KitFixture = "kitsmoke"). No requires: modules come through ctx.kit.
local probes = {}

-- Client-side perf/1: render frame times and the scene triangle count only a client reports.
function probes.perf_capture_client(ctx: any)
	local PerfProbe = ctx.kit("Diagnostics/PerfProbe")
	local PerfProbeRoblox = ctx.kit("Diagnostics/PerfProbeRoblox")
	local stats = PerfProbeRoblox.capture(ctx.env, {
		deviceClass = "desktop",
		place = "kits-diagnostic-client",
		frames = 60,
		timeout = 5,
	})
	local problems = PerfProbe.validate(stats)
	ctx.check("perf1_valid", #problems == 0, if #problems > 0 then problems else stats)
	local counts = stats.counts or {}
	ctx.check("frames_sampled", stats.frame_ms ~= nil)
	ctx.check("triangles_read", counts.triangles ~= nil)
	ctx.check("client_side", ctx.env.place ~= nil and ctx.env.place.isClient == true)
end

return probes
