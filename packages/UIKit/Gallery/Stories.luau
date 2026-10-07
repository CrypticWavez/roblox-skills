--!strict
-- @tier T1
-- Stories: one story per UIKit component, for the gallery fixture (Gallery/Browser in
-- fixtures/kits/client/ui_Gallery.client.luau), the component spec and the Studio audit probe.
-- Stories.list(ctx) returns { { name, build } } where build(target) -> cleanup is the UI Labs function-story
-- signature: it mounts into target (a Frame or ScreenGui) and returns the function that
-- removes everything it made. Content is neutral: kit keys (uikit.*, settings.*, input.*),
-- placeholder names (Item, Player 1) and a setup-mode catalog whose products are disabled,
-- so no story designs production UI or shows a real product. ctx is a UIKit/Build context
-- (env, events, runner); stories use its class, so the same list previews phone, desktop
-- and console by building with another ctx.
local Build = require("../Build")
local Catalog = require("../../GameKit/Catalog")
local Settings = require("../../GameKit/Settings")

local Badge = require("../Components/Badge")
local Button = require("../Components/Button")
local Card = require("../Components/Card")
local ConfirmDialog = require("../Components/ConfirmDialog")
local Countdown = require("../Components/Countdown")
local DialogueBox = require("../Components/DialogueBox")
local Grid = require("../Components/Grid")
local IconButton = require("../Components/IconButton")
local InventoryGrid = require("../Components/InventoryGrid")
local KeybindPrompt = require("../Components/KeybindPrompt")
local LeaderboardPanel = require("../Components/LeaderboardPanel")
local LoadingScreen = require("../Components/LoadingScreen")
local Modal = require("../Components/Modal")
local OfferPopup = require("../Components/OfferPopup")
local ProgressBar = require("../Components/ProgressBar")
local RollingCounter = require("../Components/RollingCounter")
local SettingsPanel = require("../Components/SettingsPanel")
local ShopCard = require("../Components/ShopCard")
local Slider = require("../Components/Slider")
local StatBar = require("../Components/StatBar")
local Tabs = require("../Components/Tabs")
local TeleportTransition = require("../Components/TeleportTransition")
local Timer = require("../Components/Timer")
local Toast = require("../Components/Toast")
local Toggle = require("../Components/Toggle")
local Tooltip = require("../Components/Tooltip")
local TouchActionButton = require("../Components/TouchActionButton")
local VirtualList = require("../Components/VirtualList")

local Stories = {}

export type Story = { name: string, build: (target: any) -> () -> () }
-- An InventoryGrid slot (see its header): an item, or false for an empty slot.
type Slot = { key: string, glyph: string?, image: string?, count: number? } | false

-- The neutral setup-mode catalog the ShopCard story shows (placeholder id 0, disabled).
Stories.CATALOG = Catalog.define({
	schema = "catalog/1",
	mode = "setup",
	products = {
		{
			key = "sample_product",
			kind = "devproduct",
			id = 0,
			grants = { { type = "currency", currency = "sample_currency", amount = 1 } },
			display = { nameKey = "uikit.shop.unavailable" },
			enabled = false,
			ownershipVerified = false,
		},
	},
})

-- A vertical stack Frame inside target for stories that show several variants.
local function stack(ctx: Build.Context, target: any, name: string): any
	local r = ctx.env.roblox
	local frame = Build.frame(ctx, name, {
		Size = r.UDim2.fromScale(1, 0),
		AutomaticSize = r.Enum.AutomaticSize.Y,
	}, target)
	Build.list(ctx, frame, "Vertical", { gap = "sm" })
	return frame
end

-- A story that mounts a list of components (each { module, props }) into a stack.
local function many(ctx: Build.Context, name: string, items: { { any } }): Story
	return {
		name = name,
		build = function(target: any): () -> ()
			local scope = ctx.scope:Extend()
			local child = Build.with(ctx, { scope = scope })
			local frame = stack(ctx, target, name)
			scope:Add(frame)
			for index, item in items do
				local props = table.clone(item[2])
				props.layoutOrder = props.layoutOrder or index
				item[1].mount(props, child, frame)
			end
			return function()
				scope:Destroy()
			end
		end,
	}
end

-- A story with custom code: fn(child ctx, target, scope) mounts and returns nothing.
local function custom(ctx: Build.Context, name: string, fn: (Build.Context, any, any) -> ()): Story
	return {
		name = name,
		build = function(target: any): () -> ()
			local scope = ctx.scope:Extend()
			local child = Build.with(ctx, { scope = scope })
			fn(child, target, scope)
			return function()
				scope:Destroy()
			end
		end,
	}
end

