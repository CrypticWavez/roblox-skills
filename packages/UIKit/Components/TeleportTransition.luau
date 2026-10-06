--!strict
-- @tier T1
-- TeleportTransition: a full-screen cover that hides a teleport, require-free like LoadingScreen
-- (it must also run in ReplicatedFirst of the destination place). Continuity (documented in
-- docs/uikit.md "Teleports"): before teleporting, the game builds the gui, plays cover() and,
-- once covered, calls TeleportService:SetTeleportGui(gui) and teleports; the destination's
-- ReplicatedFirst script gets the same gui from TeleportService:GetArrivingTeleportGui(),
-- parents it, adopts it with TeleportTransition.adopt(gui, env) (state "covered"), and calls
-- reveal() when its own loading is done. A failed teleport (TeleportInitFailed) calls
-- fail(text): the message shows and the cover reveals the place the player is still in. The
-- real teleport is T4 (it needs published places); this module is the visual state machine:
--   idle -> covering -> covered -> revealing -> done   (fail: covering|covered -> revealing)
-- step(dt) drives it (RunService.PreRender); reducedMotion shortens every fade to 0.15 s.
-- Tree: TeleportTransition (ScreenGui) > Cover (Frame) > Label (TextLabel), Message (TextLabel)
local TeleportTransition = {}

TeleportTransition.LOOK = table.freeze({
	background = { 0, 0, 0 },
	text = { 246, 246, 246 },
	font = "rbxasset://fonts/families/BuilderSans.json",
	displayOrder = 90, -- tokens.layer.transition
	cover = 0.35,
	reveal = 0.5,
	reducedFade = 0.15,
})

local KEYS = { "labelText", "reducedMotion" }

