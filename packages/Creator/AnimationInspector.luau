--!strict
-- Read-only owned rig/Animator snapshots and bounded marker subscriptions. Never loads/plays assets.
local Env = require("../GameKit/Env")

local AnimationInspector = {}

-- Target check shared by the Creator inspectors (Observation, AnimationInspector, WorldInspector)
-- and kit debug code: GameKit/Env.check on the running session's place, ok only in Studio with
-- GameId 0 and PlaceId 0. Server and client both qualify, so server probes can inspect too; a
-- published game or place is refused (reasons published_game, published_place, not_studio).
local function assertDiagnosticTarget(what: string)
	local ok, env = pcall(Env.studio)
	Env.assertDiagnostic(if ok then env else {} :: any, what)
end
local defaults = {
	foot_slide_speed = 0.25,
	contact_tolerance = 0.1,
	max_sample_gap = 0.1,
	blend_step = 0.35,
	marker_error = 0.1,
	joint_translation_step = 0.5,
}
local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function label(value: any): boolean
	return type(value) == "string"
		and #value > 0
		and #value <= 80
		and value:match("^[a-z][a-z0-9_-]*$") ~= nil
end
local function array(value: any, cap: number): boolean
	if type(value) ~= "table" or #value > cap then
		return false
	end
	local count = 0
	for key in value do
		count += 1
		if count > cap or type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then
			return false
		end
	end
	return count == #value
end
local function vector(value: Vector3): { number }
	assert(
		finite(value.X)
			and finite(value.Y)
			and finite(value.Z)
			and math.max(math.abs(value.X), math.abs(value.Y), math.abs(value.Z)) <= 1000000,
		"position outside finite trace bounds"
	)
	return { value.X, value.Y, value.Z }
end
local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end
function AnimationInspector.validateThresholds(overrides: any): any
	assert(overrides == nil or type(overrides) == "table", "threshold table required")
	local result = table.clone(defaults)
	for key, value in overrides or {} do
		assert(
			defaults[key] ~= nil
				and finite(value)
				and value > 0
				and value
					<= (if key == "foot_slide_speed" or key == "joint_translation_step" then 100 else 1),
			"invalid bounded animation threshold"
		)
		result[key] = value
	end
	return result
