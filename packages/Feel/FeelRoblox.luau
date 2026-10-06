--!strict
-- @tier T3
-- probe: feel_marker_cue
-- FeelRoblox: the client adapter that turns Feel cores into engine changes. One instance per
-- local player:
--   * Cues fire into VFX (an AVKit VfxPoolRoblox), sound (an AVKit AudioGraphRoblox), Shake,
--     HitStop, Haptics, Screen and Popups;
--   * step(dt) applies them: camera shake offset and FOV punch on the Camera (call it every frame
--     after the camera scripts, RunService:BindToRenderStep at RenderPriority.Camera.Value + 1),
--     AnimationTrack:AdjustSpeed(0) during hit-stop and back to the saved speed after, an owned
--     ColorCorrectionEffect ("FeelColorCorrection") and BlurEffect ("FeelBlur") under the
--     Camera, an edge-gradient vignette ScreenGui (no image asset) and pooled BillboardGui
--     popups on Instance anchors;
--   * settings/1: setEffective(Settings.effective(...)) feeds shakeScale, reducedMotion,
--     allowFlashes and haptics to every core.
--   FeelRoblox.new(env, options) -> feel;  feel:fire(id, context?);  feel:step(dt)
--   feel:bindMarkers(track, map, context?);  feel:freeze(track);  feel:destroy()
-- context: { at = Vector3 | CFrame | Instance (vfx, sound), anchor = Instance (popup),
-- value = number (popup), key = string (popup merge key) }.
-- options.engine overrides haptic(pattern) and now() for Lune specs.
local Cues = require("./Cues")
local Haptics = require("./Haptics")
local HitStop = require("./HitStop")
local Popups = require("./Popups")
local Screen = require("./Screen")
local Shake = require("./Shake")

local FeelRoblox = {}

FeelRoblox.POPUP_POOL = 16 -- convention

export type Options = {
	camera: any,
	guiParent: any?,
	effective: any?,
	cues: { [string]: any }?,
	vfx: any?,
	audio: any?,
	shake: any?,
	popups: any?,
	known: any?,
	engine: any?,
}

