--!strict
-- @tier T0
-- Moderation: pure helpers for a game's own moderation (bans through Players:BanAsync are
-- ModerationRoblox, T4 and owner-run). banRequest() validates a ban and builds the BanAsync
-- config table; ladder()/decide() turn a game-supplied escalation ladder (offense count ->
-- warn, kick or ban with a duration) into the next action. The factory ships no ladder and no
-- durations: those are moderation policy, chosen by the game's owner.
-- Field names follow the Players:BanAsync config (UserIds, ApplyToUniverse, Duration,
-- DisplayReason, PrivateReason, ExcludeAltAccounts). The length and count limits below are as
-- recalled from the class reference and UNVERIFIED in this pass; they are enforced here so a
-- request that might be refused fails before it reaches the engine.
local Check = require("./Check")

local Moderation = {}

Moderation.MAX_USER_IDS = 50 -- UNVERIFIED limit per BanAsync call
Moderation.MAX_DISPLAY_REASON = 400 -- UNVERIFIED (characters shown to the banned user)
Moderation.MAX_PRIVATE_REASON = 1000 -- UNVERIFIED (kept for the game's moderators)
Moderation.PERMANENT = -1 -- BanAsync Duration for a permanent ban
Moderation.ACTIONS = table.freeze({ "warn", "kick", "ban" })

export type BanRequest = {
	userIds: { number },
	duration: number, -- seconds > 0, or Moderation.PERMANENT
	displayReason: string,
	privateReason: string,
	applyToUniverse: boolean?, -- default true
	excludeAltAccounts: boolean?, -- default false (Roblox extends bans to suspected alts)
}

local function textProblem(value: any, name: string, limit: number): string?
	if type(value) ~= "string" or value == "" then
		return name .. " must be a non-empty string"
	end
	local length = utf8.len(value)
	if length == nil then
		return name .. " must be valid UTF-8"
	end
	if length > limit then
		return string.format("%s is %d characters (at most %d)", name, length, limit)
	end
	return nil
end

-- (config, {}) with the BanAsync config table, or (nil, problems).
function Moderation.banRequest(request: any): ({ [string]: any }?, { string })
	if type(request) ~= "table" then
		return nil, { "request must be a table" }
	end
	local problems = {}
	local userIds = request.userIds
	if type(userIds) ~= "table" or #userIds < 1 or #userIds > Moderation.MAX_USER_IDS then
		table.insert(problems, string.format("userIds must list 1 to %d user ids", Moderation.MAX_USER_IDS))
	else
		local seen = {}
		for _, userId in userIds do
			if not (Check.integer(userId) and userId > 0) then
				table.insert(problems, "userIds must be integers > 0, got " .. Check.describe(userId))
			elseif seen[userId] then
				table.insert(problems, "userIds repeats " .. tostring(userId))
			end
			seen[userId] = true
		end
	end
	local duration = request.duration
	if not (duration == Moderation.PERMANENT or (Check.integer(duration) and duration > 0)) then
		table.insert(problems, "duration must be whole seconds > 0 or Moderation.PERMANENT (-1)")
	end
	local display = textProblem(request.displayReason, "displayReason", Moderation.MAX_DISPLAY_REASON)
	if display then
		table.insert(problems, display)
	end
	local private = textProblem(request.privateReason, "privateReason", Moderation.MAX_PRIVATE_REASON)
	if private then
		table.insert(problems, private)
	end
	for _, flag in { "applyToUniverse", "excludeAltAccounts" } do
		if request[flag] ~= nil and type(request[flag]) ~= "boolean" then
			table.insert(problems, flag .. " must be a boolean")
		end
	end
	if #problems > 0 then
		return nil, problems
	end
	return {
		UserIds = table.clone(userIds),
		ApplyToUniverse = request.applyToUniverse ~= false,
		Duration = duration,
		DisplayReason = request.displayReason,
		PrivateReason = request.privateReason,
		ExcludeAltAccounts = request.excludeAltAccounts == true,
	}, {}
end

export type Step = { after: number, action: "warn" | "kick" | "ban", duration: number? }

-- Validates a ladder (the game's data): steps sorted by `after` (offense counts >= 1, strictly
-- increasing); bans carry a duration (seconds or PERMANENT). Returns a frozen copy or raises.
function Moderation.ladder(steps: { Step }): { Step }
	assert(type(steps) == "table" and #steps >= 1, "Moderation.ladder: at least one step")
	local out = {}
	local last = 0
	for index, step in steps do
		local where = "step " .. index
		assert(type(step) == "table", "Moderation.ladder: " .. where .. " must be a table")
		assert(
			Check.integer(step.after) and step.after > last,
			"Moderation.ladder: " .. where .. ".after must be an integer above the previous step's"
		)
		assert(
			table.find(Moderation.ACTIONS, step.action),
			"Moderation.ladder: " .. where .. ".action must be warn, kick or ban"
		)
		if step.action == "ban" then
			assert(
				step.duration == Moderation.PERMANENT
					or (Check.integer(step.duration) and (step.duration :: number) > 0),
				"Moderation.ladder: " .. where .. " bans need a duration"
			)
		else
			assert(step.duration == nil, "Moderation.ladder: only ban steps take a duration")
		end
		last = step.after
		table.insert(out, table.freeze(table.clone(step)))
	end
	return table.freeze(out)
end

-- The step for an offense count: the last step whose `after` is <= count, or nil (below the
-- first step).
function Moderation.decide(ladder: { Step }, offenses: number): Step?
	assert(Check.integer(offenses) and offenses >= 0, "Moderation.decide: offenses must be an integer >= 0")
	local chosen: Step? = nil
	for _, step in ladder do
		if step.after <= offenses then
			chosen = step
		end
	end
	return chosen
end

return Moderation
