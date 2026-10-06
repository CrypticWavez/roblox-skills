--!strict
-- @tier T1
-- Gallery/Browser: the story browser behind the gallery fixture (fixtures/kits/client/
-- ui_Gallery.client.luau). A sidebar lists every Stories.list story; choosing one mounts it on
-- the stage through the UI Labs (target) -> cleanup signature and cleans the previous one. The
-- toolbar previews the same story with the light theme, reduced motion, pseudo-localised text
-- and as a phone, desktop or console: the stage takes that class's viewport size and a UIScale
-- shrinks it to fit the space left (never enlarges). Settings changes rebuild the story with a
-- fresh context from options.context(settings), which returns (ctx, release?); the browser
-- calls release when that context is replaced. The browser's own chrome uses options.chrome
-- and plain English labels (a developer tool, not localised; story names are component names).
-- options.onSelected(name, stage, ctx) runs after each mount (the fixture audits there).
-- Tree: Browser (Frame) > Sidebar (Frame) > Title, List (ScrollingFrame) > <story> buttons;
--   Main (Frame) > Toolbar (Frame) > toggles, device buttons; Area (Frame) > Stage (Frame) > Scale
local Breakpoints = require("../Breakpoints")
local Build = require("../Build")
local Button = require("../Components/Button")
local Stories = require("./Stories")
local Toggle = require("../Components/Toggle")

local Browser = {}

-- Preview classes (convention: a landscape phone with a notch, a 1280x720 desktop window and
-- a 1080p ten-foot console).
Browser.DEVICES = table.freeze({
	phone = {
		viewport = { 844, 390 },
		input = "Touch",
		insets = { left = 47, right = 47, top = 0, bottom = 21 },
	},
	desktop = { viewport = { 1280, 720 }, input = "KeyboardAndMouse" },
	console = { viewport = { 1920, 1080 }, input = "Gamepad", tenFoot = true },
})
Browser.DEVICE_ORDER = table.freeze({ "phone", "desktop", "console" })
local SIDEBAR = 240 -- px, convention
local TOOLBAR = 56

export type Settings = { theme: string, reducedMotion: boolean, pseudo: boolean, device: string }
export type Options = {
	chrome: Build.Context,
	context: (settings: Settings) -> (Build.Context, (() -> ())?),
	onSelected: ((name: string, stage: any, ctx: Build.Context) -> ())?,
	initial: string?,
	settings: { [string]: any }?,
}

-- The Breakpoints class for a device name.
function Browser.class(device: string): Breakpoints.Class
	local info = Browser.DEVICES[device]
	if info == nil then
		error("Browser.class: unknown device " .. tostring(device), 2)
	end
	return Breakpoints.classify(info :: any)
end

-- The UIScale that fits a viewport into an area (at most 1).
function Browser.fit(viewport: { number }, area: { w: number, h: number }?): number
	if area == nil or area.w <= 0 or area.h <= 0 then
		return 1
	end
	return math.min(1, area.w / viewport[1], area.h / viewport[2])
end

local function validSettings(settings: { [string]: any }): Settings
	local out: Settings = { theme = "dark", reducedMotion = false, pseudo = false, device = "desktop" }
	for key, value in settings do
		if key == "theme" then
			assert(value == "dark" or value == "light", "Browser: theme must be dark or light")
		elseif key == "device" then
			assert(Browser.DEVICES[value] ~= nil, "Browser: device must be phone, desktop or console")
		elseif key == "reducedMotion" or key == "pseudo" then
			assert(type(value) == "boolean", "Browser: " .. key .. " must be a boolean")
		else
			error("Browser: unknown setting " .. tostring(key), 3)
		end
		(out :: any)[key] = value
	end
	return out
end

