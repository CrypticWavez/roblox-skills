--!strict
-- SETUP_ONLY. Neutral API/control fixture in an explicitly selected unpublished place.
local RunService = game:GetService("RunService")
if not RunService:IsStudio() or game.GameId ~= 0 then
	warn("Workbench diagnostic refused: requires unpublished Studio place")
	return
end
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local SoundService = game:GetService("SoundService")
local root = game:GetService("ReplicatedStorage"):WaitForChild("Workbench"):WaitForChild("Runtime")
local UI = require(root.NativeUI)
local Audio = require(root.NativeAudio)
local Mixer = require(root.AudioMixer)
local Motion = require(root.Motion)
local Lifetime = require(root.Lifetime)
local Effects = require(root.NativeEffects)
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
-- Studio may report a 1x1 camera during startup. Require a stable real viewport
-- before creating/focusing UI or collecting any layout evidence.
local deadline, stableFrames, previousViewport = os.clock() + 20, 0, Vector2.zero
while stableFrames < 4 and os.clock() < deadline do
	RunService.PreRender:Wait()
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.zero
	if game:IsLoaded() and viewport.X >= 320 and viewport.Y >= 240 and viewport == previousViewport then
		stableFrames += 1
	else
		stableFrames = 0
	end
	previousViewport = viewport
end
if stableFrames < 4 then
	warn("WORKBENCH_RUNTIME_BLOCKED: viewport did not stabilize within 20 seconds")
	return
end
local evidence = Instance.new("StringValue")
-- PlayerGui siblings can be removed on initial spawn. PlayerScripts survives it.
evidence.Name, evidence.Parent = "WorkbenchRuntimeEvidence", Players.LocalPlayer:WaitForChild("PlayerScripts")
local owned = Instance.new("Folder")
owned.Name, owned.Parent = "WorkbenchRuntimeFixture", workspace
local report = {
	mode = "SETUP_ONLY",
	status = "running",
	method = "assisted_native_diagnostic",
	placeId = game.PlaceId,
	universeId = game.GameId,
	inputCoverage = "programmatic activation only; physical keyboard touch controller unverified",
	audioHearing = "NOT_VERIFIED",
	checks = {},
	motionSamples = {},
}
local function check(name, condition)
	table.insert(report.checks, { name = name, passed = condition == true })
end
local currentTheme = "slate"
local panel = UI.panel(playerGui, {
	title = "PRODUCTION WORKBENCH / UI DIAGNOSTIC",
	actionText = "Switch theme",
	onActivated = function(self)
		currentTheme = if currentTheme == "slate" then "daylight" else "slate"
		self:setTheme(currentTheme)
	end,
	onCardActivated = function(id, self)
		self:setState("ready", "Selected diagnostic state: " .. tostring(id))
	end,
})
panel:setCards({
	{ id = "loading", label = "LOADING\nBounded transition" },
	{ id = "ready", label = "READY\nKeyboard · Touch · Controller" },
	{ id = "empty", label = "EMPTY\nClear recovery guidance" },
	{ id = "error", label = "ERROR\nRetry without duplicate action" },
	{ id = "localized", label = "LOCALIZATION\nÜberprüfung · 日本語 · العربية" },
	{ id = "disabled", label = "DISABLED\nUnavailable action", disabled = true },
})
check("loading blocks activation", panel:activate() == false)
for _, state in { "loading", "empty", "disabled" } do
	panel:setState(state)
	check(state .. " is noninteractive", panel.primary.Active == false)
end
panel:setState("error")
check("error permits retry", panel.primary.Active)
panel:setState(
	"ready",
	"Native components, safe insets, responsive cards and explicit states. This is a tool fixture, not a game."
)
panel:activate()
check("activation invokes callback", panel.activations == 1 and currentTheme == "daylight")
panel:setTheme("slate")
currentTheme = "slate"
for _ = 1, 4 do
	RunService.PreRender:Wait()
end
check("focus after stable layout", panel:focus())

local mixer = Mixer.new({ "music", "effects", "interface" })
local audio = Audio.new(mixer, { "music", "effects", "interface" }, SoundService)
local silent = Instance.new("Sound")
silent.Name, silent.Parent = "UnconfiguredPermissionDiagnostic", owned
audio:register(silent, "interface")
mixer:setVolume("music", 0.8)
mixer:duck("music", 0.25, 0.5)
audio:step(0)
check("native SoundGroup receives ducked volume", math.abs(audio.groups.music.Volume - 0.2) < 0.001)
audio:step(1)
check("native SoundGroup restores volume", math.abs(audio.groups.music.Volume - 0.8) < 0.001)
report.audio = audio:inspect()

local lifetime = Lifetime.new(8)
local effects = Effects.new(lifetime, owned, false)
local _, marker = effects:marker(Vector3.new(0, 5, 0), 1, Color3.fromRGB(101, 156, 199), 1.2, 5)
local motion = Motion.transition(0, 1)
motion:set(4, false)
local started, elapsed = os.clock(), 0
local connection
connection = RunService.Heartbeat:Connect(function(dt)
	elapsed += dt
	lifetime:step(dt)
	local x = motion:step(dt)
	if marker.Parent then
		marker.Position = Vector3.new(x, 5, 0)
	end
	if #report.motionSamples < 180 then
		table.insert(report.motionSamples, {
			time = os.clock() - started,
			dt = dt,
			position = { x, 5, 0 },
			velocity = if elapsed > 1 then 0 else nil,
		})
	end
	if elapsed >= 1.5 then
		connection:Disconnect()
		check("effect lifetime removes marker", lifetime:count() == 0 and marker.Parent == nil)
		check("motion reaches endpoint", math.abs(motion.value - 4) < 0.001)
		motion:set(2, true)
		check("reduced motion snaps endpoint", motion.value == 2)
		report.ui = panel:inspect()
		report.viewport = {
			width = workspace.CurrentCamera.ViewportSize.X,
			height = workspace.CurrentCamera.ViewportSize.Y,
		}
		report.status = "partially_verified"
		report.limitations = {
			"Scripted part motion is not an Animator or locomotion test",
			"No uploaded/permissioned audio was played",
			"Device emulation and programmatic activation do not verify physical devices",
			"No aesthetic or game quality acceptance",
		}
		evidence.Value = HttpService:JSONEncode(report)
		print("WORKBENCH_RUNTIME_DIAGNOSTIC " .. evidence.Value)
		audio:destroy()
		effects:destroy()
		owned:Destroy()
	end
end)
