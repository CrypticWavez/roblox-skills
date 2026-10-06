--!strict
-- @tier T3
-- probe: cin_play_sample
-- CinematicsRoblox: plays a cinematics/1 cutscene on a Camera (docs/uikit.md "Cinematics").
-- play(cin, options) takes the camera (CameraType Scriptable for the run; type, CFrame, Focus
-- and FieldOfView are restored when it ends, is skipped or stopped), drives the pure
-- Cinematics.player from RunService.PreRender, applies each sample (a look-at frame built with
-- CFrame.fromMatrix, the same as CFrame.lookAt with world up and independent of Lune 0.10's
-- lookAt, which mirrors -Z targets; then * roll; or CFrame.fromOrientation for orientation
-- keys; looking straight up or down uses +X as right, convention; positions relative to
-- options.anchor when space = "anchor"), and shows an overlay ScreenGui (ScreenInsets None,
-- DisplayOrder 80 = tokens.layer.cinematic) with letterbox bars, a black fade, subtitles
-- (options.text resolves keys; subtitles show only when options.subtitles ~= false) and a
-- hold-to-skip hint. Skip input comes only through the Input Action System: pass the
-- cinematic.skip InputAction (InputMapRoblox) as options.skipAction; its context is enabled for
-- the run when options.skipContext is given. Reduced motion (options.reducedMotion) plays
-- Cinematics.reduce(cin): cuts instead of camera moves. onEvent(name, payload, skipped) gets
-- every event; onFinished(state) runs once with finished, skipped or stopped. keyFromCamera
-- turns the current view into a key for authoring in Studio. Both are T3: proven only by probe
-- cin_play_sample in a play session on the unpublished diagnostic place.
local Cinematics = require("./Cinematics")
local Env = require("../GameKit/Env")

local CinematicsRoblox = {}

export type Options = {
	camera: any,
	env: any,
	anchor: any?,
	onEvent: ((name: string, payload: any?, skipped: boolean) -> ())?,
	onFinished: ((state: string) -> ())?,
	skippable: boolean?,
	skipAction: any?,
	skipContext: any?,
	reducedMotion: boolean?,
	subtitles: boolean?,
	text: ((key: string) -> string)?,
	parent: any?,
}

local function overlay(r: any, parent: any?): (any, { [string]: any })
	local gui = r.Instance.new("ScreenGui")
	gui.Name = "CinematicOverlay"
	gui.DisplayOrder = 80
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = r.Enum.ScreenInsets.None
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = r.Enum.ZIndexBehavior.Sibling
	gui.AutoLocalize = false
	local function bar(name: string, anchorY: number): any
		local frame = r.Instance.new("Frame")
		frame.Name = name
		frame.BackgroundColor3 = r.Color3.new(0, 0, 0)
		frame.BorderSizePixel = 0
		frame.AnchorPoint = r.Vector2.new(0, anchorY)
		frame.Position = r.UDim2.fromScale(0, anchorY)
		frame.Size = r.UDim2.fromScale(1, 0)
		frame.Parent = gui
		return frame
	end
	local top = bar("TopBar", 0)
	local bottom = bar("BottomBar", 1)
	local fade = r.Instance.new("Frame")
	fade.Name = "Fade"
	fade.BackgroundColor3 = r.Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.Size = r.UDim2.fromScale(1, 1)
	fade.ZIndex = 3
	fade.Parent = gui
	local font = r.Font.new("rbxasset://fonts/families/BuilderSans.json", r.Enum.FontWeight.Medium)
	local subtitle = r.Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.FontFace = font
	subtitle.TextSize = 22
	subtitle.TextColor3 = r.Color3.new(1, 1, 1)
	subtitle.TextStrokeTransparency = 0.4
	subtitle.TextWrapped = true
	subtitle.AutoLocalize = false
	subtitle.AnchorPoint = r.Vector2.new(0.5, 1)
	subtitle.Position = r.UDim2.new(0.5, 0, 1, -24)
	subtitle.Size = r.UDim2.new(0.8, 0, 0, 60)
	subtitle.ZIndex = 2
	subtitle.Text = ""
	subtitle.Parent = gui
	local hint = r.Instance.new("TextLabel")
	hint.Name = "SkipHint"
	hint.BackgroundTransparency = 1
	hint.FontFace = font
	hint.TextSize = 16
	hint.TextColor3 = r.Color3.new(1, 1, 1)
	hint.TextTransparency = 0.2
	hint.AutoLocalize = false
	hint.AnchorPoint = r.Vector2.new(1, 1)
	hint.Position = r.UDim2.new(1, -24, 1, -24)
	hint.Size = r.UDim2.fromOffset(200, 24)
	hint.TextXAlignment = r.Enum.TextXAlignment.Right
	hint.Visible = false
	hint.ZIndex = 4
	hint.Parent = gui
	local progress = r.Instance.new("Frame")
	progress.Name = "Progress"
	progress.BackgroundColor3 = r.Color3.new(1, 1, 1)
	progress.BorderSizePixel = 0
	progress.Position = r.UDim2.new(0, 0, 1, 2)
	progress.Size = r.UDim2.new(0, 0, 0, 2)
	progress.Parent = hint
	gui.Parent = parent
	return gui,
		{ top = top, bottom = bottom, fade = fade, subtitle = subtitle, hint = hint, progress = progress }