function FeelRoblox.new(env: any, options: Options)
	assert(type(options) == "table" and options.camera ~= nil, "FeelRoblox: options.camera is required")
	local lib = if env.roblox then env.roblox else env
	local report = env.report or function(_message: string) end
	local camera = options.camera
	local effective: any = options.effective or {}
	local engine: any = {
		now = function(): number
			return env.clock()
		end,
		haptic = function(pattern: any)
			local effect = lib.Instance.new("HapticEffect")
			effect.Type = (lib.Enum.HapticEffectType :: any)[pattern.type]
			effect.Looped = pattern.looped == true
			if pattern.waveform then
				local keys = {}
				for _, key in pattern.waveform do
					table.insert(
						keys,
						lib.FloatCurveKey.new(key[1], key[2], lib.Enum.KeyInterpolationMode.Linear)
					)
				end
				effect:SetWaveformKeys(keys)
			end
			effect.Parent = camera
			effect:Play()
			local lifetime = pattern.duration or 1.5
			env.defer(function()
				env.wait(lifetime)
				effect:Destroy()
			end)
		end,
	}
	for key, fn in options.engine or {} do
		engine[key] = fn
	end

	local shake = Shake.new(options.shake)
	local hitStop = HitStop.new()
	local haptics = Haptics.new({ effective = effective })
	local screen = Screen.new({ effective = effective })
	local popups = Popups.new(options.popups)
	popups:setReducedMotion(effective.reducedMotion == true)

	-- Owned post effects (one each; never touches the game's own effects).
	local colorCorrection = lib.Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "FeelColorCorrection"
	colorCorrection.Parent = camera
	local blur = lib.Instance.new("BlurEffect")
	blur.Name = "FeelBlur"
	blur.Size = 0
	blur.Parent = camera
	local baseFov = camera.FieldOfView
	local lastFovOffset = 0

	-- Vignette: four black edge frames whose UIGradients fade inward.
	local vignetteGui = nil
	local edges = {}
	if options.guiParent ~= nil then
		vignetteGui = lib.Instance.new("ScreenGui")
		vignetteGui.Name = "FeelVignette"
		vignetteGui.IgnoreGuiInset = true
		vignetteGui.DisplayOrder = 50
		vignetteGui.ResetOnSpawn = false
		local sides = {
			{
				name = "Top",
				size = lib.UDim2.fromScale(1, 0.3),
				position = lib.UDim2.fromScale(0, 0),
				rotation = 90,
			},
			{
				name = "Bottom",
				size = lib.UDim2.fromScale(1, 0.3),
				position = lib.UDim2.fromScale(0, 0.7),
				rotation = 270,
			},
			{
				name = "Left",
				size = lib.UDim2.fromScale(0.25, 1),
				position = lib.UDim2.fromScale(0, 0),
				rotation = 0,
			},
			{
				name = "Right",
				size = lib.UDim2.fromScale(0.25, 1),
				position = lib.UDim2.fromScale(0.75, 0),
				rotation = 180,
			},
		}
		for _, side in sides do
			local frame = lib.Instance.new("Frame")
			frame.Name = side.name
			frame.Size = side.size
			frame.Position = side.position
			frame.BorderSizePixel = 0
			frame.BackgroundColor3 = lib.Color3.new(0, 0, 0)
			frame.BackgroundTransparency = 1
			local gradient = lib.Instance.new("UIGradient")
			gradient.Rotation = side.rotation
			gradient.Transparency = lib.NumberSequence.new({
				lib.NumberSequenceKeypoint.new(0, 0),
				lib.NumberSequenceKeypoint.new(1, 1),
			})
			gradient.Parent = frame
			frame.Parent = vignetteGui
			table.insert(edges, frame)
		end
		vignetteGui.Parent = options.guiParent
	end

	-- Popup BillboardGuis, pooled.
	local popupGuis: { [number]: any } = {}
	local popupIdle: { any } = {}
	local function popupGui(): any
		local idle = table.remove(popupIdle)
		if idle then
			return idle
		end
		local gui = lib.Instance.new("BillboardGui")
		gui.Name = "FeelPopup"
		gui.AlwaysOnTop = true
		gui.Size = lib.UDim2.fromScale(3, 1)
		gui.MaxDistance = 120
		gui.LightInfluence = 0
		local text = lib.Instance.new("TextLabel")
		text.Name = "Text"
		text.BackgroundTransparency = 1
		text.Size = lib.UDim2.fromScale(1, 1)
		text.TextScaled = true
		text.TextColor3 = lib.Color3.new(1, 1, 1)
		local stroke = lib.Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Parent = text
		local scale = lib.Instance.new("UIScale")
		scale.Parent = text
		text.Parent = gui
		return gui
	end

	-- Hit-stop: tracks registered with freeze() pause while frozen.
	local tracks: { [any]: number | false } = {}

	local sinks = {
		vfx = function(id: string, context: any)
			if options.vfx and context and context.at ~= nil then
				options.vfx:play(id, context.at)
			end
		end,
		sound = function(id: string, context: any)
			if options.audio then
				options.audio:play(id, if context then context.at else nil)
			end
		end,
		shake = function(amount: any)
			shake:add(amount)
		end,
		hitStop = function(seconds: number)
			hitStop:request(seconds, engine.now())
		end,
		haptic = function(pattern: any)
			local clamped = haptics:request(pattern, engine.now())
			if clamped then
				engine.haptic(clamped)
			end
		end,
		flash = function(spec: any)
			screen:flash(spec, engine.now())
		end,
		tint = function(spec: any)
			screen:tint(spec, engine.now())
		end,
		popup = function(spec: any, context: any)
			if context == nil or context.anchor == nil or context.value == nil then
				return
			end
			popups:push({
				key = (context.key or spec.kind or "popup"),
				kind = spec.kind,
				value = context.value,
				anchor = context.anchor,
			}, engine.now())
		end,
	}
	local cues = Cues.new(options.cues or Cues.defaults(), sinks, { known = options.known, report = report })

	local api: any = {}

	function api:fire(id: string, context: any?): ({ string }?, string?)
		return cues:fire(id, context)
	end

	function api:bindMarkers(track: any, map: { [string]: string }, context: any?): { any }
		return cues:bindMarkers(track, map, context)
	end

	-- Registers an AnimationTrack to pause during hit-stop.
	function api:freeze(track: any)
		if tracks[track] == nil then
			tracks[track] = false
		end
	end

	function api:release(track: any)
		local saved = tracks[track]
		if type(saved) == "number" then
			track:AdjustSpeed(saved)
		end
		tracks[track] = nil
	end

	function api:setEffective(value: any)
		effective = value or {}
		haptics:setEffective(effective)
		screen:setEffective(effective)
		popups:setReducedMotion(effective.reducedMotion == true)
	end

	function api:step(dt: number)
		cues:frame()
		local now = engine.now()
		-- shake: offsets on top of the camera's CFrame for this frame
		local scale = if effective.shakeScale == nil then 1 else effective.shakeScale
		local o = shake:step(dt, scale)
		if o.x ~= 0 or o.y ~= 0 or o.z ~= 0 or o.pitch ~= 0 or o.yaw ~= 0 or o.roll ~= 0 then
			camera.CFrame = camera.CFrame
				* lib.CFrame.new(o.x, o.y, o.z)
				* lib.CFrame.Angles(math.rad(o.pitch), math.rad(o.yaw), math.rad(o.roll))
		end
		-- hit-stop
		local frozen = hitStop:frozen(now)
		for track, saved in tracks do
			if frozen and saved == false then
				tracks[track] = track.Speed
				track:AdjustSpeed(0)
			elseif not frozen and type(saved) == "number" then
				track:AdjustSpeed(saved)
				tracks[track] = false
			end
		end
		-- screen
		local s = screen:sample(now)
		colorCorrection.Brightness = s.brightness
		colorCorrection.Saturation = s.saturation
		local mix = s.tintAmount
		colorCorrection.TintColor = lib.Color3.fromRGB(
			255 + (s.tint[1] - 255) * mix,
			255 + (s.tint[2] - 255) * mix,
			255 + (s.tint[3] - 255) * mix
		)
		blur.Size = s.blur
		if s.fov ~= 0 or lastFovOffset ~= 0 then
			if lastFovOffset == 0 then
				baseFov = camera.FieldOfView
			end
			camera.FieldOfView = math.clamp(baseFov + s.fov, 1, 120)
			lastFovOffset = s.fov
		end
		for _, frame in edges do
			frame.BackgroundTransparency = 1 - s.vignette * 0.85
		end
		-- popups
		local visible = popups:step(now)
		local seen = {}
		for _, popup in visible do
			seen[popup.id] = true
			local gui = popupGuis[popup.id]
			if gui == nil then
				gui = popupGui()
				popupGuis[popup.id] = gui
				gui.Adornee = popup.anchor
				gui.Parent = popup.anchor
			end
			local text = gui:FindFirstChild("Text")
			text.Text = popup.text
			text.TextTransparency = 1 - popup.alpha
			text:SetAttribute("PopupKind", popup.kind)
			text:FindFirstChildOfClass("UIScale").Scale = popup.scale
			gui.StudsOffsetWorldSpace = lib.Vector3.new(0, 2 + popup.offset, 0)
		end
		for id, gui in popupGuis do
			if not seen[id] then
				popupGuis[id] = nil
				gui.Parent = nil
				if #popupIdle < FeelRoblox.POPUP_POOL then
					table.insert(popupIdle, gui)
				else
					gui:Destroy()
				end
			end
		end
	end

	function api:stats(): any
		return { cues = cues:stats(), screen = screen:stats(), trauma = shake:trauma() }
	end

	function api:destroy()
		for track in tracks do
			api:release(track)
		end
		colorCorrection:Destroy()
		blur:Destroy()
		if lastFovOffset ~= 0 then
			camera.FieldOfView = baseFov
		end
		if vignetteGui then
			vignetteGui:Destroy()
		end
		for _, gui in popupGuis do
			gui:Destroy()
		end
		for _, gui in popupIdle do
			gui:Destroy()
		end
		table.clear(popupGuis)
		table.clear(popupIdle)
	end

	return api
end

return FeelRoblox
