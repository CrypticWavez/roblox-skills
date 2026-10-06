--!strict
-- @tier T0
-- PolicyGate: per-player feature gating from PolicyService, failing closed. evaluate(info,
-- feature) maps a GetPolicyInfoForPlayerAsync result to (allowed, reason): a feature is allowed
-- only when the field that permits it holds exactly the permitting boolean; a missing, wrong-typed
-- or unknown field, an unknown feature, or no info at all means "not allowed". A gate caches one
-- info per player (load yields through the injected fetch, retried with GameKit/Retry); allows()
-- and predicate() never yield, and say "not allowed" until a load succeeded. A failed load is
-- cached as failed for negativeTtl seconds (convention), so callers do not hammer PolicyService.
-- Features (docs/runtime-kits.md "Policy predicate"):
--   paidRandomItems   ArePaidRandomItemsRestricted == false
--   trading           IsPaidItemTradingAllowed == true (trading paid items or their outcomes)
--   ads               AreAdsAllowed == true
--   subscriptions     IsEligibleToPurchaseSubscription == true
--   commerceProducts  IsEligibleToPurchaseCommerceProduct == true
--   contentSharing    IsContentSharingAllowed == true
--   voice             VoiceEnabled == true (not a PolicyService field: PolicyGateRoblox adds it
--                     from VoiceChatService; absent means not allowed)
--   externalLinks     always false: Community Standards allow no external URLs in a game
--   socialLinks       always false in game: Roblox shows the experience's social links on its
--                     page to eligible users; a game cannot show them itself
-- Region treatments (what to do when a feature is off) are the game's; PolicyGate only answers.
local Check = require("./Check")
local Retry = require("./Retry")

local PolicyGate = {}

PolicyGate.DEFAULT_NEGATIVE_TTL = 30 -- convention: seconds before a failed load may be retried
PolicyGate.FEATURES = table.freeze({
	"paidRandomItems",
	"trading",
	"ads",
	"subscriptions",
	"commerceProducts",
	"contentSharing",
	"voice",
	"externalLinks",
	"socialLinks",
})
-- feature -> { field, permitting value }; nil field = never allowed in game.
local RULES: { [string]: { field: string?, allow: boolean? } } = {
	paidRandomItems = { field = "ArePaidRandomItemsRestricted", allow = false },
	trading = { field = "IsPaidItemTradingAllowed", allow = true },
	ads = { field = "AreAdsAllowed", allow = true },
	subscriptions = { field = "IsEligibleToPurchaseSubscription", allow = true },
	commerceProducts = { field = "IsEligibleToPurchaseCommerceProduct", allow = true },
	contentSharing = { field = "IsContentSharingAllowed", allow = true },
	voice = { field = "VoiceEnabled", allow = true },
	externalLinks = {},
	socialLinks = {},
}
PolicyGate.REASONS = table.freeze({
	"allowed",
	"denied", -- the policy says no
	"unknown_feature",
	"no_policy", -- no info (not loaded, failed, not a table)
	"missing_field", -- the field is absent or not a boolean
	"never_in_game", -- externalLinks, socialLinks
})

-- (allowed, reason) for one feature given a policy info table. Never raises.
function PolicyGate.evaluate(info: any, feature: any): (boolean, string)
	local rule = type(feature) == "string" and RULES[feature] or nil
	if rule == nil then
		return false, "unknown_feature"
	end
	if rule.field == nil then
		return false, "never_in_game"
	end
	if type(info) ~= "table" then
		return false, "no_policy"
	end
	local ok, value = pcall(function(): any
		return info[rule.field]
	end)
	if not ok or type(value) ~= "boolean" then
		return false, "missing_field"
	end
	if value == rule.allow then
		return true, "allowed"
	end
	return false, "denied"
end

-- Every feature's verdict for one info table (for logs and probes).
function PolicyGate.matrix(info: any): { [string]: boolean }
	local out = {}
	for _, feature in PolicyGate.FEATURES do
		out[feature] = (PolicyGate.evaluate(info, feature))
	end
	return out
end

export type Options = {
	fetch: (player: any) -> any, -- yields; returns the info table or raises (PolicyGateRoblox.fetcher)
	retry: Retry.Options?, -- default 3 attempts, 0.5 s base
	negativeTtl: number?,
	keyOf: ((player: any) -> any)?, -- default player.UserId
}

local Gate = {}
Gate.__index = Gate

