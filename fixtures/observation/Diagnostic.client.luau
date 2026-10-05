--!strict
-- Neutral camera/trace/ring/cleanup fixture; requires source hashes injected by the host.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
if not RunService:IsStudio() or game.GameId ~= 0 or game.PlaceId ~= 0 then
	warn("Workbench scenario refused: unpublished Studio target required")
	return
end
local configValue = game:GetService("ReplicatedStorage"):WaitForChild("WorkbenchScenarioConfiguration", 20)
if not configValue or not configValue:IsA("StringValue") then
	warn("Workbench scenario blocked: host source/device configuration missing")
	return
end
local config = HttpService:JSONDecode(configValue.Value)
local deadline = os.clock() + 20
local stable = 0
local previousViewport = Vector2.zero
while stable < 4 and os.clock() < deadline do
	RunService.RenderStepped:Wait()
	local camera = workspace.CurrentCamera
	local view = if camera then camera.ViewportSize else Vector2.zero
	if view.X >= 320 and view.Y >= 240 and view == previousViewport then
		stable += 1
	else
		stable = 0
	end
	previousViewport = view
end
if stable < 4 then
	warn("Workbench scenario blocked: viewport did not stabilize")
	return
end
local root = Instance.new("Folder")
root.Name, root.Parent = "WorkbenchObservationNeutralFixture", workspace
root:SetAttribute("WorkbenchOwned", true)
local part = Instance.new("Part")
part.Name, part.Size, part.Position = "NeutralObservedPart", Vector3.new(2, 2, 2), Vector3.new(0, 3, 0)
part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, false, false, false
part.Color, part.Parent = Color3.fromRGB(95, 151, 192), root
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.Parent =
	"WorkbenchObservationStatus", false, Players.LocalPlayer:WaitForChild("PlayerGui")
gui:SetAttribute("WorkbenchOwned", true)
local label = Instance.new("TextLabel")
label.Name, label.Size, label.AnchorPoint = "Status", UDim2.fromOffset(270, 96), Vector2.new(1, 1)
label.TextWrapped = true
label.Position, label.Text, label.TextSize =
	UDim2.new(1, -16, 1, -16), "OBSERVATION / PROGRAMMATIC\nNo gameplay or physical input claim", 16
label.BackgroundColor3, label.TextColor3, label.Parent = Color3.fromRGB(24, 37, 48), Color3.new(1, 1, 1), gui
local receipt = Instance.new("StringValue")
receipt.Name, receipt.Parent = "WorkbenchScenarioEvidence", Players.LocalPlayer:WaitForChild("PlayerScripts")
local Observation = require(
	game:GetService("ReplicatedStorage")
		:WaitForChild("Workbench")
		:WaitForChild("Creator")
		:WaitForChild("Observation")
)
local camera = workspace.CurrentCamera
local originalType, originalFrame, originalFov = camera.CameraType, camera.CFrame, camera.FieldOfView
local checks = {}
local function check(name, passed)
	table.insert(checks, { name = name, passed = passed == true })
end
local observer
local ok, failure = pcall(function()
	observer = Observation.new({
		id = "native-neutral-observation",
		roots = { root, gui },
		actors = { { id = "neutral-part", part = part } },
		ui = { { id = "status-label", object = label } },
		animators = {},
		seed = 1005,
		limits = { max_samples = 8, max_events = 6, max_duration_seconds = 5 },
		studio_id = config.studio_id,
		source_manifest = config.source_manifest,
		device = config.device,
		privacy = {
			retention_permitted = true,
			raw_identifiers_excluded = true,
			reviewed_by = "owned diagnostic fixture",
		},
		cameras = config.cameras,
		input_origin = "programmatic",
	})
	check("invalid sample interval rejected", not pcall(observer.sample, observer, 0))
	check(
		"nonfinite action rejected",
		not pcall(observer.recordAction, observer, "fixture_action", "programmatic", "invalid", { math.huge })
	)
	check(
		"false physical input label rejected",
		not pcall(observer.recordAction, observer, "input_began", "physical_user", "key-tab", {})
	)
	observer:showCollisionBounds(true)
	check("owned collision bounds created", root:FindFirstChild("WorkbenchCollisionBounds") ~= nil)
	observer:recordAction("marker", "programmatic", "sync-start", {})
	local started = os.clock()
	for index = 1, 24 do
		local dt = RunService.RenderStepped:Wait()
		if index == 1 or index == 9 or index == 17 then
			local name = if index == 1 then "player" elseif index == 9 then "overview" else "inspection"
			observer:setCamera(name)
			local definition = config.cameras[name]
			check(
				name .. " camera applies fixed position",
				(camera.CFrame.Position - Vector3.new(table.unpack(definition.position))).Magnitude < 0.001
			)
		end
		part.Position = Vector3.new(index / 12, 3, 0)
		observer:recordAction("fixture_action", "programmatic", "translated-marker", { index })
		observer:sample(dt)
		if os.clock() - started > 4.5 then
			break
		end
	end
	observer:recordAction("marker", "programmatic", "sync-end", {})
	observer:stop()
	local trace = observer:export()
	check("bounded sample ring retains eight rows", #trace.samples == 8 and trace.limits.dropped_samples > 0)
	check("bounded event ring records drops", #trace.events == 6 and trace.limits.dropped_events > 0)
	check(
		"trace records native owned position",
		trace.samples[#trace.samples].actors[1].position[1] == part.Position.X
	)
	check(
		"anchored translation is not physical velocity",
		trace.samples[#trace.samples].actors[1].velocity[1] == 0
	)
	check(
		"UI/performance/count snapshots exist",
		#trace.samples[#trace.samples].ui == 1
			and trace.samples[#trace.samples].counts.parts == 1
			and trace.samples[#trace.samples].performance.frame_ms > 0
	)
	check("stopped recorder refuses more rows", observer:sample(1 / 60) == false)
	observer:destroy()
	check(
		"camera state restored",
		camera.CameraType == originalType
			and camera.CFrame == originalFrame
			and camera.FieldOfView == originalFov
	)
	check("collision overlay removed", root:FindFirstChild("WorkbenchCollisionBounds") == nil)
	observer:destroy()
	check("repeated destroy is harmless", observer.destroyed == true)
	receipt.Value = HttpService:JSONEncode({
		mode = "SETUP_ONLY",
		method = "assisted_native_diagnostic",
		status = "partially_verified",
		checks = checks,
		trace = trace,
		limits = {
			physical_input = "NOT_VERIFIED",
			animation_quality = "NOT_VERIFIED",
			video_sync = "NOT_VERIFIED",
			gpu_server_network = "NOT_VERIFIED",
		},
	})
end)
if observer then
	observer:destroy()
end
root:Destroy()
gui:Destroy()
if not ok then
	receipt.Value = HttpService:JSONEncode({
		mode = "SETUP_ONLY",
		status = "blocked",
		checks = checks,
		error = tostring(failure),
	})
	warn("Workbench observation fixture blocked")
end