end
function AnimationInspector.contactSegment(previous: any, current: any, dt: any, thresholds: any): any
	local config = AnimationInspector.validateThresholds(thresholds)
	assert(finite(dt) and dt > 0 and dt <= 120, "positive finite contact interval required")
	for _, row in { previous, current } do
		assert(
			type(row) == "table"
				and type(row.planted) == "boolean"
				and type(row.present) == "boolean"
				and finite(row.surface_y)
				and math.abs(row.surface_y) <= 1000000,
			"contact probe fields required"
		)
		for _, field in { "position", "support_position" } do
			assert(array(row[field], 3) and #row[field] == 3, "three-component probe vector required")
			for _, value in row[field] do
				assert(finite(value) and math.abs(value) <= 1000000, "nonfinite probe position")
			end
		end
	end
	local planeError = current.position[2] - current.surface_y
	local usable = previous.present
		and current.present
		and previous.planted
		and current.planted
		and dt <= config.max_sample_gap
	local speed = 0
	if usable then
		local x = (current.position[1] - current.support_position[1])
			- (previous.position[1] - previous.support_position[1])
		local z = (current.position[3] - current.support_position[3])
			- (previous.position[3] - previous.support_position[3])
		speed = math.sqrt(x * x + z * z) / dt
		assert(finite(speed), "contact speed arithmetic exceeded finite bounds")
	end
	return {
		usable = usable,
		horizontal_speed = speed,
		slide_candidate = usable and speed > config.foot_slide_speed,
		plane_error = planeError,
		contact_candidate = current.present
			and current.planted
			and math.abs(planeError) > config.contact_tolerance,
	}
end
function AnimationInspector.new(options: any): any
	assertDiagnosticTarget("AnimationInspector")
	assert(type(options) == "table", "animation options required")
	local root, animator = options.root, options.animator
	assert(
		typeof(root) == "Instance"
			and (root:IsA("Folder") or root:IsA("Model"))
			and root:IsDescendantOf(workspace)
			and root:GetAttribute("WorkbenchOwned") == true,
		"explicit owned rig below workspace required"
	)
	assert(
		typeof(animator) == "Instance" and animator:IsA("Animator") and animator:IsDescendantOf(root),
		"owned Animator required"
	)
	assert(
		type(options.studio_id) == "string" and #options.studio_id > 0 and #options.studio_id <= 120,
		"explicit Studio identity required"
	)
	local studioId = options.studio_id
	assert(
		type(options.source_manifest) == "table" and type(options.source_manifest.files) == "table",
		"actual source manifest required"
	)
	local files, fileCount = {}, 0
	for path, sha in options.source_manifest.files do
		fileCount += 1
		assert(
			fileCount <= 32
				and type(path) == "string"
				and #path <= 240
				and type(sha) == "string"
				and #sha == 64
				and sha:match("^[a-f0-9]+$"),
			"bounded source hashes required"
		)
		files[path] = sha
	end
	assert(
		fileCount > 0
			and type(options.privacy) == "table"
			and options.privacy.retention_permitted == true
			and options.privacy.raw_identifiers_excluded == true,
		"source and explicit privacy context required"
	)
	local thresholds = AnimationInspector.validateThresholds(options.thresholds)
	local maxSamples, maxEvents, maxDuration =
		options.max_samples or 120, options.max_events or 128, options.max_duration or 30
	assert(
		finite(maxSamples)
			and maxSamples % 1 == 0
			and maxSamples >= 2
			and maxSamples <= 600
			and finite(maxEvents)
			and maxEvents % 1 == 0
			and maxEvents >= 1
			and maxEvents <= 256
			and finite(maxDuration)
			and maxDuration > 0
			and maxDuration <= 120,
		"invalid animation capture caps"
	)
	local registrations, nodeIds, nodeRows, jointRows, jointObjects = {}, {}, {}, {}, {}
	local stack, descendants = { root }, 0
	while #stack > 0 do
		local item = table.remove(stack)
		local children = item:GetChildren()
		descendants += #children
		assert(descendants <= 512, "owned rig descendant cap exceeded")
		for _, child in children do
			table.insert(stack, child)
			if child:IsA("BasePart") or child:IsA("Bone") then
				assert(#registrations < 128, "rig node cap exceeded")
				local id = "node-" .. (#registrations + 1)
				nodeIds[child] = id
				table.insert(registrations, child)
			elseif child:IsA("Motor6D") then
				table.insert(jointObjects, child)
			end
		end
	end
	assert(#registrations > 0, "owned rig has no part/bone nodes")
	for _, node in registrations do
		local parent = node.Parent
		while parent and parent ~= root and not nodeIds[parent] do
			parent = parent.Parent
		end
		table.insert(nodeRows, {
			id = nodeIds[node],
			kind = if node:IsA("Bone") then "bone" else "part",
			parent_id = nodeIds[parent],
		})
		if node:IsA("Bone") then
			table.insert(jointObjects, node)
		end
	end
	assert(#jointObjects <= 128, "rig joint cap exceeded")
	for index, joint in jointObjects do
		table.insert(jointRows, {
			id = "joint-" .. index,
			kind = if joint:IsA("Motor6D") then "motor" else "bone",
			part0_id = if joint:IsA("Motor6D") then nodeIds[joint.Part0] else nodeIds[joint.Parent],
			part1_id = if joint:IsA("Motor6D") then nodeIds[joint.Part1] else nodeIds[joint],
		})
	end
	local probes, probeIds = {}, {}
	assert(array(options.probes or {}, 8), "at most eight dense probe registrations")
	for _, registration in options.probes or {} do
		assert(
			type(registration) == "table" and label(registration.id) and not probeIds[registration.id],
			"unique probe labels required"
		)
		local object, support = registration.object, registration.support
		assert(
			typeof(object) == "Instance"
				and object:IsDescendantOf(root)
				and (object:IsA("BasePart") or object:IsA("Attachment")),
			"owned Part/Attachment/Bone probe required"
		)
		assert(
			support == nil
				or (
					typeof(support) == "Instance"
					and support:IsA("BasePart")
					and support:IsDescendantOf(root)
				),
			"support must be an owned Part"
		)
		assert(
			finite(registration.plane_offset_y) and math.abs(registration.plane_offset_y) <= 1000000,
			"declared horizontal plane offset required"
		)
		local probe = {
			id = registration.id,
			object = object,
			support = support,
			plane_offset_y = registration.plane_offset_y,
			planted = false,
		}
		table.insert(probes, probe)
		probeIds[probe.id] = probe
	end
	local markers, markerIds = {}, {}
	assert(array(options.markers or {}, 8), "at most eight marker names")
	for _, marker in options.markers or {} do
		assert(
			type(marker) == "string"
				and #marker <= 80
				and marker:match("^[A-Za-z][A-Za-z0-9_-]*$")
				and not markerIds[marker],
			"unique bounded marker name required"
		)
		markerIds[marker] = true
		table.insert(markers, marker)
	end
	local started, samples, events, connections, trackIds, totalTracks, droppedEvents =
		os.clock(), {}, {}, {}, {}, 0, 0
	local captureDate = DateTime.now():ToIsoDate()
	local api: any = { stopped = false, destroyed = false }
	local function live()
		assert(
			not api.stopped
				and not api.destroyed
				and root:IsDescendantOf(workspace)
				and root:GetAttribute("WorkbenchOwned") == true
				and animator:IsDescendantOf(root),
			"animation inspection scope stopped or lost"
		)
	end
	local function elapsed(): number
		return os.clock() - started
	end
	local function trackId(track: AnimationTrack): string
		if not trackIds[track] then
			totalTracks += 1
			assert(totalTracks <= 64, "lifetime track cap exceeded")
			trackIds[track] = "track-" .. totalTracks
			for _, marker in markers do
				table.insert(
					connections,
					track:GetMarkerReachedSignal(marker):Connect(function()
						local time = elapsed()
						if not api.stopped and time <= maxDuration and #events < maxEvents then
							table.insert(events, { track_id = trackIds[track], name = marker, time = time })
						else
							droppedEvents += 1
						end
					end)
				)
			end
		end
		return trackIds[track]
	end
	function api:setPlanted(id: string, planted: boolean)
		live()
		assert(probeIds[id] and type(planted) == "boolean", "known probe and declared planted flag required")
		probeIds[id].planted = planted
	end
	function api:sample(): boolean
		live()
		local time = elapsed()
		if time > maxDuration or #samples >= maxSamples then
			self:stop()
			return false
		end
		assert(#samples == 0 or time > samples[#samples].time, "sample clock must advance")
		local row: any = { time = time, poses = {}, joints = {}, tracks = {}, probes = {} }
		for _, node in registrations do
			local present = node:IsDescendantOf(root)
			local position = if not present
				then Vector3.zero
				elseif node:IsA("Bone") then node.TransformedWorldCFrame.Position
				else node.Position
			table.insert(row.poses, { id = nodeIds[node], position = vector(position), present = present })
		end
		for index, joint in jointObjects do
			table.insert(row.joints, {
				id = "joint-" .. index,
				translation = vector(
					if joint:IsDescendantOf(root) then joint.Transform.Position else Vector3.zero
				),
			})
		end
		local playing = animator:GetPlayingAnimationTracks()
		assert(#playing <= 32, "simultaneous track cap exceeded")
		for _, track in playing do
			local values =
				{ track.TimePosition, track.Length, track.Speed, track.WeightCurrent, track.WeightTarget }
			for _, value in values do
				assert(finite(value), "nonfinite native track property")
			end
			assert(
				values[1] >= 0
					and values[1] <= 1000000
					and values[2] >= 0
					and values[2] <= 1000000
					and math.abs(values[3]) <= 100
					and values[4] >= 0
					and values[4] <= 10
					and values[5] >= 0
					and values[5] <= 10,
				"native track outside bounded trace range"
			)
			table.insert(row.tracks, {
				id = trackId(track),
				priority = track.Priority.Name,
				time_position = values[1],
				length = values[2],
				speed = values[3],
				weight_current = values[4],
				weight_target = values[5],
				playing = track.IsPlaying,
				looped = track.Looped,
			})
		end
		for _, probe in probes do
			local present = probe.object:IsDescendantOf(root)
				and (probe.support == nil or probe.support:IsDescendantOf(root))
			local support = if present and probe.support then probe.support.Position else Vector3.zero
			local position = if not present
				then Vector3.zero
				elseif probe.object:IsA("Bone") then probe.object.TransformedWorldCFrame.Position
				elseif probe.object:IsA("Attachment") then probe.object.WorldPosition
				else probe.object.Position
			table.insert(row.probes, {
				id = probe.id,
				position = vector(position),
				support_position = vector(support),
				surface_y = support.Y + probe.plane_offset_y,
				planted = probe.planted,
				present = present,
			})
		end
		for _, probe in row.probes do
			assert(
				finite(probe.surface_y) and math.abs(probe.surface_y) <= 1000000,
				"support plane exceeds trace bounds"
			)
		end
		table.insert(samples, row)
		return true
	end
	function api:stop()
		api.stopped = true
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
	function api:export(): any
		assert(#samples >= 2, "at least two actual samples required")
		self:stop()
		local retained, outside = {}, 0
		for _, event in events do
			if event.time <= samples[#samples].time then
				table.insert(retained, table.clone(event))
			else
				outside += 1
			end
		end
		local nodes, joints = {}, {}
		for _, node in nodeRows do
			table.insert(nodes, table.clone(node))
		end
		for _, joint in jointRows do
			table.insert(joints, table.clone(joint))
		end
		return {
			schema_version = 1,
			mode = "SETUP_ONLY",
			method = "native_animator_observation",
			capture_date = captureDate,
			target = { universe_id = 0, place_id = 0, studio_id = studioId },
			source_manifest = { files = table.clone(files) },
			privacy = { retention_permitted = true, raw_identifiers_excluded = true },
			thresholds = table.clone(thresholds),
			rig = { nodes = nodes, joints = joints },
			samples = copy(samples),
			events = retained,
			marker_expectations = {},
			dropped_events = droppedEvents + outside,
			nondeterminism = {
				"Manual client snapshots and real marker signals; scheduling and loading are nondeterministic.",
				"Planted/support plane declarations are diagnostic assumptions; no collision solver or asset permission acceptance.",
			},
		}
	end
	function api:destroy()
		self:stop()
		api.destroyed = true
	end
	return api
end
return AnimationInspector