function Stories.list(ctx: Build.Context): { Story }
	local r = ctx.env.roblox
	local noop = function() end
	local stories: { Story } = {
		many(ctx, "Button", {
			{ Button, { textKey = "uikit.confirm", variant = "primary", onActivated = noop } },
			{ Button, { textKey = "uikit.cancel", variant = "secondary", onActivated = noop } },
			{ Button, { textKey = "uikit.back", variant = "ghost", onActivated = noop } },
			{ Button, { textKey = "uikit.retry", variant = "danger", onActivated = noop } },
			{ Button, { textKey = "uikit.continue", disabled = true } },
		}),
		many(ctx, "IconButton", {
			{ IconButton, { labelKey = "uikit.close", glyph = "x", onActivated = noop } },
			{ IconButton, { labelKey = "uikit.back", glyph = "<", variant = "ghost", round = true } },
		}),
		many(ctx, "Toggle", {
			{ Toggle, { textKey = "settings.subtitles", value = true } },
			{ Toggle, { textKey = "settings.reducedMotion", value = false } },
			{ Toggle, { textKey = "settings.haptics", disabled = true } },
		}),
		many(ctx, "Slider", {
			{ Slider, { textKey = "settings.volume.master", value = 0.8, format = "percent" } },
			{ Slider, { textKey = "settings.uiScale", min = 0.75, max = 1.5, value = 1 } },
		}),
		many(ctx, "Tabs", {
			{
				Tabs,
				{
					items = {
						{ id = "first", textKey = "settings.group.audio" },
						{ id = "second", textKey = "settings.group.display" },
						{ id = "third", textKey = "settings.group.controls" },
					},
				},
			},
		}),
		custom(ctx, "VirtualList", function(child, target)
			local holder =
				Build.frame(child, "VirtualListHolder", { Size = r.UDim2.new(1, 0, 0, 240) }, target)
			child.scope:Add(holder)
			VirtualList.mount({
				count = 1000,
				rowHeight = 32,
				render = function(row: any, index: number)
					local label = row:FindFirstChild("Text")
					if label == nil then
						label = Build.label(
							child,
							"Text",
							"body",
							"",
							nil,
							{ Size = r.UDim2.fromScale(1, 1) },
							row
						)
					end
					label.Text = "Item " .. index
				end,
			}, child, holder)
		end),
		custom(ctx, "Grid", function(child, target)
			local grid = Grid.mount({ cellHeight = 64 }, child, target)
			for index = 1, 8 do
				Card.mount({ text = "Item " .. index, layoutOrder = index }, child, grid.parts.content)
			end
		end),
		custom(ctx, "Modal", function(child, target)
			local modal = Modal.mount(
				{ textKey = "uikit.loading", bodyKey = "uikit.empty", open = true },
				child,
				target
			)
			Button.mount({
				textKey = "uikit.close",
				onActivated = function()
					modal.state.close("button")
				end,
			}, child, modal.parts.actions)
		end),
		custom(ctx, "ConfirmDialog", function(child, target)
			ConfirmDialog.mount(
				{ textKey = "uikit.confirm", bodyKey = "uikit.error", destructive = true, open = true },
				child,
				target
			)
		end),
		custom(ctx, "Toast", function(child, target)
			local host = Toast.Host.mount({ maxVisible = 3 }, child, target)
			host.state.push({ kind = "info", textKey = "uikit.loading" })
			host.state.push({ kind = "success", textKey = "uikit.toast.success" })
			host.state.push({ kind = "error", textKey = "uikit.error" })
		end),
		custom(ctx, "Tooltip", function(child, target)
			local button = IconButton.mount({ labelKey = "uikit.close", glyph = "x" }, child, target)
			Tooltip.mount({ target = button.root }, child, target)
		end),
		many(ctx, "ProgressBar", {
			{ ProgressBar, { textKey = "uikit.loading", value = 0.4, showValue = true } },
			{ ProgressBar, { indeterminate = true } },
		}),
		many(ctx, "RollingCounter", {
			{ RollingCounter, { value = 12345 } },
			{ RollingCounter, { value = 1250000, style = "compact", role = "heading" } },
		}),
		custom(ctx, "Badge", function(child, target)
			local button = IconButton.mount({ labelKey = "uikit.close", glyph = "x" }, child, target)
			Badge.mount({ count = 3, anchor = "corner" }, child, button.root)
			Badge.mount({ count = 120, variant = "neutral" }, child, target)
		end),
		many(ctx, "Card", {
			{ Card, { textKey = "uikit.empty", subtitleKey = "uikit.loading" } },
			{ Card, { textKey = "uikit.continue", onActivated = noop } },
		}),
		many(ctx, "ShopCard", {
			{
				ShopCard,
				{ catalog = Stories.CATALOG, productKey = "sample_product", price = { state = "pending" } },
			},
			{
				ShopCard,
				{
					catalog = Stories.CATALOG,
					productKey = "sample_product",
					price = { state = "pending" },
					ribbon = "best_value",
				},
			},
		}),
		custom(ctx, "OfferPopup", function(child, target)
			OfferPopup.mount({
				textKey = "uikit.shop.ribbon.starter",
				bodyKey = "uikit.empty",
				catalog = Stories.CATALOG,
				productKey = "sample_product",
				price = { state = "pending" },
				ribbon = "starter",
				secondsLeft = 86399,
				open = true,
			}, child, target)
		end),
		many(ctx, "DialogueBox", {
			{
				DialogueBox,
				{
					text = "Line of dialogue for layout checks.",
					speaker = "Speaker",
					choices = {
						{ id = "first", textKey = "uikit.confirm" },
						{ id = "second", textKey = "uikit.cancel" },
					},
				},
			},
		}),
		custom(ctx, "SettingsPanel", function(child, target)
			local holder = Build.frame(child, "SettingsHolder", { Size = r.UDim2.new(1, 0, 0, 480) }, target)
			child.scope:Add(holder)
			SettingsPanel.mount({ values = Settings.defaults() }, child, holder)
		end),
		custom(ctx, "LoadingScreen", function(child, target, scope)
			local screen = LoadingScreen.new({ titleText = child.text("uikit.loading") }, child.env)
			screen:setProgress(0.6)
			screen.parts.cover.Parent = target
			scope:Add(screen.parts.cover)
			scope:Add(function()
				screen:destroy()
			end)
		end),
		custom(ctx, "TeleportTransition", function(child, target, scope)
			local transition =
				TeleportTransition.new({ labelText = child.text("uikit.teleporting") }, child.env)
			local cover = transition.gui:FindFirstChild("Cover")
			cover.BackgroundTransparency = 0
			cover:FindFirstChild("Label").TextTransparency = 0
			cover.Parent = target
			scope:Add(cover)
			scope:Add(transition.gui)
		end),
		many(ctx, "StatBar", {
			{ StatBar, { text = "Stat", value = 60, max = 100, segments = 5 } },
			{ StatBar, { value = 20, max = 50, size = "lg", showValue = true } },
		}),
		many(ctx, "Timer", {
			{ Timer, { seconds = 125 } },
			{ Timer, { seconds = 8.4, style = "precise", warnBelow = 10 } },
		}),
		custom(ctx, "Countdown", function(child, target)
			local countdown = Countdown.mount({ from = 3 }, child, target)
			countdown.state.start()
		end),
		many(ctx, "LeaderboardPanel", {
			{
				LeaderboardPanel,
				{
					textKey = "uikit.leaderboard.empty",
					entries = {
						{ rank = 1, name = "Player 1", value = 1200 },
						{ rank = 2, name = "Player 2", value = 950, highlight = true },
						{ rank = 3, name = "Player 3", value = 400 },
					},
					height = 220,
				},
			},
		}),
		many(ctx, "KeybindPrompt", {
			{ KeybindPrompt, { action = "gameplay.interact", device = "KeyboardAndMouse" } },
			{ KeybindPrompt, { action = "gameplay.interact", device = "Gamepad" } },
			{ KeybindPrompt, { action = "ui.confirm", device = "Touch", hold = true, progress = 0.4 } },
		}),
		custom(ctx, "InventoryGrid", function(child, target)
			local holder = Build.frame(child, "InventoryHolder", { Size = r.UDim2.new(1, 0, 0, 300) }, target)
			child.scope:Add(holder)
			InventoryGrid.mount({
				capacity = 12,
				columns = 4,
				slots = { { key = "item_a", glyph = "A", count = 3 }, false, { key = "item_c", glyph = "C" } } :: { Slot },
				selected = 1,
			}, child, holder)
		end),
		many(ctx, "TouchActionButton", {
			{
				TouchActionButton,
				{
					action = "gameplay.action_1",
					uiKey = "action_1_button",
					labelKey = "input.gameplay.action_1",
					glyph = "1",
					alwaysVisible = true,
				},
			},
			{
				TouchActionButton,
				{
					action = "gameplay.jump",
					uiKey = "jump_button",
					labelKey = "input.gameplay.jump",
					glyph = "^",
					size = "sm",
					cooldown = 0.4,
					alwaysVisible = true,
				},
			},
		}),
	}
	return stories
end

-- Story names in list order.
function Stories.names(ctx: Build.Context): { string }
	local out = {}
	for _, story in Stories.list(ctx) do
		table.insert(out, story.name)
	end
	return out
end

return Stories
