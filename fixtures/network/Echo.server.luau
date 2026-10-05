--!strict
-- Bounded local echo; only the explicit StudioTestService argument enables two-client mode.
assert(game.PlaceId == 0 and game.GameId == 0, "network fixture requires an unpublished diagnostic")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local modules = ReplicatedStorage:WaitForChild("WorkbenchNetwork", 10)
assert(modules, "network source folder missing")
local FaultQueue = require(modules:WaitForChild("FaultQueue"))
local settings = require(modules:WaitForChild("Settings"))
local sourceManifest = require(modules:WaitForChild("SourceManifest"))
local argsAvailable, testArgs = pcall(function()
	return StudioTestService:GetTestArgs()
end)
local multi = argsAvailable and type(testArgs) == "table" and testArgs.mode == settings.multiplayerMode
local expectedClients = if multi then 2 else 1
local deadlineSeconds = if multi then settings.multiplayerDeadlineSeconds else settings.serverDeadlineSeconds
modules:SetAttribute("RunMode", if multi then "multiplayer" else "single")
assert(not ReplicatedStorage:FindFirstChild("WorkbenchNetworkTransport"), "network transport already exists")
assert(not ServerStorage:FindFirstChild("WorkbenchNetworkEvidence"), "network evidence already exists")
local transport = Instance.new("Folder")
transport.Name = "WorkbenchNetworkTransport"
local remote = Instance.new("RemoteEvent")
remote.Name = "Echo"
remote.Parent = transport
local evidence = Instance.new("StringValue")
evidence.Name = "WorkbenchNetworkEvidence"
evidence.Parent = ServerStorage
local states: { any } = {}
local stateByPlayer: { [Player]: any } = {}
local joined: { [Player]: boolean } = {}
local removed: { number } = {}
local joinedCount, peakPlayers, extraPlayers = 0, #Players:GetPlayers(), 0
local started, finished, completionScheduled = false, false, false
local startedAt = os.clock()
local receive: RBXScriptConnection? = nil
local heartbeat: RBXScriptConnection? = nil
local removing: RBXScriptConnection? = nil
local adding: RBXScriptConnection? = nil
local watchdog: thread? = nil
local finalReport: any = nil
local function finite(value: any, maximum: number): boolean
	return type(value) == "number" and value == value and value >= 0 and value <= maximum
end
local function allClientReports(): boolean
	if #states ~= expectedClients then
		return false
	end
	for _, state in states do
		if not state.clientReport then
			return false
		end
	end
	return true
