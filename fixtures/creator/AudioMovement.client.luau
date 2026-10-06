--!strict
-- Neutral parameter and SoundGroup diagnostic. No asset playback or character controller.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local SoundService = game:GetService("SoundService")
local packages = game:GetService("ReplicatedStorage").Workbench
local Director = require(packages.Creator.AudioDirector)
local Movement = require(packages.Creator.MovementProfile)
local Mixer = require(packages.Runtime.AudioMixer)
local NativeAudio = require(packages.Runtime.NativeAudio)
local player = assert(Players.LocalPlayer, "native client required")
local checks, samples, backendCalls = {}, {}, 0
local function check(name, passed)
	table.insert(checks, { name = name, passed = passed })
end
local mixer = Mixer.new({ "layerA", "layerB", "effects" })
local native = NativeAudio.new(mixer, { "layerA", "layerB", "effects" }, SoundService)
local director = Director.new(
	{
		events = {
			missing = { channel = "effects", configured = false, gain = 1, looped = false },
			rejected = { channel = "effects", configured = true, gain = 1, looped = false },
		},
		states = { quiet = { layerA = 1, layerB = 0 }, active = { layerA = 0, layerB = 1 } },
	},
	mixer,
	{
		play = function()
			backendCalls += 1
			return false
		end,
		stop = function() end,
	}
)
check("missing asset suppresses backend", not director:emit("missing") and backendCalls == 0)
check("unavailable backend is explicit", not director:emit("rejected") and backendCalls == 1)
director:setState("quiet", 0, false)
director:setState("active", 2, false)
native:step(1)
check(
	"native groups receive midpoint crossfade",
	native.groups.layerA.Volume == 0.5 and native.groups.layerB.Volume == 0.5
)
director:setState("quiet", 2, false)
native:step(0)
check(
	"interrupted envelope preserves native current gains",
	native.groups.layerA.Volume == 0.5 and native.groups.layerB.Volume == 0.5
)
director:setState("active", 2, true)
native:step(0)
check(
	"reduced transition snaps native group",
	native.groups.layerA.Volume == 0 and native.groups.layerB.Volume == 1
)
local audioSnapshot = native:inspect()
director:destroy()
director:destroy()
native:destroy()
native:destroy()
check("native audio scope cleanup", SoundService:FindFirstChild("WorkbenchAudio") == nil)
local profile = {
	speed = 6,
	acceleration = 12,
	deceleration = 24,
	turnRate = math.pi,
	camera = { height = 6, distance = 12, fieldOfView = 70 },
}
local movement = Movement.new(profile)
local marker = Instance.new("Part")
marker.Name, marker.Anchored, marker.CanCollide = "MovementParameterDiagnostic", true, false
marker.Size, marker.Color = Vector3.new(0.5, 0.5, 0.5), Color3.fromRGB(120, 170, 210)
marker.Position, marker.Parent = Vector3.new(0, 4, 0), workspace
local elapsed, peak, clamped = 0, 0, 0
while elapsed < 1.4 do
	local frameDt = RunService.Heartbeat:Wait()
	local dt = math.min(frameDt, 0.25)
	if frameDt > 0.25 then
		clamped += 1
	end
	elapsed += frameDt
	local state = movement:step(if elapsed < 0.7 then 1 else 0, if elapsed < 0.7 then 1 else 0, dt)
	peak = math.max(peak, state.speed)
	marker.Position += Vector3.new(state.x, 0, state.z) * dt
	table.insert(samples, {
		time = elapsed,
		dt = frameDt,
		solverDt = dt,
		speed = state.speed,
		heading = state.heading,
		position = { marker.Position.X, marker.Position.Y, marker.Position.Z },
		input = if elapsed < 0.7 then { 1, 1 } else { 0, 0 },
	})
end
check("diagonal parameter speed remains bounded", peak <= profile.speed + 0.000001)
check("parameter preview decelerates to stop", movement:step(0, 0, 0).speed == 0)
marker:Destroy()
check("owned parameter marker removed", workspace:FindFirstChild("MovementParameterDiagnostic") == nil)
local evidence = Instance.new("StringValue")
evidence.Name = "WorkbenchCreatorAudioMovementEvidence"
evidence.Value = HttpService:JSONEncode({
	mode = "SETUP_ONLY",
	method = "assisted_native_parameter_diagnostic",
	placeId = game.PlaceId,
	universeId = game.GameId,
	checks = checks,
	audio = audioSnapshot,
	director = director:inspect(),
	movementSamples = samples,
	cameraParameters = movement:camera(),
	largeFrameClamps = clamped,
	limits = {
		"SoundGroup state only; no asset playback, permission or heard audio proof.",
		"Synthetic fixture inputs move one anchored marker; no avatar physics, collision, jumping or feel acceptance.",
	},
})
evidence.Parent = player.PlayerScripts
