--!strict
-- SETUP_ONLY bounded native inspection. No gameplay, remotes, uploads or screen recording.
local Env = require("../GameKit/Env")

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Observation = {}

-- Target check shared by the Creator inspectors (Observation, AnimationInspector, WorldInspector)
-- and kit debug code: GameKit/Env.check on the running session's place, ok only in Studio with
-- GameId 0 and PlaceId 0. Server and client both qualify, so server probes can inspect too; a
-- published game or place is refused (reasons published_game, published_place, not_studio).
local function assertDiagnosticTarget(what: string)
	local ok, env = pcall(Env.studio)
	Env.assertDiagnostic(if ok then env else {} :: any, what)
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function label(value: any): boolean
	return type(value) == "string"
		and #value > 0
		and #value <= 80
		and value:match("^[a-z][a-z0-9_-]*$") ~= nil
end

local function vector(value: Vector3): { number }
	return { value.X, value.Y, value.Z }
end

local function copy(value: any, depth: number?): any
	local current = depth or 0
	assert(current <= 16, "observation metadata nesting exceeds cap")
	if type(value) ~= "table" then
		assert(
			type(value) == "string" or type(value) == "boolean" or value == nil or finite(value),
			"metadata must be JSON values"
		)
		return value
	end
	local result = {}
	for key, child in value do
		assert(type(key) == "string" or type(key) == "number", "invalid metadata key")
		result[key] = copy(child, current + 1)
	end
	return result
end

local function ring(capacity: number): any
	local result: any = { capacity = capacity, rows = {}, first = 1, count = 0, dropped = 0 }
	function result:push(row: any)
		if self.count < self.capacity then
			self.rows[(self.first + self.count - 1) % self.capacity + 1] = row
			self.count += 1
		else
			self.rows[self.first] = row
			self.first = self.first % self.capacity + 1
			self.dropped += 1
		end
	end
	function result:export(): any
		local rows = {}
		for index = 0, self.count - 1 do
			table.insert(rows, copy(self.rows[(self.first + index - 1) % self.capacity + 1]))
		end
		return rows
	end
	return result
end