end
local function finalize(reason: string)
	if finished then
		return
	end
	finished = true
	if watchdog then
		task.cancel(watchdog)
		watchdog = nil
	end
	for _, connection in { receive, heartbeat, removing, adding } do
		if connection then
			connection:Disconnect()
		end
	end
	local participants = {}
	local allParticipantChecks = #states == expectedClients
	for _, state in states do
		local before = state.beforeCleanup or state.queue:stats()
		state.queue:destroy()
		local client = state.clientReport
		local checks = {
			allUniqueInputReceived = #state.requested == settings.packetCount,
			inputDuplicatesDeduped = state.duplicateInput
				== math.floor(settings.packetCount / settings.duplicateInputEvery),
			boundedInput = state.invalidInput == 0 and state.rawInput <= settings.maxInputMessages,
			boundedQueue = before.peakQueued <= settings.options.capacity,
			queueDrained = before.queued == 0,
			clientReportReceived = client ~= nil,
			allAdmittedEchoesReceived = client ~= nil and client.rawEcho == before.delivered,
			uniqueMatchesAccepted = client ~= nil and client.uniqueEcho == before.accepted,
			duplicateMatchesInjected = client ~= nil and client.duplicateEcho == before.duplicates,
			validReplies = client ~= nil and client.invalidEcho == 0,
			latencySamplesConsistent = client ~= nil
				and client.latencySampleCount == client.rawEcho
				and client.minimumMs <= client.p50Ms
				and client.p50Ms <= client.p95Ms
				and client.p95Ms <= client.maximumMs,
		}
		for _, value in checks do
			if not value then
				allParticipantChecks = false
			end
		end
		table.insert(participants, {
			sessionIndex = state.index,
			inputSequences = state.requested,
			rawInput = state.rawInput,
			duplicateInput = state.duplicateInput,
			invalidInput = state.invalidInput,
			queueBeforeCleanup = before,
			queueAfterCleanup = state.queue:stats(),
			client = client,
			leaveAttempt = state.leaveAttempt,
			checks = checks,
		})
	end
	transport:Destroy()
	finalReport = {
		schemaVersion = settings.schemaVersion,
		status = "partially_verified",
		mode = if multi then "multiplayer" else "single",
		coverage = if multi
			then "local Studio one server and two clients; synthetic in-memory impairment and one requested leave"
			else "local Studio one server and one client; synthetic in-memory impairment",
		notCertified = {
			"physical network impairment",
			"production networking/security",
			"game load performance",
			"universal multiplayer/device support",
			"release readiness",
		},
		placeId = game.PlaceId,
		gameId = game.GameId,
		sourceInputSha256 = sourceManifest.input_sha256,
		finishReason = reason,
		expectedClients = expectedClients,
		joinedSessionCount = joinedCount,
		peakPlayerCount = peakPlayers,
		remainingPlayerCount = #Players:GetPlayers(),
		extraPlayers = extraPlayers,
		playerRemovingSessionIndices = removed,
		impairment = settings.options,
		participants = participants,
		elapsedSeconds = os.clock() - startedAt,
		studioTestService = {
			getTestArgsAvailable = argsAvailable,
			multiplayerArgsMatched = multi,
			endTest = if multi then "request_pending" else "not_used",
		},
		cleanup = {
			transportDestroyed = transport.Parent == nil,
			receiveConnected = receive ~= nil and receive.Connected,
			heartbeatConnected = heartbeat ~= nil and heartbeat.Connected,
			playerAddedConnected = adding ~= nil and adding.Connected,
			playerRemovingConnected = removing ~= nil and removing.Connected,
		},
		checks = {
			unpublished = game.PlaceId == 0 and game.GameId == 0,
			expectedPlayersObserved = joinedCount == expectedClients
				and peakPlayers == expectedClients
				and extraPlayers == 0,
			allParticipantsPassed = allParticipantChecks,
			requestedLeaveObserved = not multi or (#removed == 1 and removed[1] == 1),
			remainingPlayerCount = #Players:GetPlayers() == 1,
			completedBeforeDeadline = reason == "completed",
		},
	}
	for _, value in finalReport.checks do
		if not value then
			finalReport.status = "blocked"
		end
	end
	evidence.Value = HttpService:JSONEncode(finalReport)
	if multi then
		finalReport.studioTestService.endTest = "requested"
		evidence.Value = HttpService:JSONEncode(finalReport)
		local ok, problem = pcall(function()
			StudioTestService:EndTest(finalReport)
		end)
		if not ok then
			finalReport.status = "blocked"
			finalReport.studioTestService.endTest = "error"
			finalReport.studioTestService.error = tostring(problem)
			evidence.Value = HttpService:JSONEncode(finalReport)
		end
	end
end
local function scheduleCompletion()
	if finished or completionScheduled or not allClientReports() then
		return
	end
	if multi and not (#removed == 1 and removed[1] == 1) then
		return
	end
	completionScheduled = true
	-- Let final acknowledgments arrive before destroying the namespaced transport.
	task.delay(0.5, function()
		finalize("completed")
	end)
end
local function registerJoin(player: Player)
	if joined[player] then
		return
	end
	joined[player] = true
	joinedCount += 1
	peakPlayers = math.max(peakPlayers, #Players:GetPlayers())
	if joinedCount > expectedClients then
		extraPlayers += 1
	end
end
adding = Players.PlayerAdded:Connect(registerJoin)
for _, player in Players:GetPlayers() do
	registerJoin(player)
end
removing = Players.PlayerRemoving:Connect(function(player)
	local state = stateByPlayer[player]
	if state then
		table.insert(removed, state.index)
		state.queue:destroy()
		-- PlayerRemoving fires before the player is fully removed from Players.
		task.delay(0.1, scheduleCompletion)
	end
	joined[player] = nil
	stateByPlayer[player] = nil
end)
local function startClients()
	if started or #states ~= expectedClients or #Players:GetPlayers() ~= expectedClients then
		return
	end
	started = true
	peakPlayers = math.max(peakPlayers, #Players:GetPlayers())
	for _, state in states do
		remote:FireClient(state.player, "started", {
			sessionIndex = state.index,
			packetCount = settings.packetCount,
			mode = if multi then "multiplayer" else "single",
		})
	end
end
receive = remote.OnServerEvent:Connect(function(player: Player, command: any, first: any, second: any)
	if finished then
		return
	end
	local state = stateByPlayer[player]
	if command == "start" and not state then
		if #states >= expectedClients then
			extraPlayers += 1
			return
		end
		local options = table.clone(settings.options)
		options.seed += #states
		state = {
			player = player,
			index = #states + 1,
			queue = FaultQueue.new(options),
			seen = {},
			requested = {},
			rawInput = 0,
			duplicateInput = 0,
			invalidInput = 0,
			echoFinished = false,
			clientReport = nil,
			leaveAttempt = nil,
		}
		table.insert(states, state)
		stateByPlayer[player] = state
		startClients()
		return
	end
	if not state or not started then
		return
	end
	if command == "packet" and not state.echoFinished then
		state.rawInput += 1
		if state.rawInput > settings.maxInputMessages then
			finalize("input_bound_exceeded")
			return
		end
		if
			not finite(first, settings.packetCount)
			or first < 1
			or first % 1 ~= 0
			or not finite(second, 1000000000)
		then
			state.invalidInput += 1
			return
		end
		if state.seen[first] then
			state.duplicateInput += 1
			return
		end
		state.seen[first] = true
		table.insert(state.requested, first)
		state.queue:enqueue({ sequence = first, sentAt = second, label = "neutral-echo" })
	elseif command == "finish" and not state.echoFinished then
		state.echoFinished = true
		state.beforeCleanup = state.queue:stats()
		state.queue:destroy()
		remote:FireClient(player, "finished", { sessionIndex = state.index, queue = state.beforeCleanup })
	elseif command == "report" and state.echoFinished and not state.clientReport then
		if type(first) ~= "table" then
			state.invalidInput += 1
			return
		end
		-- Retain only bounded diagnostics, not arbitrary client objects/private identifiers.
		local checked: any = { sessionIndex = state.index }
		for _, key in
			{
				"rawEcho",
				"uniqueEcho",
				"duplicateEcho",
				"outOfOrderUniqueEcho",
				"invalidEcho",
				"latencySampleCount",
			}
		do
			if not finite(first[key], settings.options.capacity) or first[key] % 1 ~= 0 then
				state.invalidInput += 1
				return
			end
			checked[key] = first[key]
		end
		for _, key in { "minimumMs", "p50Ms", "p95Ms", "maximumMs" } do
			if not finite(first[key], 30000) then
				state.invalidInput += 1
				return
			end
			checked[key] = first[key]
		end
		if
			type(first.uniqueSequenceOrder) ~= "table"
			or #first.uniqueSequenceOrder ~= checked.uniqueEcho
			or #first.uniqueSequenceOrder > settings.packetCount
		then
			state.invalidInput += 1
			return
		end
		local receivedOrder, receivedSeen = {}, {}
		for key, sequence in first.uniqueSequenceOrder do
			if
				not finite(key, #first.uniqueSequenceOrder)
				or key < 1
				or key % 1 ~= 0
				or not finite(sequence, settings.packetCount)
				or sequence < 1
				or sequence % 1 ~= 0
				or receivedSeen[sequence]
			then
				state.invalidInput += 1
				return
			end
			receivedSeen[sequence] = true
		end
		for _, sequence in first.uniqueSequenceOrder do
			table.insert(receivedOrder, sequence)
		end
		checked.uniqueSequenceOrder = receivedOrder
		state.clientReport = checked
		remote:FireClient(
			player,
			"reportAck",
			{ sessionIndex = state.index, requestLeave = multi and state.index == 1 }
		)
		scheduleCompletion()
	elseif command == "leaveAttempt" and multi and state.index == 1 and type(first) == "boolean" then
		state.leaveAttempt = { canLeaveTest = first }
		if not first then
			task.delay(0.5, function()
				finalize("leave_unavailable")
			end)
		end
	else
		state.invalidInput += 1
	end
end)
heartbeat = RunService.Heartbeat:Connect(function(delta)
	if finished then
		return
	end
	for _, state in states do
		if not state.echoFinished then
			for _, packet in state.queue:advance(math.min(delta, 60)) do
				if state.player.Parent == Players then
					remote:FireClient(state.player, "echo", packet.sequence, packet.sentAt)
				end
			end
		end
	end
end)
watchdog = task.delay(deadlineSeconds, function()
	watchdog = nil
	finalize("server_deadline")
end)
transport:SetAttribute("Ready", true)
transport.Parent = ReplicatedStorage
