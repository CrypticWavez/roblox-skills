--!strict
-- Unpublished neutral component fixture, never a game or purchasing surface.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
assert(game.GameId == 0 and game.PlaceId == 0, "Unpublished SETUP_ONLY fixture required")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local UI = require(game:GetService("ReplicatedStorage").Workbench.Creator.UI)
local stable, deadline = 0, os.clock() + 20
while stable < 4 and os.clock() < deadline do
	RunService.RenderStepped:Wait()
	local camera = workspace.CurrentCamera
	stable = if camera
			and camera.ViewportSize.X >= 240
			and camera.ViewportSize.Y >= 240
		then stable + 1
		else 0
end
assert(stable == 4, "stable diagnostic viewport missing")
local dictionary = table.clone(UI.defaults)
dictionary.entry = "Neutral inspection entry"
dictionary.longEntry = "A longer localized component title for small-screen inspection"
dictionary.description =
	"This is a neutral item-information component. Selection, scrolling, text wrapping and state changes are tool diagnostics. It grants nothing and starts no gameplay."
dictionary.offer = "Unconfigured neutral offer"
local priceCalls, settingsCalls, retries = 0, 0, 0
local function create()
	return UI.new(playerGui, {
		theme = "slate",
		universeId = 0,
		localeProvider = function(key)
			return dictionary[key]
		end,
		currentPriceProvider = function()
			priceCalls += 1
			error("Unconfigured fixture must not query current prices")
		end,
		onSettingsChanged = function()
			settingsCalls += 1
		end,
		onRetry = function()
			retries += 1
		end,
	})
end
local api = create()
local checks, states = {}, {}
local function check(name, passed)
	table.insert(checks, { name = name, passed = passed })
end
local function capture(name)
	for _ = 1, 4 do
		RunService.RenderStepped:Wait()
	end
	local report = api:audit()
	report.name = name
	table.insert(states, report)
end
api:setHud("ready", "SETUP_ONLY")
api:open()
capture("inventory_empty")
api:setInventory("loading", {})
capture("inventory_loading")
api:setInventory("error", {})
capture("inventory_error")
api:setInventory("ready", {
	{ id = "neutral_entry", labelKey = "entry", descriptionKey = "description", count = 2 },
	{ id = "long_entry", labelKey = "longEntry", descriptionKey = "description", count = 1 },
})
capture("inventory_ready_long_text")
check("inventory available without gameplay", api.view == "inventory")
api:setShop("ready", { { id = "unconfigured_offer", labelKey = "offer", kind = "pass", enabled = false } })
api:show("shop")
capture("shop_unavailable")
check("missing identities query no prices", priceCalls == 0)
api:show("settings")
api:setVolume(0.42)
api:setReducedMotion(true)
capture("settings")
check("settings notify bounded callbacks", settingsCalls == 2)
check(
	"settings volume and reduced motion",
	api:audit().settings.volume == 0.42 and api:audit().settings.reducedMotion == true
)
api:close()
capture("menu_closed")
check("close hides menu", api.panel.Visible == false)
api:destroy()
api:destroy()
check("idempotent scope cleanup", api.closed and api.root.Parent == nil)
check("closed scope rejects updates", not pcall(function()
	api:setVolume(0.5)
end))
api = create()
api:setInventory(
	"ready",
	{ { id = "neutral_entry", labelKey = "entry", descriptionKey = "description", count = 2 } }
)
api:open()
capture("recreated_ready")
local report = {
	mode = "SETUP_ONLY",
	method = "assisted_creator_UI_fixture",
	placeId = game.PlaceId,
	universeId = game.GameId,
	checks = checks,
	states = states,
	priceCalls = priceCalls,
	retries = retries,
	inputCoverage = "programmatic API checks only; native simulated and physical input require separate action traces",
	limits = {
		"Pure tests and native component state checks are separate.",
		"No purchases, audio hearing, live pricing or physical-device acceptance.",
	},
}
local evidence = Instance.new("StringValue")
evidence.Name = "WorkbenchCreatorUIEvidence"
evidence.Value = HttpService:JSONEncode(report)
evidence.Parent = player:WaitForChild("PlayerScripts")
script.Destroying:Connect(function()
	api:destroy()
end)