function TeleportTransition.validate(props: any): { string }
	if type(props) ~= "table" then
		return { "TeleportTransition: props must be a table" }
	end
	local problems = {}
	for key, value in props do
		if not table.find(KEYS, key) then
			table.insert(problems, "TeleportTransition: unknown prop " .. tostring(key))
		elseif key == "labelText" and (type(value) ~= "string" or #value > 256) then
			table.insert(problems, "TeleportTransition: labelText must be a string of at most 256 bytes")
		elseif key == "reducedMotion" and type(value) ~= "boolean" then
			table.insert(problems, "TeleportTransition: reducedMotion must be a boolean")
		end
	end
	table.sort(problems)
	return problems
end

local function make(r: any, className: string, props: { [string]: any }, parent: any?): any
	local instance = r.Instance.new(className)
	instance.Name = props.Name
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

-- The gui (fully transparent, ready to cover) and its parts.
function TeleportTransition.build(props: any, env: any): (any, { [string]: any })
	local problems = TeleportTransition.validate(props)
	if #problems > 0 then
		error(table.concat(problems, "; "), 2)
	end
	local r = env and env.roblox
	assert(r, "TeleportTransition.build: env.roblox (Roblox datatypes) is required")
	local look = TeleportTransition.LOOK
	local function color(c: { number }): any
		return r.Color3.fromRGB(c[1], c[2], c[3])
	end
	local gui = make(r, "ScreenGui", {
		Name = "TeleportTransition",
		DisplayOrder = look.displayOrder,
		IgnoreGuiInset = true,
		ScreenInsets = r.Enum.ScreenInsets.None,
		ResetOnSpawn = false,
		ZIndexBehavior = r.Enum.ZIndexBehavior.Sibling,
		AutoLocalize = false,
	})
	local cover = make(r, "Frame", {
		Name = "Cover",
		BackgroundColor3 = color(look.background),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = r.UDim2.fromScale(1, 1),
		Active = true, -- swallows clicks while covered
	}, gui)
	local font = r.Font.new(look.font, r.Enum.FontWeight.SemiBold, r.Enum.FontStyle.Normal)
	local label = make(r, "TextLabel", {
		Name = "Label",
		Text = props.labelText or "",
		FontFace = font,
		TextSize = 22,
		TextColor3 = color(look.text),
		TextTransparency = 1,
		BackgroundTransparency = 1,
		AnchorPoint = r.Vector2.new(0.5, 0.5),
		Position = r.UDim2.fromScale(0.5, 0.5),
		Size = r.UDim2.new(1, -48, 0, 30),
		AutoLocalize = false,
	}, cover)
	local message = make(r, "TextLabel", {
		Name = "Message",
		Text = "",
		FontFace = r.Font.new(look.font, r.Enum.FontWeight.Regular, r.Enum.FontStyle.Normal),
		TextSize = 18,
		TextColor3 = color(look.text),
		TextTransparency = 1,
		BackgroundTransparency = 1,
		AnchorPoint = r.Vector2.new(0.5, 0),
		Position = r.UDim2.new(0.5, 0, 0.5, 24),
		Size = r.UDim2.new(1, -48, 0, 48),
		TextWrapped = true,
		AutoLocalize = false,
	}, cover)
	gui:SetAttribute("TeleportTransitionState", "idle")
	return gui, { cover = cover, label = label, message = message }
end

export type Controller = {
	gui: any,
	cover: (self: Controller, onCovered: (() -> ())?) -> boolean,
	reveal: (self: Controller, onDone: (() -> ())?) -> boolean,
	fail: (self: Controller, text: string?) -> boolean,
	step: (self: Controller, dt: number) -> (),
	state: (self: Controller) -> string,
	opacity: (self: Controller) -> number,
}

local function controller(gui: any, parts: { [string]: any }, initial: string, reduced: boolean): Controller
	local look = TeleportTransition.LOOK
	local state = initial
	-- opacity 0 = clear, 1 = fully covered; moves toward goal over `length` seconds.
	local opacity = if initial == "covered" then 1 else 0
	local from, goal, elapsed, length = opacity, opacity, 0, 0
	local callback: (() -> ())? = nil
	local self: any = { gui = gui }

	local function apply()
		local t = 1 - opacity
		parts.cover.BackgroundTransparency = t
		parts.label.TextTransparency = t
		parts.message.TextTransparency = if parts.message.Text == "" then 1 else t
		parts.cover.Active = opacity > 0
		gui:SetAttribute("TeleportTransitionState", state)
	end

	local function go(nextState: string, target: number, seconds: number, fn: (() -> ())?)
		state = nextState
		from, goal, elapsed = opacity, target, 0
		length = if reduced then math.min(seconds, look.reducedFade) else seconds
		callback = fn
		apply()
	end

	function self.cover(_s: any, onCovered: (() -> ())?): boolean
		if state ~= "idle" then
			return false
		end
		go("covering", 1, look.cover, onCovered)
		return true
	end

	function self.reveal(_s: any, onDone: (() -> ())?): boolean
		if state ~= "covered" then
			return false
		end
		go("revealing", 0, look.reveal, onDone)
		return true
	end

	function self.fail(_s: any, text: string?): boolean
		if state ~= "covering" and state ~= "covered" then
			return false
		end
		parts.message.Text = text or ""
		go("revealing", 0, look.reveal, nil)
		return true
	end

	function self.step(_s: any, dt: number)
		if type(dt) ~= "number" or dt < 0 or dt ~= dt then
			return
		end
		if state ~= "covering" and state ~= "revealing" then
			return
		end
		elapsed += dt
		local alpha = if length <= 0 then 1 else math.clamp(elapsed / length, 0, 1)
		-- Quad.Out toward the goal (eases into the cover and out of the reveal).
		local eased = 1 - (1 - alpha) * (1 - alpha)
		opacity = from + (goal - from) * eased
		if alpha >= 1 then
			opacity = goal
			state = if state == "covering" then "covered" else "done"
			local fn = callback
			callback = nil
			apply()
			if fn then
				fn()
			end
			return
		end
		apply()
	end

	function self.state(_s: any): string
		return state
	end

	function self.opacity(_s: any): number
		return opacity
	end

	apply()
	return self
end

-- A controller over a new gui, idle and clear.
function TeleportTransition.new(props: any, env: any): Controller
	local gui, parts = TeleportTransition.build(props, env)
	return controller(gui, parts, "idle", props.reducedMotion == true)
end

-- A controller over an arriving gui (TeleportService:GetArrivingTeleportGui()), covered.
-- Raises if the gui is not a TeleportTransition tree.
function TeleportTransition.adopt(gui: any, options: { reducedMotion: boolean? }?): Controller
	local cover = gui and gui:FindFirstChild("Cover")
	local label = cover and cover:FindFirstChild("Label")
	local message = cover and cover:FindFirstChild("Message")
	if not (cover and label and message) then
		error("TeleportTransition.adopt: not a TeleportTransition gui", 2)
	end
	return controller(
		gui,
		{ cover = cover, label = label, message = message },
		"covered",
		options ~= nil and options.reducedMotion == true
	)
end

return TeleportTransition
