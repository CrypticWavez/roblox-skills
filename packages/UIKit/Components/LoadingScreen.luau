--!strict
-- @tier T1
-- LoadingScreen: the first screen a player sees, safe in ReplicatedFirst: this module requires
-- nothing (ReplicatedStorage and the rest of UIKit may not have replicated yet), so its look is
-- a frozen copy of the dark-theme tokens below (keep in sync with UIKit/Tokens). Datatypes come
-- from env.roblox, the only parameter it needs. The client script in ReplicatedFirst calls
-- ReplicatedFirst:RemoveDefaultLoadingScreen(), parents screen.gui to PlayerGui, drives
-- screen:step(dt) from RunService.PreRender, reports progress (for example from
-- ContentProvider.RequestQueueSize or its own preload list) and calls screen:finish() when the
-- game is ready. Progress is smoothed (exponential, frame-rate independent) and never moves
-- backwards; finish() fills the bar, fades everything out (0.4 s) and destroys the gui. With
-- reducedMotion the spinner stands still and the fade is 0.15 s. Text arrives already localised
-- (titleText, statusText). Tree:
--   LoadingScreen (ScreenGui) > Cover (Frame) > Center (Frame) > Title, Spinner (Frame) > Corner,
--   Stroke, Gradient; Bar (Frame) > Corner, Fill (Frame) > Corner; Status
local LoadingScreen = {}

-- Frozen copy of the UIKit dark theme values this screen uses (convention).
LoadingScreen.LOOK = table.freeze({
	background = { 18, 18, 18 },
	text = { 246, 246, 246 },
	textMuted = { 196, 196, 196 },
	track = { 50, 50, 50 },
	fill = { 236, 236, 236 },
	font = "rbxasset://fonts/families/BuilderSans.json",
	displayOrder = 90, -- tokens.layer.transition
	barWidth = 280,
	barHeight = 6,
	spinner = 40,
	fade = 0.4,
	reducedFade = 0.15,
	smoothing = 8, -- 1/s, exponential approach of the shown progress to the reported one
})

local KEYS = { "titleText", "statusText", "reducedMotion", "showSpinner" }

