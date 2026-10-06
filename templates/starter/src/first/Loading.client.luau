--!strict
-- @tier T3
-- Loading screen (ReplicatedFirst.Loading). Replaces the default loading screen with a neutral one:
-- a status line and a progress bar driven by the client boot's LocalPlayer attributes (BootProgress,
-- BootState, BootFailedPhase; src/client/init.client.luau). On failure it stays up and names the phase;
-- when loading is slow it says so. No art, branding or game text: the strings are localisation keys
-- (src/localization/strings.csv) with their source text as the fallback. Respects reduced motion.
-- Self-contained on purpose: ReplicatedFirst runs before ReplicatedStorage has replicated.
local GuiService = game:GetService("GuiService")
local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

local SLOW_AFTER = 30 -- seconds before the "still loading" line (convention; Config.loading.timeoutSeconds)
local SOURCE = {
	["loading.status"] = "Loading",
	["loading.slow"] = "Still loading",
	["loading.failed"] = "Loading failed ({phase}). Please rejoin.",
}

local player = Players.LocalPlayer
local translator: any = nil
task.spawn(function()
	local ok, result = pcall(LocalizationService.GetTranslatorForPlayerAsync, LocalizationService, player)
	if ok then
		translator = result
	end
end)

local function formatByKey(key: string, args: { [string]: string }?): string
	if translator ~= nil then
		local ok, text = pcall(translator.FormatByKey, translator, key, args)
		if ok and type(text) == "string" then
			return text
		end
	end
	local text = SOURCE[key] or key
	for name, value in args or {} do
		text = string.gsub(text, "{" .. name .. "}", value)
	end
	return text
end

ReplicatedFirst:RemoveDefaultLoadingScreen()

local gui = Instance.new("ScreenGui")
gui.Name = "Loading"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000

local backdrop = Instance.new("Frame")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
backdrop.BorderSizePixel = 0
backdrop.Parent = gui

local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(0.5, 0.5)
status.Position = UDim2.fromScale(0.5, 0.5)
status.Size = UDim2.new(0.8, 0, 0, 32)
status.BackgroundTransparency = 1
status.FontFace = Font.fromEnum(Enum.Font.BuilderSans)
status.TextScaled = true
status.TextColor3 = Color3.fromRGB(235, 235, 240)
status.AutoLocalize = false -- formatByKey already localises
status.Text = formatByKey("loading.status")
status.Parent = backdrop

local track = Instance.new("Frame")
track.Name = "Track"
track.AnchorPoint = Vector2.new(0.5, 0)
track.Position = UDim2.new(0.5, 0, 0.5, 28)
track.Size = UDim2.new(0.4, 0, 0, 6)
track.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
track.BorderSizePixel = 0
track.Parent = backdrop

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = Color3.fromRGB(235, 235, 240)
fill.BorderSizePixel = 0
fill.Parent = track

gui.Parent = player:WaitForChild("PlayerGui")

local function setProgress(value: number)
	local goal = UDim2.fromScale(math.clamp(value, 0, 1), 1)
	if GuiService.ReducedMotionEnabled then
		fill.Size = goal
	else
		TweenService:Create(fill, TweenInfo.new(0.2), { Size = goal }):Play()
	end
end

local started = time()
local finished = false
local function refresh()
	local state = player:GetAttribute("BootState")
	setProgress(tonumber(player:GetAttribute("BootProgress")) or 0)
	if state == "failed" then
		finished = true
		local phase = tostring(player:GetAttribute("BootFailedPhase") or "?")
		status.Text = formatByKey("loading.failed", { phase = phase })
	elseif state == "ready" and game:IsLoaded() then
		finished = true
		gui:Destroy()
	end
end

player:GetAttributeChangedSignal("BootProgress"):Connect(refresh)
player:GetAttributeChangedSignal("BootState"):Connect(refresh)
if not game:IsLoaded() then
	game.Loaded:Wait()
end
refresh()
while not finished do
	task.wait(1)
	if not finished and time() - started > SLOW_AFTER then
		status.Text = formatByKey("loading.slow")
	end
end
