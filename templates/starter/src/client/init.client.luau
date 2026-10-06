--!strict
-- @tier T3
-- Client entry (StarterPlayerScripts.Client). Runs the client boot phases (Phases.luau) through
-- src/shared/Boot.luau, prints one BOOT_REPORT line and publishes progress for the loading screen
-- (src/first/Loading.client.luau) as LocalPlayer attributes: BootProgress (0-1) and BootState
-- ("booting", "ready" or "failed"), plus BootFailedPhase on failure.
-- Pending Studio evidence: release item S07 (ok=true in Play Solo and Server & Clients).
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Boot = require(Shared:WaitForChild("Boot"))
local Config = require(Shared:WaitForChild("Config"))
local KitLoader = require(Shared:WaitForChild("KitLoader"))
local Phases = require(script:WaitForChild("Phases"))

local function newScreenGui(name: string, parent: Instance): Instance
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.Parent = parent
	return gui
end

player:SetAttribute("BootState", "booting")
player:SetAttribute("BootProgress", 0)

local phases = Phases.client({
	config = Config,
	kitLoader = KitLoader,
	kitsRoot = ReplicatedStorage:FindFirstChild("Kits"),
	loader = require,
	replicatedStorage = ReplicatedStorage,
	playerGui = player:WaitForChild("PlayerGui"),
	systemReducedMotion = function()
		return GuiService.ReducedMotionEnabled
	end,
	newScreenGui = newScreenGui,
})

local done = 0
local report = Boot.run({
	side = "client",
	phases = phases,
	timeouts = Config.get("boot.timeouts", nil),
	context = { player = player },
	onPhase = function(_result)
		done += 1
		player:SetAttribute("BootProgress", done / #Boot.PHASES)
	end,
}, {
	clock = time,
	spawn = task.spawn,
	wait = task.wait,
	cancel = task.cancel,
})

print(Boot.line(report))
if not report.ok then
	player:SetAttribute("BootFailedPhase", report.failed)
	warn(`client boot stopped in phase {report.failed}: {report.reason}`)
end
player:SetAttribute("BootState", if report.ok then "ready" else "failed")
