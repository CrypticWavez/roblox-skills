--!strict
-- Studio RunScript entry for probe perf_capture (Diagnostics/PerfProbeRoblox, tier T3): reads the
-- Stats service, a bounded Workspace walk and, in a running session, Heartbeat step times into a
-- perf/1 table, printed as the detail of check perf1_valid. Run it with
--   python3 tools/studio_run.py --probe perf_capture --build
-- on the owner's PC (unpublished place only); reports/engine/perf_capture.json then holds the
-- numbers. The Stats member names are UNVERIFIED until this has run. Not run in this container.
local ReplicatedStorage = (game :: any):GetService("ReplicatedStorage")
local ServerScriptService = (game :: any):GetService("ServerScriptService")
local Workbench = ReplicatedStorage:WaitForChild("Workbench", 10)

local function kit(path: string): any
	local node = Workbench
	for _, part in string.split(path, "/") do
		node = node:WaitForChild(part, 10)
	end
	return (require :: any)(node)
end

local Probe = kit("GameKit/Probe")
local EnvRoblox = kit("GameKit/EnvRoblox")
local registry = (require :: any)(
	ServerScriptService:WaitForChild("KitFixtures", 10):WaitForChild("kitsmoke_probes", 10)
)

Probe.runAll(registry, { env = EnvRoblox.studio(), kit = kit, only = { "perf_capture" } })
