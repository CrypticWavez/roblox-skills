--!strict
-- Feel/FeelRoblox on @lune/roblox: a cue reaches the VFX and audio adapters, shake moves the
-- Camera, hit-stop pauses and restores a track, flashes drive the owned ColorCorrectionEffect,
-- popups become BillboardGuis on their anchor, settings/1 flags switch shake and haptics off,
-- and destroy removes everything it made. Haptics and the clock go through options.engine
-- (Lune has no HapticEffect playback). Studio proof is probe feel_marker_cue.
local roblox = require("@lune/roblox")
local FeelRoblox = require("../packages/Feel/FeelRoblox")
local Settings = require("../packages/GameKit/Settings")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function effective(patch: { [string]: any }): any
	local values = Settings.defaults()
	for key, value in patch do
		values[key] = value
	end
	return Settings.effective(values)
end

local function harness(patch: { [string]: any }?)
	local clock = 0
	local calls = { vfx = {}, audio = {}, haptics = {} }
	local camera = roblox.Instance.new("Camera")
	camera.FieldOfView = 70
	local gui = roblox.Instance.new("Folder")
	local feel = FeelRoblox.new({
		roblox = roblox,
		clock = function()
			return clock
		end,
	}, {
		camera = camera,
		guiParent = gui,
		effective = effective(patch or {}),
		vfx = {
			play = function(_self: any, id: string, at: any)
				table.insert(calls.vfx, id)
			end,
		},
		audio = {
			play = function(_self: any, id: string)
				table.insert(calls.audio, id)
			end,
		},
		engine = {
			now = function()
				return clock
			end,
			haptic = function(pattern: any)
				table.insert(calls.haptics, pattern.type)
			end,
		},
	})
	return feel, calls, camera, gui, function(value: number)
		clock = value
	end
end

local function fakeTrack()
	local track: any = { Speed = 1, adjustments = {} }
	function track:AdjustSpeed(speed: number)
		self.Speed = speed
		table.insert(self.adjustments, speed)
	end
	return track
end

test("a cue reaches VFX, audio and haptics; shake moves the camera; hit-stop pauses a track", function(t)
	local feel, calls, camera, _, setClock = harness()
	local track = fakeTrack()
	feel:freeze(track)
	local channels = assert(feel:fire("hit_heavy", { at = roblox.Vector3.zero }))
	t.eq(channels, { "vfx", "sound", "shake", "hitStop", "haptic", "flash" })
	t.eq(calls.vfx, { "hit_spark" })
	t.eq(calls.audio, { "hit_heavy" })
	t.eq(calls.haptics, { "GameplayCollision" })
	local before = camera.CFrame
	feel:step(1 / 60)
	t.ok(camera.CFrame ~= before, "the shake offset is applied")
	t.eq(track.Speed, 0, "frozen during hit-stop")
	local correction = camera:FindFirstChild("FeelColorCorrection")
	t.ok(correction.Brightness > 0, "the flash shows")
	setClock(0.2)
	feel:step(1 / 60)
	t.eq(track.Speed, 1, "speed restored after the freeze")
	t.eq(track.adjustments, { 0, 1 })
	setClock(2)
	feel:step(1 / 60)
	t.eq(correction.Brightness, 0)
end)

test("popups become BillboardGuis on their anchor and return to the pool", function(t)
	local feel, _, _, _, setClock = harness()
	local part = roblox.Instance.new("Part")
	feel:fire("heal", { anchor = part, value = 25 })
	feel:step(1 / 60)
	local billboard = part:FindFirstChildOfClass("BillboardGui")
	t.ok(billboard, "popup shown")
	local text = billboard:FindFirstChild("Text")
	t.eq(text.Text, "+25")
	t.eq(text:GetAttribute("PopupKind"), "heal")
	setClock(5)
	feel:step(1 / 60)
	t.eq(part:FindFirstChildOfClass("BillboardGui"), nil, "expired popups leave the anchor")
end)

test("reduced motion stops shake and FOV punches; haptics off stops haptics", function(t)
	local feel, calls, camera = harness({ reducedMotion = true, haptics = false })
	feel:fire("blast", { at = roblox.Vector3.zero })
	local before = camera.CFrame
	feel:step(1 / 60)
	t.eq(camera.CFrame, before, "no shake under reduced motion")
	t.eq(camera.FieldOfView, 70)
	t.eq(#calls.haptics, 0)
	t.eq(calls.vfx, { "explosion_small" }, "the visual channel stays")
end)

test("reduce-flashing keeps flashes soft", function(t)
	local feel, _, camera = harness({ reduceFlashing = true })
	feel:fire("blast", { at = roblox.Vector3.zero })
	feel:step(1 / 60)
	t.ok(camera:FindFirstChild("FeelColorCorrection").Brightness <= 0.12 + 1e-9)
end)

test("destroy removes owned effects and the vignette, and releases tracks", function(t)
	local feel, _, camera, gui = harness()
	local track = fakeTrack()
	feel:freeze(track)
	feel:fire("hit_light", { at = roblox.Vector3.zero })
	feel:step(1 / 60)
	t.eq(track.Speed, 0)
	t.ok(gui:FindFirstChild("FeelVignette"))
	feel:destroy()
	t.eq(camera:FindFirstChild("FeelColorCorrection"), nil)
	t.eq(camera:FindFirstChild("FeelBlur"), nil)
	t.eq(gui:FindFirstChild("FeelVignette"), nil)
	t.eq(track.Speed, 1)
	t.throws(function()
		FeelRoblox.new({ roblox = roblox }, {} :: any)
	end)
end)

return cases
