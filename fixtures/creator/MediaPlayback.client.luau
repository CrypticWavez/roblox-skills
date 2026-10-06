--!strict
-- Local-only engine diagnostic: authored temporary clips and a silent bundled sound.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ContentProvider = game:GetService("ContentProvider")
local Provider = game:GetService("KeyframeSequenceProvider")
local Inspector = require(game:GetService("ReplicatedStorage").Workbench.Creator.AnimationInspector)
local player = assert(Players.LocalPlayer, "Studio client required")
assert(RunService:IsStudio() and game.GameId == 0 and game.PlaceId == 0, "Unpublished Studio diagnostic only")
assert(not workspace:FindFirstChild("WorkbenchLocalMediaProbe"), "Owned root already exists")
local sourceManifest =
	HttpService:JSONDecode(assert(script:GetAttribute("SourceManifest"), "Actual source binding required"))
local studioId = assert(script:GetAttribute("StudioId"), "Explicit target required")
local root = Instance.new("Model")
root.Name, root.Parent = "WorkbenchLocalMediaProbe", workspace
root:SetAttribute("WorkbenchOwned", true)
local checks, audioSamples, fetches, tracks, assets, cueDispatches = {}, {}, {}, {}, {}, {}
local cueConnection = nil
local api, trace = nil, nil
local function check(name, passed)
	table.insert(checks, { name = name, passed = passed == true })
end
local function part(name, anchored, position, parent)
	local p = Instance.new("Part")
	p.Name, p.Anchored, p.Position, p.Parent = name, anchored, position, parent
	p.Size, p.CanCollide, p.CanTouch, p.CanQuery = Vector3.one, false, false, false
	p.Massless = true
	return p
end
local body = part("Root", true, Vector3.new(0, 202, 0), root)
local limb = part("Limb", false, Vector3.new(0, 200, 0), body)
local motor = Instance.new("Motor6D")
motor.Part0, motor.Part1, motor.C0, motor.Parent = body, limb, CFrame.new(0, -2, 0), body
local controller = Instance.new("AnimationController")
controller.Parent = root
local animator = Instance.new("Animator")
animator.Parent = controller
local function clip(moving, priority)
	local sequence = Instance.new("KeyframeSequence")
	sequence.Loop, sequence.Priority = true, priority
	table.insert(assets, sequence)
	for i, time in { 0, 0.4, 0.8 } do
		local key = Instance.new("Keyframe")
		key.Time, key.Parent = time, sequence
		local pose = Instance.new("Pose")
		pose.Name, pose.Weight, pose.Parent = "Root", 0, key
		local child = Instance.new("Pose")
		child.Name, child.Weight, child.Parent = "Limb", 1, pose
		child.CFrame = CFrame.new(if moving then (if i == 2 then 0.4 else -0.4) else 0, 0, 0)
		if moving and i == 2 then
			local marker = Instance.new("KeyframeMarker")
			marker.Name, marker.Value, marker.Parent = "ProbePeak", "owned-neutral", key
		end
	end
	local animation = Instance.new("Animation")
	table.insert(assets, animation)
	animation.AnimationId = Provider:RegisterKeyframeSequence(sequence)
	local track = animator:LoadAnimation(animation)
	table.insert(tracks, track)
	return track
end
local sound = Instance.new("Sound")
sound.Name, sound.SoundId, sound.Volume, sound.Looped =
	"SilentBundledProbe", "rbxasset://sounds/action_footsteps_plastic.mp3", 0, true
sound.Parent = root
local missing = Instance.new("Sound")
missing.SoundId, missing.Volume, missing.Parent =
	"rbxasset://sounds/workbench_missing_diagnostic_20261005.wav", 0, root
local function preload(label, object)
	local done, success = false, false
	local worker = task.spawn(function()
		success = pcall(function()
			ContentProvider:PreloadAsync({ object }, function(_, status)
				table.insert(fetches, { label = label, status = status.Name })
			end)
		end)
		done = true
	end)
	local deadline = os.clock() + 5
	while not done and os.clock() < deadline do
		RunService.Heartbeat:Wait()
	end
	if not done then
		task.cancel(worker)
	end
	return done and success
