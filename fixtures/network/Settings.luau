--!strict
-- Neutral SETUP_ONLY diagnostic bounds, not production networking policy.
return table.freeze({
	schemaVersion = 1,
	packetCount = 32,
	duplicateInputEvery = 5,
	maxInputMessages = 96,
	finishAfterSeconds = 2,
	serverDeadlineSeconds = 8,
	multiplayerDeadlineSeconds = 20,
	multiplayerMode = "workbench-network-multiplayer-v1",
	options = table.freeze({
		seed = 31415926,
		capacity = 96,
		minDelay = 0.05,
		maxDelay = 0.3,
		lossProbability = 0.15,
		duplicateProbability = 0.4,
	}),
})
