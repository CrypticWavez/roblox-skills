--!strict
-- @tier T3
-- Server entry (ServerScriptService.Server). Builds the env from the engine globals, runs the server
-- boot phases (Phases.luau) through src/shared/Boot.luau and prints one BOOT_REPORT line. The
-- Workspace attribute ServerBootState ("ready" or "failed") tells clients and tests how it went.
-- Pending Studio evidence: release item S07 (ok=true in Play Solo and Server & Clients).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Boot = require(Shared:WaitForChild("Boot"))
local Config = require(Shared:WaitForChild("Config"))
local KitLoader = require(Shared:WaitForChild("KitLoader"))
local Phases = require(script:WaitForChild("Phases"))

local function newFolder(name: string, parent: Instance): Instance
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local phases = Phases.server({
	config = Config,
	kitLoader = KitLoader,
	kitsRoot = ReplicatedStorage:FindFirstChild("Kits"),
	loader = require,
	replicatedStorage = ReplicatedStorage,
	newFolder = newFolder,
})

local report = Boot.run({
	side = "server",
	phases = phases,
	timeouts = Config.get("boot.timeouts", nil),
	context = {},
}, {
	clock = time,
	spawn = task.spawn,
	wait = task.wait,
	cancel = task.cancel,
})

print(Boot.line(report))
workspace:SetAttribute("ServerBootState", if report.ok then "ready" else "failed")
if not report.ok then
	warn(`server boot stopped in phase {report.failed}: {report.reason}`)
end