type Entry = { state: "loading" | "ok" | "failed", info: any?, at: number, waiters: { thread } }
type GateFields = {
	_fetch: (player: any) -> any,
	_retry: Retry.Options,
	_negativeTtl: number,
	_keyOf: (player: any) -> any,
	_entries: { [any]: Entry },
	_env: any,
}
export type Gate = typeof(setmetatable({} :: GateFields, Gate))

function PolicyGate.new(options: Options, env: any): Gate
	local problems = {}
	if type(options) ~= "table" or type(options.fetch) ~= "function" then
		table.insert(problems, "fetch(player) is required (PolicyGateRoblox.fetcher(PolicyService))")
	end
	local ttl = options and options.negativeTtl
	if ttl ~= nil and not (Check.finite(ttl) and ttl >= 0) then
		table.insert(problems, "negativeTtl must be >= 0 seconds")
	end
	local retry: Retry.Options = options and options.retry
		or { attempts = 3, base = 0.5, factor = 2, maxDelay = 4 }
	for _, problem in Retry.validate(retry) do
		table.insert(problems, "retry: " .. problem)
	end
	if env == nil or type(env.clock) ~= "function" or type(env.wait) ~= "function" then
		table.insert(problems, "env with clock and wait is required")
	end
	if #problems > 0 then
		error("PolicyGate.new: " .. table.concat(problems, "; "), 2)
	end
	return setmetatable({
		_fetch = options.fetch,
		_retry = retry,
		_negativeTtl = ttl or PolicyGate.DEFAULT_NEGATIVE_TTL,
		_keyOf = options.keyOf or function(player: any): any
			return player.UserId
		end,
		_entries = {},
		_env = env,
	}, Gate)
end

-- Loads (or reuses) the player's policy info. Yields. Concurrent loads for one player share a
-- single fetch. Returns (true) or (false, reason) with reasons failed and recent_failure.
function Gate.load(self: Gate, player: any): (boolean, string?)
	local key = self._keyOf(player)
	local env = self._env
	local entry = self._entries[key]
	if entry then
		if entry.state == "ok" then
			return true, nil
		elseif entry.state == "loading" then
			table.insert(entry.waiters, coroutine.running())
			coroutine.yield()
			local settled = self._entries[key]
			return settled ~= nil and settled.state == "ok",
				if settled and settled.state == "ok" then nil else "failed"
		elseif env.clock() - entry.at < self._negativeTtl then
			return false, "recent_failure"
		end
	end
	local current: Entry = { state = "loading", info = nil, at = env.clock(), waiters = {} }
	self._entries[key] = current
	local ok, result = Retry.run(function(): any
		local info = self._fetch(player)
		if type(info) ~= "table" then
			error("policy info is not a table")
		end
		return info
	end, self._retry, env)
	if self._entries[key] ~= current then
		-- forgotten (the player left) while loading: drop the result
		for _, thread in current.waiters do
			env.spawn(thread)
		end
		return false, "failed"
	end
	if ok then
		current.state = "ok"
		current.info = Check.copy(result)
	else
		current.state = "failed"
		env.report(string.format("PolicyGate: policy for %s not loaded: %s", tostring(key), tostring(result)))
	end
	current.at = env.clock()
	for _, thread in current.waiters do
		env.spawn(thread)
	end
	current.waiters = {}
	return ok, if ok then nil else "failed"
end

-- (allowed, reason) for a player and feature from the cache; never yields. Not loaded, loading
-- or failed means not allowed ("no_policy").
function Gate.allows(self: Gate, player: any, feature: string): (boolean, string)
	local entry = self._entries[self._keyOf(player)]
	if entry == nil or entry.state ~= "ok" then
		local _, reason = PolicyGate.evaluate(nil, feature)
		return false, if reason == "unknown_feature" or reason == "never_in_game" then reason else "no_policy"
	end
	return PolicyGate.evaluate(entry.info, feature)
end

-- The predicate other kits take: policyAllows(feature) -> boolean, for one player.
function Gate.predicate(self: Gate, player: any): (feature: string) -> boolean
	return function(feature: string): boolean
		return (self:allows(player, feature))
	end
end

-- A copy of the cached info, or nil.
function Gate.info(self: Gate, player: any): any
	local entry = self._entries[self._keyOf(player)]
	return if entry and entry.state == "ok" then Check.copy(entry.info) else nil
end

-- Drops the player's cache entry (PlayerRemoving); a load in flight is discarded.
function Gate.forget(self: Gate, player: any)
	local key = self._keyOf(player)
	local entry = self._entries[key]
	self._entries[key] = nil
	if entry and entry.state == "loading" then
		for _, thread in entry.waiters do
			self._env.spawn(thread)
		end
		entry.waiters = {}
	end
end

return PolicyGate
