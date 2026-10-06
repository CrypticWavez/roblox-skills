--!strict
-- @tier T3
-- probe: platform_policy_emulator
-- PolicyGateRoblox: the PolicyService side of GameKit/PolicyGate. fetcher() calls
-- PolicyService:GetPolicyInfoForPlayerAsync(player) (yields; may raise, which PolicyGate retries
-- and then treats as "not allowed") and, when a VoiceChatService is given, adds VoiceEnabled from
-- VoiceChatService:IsVoiceEnabledForUserIdAsync(userId) (absent on error, so voice stays off).
-- bind() loads each player's policy on join and forgets it on leave. In Studio the Player
-- Emulator ("Enable Test Profile", region) changes what GetPolicyInfoForPlayerAsync returns; the
-- probe reads the emulated info and checks the gate agrees with it field by field.
local PolicyGate = require("./PolicyGate")

local PolicyGateRoblox = {}

-- The PolicyService fields PolicyGate reads (copied out of the returned dictionary).
PolicyGateRoblox.FIELDS = table.freeze({
	"AreAdsAllowed",
	"ArePaidRandomItemsRestricted",
	"IsPaidItemTradingAllowed",
	"IsEligibleToPurchaseSubscription",
	"IsEligibleToPurchaseCommerceProduct",
	"IsContentSharingAllowed",
})

-- fetch(player) for PolicyGate.new.
function PolicyGateRoblox.fetcher(
	policyService: any,
	options: { voiceChatService: any? }?
): (player: any) -> any
	assert(policyService ~= nil, "PolicyGateRoblox.fetcher: PolicyService required")
	local voice = options and options.voiceChatService
	return function(player: any): any
		local raw = policyService:GetPolicyInfoForPlayerAsync(player)
		if type(raw) ~= "table" then
			error("GetPolicyInfoForPlayerAsync returned " .. typeof(raw))
		end
		local info: { [string]: any } = {}
		for _, field in PolicyGateRoblox.FIELDS do
			info[field] = raw[field]
		end
		if voice ~= nil then
			local ok, enabled = pcall(function(): any
				return voice:IsVoiceEnabledForUserIdAsync(player.UserId)
			end)
			if ok and type(enabled) == "boolean" then
				info.VoiceEnabled = enabled
			end
		end
		return info
	end
end

-- Loads policy for present and joining players, forgets leavers. Returns a disconnect function.
function PolicyGateRoblox.bind(gate: any, players: any, env: any): () -> ()
	assert(players ~= nil, "PolicyGateRoblox.bind: Players required")
	local connections = {
		players.PlayerAdded:Connect(function(player: any)
			env.spawn(function()
				gate:load(player)
			end)
		end),
		players.PlayerRemoving:Connect(function(player: any)
			gate:forget(player)
		end),
	}
	for _, player in players:GetPlayers() do
		env.spawn(function()
			gate:load(player)
		end)
	end
	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
	end
end

-- A gate wired to the env's services: PolicyGate.new with fetcher(PolicyService, VoiceChatService).
function PolicyGateRoblox.gate(env: any, options: { [string]: any }?): any
	local fetch = PolicyGateRoblox.fetcher(env.services.PolicyService, {
		voiceChatService = env.services.VoiceChatService,
	})
	local gateOptions: { [string]: any } = { fetch = fetch }
	for key, value in options or {} do
		gateOptions[key] = value
	end
	return PolicyGate.new(gateOptions :: any, env)
end

return PolicyGateRoblox
