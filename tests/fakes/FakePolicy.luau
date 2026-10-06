--!strict
-- FakePolicy (G1): PolicyService and VoiceChatService stand-ins for Lune specs.
-- FakePolicy.new({ preset, byUserId, env, latency }) answers GetPolicyInfoForPlayerAsync(player)
-- with a copy of a preset (by name or table; per user through byUserId), counts calls, and
-- fail(n, message) makes the next n calls raise. Presets model regions as the Player Emulator
-- does in Studio; the field names are PolicyService's. FakePolicy.voice({ enabled, fail })
-- answers VoiceChatService:IsVoiceEnabledForUserIdAsync(userId).
local FakePolicy = {}

FakePolicy.PRESETS = table.freeze({
	-- every feature allowed
	permissive = table.freeze({
		AreAdsAllowed = true,
		ArePaidRandomItemsRestricted = false,
		IsPaidItemTradingAllowed = true,
		IsEligibleToPurchaseSubscription = true,
		IsEligibleToPurchaseCommerceProduct = true,
		IsContentSharingAllowed = true,
		IsSubjectToChinaPolicies = false,
		AllowedExternalLinkReferences = table.freeze({}),
	}),
	-- every feature off (a region with paid random items restricted, no trading or ads)
	restricted = table.freeze({
		AreAdsAllowed = false,
		ArePaidRandomItemsRestricted = true,
		IsPaidItemTradingAllowed = false,
		IsEligibleToPurchaseSubscription = false,
		IsEligibleToPurchaseCommerceProduct = false,
		IsContentSharingAllowed = false,
		IsSubjectToChinaPolicies = false,
		AllowedExternalLinkReferences = table.freeze({}),
	}),
	-- paid random items restricted and no trading, the rest allowed
	mixed = table.freeze({
		AreAdsAllowed = true,
		ArePaidRandomItemsRestricted = true,
		IsPaidItemTradingAllowed = false,
		IsEligibleToPurchaseSubscription = true,
		IsEligibleToPurchaseCommerceProduct = true,
		IsContentSharingAllowed = false,
		AllowedExternalLinkReferences = table.freeze({}),
	}),
	-- fields missing (an older or partial response)
	partial = table.freeze({ AreAdsAllowed = true }),
	-- wrong types
	malformed = table.freeze({
		AreAdsAllowed = "true",
		ArePaidRandomItemsRestricted = 0,
		IsPaidItemTradingAllowed = 1,
		IsEligibleToPurchaseSubscription = "yes",
		IsEligibleToPurchaseCommerceProduct = {},
		IsContentSharingAllowed = nil,
	}),
})

local function resolve(preset: any): any
	if type(preset) == "string" then
		local found = FakePolicy.PRESETS[preset]
		assert(found ~= nil, "FakePolicy: unknown preset " .. preset)
		return found
	end
	return preset
end

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in value do
		out[key] = copy(item)
	end
	return out
end

function FakePolicy.new(
	options: { preset: any?, byUserId: { [number]: any }?, env: any?, latency: number? }?
): any
	local service = {
		preset = resolve(options and options.preset or "permissive"),
		byUserId = {} :: { [number]: any },
		calls = 0,
		_failures = {} :: { { remaining: number, message: string } },
	} :: any
	for userId, preset in (options and options.byUserId) or {} do
		service.byUserId[userId] = resolve(preset)
	end
	local env = options and options.env
	local latency = options and options.latency or 0

	function service.GetPolicyInfoForPlayerAsync(self: any, player: any): any
		self.calls += 1
		if latency > 0 and env then
			env.wait(latency)
		end
		local failure = self._failures[1]
		if failure then
			failure.remaining -= 1
			if failure.remaining <= 0 then
				table.remove(self._failures, 1)
			end
			error(failure.message, 0)
		end
		if type(player) ~= "table" or type(player.UserId) ~= "number" then
			error("GetPolicyInfoForPlayerAsync: argument 1 must be a Player", 0)
		end
		return copy(self.byUserId[player.UserId] or self.preset)
	end

	function service.fail(self: any, count: number?, message: string?)
		table.insert(
			self._failures,
			{ remaining = count or 1, message = message or "HTTP 500 (Internal Server Error)" }
		)
	end

	function service.setPreset(self: any, userId: number, preset: any)
		self.byUserId[userId] = resolve(preset)
	end

	return service
end

function FakePolicy.voice(options: { enabled: { [number]: boolean }?, fail: boolean? }?): any
	local service = { calls = 0 } :: any
	function service.IsVoiceEnabledForUserIdAsync(self: any, userId: number): boolean
		self.calls += 1
		if options and options.fail then
			error("VoiceChatService unavailable", 0)
		end
		return (options and options.enabled and options.enabled[userId]) == true
	end
	return service
end

return FakePolicy
