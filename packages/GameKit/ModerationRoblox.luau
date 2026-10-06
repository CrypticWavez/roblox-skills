--!strict
-- @tier T4
-- ModerationRoblox: Players:BanAsync, UnbanAsync and GetBanHistoryAsync behind explicit checks.
-- A ban is a production action on real accounts, so ban() refuses in Studio and refuses unless
-- the caller passes the confirm token Moderation-style ("ban_confirmed"); it only ever runs in a
-- live game, from the game's own moderator flow. Agents never run it (owner-only, T4).
-- Requests are validated by GameKit/Moderation.banRequest first; engine errors are caught and
-- returned. Roblox extends bans to suspected alternate accounts unless ExcludeAltAccounts.
local Moderation = require("./Moderation")

local ModerationRoblox = {}

ModerationRoblox.CONFIRM = "ban_confirmed"

export type Context = { place: any, confirm: string? }

local function refusal(context: Context): string?
	if context == nil or context.place == nil then
		return "no_place"
	end
	if context.place.isStudio then
		return "studio_refused"
	end
	if context.confirm ~= ModerationRoblox.CONFIRM then
		return "not_confirmed"
	end
	return nil
end

-- Bans the request's users. Returns (true) or (false, reason, detail) with reasons no_place,
-- studio_refused, not_confirmed, invalid_request (detail: problems) and ban_failed (detail: the
-- engine error). Yields.
function ModerationRoblox.ban(
	players: any,
	request: Moderation.BanRequest,
	context: Context
): (boolean, string?, any)
	local refused = refusal(context)
	if refused then
		return false, refused, nil
	end
	local config, problems = Moderation.banRequest(request)
	if config == nil then
		return false, "invalid_request", problems
	end
	local ok, err = pcall(function()
		players:BanAsync(config)
	end)
	if not ok then
		return false, "ban_failed", tostring(err)
	end
	return true, nil, nil
end

-- Lifts bans for userIds (same refusals as ban). Yields.
function ModerationRoblox.unban(
	players: any,
	userIds: { number },
	applyToUniverse: boolean?,
	context: Context
): (boolean, string?, any)
	local refused = refusal(context)
	if refused then
		return false, refused, nil
	end
	if type(userIds) ~= "table" or #userIds < 1 or #userIds > Moderation.MAX_USER_IDS then
		return false, "invalid_request", { "userIds must list 1 to 50 user ids" }
	end
	local ok, err = pcall(function()
		players:UnbanAsync({ UserIds = table.clone(userIds), ApplyToUniverse = applyToUniverse ~= false })
	end)
	if not ok then
		return false, "unban_failed", tostring(err)
	end
	return true, nil, nil
end

-- The ban history pages for a user (read-only), or (nil, error). Yields.
function ModerationRoblox.history(players: any, userId: number): (any, string?)
	local ok, pages = pcall(function(): any
		return players:GetBanHistoryAsync(userId)
	end)
	if not ok then
		return nil, tostring(pages)
	end
	return pages, nil
end

return ModerationRoblox
