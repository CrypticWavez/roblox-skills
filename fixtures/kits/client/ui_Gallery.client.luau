--!strict
-- UIKit gallery fixture (G4). Does nothing unless Workspace attribute SETUP_ONLY_KitFixture is
-- "ui-gallery" on the unpublished diagnostic place built from fixtures/kits.project.json. Then
-- it mounts UIKit/Gallery/Browser in PlayerGui: every story (UI Labs (target) -> cleanup
-- signature) with light theme, reduced motion, pseudo-loc and phone/desktop/console previews,
-- and audits each story it shows (AuditRoblox: real layout, TextFits under pseudo-loc, legacy
-- fonts), printing one UIKIT_AUDIT line per story to Output. Neutral: function-named
-- components and kit strings only; nothing here is game UI. For eyeballing and screenshots
-- (skill visual-qa); the pass/fail record is probe ui_gallery_audit.
local Players = (game :: any):GetService("Players")
local ReplicatedStorage = (game :: any):GetService("ReplicatedStorage")
local Workspace = (game :: any):GetService("Workspace")

if Workspace:GetAttribute("SETUP_ONLY_KitFixture") ~= "ui-gallery" then
	return
end

local workbench = ReplicatedStorage:WaitForChild("Workbench", 10)
local function kit(path: string): any
	local node = workbench
	for _, part in string.split(path, "/") do
		node = node:WaitForChild(part, 10)
	end
	return (require :: any)(node)
end

local AuditRoblox = kit("UIKit/AuditRoblox")
local Browser = kit("UIKit/Gallery/Browser")
local Build = kit("UIKit/Build")
local EnvRoblox = kit("GameKit/EnvRoblox")
local Localize = kit("UIKit/Localize")
local Json = kit("GameKit/Json")

local env = EnvRoblox.studio()
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local chrome = Build.context({ env = env, class = Browser.class("desktop") })
local chromeClock = chrome.runner:attach(env)
local gui = Build.screenGui(chrome, "SETUP_ONLY_UIKitGallery", "panel")

-- Each settings change gets a fresh context with its own runner on PreRender.
local function context(settings: any): (any, () -> ())
	local ctx = Build.context({
		env = env,
		theme = settings.theme,
		class = Browser.class(settings.device),
		motion = { reducedMotion = settings.reducedMotion },
		text = Localize.new({ pseudo = settings.pseudo }):fn(),
	})
	local clock = ctx.runner:attach(env)
	return ctx, function()
		clock:Disconnect()
	end
end

local auditing = 0
local browser = Browser.mount(gui, {
	chrome = chrome,
	context = context,
	initial = "Button",
	onSelected = function(name: string, stage: any, ctx: any)
		auditing += 1
		local run = auditing
		env.spawn(function()
			env.wait(0.5) -- let enter transitions settle
			if run ~= auditing or stage.Parent == nil then
				return
			end
			local ok, report = pcall(AuditRoblox.audit, stage, env, { class = ctx.class })
			if ok then
				print("UIKIT_AUDIT " .. Json.encode({ story = name, ok = report.ok, counts = report.counts }))
			else
				warn("UIKIT_AUDIT " .. name .. " failed: " .. tostring(report))
			end
		end)
	end,
})
gui.Parent = playerGui

script.Destroying:Connect(function()
	browser:destroy()
	chromeClock:Disconnect()
	gui:Destroy()
end)
