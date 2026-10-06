--!strict
-- G4 probe registry (prefix cin_): CinematicsRoblox on a real Camera. Run in a client play
-- session on the unpublished diagnostic place (tests/engine/cin_play_sample.luau); PENDING until
-- then. No requires: kit modules come through ctx.kit. The Lune registry spec runs it with a fake
-- camera and a RunService whose PreRender it fires by hand.
--   cin_play_sample  the camera follows Cinematics.sample while playing, events fire once and in
--                    order, finishing and skipping both restore the camera, skip fires only
--                    onSkip = "fire" events
local probes = {}

-- A short neutral cutscene (the orbit fixture is a ModuleScript the registry cannot require).
local CUTSCENE = {
	schema = "cinematics/1",
	id = "probe_pan",
	duration = 1.5,
	space = "world",
	camera = {
		keys = {
			{ t = 0, position = { 0, 10, -20 }, lookAt = { 0, 2, 0 }, fov = 70 },
			{ t = 0.75, position = { 12, 8, -12 }, lookAt = { 0, 2, 0 }, fov = 60 },
			{ t = 1.5, position = { 20, 6, 0 }, lookAt = { 0, 2, 0 }, fov = 50 },
		},
	},
	letterbox = { { t = 0, v = 0.1 } },
	events = {
		{ t = 0, name = "started", onSkip = "drop" },
		{ t = 0.75, name = "middle", onSkip = "drop" },
		{ t = 1.5, name = "done", onSkip = "fire" },
	},
	skip = { allowed = true, after = 0, hold = 0 },
}

function probes.cin_play_sample(ctx: any)
	local Cinematics = ctx.kit("Cinematics/Cinematics")
	local CinematicsRoblox = ctx.kit("Cinematics/CinematicsRoblox")
	local env = ctx.env
	local workspace = env.services.Workspace
	local camera = workspace and workspace.CurrentCamera
	if not ctx.check("camera", camera ~= nil, "env.services.Workspace.CurrentCamera") then
		return
	end
	local cin = Cinematics.define(CUTSCENE)
	local savedType = camera.CameraType
	local savedFov = camera.FieldOfView
	local players = env.services.Players
	local player = players and players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	local events = {}
	local finishedWith: string? = nil
	local handle = CinematicsRoblox.play(cin, {
		camera = camera,
		env = env,
		parent = playerGui,
		onEvent = function(name: string, _payload: any, skipped: boolean)
			table.insert(events, name .. (if skipped then ":skipped" else ""))
		end,
		onFinished = function(state: string)
			finishedWith = state
		end,
	})
	env.wait(0.5)
	local t = handle:time()
	local expected = Cinematics.sample(cin, t)
	local p = camera.CFrame.Position
	local offset = math.sqrt(
		(p.X - expected.position[1]) ^ 2 + (p.Y - expected.position[2]) ^ 2 + (p.Z - expected.position[3]) ^ 2
	)
	ctx.check("follows_sample", offset < 0.01, { t = t, offset = offset })
	-- The adapter builds the look-at frame itself (CFrame.fromMatrix); the engine must agree.
	local aim = expected.lookAt or { 0, 0, 0 }
	local dx, dy, dz = aim[1] - p.X, aim[2] - p.Y, aim[3] - p.Z
	local length = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 1e-9)
	local look = camera.CFrame.LookVector
	local dot = (dx * look.X + dy * look.Y + dz * look.Z) / length
	ctx.check("aims_at_look_at", dot > 0.9999, { dot = dot })
	ctx.check("fov_follows", math.abs(camera.FieldOfView - expected.fov) < 0.01, camera.FieldOfView)
	ctx.check("scriptable_while_playing", camera.CameraType.Name == "Scriptable", camera.CameraType.Name)
	if playerGui then
		local shown = playerGui:FindFirstChild("CinematicOverlay")
		local top = shown and shown:FindFirstChild("TopBar")
		ctx.check("letterbox_shown", top ~= nil and math.abs(top.Size.Y.Scale - expected.letterbox) < 1e-6)
	end
	env.wait(1.5)
	ctx.check("finished", finishedWith == "finished", finishedWith)
	if playerGui then
		ctx.check("overlay_removed", playerGui:FindFirstChild("CinematicOverlay") == nil)
	end
	ctx.check("events_once_in_order", table.concat(events, ",") == "started,middle,done", events)
	ctx.check("camera_type_restored", camera.CameraType == savedType, camera.CameraType.Name)
	ctx.check("fov_restored", math.abs(camera.FieldOfView - savedFov) < 1e-3, camera.FieldOfView)

	table.clear(events)
	finishedWith = nil
	local second = CinematicsRoblox.play(cin, {
		camera = camera,
		env = env,
		onEvent = function(name: string, _payload: any, skipped: boolean)
			table.insert(events, name .. (if skipped then ":skipped" else ""))
		end,
		onFinished = function(state: string)
			finishedWith = state
		end,
	})
	env.wait(0.2)
	ctx.check("skip_accepted", second:skip() == true)
	ctx.check("skipped", finishedWith == "skipped", finishedWith)
	ctx.check("skip_fires_only_fire_events", table.concat(events, ",") == "started,done:skipped", events)
	ctx.check("camera_restored_after_skip", camera.CameraType == savedType, camera.CameraType.Name)
end

return probes
