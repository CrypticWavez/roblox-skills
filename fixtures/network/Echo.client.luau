--!strict
assert(game.PlaceId == 0 and game.GameId == 0, "network fixture requires an unpublished diagnostic")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local player = Players.LocalPlayer
local modules = ReplicatedStorage:WaitForChild("WorkbenchNetwork", 10)
assert(modules, "network modules missing")
local settings = require(modules:WaitForChild("Settings"))
local sourceManifest = require(modules:WaitForChild("SourceManifest"))
local transport = ReplicatedStorage:WaitForChild("WorkbenchNetworkTransport", 10)
assert(transport and transport:GetAttribute("Ready") == true, "network transport not ready")
local remote = transport:WaitForChild("Echo") :: RemoteEvent
local scripts = player:WaitForChild("PlayerScripts")
assert(not scripts:FindFirstChild("WorkbenchNetworkEvidence"), "network client evidence already exists")
local evidence = Instance.new("StringValue")
evidence.Name = "WorkbenchNetworkEvidence"
evidence.Parent = scripts
local seen: { [number]: boolean } = {}
local sequences: { number } = {}
local latencies: { number } = {}
local rawEcho, duplicateEcho, outOfOrder, highest, invalidEcho = 0, 0, 0, 0, 0
local startReply: any = nil
local finishReply: any = nil
local acknowledgment: any = nil
local connection = remote.OnClientEvent:Connect(function(command: any, first: any, second: any)
	if command == "started" then
		startReply = first
	elseif command == "echo" then
		if
			type(first) ~= "number"
			or first ~= first
			or first % 1 ~= 0
			or first < 1
			or first > settings.packetCount
			or type(second) ~= "number"
			or second ~= second
			or second < 0
			or second > os.clock()
		then
			invalidEcho += 1
			return
		end
		rawEcho += 1
		if rawEcho > settings.options.capacity then
			invalidEcho += 1
			return
		end
		table.insert(latencies, (os.clock() - second) * 1000)
		if seen[first] then
			duplicateEcho += 1
		else
			seen[first] = true
			table.insert(sequences, first)
			if first < highest then
				outOfOrder += 1
			end
			highest = math.max(highest, first)
		end
	elseif command == "finished" then
		finishReply = first
	elseif command == "reportAck" then
		acknowledgment = first
	else
		invalidEcho += 1
	end
end)
remote:FireServer("start")
local startDeadline = os.clock() + 10
while not startReply and transport.Parent and os.clock() < startDeadline do
	task.wait(0.02)
end
local sent = 0
if startReply then
	for sequence = 1, settings.packetCount do
		local sentAt = os.clock()
		remote:FireServer("packet", sequence, sentAt)
		sent += 1
		if sequence % settings.duplicateInputEvery == 0 then
			remote:FireServer("packet", sequence, sentAt)
			sent += 1
		end
	end
	task.wait(settings.finishAfterSeconds)
	remote:FireServer("finish")
	local deadline = os.clock() + 3
	while not finishReply and transport.Parent and os.clock() < deadline do
		task.wait(0.02)
	end
end
table.sort(latencies)
local function percentile(fraction: number): number
	return if #latencies == 0 then 0 else latencies[math.max(1, math.ceil(#latencies * fraction))]
end
local metrics = {
	rawEcho = rawEcho,
	uniqueEcho = #sequences,
	duplicateEcho = duplicateEcho,
	outOfOrderUniqueEcho = outOfOrder,
	invalidEcho = invalidEcho,
	latencySampleCount = #latencies,
	minimumMs = latencies[1] or 0,
	p50Ms = percentile(0.5),
	p95Ms = percentile(0.95),
	maximumMs = latencies[#latencies] or 0,
	uniqueSequenceOrder = sequences,
}
if finishReply then
	remote:FireServer("report", metrics)
	local deadline = os.clock() + 3
	while not acknowledgment and transport.Parent and os.clock() < deadline do
		task.wait(0.02)
	end
end
connection:Disconnect()
connection:Disconnect()
local queueStats = if finishReply then finishReply.queue else nil
local report = {
	schemaVersion = settings.schemaVersion,
	status = "partially_verified",
	mode = if startReply then startReply.mode else "unknown",
	sessionIndex = if startReply then startReply.sessionIndex else 0,
	coverage = "actual local Studio echo path with injected server queue impairment",
	notCertified = {
		"physical network impairment",
		"game load performance",
		"universal multiplayer/device support",
		"production networking/security",
		"release readiness",
	},
	placeId = game.PlaceId,
	gameId = game.GameId,
	sourceInputSha256 = sourceManifest.input_sha256,
	sentMessages = sent,
	metrics = metrics,
	uniqueSequenceOrder = sequences,
	latencyMeaning = "client elapsed echo RTT including synthetic delay and Studio scheduling; not physical-network latency",
	queueStats = queueStats,
	acknowledgment = acknowledgment,
	cleanup = { receiveConnected = connection.Connected, transportAbsent = false },
	leaveTest = {
		requested = acknowledgment ~= nil and acknowledgment.requestLeave == true,
		canLeaveTest = false,
		attempted = false,
	},
	checks = {
		startReplyReceived = startReply ~= nil,
		finishReplyReceived = finishReply ~= nil,
		reportAcknowledged = acknowledgment ~= nil,
		declaredPacketCount = sent
			== settings.packetCount + math.floor(settings.packetCount / settings.duplicateInputEvery),
		allAdmittedEchoesObserved = queueStats ~= nil and rawEcho == queueStats.delivered,
		uniqueEchoMatchesAccepted = queueStats ~= nil and #sequences == queueStats.accepted,
		duplicateEchoMatchesInjected = queueStats ~= nil and duplicateEcho == queueStats.duplicates,
		validBoundedReplies = invalidEcho == 0 and rawEcho <= settings.options.capacity,
		listenerDisconnected = not connection.Connected,
	},
}
for _, passedCheck in report.checks do
	if not passedCheck then
		report.status = "blocked"
	end
end
if acknowledgment and acknowledgment.requestLeave then
	local canCall, allowed = pcall(function()
		return StudioTestService:CanLeaveTest()
	end)
	report.leaveTest.canLeaveTest = canCall and allowed == true
	report.leaveTest.attempted = report.leaveTest.canLeaveTest
	remote:FireServer("leaveAttempt", report.leaveTest.canLeaveTest)
	evidence.Value = HttpService:JSONEncode(report)
	if report.leaveTest.canLeaveTest then
		local ok, problem = pcall(function()
			StudioTestService:LeaveTest()
		end)
		if not ok then
			report.status = "blocked"
			report.leaveTest.error = tostring(problem)
			evidence.Value = HttpService:JSONEncode(report)
		end
	end
else
	-- Single mode retains evidence; multiplayer's surviving client may be stopped by EndTest first.
	local deadline = os.clock() + 2
	while transport.Parent and os.clock() < deadline do
		task.wait(0.02)
	end
	report.cleanup.transportAbsent = transport.Parent == nil
	if report.mode == "single" and not report.cleanup.transportAbsent then
		report.status = "blocked"
	end
	evidence.Value = HttpService:JSONEncode(report)
	print("WORKBENCH_NETWORK_CLIENT_READY " .. evidence.Value)
end