end
local ok, err = pcall(function()
	local loaded = preload("bundled", sound)
	check("bundled sound loaded with positive length", loaded and sound.IsLoaded and sound.TimeLength > 0)
	preload("missing-local", missing)
	local failed = false
	for _, row in fetches do
		if row.label == "missing-local" and row.status ~= "Success" then
			failed = true
		end
	end
	check("missing local sound fetch failure recorded", failed and not missing.IsLoaded)
	local a, b = clip(true, Enum.AnimationPriority.Movement), clip(false, Enum.AnimationPriority.Action)
	local mediaStart = os.clock()
	api = Inspector.new({
		root = root,
		animator = animator,
		studio_id = studioId,
		source_manifest = sourceManifest,
		privacy = { retention_permitted = true, raw_identifiers_excluded = true },
		probes = { { id = "neutral-limb", object = limb, plane_offset_y = 200 } },
		markers = { "ProbePeak" },
		max_samples = 200,
		max_duration = 20,
	})
	cueConnection = a:GetMarkerReachedSignal("ProbePeak"):Connect(function()
		if #cueDispatches < 8 then
			sound.TimePosition = 0
			sound:Play()
			table.insert(
				cueDispatches,
				{ time = os.clock() - mediaStart, volume = sound.Volume, playing = sound.IsPlaying }
			)
		end
	end)
	a:Play(0.3, 1, 1)
	b:Play(0.3, 0.25, 1)
	sound:Play()
	api:sample()
	local deadline, nextSample = os.clock() + 12, os.clock() + 0.05
	while os.clock() < deadline do
		RunService.RenderStepped:Wait()
		if os.clock() < nextSample then
			continue
		end
		nextSample = os.clock() + 0.05
		if not api:sample() then
			break
		end
		table.insert(audioSamples, {
			playing = sound.IsPlaying,
			time_position = sound.TimePosition,
			length = sound.TimeLength,
			volume = sound.Volume,
		})
		if #cueDispatches >= 2 then
			break
		end
	end
	trace = api:export()
	local active, moved, advanced, peak, silentPlaying = false, false, false, 0, false
	for _, sample in trace.samples do
		local priorities = {}
		for _, track in sample.tracks do
			priorities[track.priority] = true
			advanced = advanced or (track.playing and track.length > 0 and track.time_position > 0)
		end
		active = active or (priorities.Movement and priorities.Action)
		moved = moved or math.abs(sample.joints[1].translation[1]) > 0.01
	end
	for _, sample in audioSamples do
		peak = math.max(peak, sample.time_position)
		silentPlaying = silentPlaying or (sample.playing and sample.volume == 0)
	end
	check("two temporary animation priorities observed", active)
	check("temporary track timing advances", advanced)
	check("authored joint translation observed", moved)
	check("real temporary clip marker signal observed", #trace.events > 0)
	check("real marker dispatches silent sound", #cueDispatches > 0 and #cueDispatches == #trace.events)
	check("silent bundled sound engine timing advances", silentPlaying and peak > 0)
	check("probe remained explicitly unplanted", trace.samples[1].probes[1].planted == false)
	api:destroy()
	check("inspector cleanup preserves caller geometry", root.Parent == workspace and limb.Parent == body)
end)
if api then
	api:destroy()
end
if cueConnection then
	cueConnection:Disconnect()
end
sound:Stop()
for _, track in tracks do
	track:Stop(0)
	track:Destroy()
end
for _, asset in assets do
	asset:Destroy()
end
root:Destroy()
check("owned local media scope removed", workspace:FindFirstChild("WorkbenchLocalMediaProbe") == nil)
local passed = ok
for _, row in checks do
	passed = passed and row.passed
end
local receipt = Instance.new("StringValue")
receipt.Name = "WorkbenchLocalMediaEvidence"
receipt.Value = HttpService:JSONEncode({
	schema_version = 1,
	mode = "SETUP_ONLY",
	method = "assisted_native_local_media_diagnostic",
	status = if passed then "partially_verified" else "blocked",
	placeId = game.PlaceId,
	universeId = game.GameId,
	capture_date = DateTime.now():ToIsoDate(),
	checks = checks,
	trace = trace,
	audio_samples = audioSamples,
	marker_sound_dispatches = cueDispatches,
	fetch_statuses = fetches,
	error = if ok then nil else tostring(err),
	limitations = {
		"Studio-only temporary local clips; no uploaded animation or production ownership/permission acceptance.",
		"Sound Volume is zero: engine state/timing only, hearing NOT_VERIFIED. Missing bundled path is not an account permission failure.",
		"Manual sparse samples, two-part neutral rig and declared unplanted probe; no avatar physics/contact/visual-quality acceptance.",
		"Temporary animation registration cache is Studio-session scoped; no individual unregister API used.",
	},
})
receipt.Parent = player.PlayerScripts