end

-- A CFrame at eye looking at target with world up (CFrame.lookAt semantics). When the view is
-- vertical, right is +X (convention); eye == target keeps the identity rotation.
function CinematicsRoblox.lookAt(r: any, eye: any, target: any): any
	local delta = target - eye
	if delta.Magnitude < 1e-9 then
		return r.CFrame.new(eye)
	end
	local look = delta.Unit
	local right = look:Cross(r.Vector3.new(0, 1, 0))
	right = if right.Magnitude < 1e-6 then r.Vector3.new(1, 0, 0) else right.Unit
	return r.CFrame.fromMatrix(eye, right, right:Cross(look))
end

-- The camera CFrame for a sample (relative to anchor when given).
function CinematicsRoblox.cframe(sample: Cinematics.Sample, r: any, anchor: any?): any
	local p = sample.position
	local cf
	if sample.lookAt then
		local l = sample.lookAt :: { number }
		cf = CinematicsRoblox.lookAt(r, r.Vector3.new(p[1], p[2], p[3]), r.Vector3.new(l[1], l[2], l[3]))
			* r.CFrame.Angles(0, 0, math.rad(sample.roll))
	else
		local o = sample.orientation :: { number }
		cf = r.CFrame.new(p[1], p[2], p[3])
			* r.CFrame.fromOrientation(math.rad(o[1]), math.rad(o[2]), math.rad(o[3]))
	end
	if anchor then
		return anchor * cf
	end
	return cf
end

