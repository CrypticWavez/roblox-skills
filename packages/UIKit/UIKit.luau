--!strict
-- @tier T1
-- UIKit facade: one require for the whole kit (docs/uikit.md). Pure modules (tokens, style,
-- breakpoints, state, easing, transitions, navigation, localisation, audits, the component
-- contract and every component) plus the gallery stories and browser. The Roblox adapters (StyleRoblox,
-- AuditRoblox) are not loaded here; require them directly in client code. Typical start:
--   local UIKit = require(path.to.UIKit)
--   local ctx = UIKit.context({ env = EnvRoblox.studio(), class = UIKit.Breakpoints.classify(...) })
--   ctx.runner:attach(env)                    -- motion and timers on RunService.PreRender
--   local gui = UIKit.Build.screenGui(ctx, "Hud", "hud")
--   UIKit.Components.Button.mount({ textKey = "uikit.confirm", onActivated = fn }, ctx, gui)
local Audit = require("./Audit")
local Breakpoints = require("./Breakpoints")
local Browser = require("./Gallery/Browser")
local Build = require("./Build")
local Ease = require("./Ease")
local Localize = require("./Localize")
local Nav = require("./Nav")
local State = require("./State")
local Stories = require("./Gallery/Stories")
local Style = require("./Style")
local Tokens = require("./Tokens")
local Transitions = require("./Transitions")

local Components = {
	Badge = require("./Components/Badge"),
	Button = require("./Components/Button"),
	Card = require("./Components/Card"),
	ConfirmDialog = require("./Components/ConfirmDialog"),
	Countdown = require("./Components/Countdown"),
	DialogueBox = require("./Components/DialogueBox"),
	Grid = require("./Components/Grid"),
	IconButton = require("./Components/IconButton"),
	InventoryGrid = require("./Components/InventoryGrid"),
	KeybindPrompt = require("./Components/KeybindPrompt"),
	LeaderboardPanel = require("./Components/LeaderboardPanel"),
	LoadingScreen = require("./Components/LoadingScreen"),
	Modal = require("./Components/Modal"),
	OfferPopup = require("./Components/OfferPopup"),
	ProgressBar = require("./Components/ProgressBar"),
	RollingCounter = require("./Components/RollingCounter"),
	SettingsPanel = require("./Components/SettingsPanel"),
	ShopCard = require("./Components/ShopCard"),
	Slider = require("./Components/Slider"),
	StatBar = require("./Components/StatBar"),
	Tabs = require("./Components/Tabs"),
	TeleportTransition = require("./Components/TeleportTransition"),
	Timer = require("./Components/Timer"),
	Toast = require("./Components/Toast"),
	Toggle = require("./Components/Toggle"),
	Tooltip = require("./Components/Tooltip"),
	TouchActionButton = require("./Components/TouchActionButton"),
	VirtualList = require("./Components/VirtualList"),
}

local UIKit = {
	VERSION = "uikit/1",
	Audit = Audit,
	Breakpoints = Breakpoints,
	Browser = Browser,
	Build = Build,
	Components = table.freeze(Components),
	Ease = Ease,
	Localize = Localize,
	Nav = Nav,
	State = State,
	Stories = Stories,
	Style = Style,
	Tokens = Tokens,
	Transitions = Transitions,
	context = Build.context,
}

return table.freeze(UIKit)
