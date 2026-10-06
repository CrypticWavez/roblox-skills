--!strict
-- FakeTextService (G1): TextService and TextChatService stand-ins for Lune specs.
-- FakeTextService.new({ blocked, online }) answers FilterStringAsync(text, fromUserId, context?)
-- with a result whose GetNonChatStringForBroadcastAsync() and GetNonChatStringForUserAsync(to)
-- replace each blocked word (case-insensitive, whole letters) with hash marks, as Roblox's filter
-- shows filtered text. Like the engine, FilterStringAsync raises when fromUserId is not online and
-- the per-user variant raises when the recipient is not. fail(n) makes the next n calls raise;
-- calls records (method, args). FakeTextService.chat({ blockedPairs, directAllowed }) answers
-- TextChatService:CanUsersChatAsync and CanUsersDirectChatAsync.
local FakeTextService = {}

local function mask(text: string, blocked: { string }): string
	local out = text
	for _, word in blocked do
		local lowerWord = string.lower(word)
		local result = {}
		local index = 1
		local lowerText = string.lower(out)
		while index <= #out do
			local first, last = string.find(lowerText, lowerWord, index, true)
			if first == nil then
				table.insert(result, string.sub(out, index))
				break
			end
			table.insert(result, string.sub(out, index, first - 1))
			table.insert(result, string.rep("#", last - first + 1))
			index = last + 1
		end
		out = table.concat(result)
	end
	return out
end

function FakeTextService.new(options: { blocked: { string }?, online: { number }? }?): any
	local blocked = options and options.blocked or {}
	local online: { [number]: boolean } = {}
	for _, userId in (options and options.online) or {} do
		online[userId] = true
	end
	local service = { calls = {}, online = online, _failures = 0 } :: any

	local function enter(method: string, ...: any)
		table.insert(service.calls, { method = method, args = table.pack(...) })
		if service._failures > 0 then
			service._failures -= 1
			error("TextService: HTTP 503", 0)
		end
	end

	function service.FilterStringAsync(self: any, text: string, fromUserId: number, context: any?): any
		enter("FilterStringAsync", text, fromUserId, context)
		if type(text) ~= "string" then
			error("FilterStringAsync: text must be a string", 0)
		end
		if not self.online[fromUserId] then
			error("FilterStringAsync: user " .. tostring(fromUserId) .. " is not online", 0)
		end
		local result = {}
		function result.GetNonChatStringForBroadcastAsync(_result: any): string
			enter("GetNonChatStringForBroadcastAsync")
			return mask(text, blocked)
		end
		function result.GetNonChatStringForUserAsync(_result: any, toUserId: number): string
			enter("GetNonChatStringForUserAsync", toUserId)
			if not service.online[toUserId] then
				error("GetNonChatStringForUserAsync: user " .. tostring(toUserId) .. " is not online", 0)
			end
			return mask(text, blocked)
		end
		return result
	end

	function service.fail(self: any, count: number?)
		self._failures += count or 1
	end

	return service
end

function FakeTextService.chat(
	options: { blockedPairs: { { number } }?, directAllowed: { number }?, fail: boolean? }?
): any
	local service = {} :: any
	local function blockedPair(a: number, b: number): boolean
		for _, pair in (options and options.blockedPairs) or {} do
			if (pair[1] == a and pair[2] == b) or (pair[1] == b and pair[2] == a) then
				return true
			end
		end
		return false
	end
	function service.CanUsersChatAsync(_self: any, a: number, b: number): boolean
		if options and options.fail then
			error("TextChatService unavailable", 0)
		end
		return not blockedPair(a, b)
	end
	function service.CanUsersDirectChatAsync(_self: any, requester: number, userIds: { number }): { number }
		if options and options.fail then
			error("TextChatService unavailable", 0)
		end
		local out = {}
		for _, userId in userIds do
			if
				not blockedPair(requester, userId)
				and table.find((options and options.directAllowed) or userIds, userId)
			then
				table.insert(out, userId)
			end
		end
		return out
	end
	return service
end

return FakeTextService