-- Plays cin; returns a handle { skip(), stop(), state(), time() }.
function CinematicsRoblox.play(cin: Cinematics.Cinematic, options: Options): any
	local problems = Cinematics.validate(cin)
	if #problems > 0 then
		error("CinematicsRoblox.play: " .. table.concat(problems, "; "), 2)
	end
	assert(
		type(options) == "table" and options.camera and options.env,
		"CinematicsRoblox.play: needs { camera, env }"
	)
	local env = options.env
	local r = env.roblox
	local camera = options.camera
	local run = if options.reducedMotion then Cinematics.reduce(cin) else cin
	local player = Cinematics.player(run, { skippable = options.skippable })
	local anchor = if cin.space == "anchor" then options.anchor else nil
	local saved = {
		CameraType = camera.CameraType,
		CFrame = camera.CFrame,
		Focus = camera.Focus,
		FieldOfView = camera.FieldOfView,
	}
	local gui, parts = overlay(r, options.parent)
	local connections = {}
	local skipHeld = false
	local done = false
	local handle: any = {}

	local function apply(frame: Cinematics.Frame)
		local sample = frame.sample
		local cf = CinematicsRoblox.cframe(sample, r, anchor)
		camera.CFrame = cf
		camera.Focus = if sample.lookAt
			then (if anchor then anchor else r.CFrame.new()) * r.CFrame.new(
				(sample.lookAt :: any)[1],
				(sample.lookAt :: any)[2],
				(sample.lookAt :: any)[3]
			)
			else cf * r.CFrame.new(0, 0, -10)
		camera.FieldOfView = sample.fov
		parts.top.Size = r.UDim2.fromScale(1, sample.letterbox)
		parts.bottom.Size = r.UDim2.fromScale(1, sample.letterbox)
		parts.fade.BackgroundTransparency = 1 - sample.fade
		local key = if options.subtitles ~= false then sample.subtitle else nil
		parts.subtitle.Text = if key and options.text then options.text(key) else (key or "")
		parts.hint.Visible = player:canSkip()
		if parts.hint.Visible and parts.hint.Text == "" then
			parts.hint.Text = if options.text then options.text("uikit.hold_to_skip") else "Hold to skip"
		end
		parts.progress.Size = r.UDim2.new(frame.skipProgress, 0, 0, 2)
		for _, event in frame.events do
			if options.onEvent then
				local ok, err = pcall(options.onEvent, event.name, event.payload, frame.state == "skipped")
				if not ok then
					env.report("Cinematics onEvent error: " .. tostring(err))
				end
			end
		end
	end

	local function finish(state: string)
		if done then
			return
		end
		done = true
		for _, connection in connections do
			connection:Disconnect()
		end
		if options.skipContext then
			options.skipContext.Enabled = false
		end
		camera.CameraType = saved.CameraType
		camera.CFrame = saved.CFrame
		camera.Focus = saved.Focus
		camera.FieldOfView = saved.FieldOfView
		gui:Destroy()
		if options.onFinished then
			local ok, err = pcall(options.onFinished, state)
			if not ok then
				env.report("Cinematics onFinished error: " .. tostring(err))
			end
		end
	end

	camera.CameraType = r.Enum.CameraType.Scriptable
	if options.skipContext then
		options.skipContext.Enabled = true
	end
	if options.skipAction then
		table.insert(
			connections,
			options.skipAction.Pressed:Connect(function()
				skipHeld = true
			end)
		)
		table.insert(
			connections,
			options.skipAction.Released:Connect(function()
				skipHeld = false
			end)
		)
	end
	local runService = Env.service(env, "RunService")
	apply(player:step(0))
	table.insert(
		connections,
		runService.PreRender:Connect(function(dt: number)
			local frame = player:step(dt, skipHeld)
			apply(frame)
			if frame.state ~= "playing" then
				finish(frame.state)
			end
		end)
	)
	-- The camera leaving the workspace (character reset swaps it) ends the run.
	table.insert(
		connections,
		camera.Destroying:Connect(function()
			finish("stopped")
		end)
	)

	function handle.skip(_self: any): boolean
		local frame = player:skip()
		if frame == nil then
			return false
		end
		apply(frame)
		finish("skipped")
		return true
	end
	function handle.stop(_self: any)
		player:stop()
		finish("stopped")
	end
	function handle.state(_self: any): string
		return if done then player:state() else "playing"
	end
	function handle.time(_self: any): number
		return player:time()
	end
	return handle
end

-- A camera key from the camera's current view (Studio authoring): position, a lookAt
-- distance studs ahead and the field of view, rounded to 1e-3.
function CinematicsRoblox.keyFromCamera(camera: any, t: number, distance: number?): Cinematics.Key
	local cf = camera.CFrame
	local ahead = cf.Position + cf.LookVector * (distance or 20)
	local function round(v: number): number
		return math.round(v * 1000) / 1000
	end
	return {
		t = t,
		position = { round(cf.Position.X), round(cf.Position.Y), round(cf.Position.Z) },
		lookAt = { round(ahead.X), round(ahead.Y), round(ahead.Z) },
		fov = round(camera.FieldOfView),
	}
end

return CinematicsRoblox
