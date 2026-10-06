--!strict
-- @tier T4
-- TextFilterRoblox: the TextService and TextChatService calls behind GameKit/TextFilter.
--   backend(TextService, { context })   filter(text, fromUserId, audience) for TextFilter.new:
--       TextService:FilterStringAsync(text, fromUserId, context), then
--       GetNonChatStringForBroadcastAsync() for "broadcast" or GetNonChatStringForUserAsync(toUserId).
--       FilterStringAsync raises when fromUserId is not in the server; GetNonChatStringForUserAsync
--       needs the recipient online too. Errors propagate so TextFilter fails closed.
--   canChat / canDirectChat(TextChatService, userIds)   CanUsersChatAsync / CanUsersDirectChatAsync,
--       false on any error (fail closed).
-- T4: whether filtering replaces text in Studio is UNVERIFIED (research
-- release-monetization-analytics-2026-10 section 13); the filtering effect is only observable
-- in a published game. The routing is proven in Lune against tests/fakes/FakeTextService.
local TextFilterRoblox = {}

-- Enum.TextFilterContext item names; PublicChat is the default for text many players see.
TextFilterRoblox.CONTEXTS = table.freeze({ "PublicChat", "PrivateChat" })

export type BackendOptions = { context: any? } -- an Enum.TextFilterContext item

function TextFilterRoblox.backend(textService: any, options: BackendOptions?): (string, number, any) -> string
	assert(textService ~= nil, "TextFilterRoblox.backend: TextService required")
	local context = options and options.context
	return function(text: string, fromUserId: number, audience: any): string
		local result = if context ~= nil
			then textService:FilterStringAsync(text, fromUserId, context)
			else textService:FilterStringAsync(text, fromUserId)
		if audience == "broadcast" then
			return result:GetNonChatStringForBroadcastAsync()
		end
		return result:GetNonChatStringForUserAsync(audience)
	end
end

-- Whether these users may chat with each other (TextChatService:CanUsersChatAsync). Yields.
function TextFilterRoblox.canChat(textChatService: any, userIdA: number, userIdB: number): boolean
	local ok, allowed = pcall(function(): any
		return textChatService:CanUsersChatAsync(userIdA, userIdB)
	end)
	return ok and allowed == true
end

-- Whether these users may share a direct (1:1) chat (TextChatService:CanUsersDirectChatAsync,
-- which returns the allowed subset of userIds). Yields. Any error means none.
function TextFilterRoblox.canDirectChat(
	textChatService: any,
	requesterUserId: number,
	userIds: { number }
): { number }
	local ok, allowed = pcall(function(): any
		return textChatService:CanUsersDirectChatAsync(requesterUserId, userIds)
	end)
	if not ok or type(allowed) ~= "table" then
		return {}
	end
	local out = {}
	for _, userId in allowed do
		if type(userId) == "number" and table.find(userIds, userId) then
			table.insert(out, userId)
		end
	end
	return out
end

return TextFilterRoblox