function Observation.new(options: any): any
	assertDiagnosticTarget("Observation")
	assert(type(options) == "table" and label(options.id), "observation options need a stable id")
	assert(
		type(options.roots) == "table" and #options.roots >= 1 and #options.roots <= 4,
		"one to four owned roots required"
	)
	for _, root in options.roots do
		assert(
			typeof(root) == "Instance" and root:GetAttribute("WorkbenchOwned") == true,
			"roots need explicit WorkbenchOwned ownership"
		)
	end
	local roots = table.clone(options.roots)
	local function owned(instance: Instance): boolean
		for _, root in roots do
			if instance == root or instance:IsDescendantOf(root) then
				return true
			end
		end
		return false
	end
	local limits = copy(options.limits or { max_samples = 600, max_events = 128, max_duration_seconds = 30 })
	assert(
		finite(limits.max_samples)
			and limits.max_samples % 1 == 0
			and limits.max_samples >= 2
			and limits.max_samples <= 3600,
		"invalid sample cap"
	)
	assert(
		finite(limits.max_events)
			and limits.max_events % 1 == 0
			and limits.max_events >= 1
			and limits.max_events <= 1000,
		"invalid event cap"
	)
	assert(
		finite(limits.max_duration_seconds)
			and limits.max_duration_seconds > 0
			and limits.max_duration_seconds <= 180,
		"invalid duration cap"
	)
	assert(
		finite(options.seed) and options.seed % 1 == 0 and options.seed >= 0 and options.seed <= 4294967295,
		"invalid scenario seed"
	)
	assert(
		options.input_origin == "programmatic"
			or options.input_origin == "assisted_native"
			or options.input_origin == "physical_user",
		"native input origin must be explicit"
	)
	assert(
		type(options.privacy) == "table"
			and options.privacy.retention_permitted == true
			and options.privacy.raw_identifiers_excluded == true,
		"privacy/retention review required"
	)
	assert(
		type(options.source_manifest) == "table"
			and type(options.source_manifest.files) == "table"
			and next(options.source_manifest.files) ~= nil,
		"source hashes must be supplied from filesystem readback"
	)
	assert(
		type(options.device) == "table" and type(options.studio_id) == "string" and #options.studio_id > 0,
		"explicit device and Studio target required"
	)
	if options.input_origin == "physical_user" then
		assert(
			options.device.emulated == false and type(options.physical_review) == "table",
			"physical input requires a retained human review receipt and real hardware"
		)
	end
	local camera = workspace.CurrentCamera
	assert(
		camera and camera.ViewportSize.X >= 2 and camera.ViewportSize.Y >= 2,
		"stable native viewport required"
	)
	local previous = {
		cameraType = camera.CameraType,
		cframe = camera.CFrame,
		focus = camera.Focus,
		fieldOfView = camera.FieldOfView,
		subject = camera.CameraSubject,
	}
	for _, name in { "player", "overview", "inspection" } do
		local definition = options.cameras and options.cameras[name]
		assert(
			type(definition) == "table" and definition.mode == "fixed",
			"all three fixed camera definitions required"
		)
		for _, key in { "position", "look_at" } do
			assert(
				type(definition[key]) == "table" and #definition[key] == 3,
				"camera vectors require three numbers"
			)
			for _, component in definition[key] do
				assert(
					finite(component) and math.abs(component) <= 1000000,
					"camera vector must be finite and bounded"
				)
			end
		end
		assert(
			finite(definition.field_of_view)
				and definition.field_of_view >= 1
				and definition.field_of_view <= 120,
			"invalid camera field of view"
		)
		assert(
			Vector3.new(table.unpack(definition.position)) ~= Vector3.new(table.unpack(definition.look_at)),
			"camera look target cannot equal position"
		)
	end
	assert(
		type(options.actors) == "table" and #options.actors >= 1 and #options.actors <= 32,
		"one to 32 tracked owned parts required"
	)
	local ids = {}
	for _, actor in options.actors do
		assert(
			label(actor.id)
				and not ids[actor.id]
				and typeof(actor.part) == "Instance"
				and actor.part:IsA("BasePart")
				and owned(actor.part),
			"actors require unique labels and owned BaseParts"
		)
		ids[actor.id] = true
	end
	local actors = {}
	for _, actor in options.actors do
		table.insert(actors, { id = actor.id, part = actor.part })
	end
	local gui = {}
	for _, item in options.ui or {} do
		table.insert(gui, { id = item.id, object = item.object })
	end
	assert(#gui <= 32, "UI registration cap exceeded")
	ids = {}
	for _, item in gui do
		assert(
			label(item.id)
				and not ids[item.id]
				and typeof(item.object) == "Instance"
				and item.object:IsA("GuiObject")
				and owned(item.object),
			"UI requires unique labels and owned GuiObjects"
		)
		ids[item.id] = true
	end
	local animators = {}
	for _, item in options.animators or {} do
		table.insert(animators, { actor_id = item.actor_id, animator = item.animator })
	end
	assert(#animators <= 32, "Animator registration cap exceeded")
	for _, item in animators do
		assert(
			label(item.actor_id)
				and typeof(item.animator) == "Instance"
				and item.animator:IsA("Animator")
				and owned(item.animator),
			"Animator must belong to an owned tracked actor"
		)
		local found = false
		for _, actor in actors do
			found = found or actor.id == item.actor_id
		end
		assert(found, "Animator actor label is not registered")
	end
	local api: any = {
		destroyed = false,
		stopped = false,
		cameraName = "unmanaged",
		cameraOwned = false,
		error = nil,
		running = false,
		inputBound = false,
	}
	local samples, events = ring(limits.max_samples), ring(limits.max_events)
	local started, eventSerial, lastTime = os.clock(), 0, 0
	local capturedAt = DateTime.now():ToIsoDate()
	local pending, connections = {}, {}
	local droppedActions, trackSerial = 0, 0
	local trackLabels: any = setmetatable({}, { __mode = "k" })
	local overlays: Folder? = nil
	local metadata = copy({
		id = options.id,
		seed = options.seed,
		studio_id = options.studio_id,
		source_manifest = options.source_manifest,
		device = options.device,
		privacy = options.privacy,
		cameras = options.cameras,
		input_origin = options.input_origin,
		physical_review = options.physical_review,
	})
	local function cameraState(): any
		local current = workspace.CurrentCamera
		assert(current, "native camera disappeared")
		return {
			name = if current == camera then api.cameraName else "unmanaged",
			camera_type = current.CameraType.Name,
			position = vector(current.CFrame.Position),
			look_vector = vector(current.CFrame.LookVector),
			field_of_view = current.FieldOfView,
			viewport = { current.ViewportSize.X, current.ViewportSize.Y },
		}
	end
	local function actorState(): any
		local rows = {}
		for _, actor in actors do
			table.insert(rows, {
				id = actor.id,
				position = vector(actor.part.Position),
				velocity = vector(actor.part.AssemblyLinearVelocity),
				present = owned(actor.part),
			})
		end
		return rows
	end
	local initial = { actors = actorState(), camera = cameraState() }
	function api:recordAction(kind: string, origin: string, control: string, value: any): boolean
		assert(
			kind == "input_began"
				or kind == "input_ended"
				or kind == "fixture_action"
				or kind == "camera_mode"
				or kind == "marker",
			"unsupported action kind"
		)
		assert(
			origin == "programmatic" or origin == metadata.input_origin,
			"action origin contradicts declared input provenance"
		)
		assert(
			label(control) and type(value) == "table" and #value <= 4,
			"action needs a sanitized label and bounded numeric values"
		)
		for _, component in value do
			assert(
				finite(component) and math.abs(component) <= 1000000,
				"action values must be finite and bounded"
			)
		end
		local time = os.clock() - started
		if self.stopped or self.destroyed or time > limits.max_duration_seconds then
			return false
		end
		eventSerial += 1
		local action = { kind = kind, origin = origin, control = control, value = copy(value) }
		events:push({ id = "event-" .. eventSerial, time = time, action = action })
		if #pending >= 16 then
			table.remove(pending, 1)
			droppedActions += 1
		end
		table.insert(pending, action)
		lastTime = math.max(lastTime, time)
		return true
	end
	function api:setCamera(name: string)
		assert(
			not self.destroyed and not self.stopped and metadata.cameras[name],
			"invalid or inactive camera preset"
		)
		assert(
			workspace.CurrentCamera == camera,
			"camera changed; serialize ownership before applying presets"
		)
		local definition = metadata.cameras[name]
		local target = Vector3.new(table.unpack(definition.look_at))
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.lookAt(Vector3.new(table.unpack(definition.position)), target)
		camera.Focus = CFrame.new(target)
		camera.FieldOfView = definition.field_of_view
		self.cameraName, self.cameraOwned = name, true
		self:recordAction("camera_mode", "programmatic", name, {})
	end
	function api:showCollisionBounds(enabled: boolean)
		assert(not self.destroyed and type(enabled) == "boolean", "invalid overlay state")
		if overlays then
			overlays:Destroy()
			overlays = nil
		end
		if enabled then
			local folder = Instance.new("Folder")
			folder.Name, folder.Parent = "WorkbenchCollisionBounds", roots[1]
			overlays = folder
			for _, actor in actors do
				local box = Instance.new("SelectionBox")
				box.Name, box.Adornee = "OwnedCollisionBounds", actor.part
				box.LineThickness, box.SurfaceTransparency = 0.035, 1
				box.Color3 = if actor.part.CanCollide
					then Color3.fromRGB(89, 207, 137)
					else Color3.fromRGB(230, 146, 85)
				box.Parent = folder
			end
		end
	end
	function api:sample(dt: number): boolean
		assert(finite(dt) and dt > 0, "sample interval must be finite and positive")
		local time = os.clock() - started
		if self.stopped or self.destroyed then
			return false
		end
		if time > limits.max_duration_seconds then
			self:stop()
			return false
		end
		local rows, uiRows = {}, {}
		for _, item in animators do
			for _, track in item.animator:GetPlayingAnimationTracks() do
				assert(#rows < 32, "active animation snapshot cap exceeded")
				if not trackLabels[track] then
					trackSerial += 1
					trackLabels[track] = "track-" .. trackSerial
				end
				table.insert(rows, {
					actor_id = item.actor_id,
					track_label = trackLabels[track],
					priority = track.Priority.Name,
					time_position = track.TimePosition,
					speed = track.Speed,
					weight = track.WeightCurrent,
					playing = track.IsPlaying,
				})
			end
		end
		for _, item in gui do
			local object = item.object
			local fits = true
			if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
				fits = object.TextBounds.X <= object.AbsoluteSize.X + 1
					and object.TextBounds.Y <= object.AbsoluteSize.Y + 1
			end
			table.insert(uiRows, {
				id = item.id,
				bounds = {
					object.AbsolutePosition.X,
					object.AbsolutePosition.Y,
					object.AbsoluteSize.X,
					object.AbsoluteSize.Y,
				},
				visible = object.Visible,
				text_fits = fits,
			})
		end
		local counts = {
			owned_instances = 0,
			parts = 0,
			gui_objects = 0,
			active_animation_tracks = #rows,
			effect_instances = 0,
		}
		local seen = {}
		for _, root in roots do
			local descendants = root:GetDescendants()
			assert(#descendants <= 5000, "owned root descendant cap exceeded")
			table.insert(descendants, root)
			for _, instance in descendants do
				if not seen[instance] then
					seen[instance] = true
					counts.owned_instances += 1
					counts.parts += if instance:IsA("BasePart") then 1 else 0
					counts.gui_objects += if instance:IsA("GuiObject") then 1 else 0
					counts.effect_instances += if instance:IsA("ParticleEmitter")
							or instance:IsA("Beam")
							or instance:IsA("Trail")
						then 1
						else 0
				end
			end
		end
		assert(counts.owned_instances <= 5000, "combined owned instance cap exceeded")
		samples:push({
			time = time,
			dt = dt,
			actors = actorState(),
			camera = cameraState(),
			actions = copy(pending),
			animations = rows,
			ui = uiRows,
			counts = counts,
			performance = { frame_ms = dt * 1000, lua_memory_kb = gcinfo() },
		})
		pending = {}
		lastTime = math.max(lastTime, time)
		return true
	end
	function api:start()
		assert(
			not self.stopped and not self.destroyed and not self.running,
			"observation already running or closed"
		)
		self.running = true
		table.insert(
			connections,
			RunService.RenderStepped:Connect(function(dt)
				local ok, reason = pcall(self.sample, self, dt)
				if not ok then
					self.error = tostring(reason)
					self:stop()
				end
			end)
		)
	end
	function api:bindInput(origin: string)
		assert(
			origin ~= "programmatic"
				and origin == metadata.input_origin
				and not self.stopped
				and not self.destroyed
				and not self.inputBound,
			"input origin must match the declared capture"
		)
		self.inputBound = true
		local allowed = {
			Tab = true,
			Return = true,
			Escape = true,
			Space = true,
			W = true,
			A = true,
			S = true,
			D = true,
			ButtonA = true,
			ButtonB = true,
			DPadUp = true,
			DPadDown = true,
			DPadLeft = true,
			DPadRight = true,
		}
		local function input(kind, object, processed)
			-- Never log text-entry input or platform/chat processed events.
			if processed or UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			local key = object.KeyCode.Name
			if allowed[key] then
				self:recordAction(kind, origin, "key-" .. key:lower(), {})
			elseif
				object.UserInputType == Enum.UserInputType.MouseButton1
				or object.UserInputType == Enum.UserInputType.Touch
			then
				self:recordAction(kind, origin, object.UserInputType.Name:lower(), vector(object.Position))
			end
		end
		table.insert(
			connections,
			UserInputService.InputBegan:Connect(function(object, processed)
				input("input_began", object, processed)
			end)
		)
		table.insert(
			connections,
			UserInputService.InputEnded:Connect(function(object, processed)
				input("input_ended", object, processed)
			end)
		)
	end
	function api:stop()
		self.stopped = true
		self.running = false
		for _, connection in connections do
			connection:Disconnect()
		end
		connections = {}
	end
	function api:export(): any
		assert(samples.count >= 2 and not self.error, "capture needs two samples and no collection error")
		local device = copy(metadata.device)
		device.viewport = initial.camera.viewport
		return {
			schema_version = 1,
			id = metadata.id,
			mode = "SETUP_ONLY",
			method = if metadata.input_origin == "physical_user"
				then "physical_session_observation"
				else "assisted_native_observation",
			capture_date = capturedAt,
			target = { universe_id = game.GameId, place_id = game.PlaceId, studio_id = metadata.studio_id },
			source_manifest = copy(metadata.source_manifest),
			seed = metadata.seed,
			initial_state = copy(initial),
			nondeterminism = {
				"Seed is setup metadata only; RunService scheduling, physics, network, assets and actual input timing can diverge.",
				"Frame interval and Lua heap are sampled diagnostics; GPU, server and network timings are not measured.",
			},
			device = device,
			privacy = copy(metadata.privacy),
			input_origin = metadata.input_origin,
			physical_review = copy(metadata.physical_review),
			cameras = copy(metadata.cameras),
			limits = {
				max_samples = limits.max_samples,
				max_events = limits.max_events,
				max_duration_seconds = limits.max_duration_seconds,
				dropped_samples = samples.dropped,
				dropped_events = events.dropped,
				dropped_actions = droppedActions,
			},
			duration_seconds = lastTime,
			samples = samples:export(),
			events = events:export(),
		}
	end
	function api:destroy()
		if self.destroyed then
			return
		end
		self:stop()
		if overlays then
			overlays:Destroy()
			overlays = nil
		end
		if self.cameraOwned and camera.Parent ~= nil then
			camera.CameraType, camera.CFrame, camera.Focus =
				previous.cameraType, previous.cframe, previous.focus
			camera.FieldOfView, camera.CameraSubject = previous.fieldOfView, previous.subject
		end
		self.destroyed = true
	end
	return api
end

return Observation