-- Mounts the browser into target; returns { select(name) -> boolean, set(patch), current(),
-- settings(), names(), destroy() }.
function Browser.mount(target: any, options: Options): any
	assert(
		type(options) == "table" and options.chrome and type(options.context) == "function",
		"Browser.mount: needs { chrome, context }"
	)
	local chrome = options.chrome
	local r = chrome.env.roblox
	local scope = chrome.scope:Extend()
	local ui = Build.with(chrome, { scope = scope })
	local settings = validSettings(options.settings or {})

	local root = Build.surface(ui, "Browser", "background", { Size = r.UDim2.fromScale(1, 1) }, target)
	scope:Add(root)
	local sidebar = Build.surface(ui, "Sidebar", "surface", {
		Size = r.UDim2.new(0, SIDEBAR, 1, 0),
	}, root)
	Build.padding(ui, sidebar, "sm")
	Build.label(ui, "Title", "heading", "UIKit gallery", nil, {
		Size = r.UDim2.new(1, 0, 0, 32),
		TextWrapped = false,
	}, sidebar)
	local list = Build.make(ui, "ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = r.UDim2.fromOffset(0, 40),
		Size = r.UDim2.new(1, 0, 1, -40),
		CanvasSize = r.UDim2.new(),
		AutomaticCanvasSize = r.Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollingDirection = r.Enum.ScrollingDirection.Y,
		Selectable = false,
	}, sidebar)
	Build.list(ui, list, "Vertical", { gap = "xs" })

	local main = Build.frame(ui, "Main", {
		Position = r.UDim2.fromOffset(SIDEBAR, 0),
		Size = r.UDim2.new(1, -SIDEBAR, 1, 0),
	}, root)
	local toolbar = Build.frame(ui, "Toolbar", { Size = r.UDim2.new(1, 0, 0, TOOLBAR) }, main)
	Build.padding(ui, toolbar, "sm")
	Build.list(ui, toolbar, "Horizontal", { gap = "sm", valign = "Center" })
	local area = Build.frame(ui, "Area", {
		Position = r.UDim2.fromOffset(0, TOOLBAR),
		Size = r.UDim2.new(1, 0, 1, -TOOLBAR),
		ClipsDescendants = true,
	}, main)

	-- Story names come from a probe context (stories are rebuilt per settings).
	local names = Stories.names(chrome)
	local current: string? = nil
	local storyCtx: Build.Context? = nil
	local release: (() -> ())? = nil
	local cleanup: (() -> ())? = nil
	local stage: any = nil
	local buttons: { [string]: any } = {}
	local deviceButtons: { [string]: any } = {}

	local function unmount()
		if cleanup then
			local fn = cleanup
			cleanup = nil
			fn()
		end
		if stage then
			stage:Destroy()
			stage = nil
		end
		if storyCtx then
			storyCtx.scope:Destroy()
			storyCtx = nil
		end
		if release then
			local fn = release
			release = nil
			fn()
		end
	end

	local function refit()
		if stage == nil then
			return
		end
		local viewport = Browser.DEVICES[settings.device].viewport
		local scale = Browser.fit(viewport, ui.measure(area))
		stage:FindFirstChild("Scale").Scale = scale
	end

	local function mountCurrent()
		unmount()
		if current == nil then
			return
		end
		local ctx, done = options.context(table.clone(settings))
		storyCtx, release = ctx, done
		local viewport = Browser.DEVICES[settings.device].viewport
		stage = Build.surface(ctx, "Stage", "background", {
			AnchorPoint = r.Vector2.new(0.5, 0.5),
			Position = r.UDim2.fromScale(0.5, 0.5),
			Size = r.UDim2.fromOffset(viewport[1], viewport[2]),
			ClipsDescendants = true,
		}, area)
		Build.make(ctx, "UIScale", { Name = "Scale" }, stage)
		Build.stroke(ui, stage, "border", "hairline")
		local story
		for _, item in Stories.list(ctx) do
			if item.name == current then
				story = item
			end
		end
		assert(story, "Browser: story vanished: " .. tostring(current))
		cleanup = story.build(stage)
		refit()
		if options.onSelected then
			options.onSelected(current :: string, stage, ctx)
		end
	end

	local function paintSelection()
		for name, handle in buttons do
			handle:update({ variant = if name == current then "secondary" else "ghost" })
		end
		for name, handle in deviceButtons do
			handle:update({ variant = if name == settings.device then "secondary" else "ghost" })
		end
	end

	local api: any = {}

	function api.select(_self: any, name: string): boolean
		if not table.find(names, name) then
			return false
		end
		current = name
		paintSelection()
		mountCurrent()
		return true
	end

	function api.set(_self: any, patch: { [string]: any })
		local merged: { [string]: any } = table.clone(settings :: any)
		for key, value in patch do
			merged[key] = value
		end
		settings = validSettings(merged)
		paintSelection()
		mountCurrent()
	end

	function api.current(_self: any): string?
		return current
	end

	function api.settings(_self: any): Settings
		return table.clone(settings)
	end

	function api.names(_self: any): { string }
		return table.clone(names)
	end

	function api.stage(_self: any): any
		return stage
	end

	function api.destroy(_self: any)
		unmount()
		scope:Destroy()
	end

	for index, name in names do
		buttons[name] = Button.mount({
			text = name,
			variant = "ghost",
			size = "sm",
			fill = true,
			layoutOrder = index,
			onActivated = function()
				api:select(name)
			end,
		}, ui, list)
	end
	local toggles = {
		{ text = "Light theme", key = "theme", value = settings.theme == "light" },
		{ text = "Reduced motion", key = "reducedMotion", value = settings.reducedMotion },
		{ text = "Pseudo-loc", key = "pseudo", value = settings.pseudo },
	}
	for index, item in toggles do
		Toggle.mount({
			text = item.text,
			value = item.value,
			width = 200,
			layoutOrder = index,
			onChanged = function(value: boolean)
				if item.key == "theme" then
					api:set({ theme = if value then "light" else "dark" })
				else
					api:set({ [item.key] = value })
				end
			end,
		}, ui, toolbar)
	end
	for index, device in Browser.DEVICE_ORDER do
		deviceButtons[device] = Button.mount({
			text = string.upper(string.sub(device, 1, 1)) .. string.sub(device, 2),
			variant = "ghost",
			size = "sm",
			layoutOrder = 10 + index,
			onActivated = function()
				api:set({ device = device })
			end,
		}, ui, toolbar)
	end
	scope:Add(ui.onChanged(area, "AbsoluteSize", refit))
	scope:Add(unmount)
	paintSelection()
	if options.initial then
		api:select(options.initial)
	end
	return api
end

return Browser