-- Problems with props (empty when valid).
function LoadingScreen.validate(props: any): { string }
	if type(props) ~= "table" then
		return { "LoadingScreen: props must be a table" }
	end
	local problems = {}
	for key, value in props do
		if not table.find(KEYS, key) then
			table.insert(problems, "LoadingScreen: unknown prop " .. tostring(key))
		elseif (key == "titleText" or key == "statusText") and (type(value) ~= "string" or #value > 256) then
			table.insert(problems, "LoadingScreen: " .. key .. " must be a string of at most 256 bytes")
		elseif (key == "reducedMotion" or key == "showSpinner") and type(value) ~= "boolean" then
			table.insert(problems, "LoadingScreen: " .. key .. " must be a boolean")
		end
	end
	table.sort(problems)
	return problems
end

local function make(r: any, className: string, props: { [string]: any }, parent: any?): any
	local instance = r.Instance.new(className)
	if props.Name then
		instance.Name = props.Name
	end
	local keys = {}
	for key in props do
		if key ~= "Name" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	for _, key in keys do
		instance[key] = props[key]
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

local function rgb(r: any, c: { number }): any
	return r.Color3.fromRGB(c[1], c[2], c[3])
end

-- The Instance tree (not parented) and its parts.
function LoadingScreen.build(props: any, env: any): (any, { [string]: any })
	local problems = LoadingScreen.validate(props)
	if #problems > 0 then
		error(table.concat(problems, "; "), 2)
	end
	local r = env and env.roblox
	assert(r, "LoadingScreen.build: env.roblox (Roblox datatypes) is required")
	local look = LoadingScreen.LOOK
	local font = function(weight: string): any
		return r.Font.new(look.font, r.Enum.FontWeight[weight], r.Enum.FontStyle.Normal)
	end
	local gui = make(r, "ScreenGui", {
		Name = "LoadingScreen",
		DisplayOrder = look.displayOrder,
		IgnoreGuiInset = true,
		ScreenInsets = r.Enum.ScreenInsets.None,
		ResetOnSpawn = false,
		ZIndexBehavior = r.Enum.ZIndexBehavior.Sibling,
		AutoLocalize = false,
	})
	local cover = make(r, "Frame", {
		Name = "Cover",
		BackgroundColor3 = rgb(r, look.background),
		BorderSizePixel = 0,
		Size = r.UDim2.fromScale(1, 1),
	}, gui)
	local center = make(r, "Frame", {
		Name = "Center",
		AnchorPoint = r.Vector2.new(0.5, 0.5),
		Position = r.UDim2.fromScale(0.5, 0.5),
		Size = r.UDim2.fromOffset(look.barWidth, 160),
		BackgroundTransparency = 1,
	}, cover)
	local title = make(r, "TextLabel", {
		Name = "Title",
		Text = props.titleText or "",
		FontFace = font("Bold"),
		TextSize = 28,
		TextColor3 = rgb(r, look.text),
		BackgroundTransparency = 1,
		Size = r.UDim2.new(1, 0, 0, 34),
		TextWrapped = true,
		AutoLocalize = false,
	}, center)
	local spinner = make(r, "Frame", {
		Name = "Spinner",
		AnchorPoint = r.Vector2.new(0.5, 0),
		Position = r.UDim2.new(0.5, 0, 0, 50),
		Size = r.UDim2.fromOffset(look.spinner, look.spinner),
		BackgroundTransparency = 1,
		Visible = props.showSpinner ~= false,
	}, center)
	make(r, "UICorner", { Name = "Corner", CornerRadius = r.UDim.new(0.5, 0) }, spinner)
	local ring = make(r, "UIStroke", {
		Name = "Stroke",
		Color = rgb(r, look.fill),
		Thickness = 4,
	}, spinner)
	-- A transparency gradient on the stroke turns the ring into an arc that reads as motion.
	make(r, "UIGradient", {
		Name = "Gradient",
		Transparency = r.NumberSequence.new({
			r.NumberSequenceKeypoint.new(0, 0),
			r.NumberSequenceKeypoint.new(0.6, 0.2),
			r.NumberSequenceKeypoint.new(1, 1),
		}),
	}, ring)
	local bar = make(r, "Frame", {
		Name = "Bar",
		AnchorPoint = r.Vector2.new(0.5, 0),
		Position = r.UDim2.new(0.5, 0, 0, 110),
		Size = r.UDim2.fromOffset(look.barWidth, look.barHeight),
		BackgroundColor3 = rgb(r, look.track),
		BorderSizePixel = 0,
	}, center)
	make(r, "UICorner", { Name = "Corner", CornerRadius = r.UDim.new(0.5, 0) }, bar)
	local fill = make(r, "Frame", {
		Name = "Fill",
		Size = r.UDim2.fromScale(0, 1),
		BackgroundColor3 = rgb(r, look.fill),
		BorderSizePixel = 0,
	}, bar)
	make(r, "UICorner", { Name = "Corner", CornerRadius = r.UDim.new(0.5, 0) }, fill)
	local status = make(r, "TextLabel", {
		Name = "Status",
		Text = props.statusText or "",
		FontFace = font("Regular"),
		TextSize = 16,
		TextColor3 = rgb(r, look.textMuted),
		BackgroundTransparency = 1,
		Position = r.UDim2.fromOffset(0, 126),
		Size = r.UDim2.new(1, 0, 0, 22),
		TextWrapped = true,
		AutoLocalize = false,
	}, center)
	return gui,
		{
			cover = cover,
			title = title,
			spinner = spinner,
			ring = ring,
			bar = bar,
			fill = fill,
			status = status,
		}
end

export type Screen = {
	gui: any,
	parts: { [string]: any },
	setProgress: (self: Screen, alpha: number) -> (),
	setStatus: (self: Screen, text: string) -> (),
	step: (self: Screen, dt: number) -> (),
	finish: (self: Screen, onDone: (() -> ())?) -> (),
	destroy: (self: Screen) -> (),
	state: (self: Screen) -> string,
	shown: (self: Screen) -> number,
}

-- A loading screen controller. States: loading, finishing, done.
function LoadingScreen.new(props: any, env: any): Screen
	local gui, parts = LoadingScreen.build(props, env)
	local r = env.roblox
	local look = LoadingScreen.LOOK
	local reduced = props.reducedMotion == true
	local target, shown, angle = 0, 0, 0
	local state = "loading"
	local fadeTime, fadeLength = 0, if reduced then look.reducedFade else look.fade
	local onFinished: (() -> ())? = nil
	local screen: any = { gui = gui, parts = parts }

	local function render()
		parts.fill.Size = r.UDim2.fromScale(math.clamp(shown, 0, 1), 1)
		parts.spinner.Rotation = angle
	end

	local function fade(alpha: number)
		-- alpha 0 = opaque, 1 = gone; every visible part follows.
		parts.cover.BackgroundTransparency = alpha
		parts.title.TextTransparency = alpha
		parts.status.TextTransparency = alpha
		parts.bar.BackgroundTransparency = alpha
		parts.fill.BackgroundTransparency = alpha
		parts.ring.Transparency = alpha
	end

	function screen.setProgress(_self: any, alpha: number)
		if type(alpha) ~= "number" or alpha ~= alpha then
			return
		end
		target = math.max(target, math.clamp(alpha, 0, 1))
	end

	function screen.setStatus(_self: any, text: string)
		assert(
			type(text) == "string" and #text <= 256,
			"LoadingScreen: status must be a string of at most 256 bytes"
		)
		parts.status.Text = text
	end

	function screen.step(_self: any, dt: number)
		if state == "done" or type(dt) ~= "number" or dt < 0 or dt ~= dt then
			return
		end
		shown += (target - shown) * (1 - math.exp(-look.smoothing * dt))
		if math.abs(target - shown) < 1e-3 then
			shown = target
		end
		if not reduced and parts.spinner.Visible then
			angle = (angle + 360 * dt) % 360
		end
		render()
		if state == "finishing" then
			fadeTime += dt
			local alpha = if fadeLength <= 0 then 1 else math.clamp(fadeTime / fadeLength, 0, 1)
			fade(alpha)
			if alpha >= 1 then
				state = "done"
				gui:Destroy()
				local fn = onFinished
				onFinished = nil
				if fn then
					fn()
				end
			end
		end
	end

	function screen.finish(_self: any, onDone: (() -> ())?)
		if state ~= "loading" then
			return
		end
		state = "finishing"
		target = 1
		shown = 1
		onFinished = onDone
		render()
	end

	function screen.destroy(_self: any)
		if state == "done" then
			return
		end
		state = "done"
		onFinished = nil
		gui:Destroy()
	end

	function screen.state(_self: any): string
		return state
	end

	function screen.shown(_self: any): number
		return shown
	end

	render()
	return screen
end

return LoadingScreen
