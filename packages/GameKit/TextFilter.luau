--!strict
-- @tier T0
-- TextFilter: the server path for player-written text that other players will see (names,
-- signs, notes, descriptions; chat goes through TextChatService, which filters on its own).
-- Roblox requires filtering such text, and removes games that do not. submit() runs, in order:
-- type and UTF-8 checks, control characters stripped (newlines only when allowed), trim, empty
-- and length checks (codepoints), a per-player rate limit, then the injected filter (yields:
-- TextFilterRoblox.backend calls TextService:FilterStringAsync and the broadcast or per-user
-- variant). It fails closed: any failure returns (false, "", reason), so callers display nothing.
-- Filter after submit, never per keystroke. Stored text is filtered again when it is shown to a
-- different audience (filter(text, author, audience) per viewer or broadcast).
-- Conventions: maxLength 200 codepoints and the default rate.
local RateLimit = require("./RateLimit")

local TextFilter = {}

TextFilter.DEFAULT_MAX_LENGTH = 200 -- convention
TextFilter.DEFAULT_RATE = table.freeze({ capacity = 5, refillPerSec = 0.5 }) -- convention
TextFilter.REASONS = table.freeze({
	"invalid", -- not a string
	"invalid_utf8",
	"empty", -- nothing left after stripping and trimming
	"too_long",
	"rate",
	"invalid_audience",
	"filter_failed", -- the filter raised or returned something other than a string
})

export type Audience = "broadcast" | number -- everyone, or one recipient's UserId
export type FilterFn = (text: string, fromUserId: number, audience: Audience) -> string

export type Options = {
	filter: FilterFn,
	maxLength: number?,
	allowNewlines: boolean?,
	rate: { capacity: number, refillPerSec: number }?,
}

-- Invisible code points removed before filtering: zero-width (U+200B-U+200F, U+2060-U+2064,
-- U+FEFF) and bidirectional controls (U+202A-U+202E, U+2066-U+2069).
local STRIPPED: { [number]: boolean } = { [0xFEFF] = true }
for code = 0x200B, 0x200F do
	STRIPPED[code] = true
end
for code = 0x202A, 0x202E do
	STRIPPED[code] = true
end
for code = 0x2060, 0x2069 do
	STRIPPED[code] = true
end

-- (clean text) or (nil, reason): the checks before the filter, without the rate limit.
function TextFilter.prepare(text: any, maxLength: number?, allowNewlines: boolean?): (string?, string?)
	if type(text) ~= "string" then
		return nil, "invalid"
	end
	if utf8.len(text) == nil then
		return nil, "invalid_utf8"
	end
	-- drop control characters (C0, DEL, C1), bidirectional overrides and zero-width characters
	-- (spoofing tools); a tab becomes a space; \n stays only when allowed
	local parts = table.create(#text)
	for _, code in utf8.codes(text) do
		if code == 10 and allowNewlines then
			table.insert(parts, "\n")
		elseif code == 9 then
			table.insert(parts, " ")
		elseif not (code < 32 or (code >= 127 and code <= 159) or STRIPPED[code]) then
			table.insert(parts, utf8.char(code))
		end
	end
	local cleaned = table.concat(parts)
	cleaned = string.gsub(cleaned, "^%s+", "")
	cleaned = string.gsub(cleaned, "%s+$", "")
	if cleaned == "" then
		return nil, "empty"
	end
	if (utf8.len(cleaned) :: number) > (maxLength or TextFilter.DEFAULT_MAX_LENGTH) then
		return nil, "too_long"
	end
	return cleaned, nil
end

local Pipeline = {}
Pipeline.__index = Pipeline

type PipelineFields = {
	_filter: FilterFn,
	_maxLength: number,
	_allowNewlines: boolean,
	_limiter: any,
	_env: any,
	_counts: { [string]: number },
}
export type Pipeline = typeof(setmetatable({} :: PipelineFields, Pipeline))

function TextFilter.new(options: Options, env: any): Pipeline
	local problems = {}
	if type(options) ~= "table" or type(options.filter) ~= "function" then
		table.insert(problems, "filter(text, fromUserId, audience) is required (TextFilterRoblox.backend)")
	end
	local maxLength = options and options.maxLength
	if maxLength ~= nil and not (type(maxLength) == "number" and maxLength >= 1 and maxLength % 1 == 0) then
		table.insert(problems, "maxLength must be an integer >= 1")
	end
	if env == nil or type(env.clock) ~= "function" then
		table.insert(problems, "env with clock is required")
	end
	if #problems > 0 then
		error("TextFilter.new: " .. table.concat(problems, "; "), 2)
	end
	local rate = options.rate or TextFilter.DEFAULT_RATE
	return setmetatable({
		_filter = options.filter,
		_maxLength = maxLength or TextFilter.DEFAULT_MAX_LENGTH,
		_allowNewlines = options.allowNewlines == true,
		_limiter = RateLimit.new({ capacity = rate.capacity, refillPerSec = rate.refillPerSec }, env),
		_env = env,
		_counts = {},
	}, Pipeline)
end

local function refuse(self: Pipeline, reason: string): (boolean, string, string)
	self._counts[reason] = (self._counts[reason] or 0) + 1
	return false, "", reason
end

local function userIdOf(player: any): number?
	if type(player) == "number" then
		return player
	end
	local ok, userId = pcall(function(): any
		return player.UserId
	end)
	return if ok and type(userId) == "number" then userId else nil
end

-- Runs the full pipeline for text written by player (a Player or a UserId) and shown to
-- audience ("broadcast" or a recipient UserId). Yields in the filter. Returns
-- (true, filteredText, "ok") or (false, "", reason). The filtered text may contain hash marks.
function Pipeline.submit(
	self: Pipeline,
	player: any,
	text: any,
	audience: Audience?
): (boolean, string, string)
	local userId = userIdOf(player)
	if userId == nil then
		return refuse(self, "invalid")
	end
	local target: any = audience or "broadcast"
	if target ~= "broadcast" and not (type(target) == "number" and target > 0 and target % 1 == 0) then
		return refuse(self, "invalid_audience")
	end
	local cleaned, reason = TextFilter.prepare(text, self._maxLength, self._allowNewlines)
	if cleaned == nil then
		return refuse(self, reason :: string)
	end
	if not self._limiter:take(userId) then
		return refuse(self, "rate")
	end
	return self:filter(cleaned, userId, target)
end

-- Filters already-validated text for one audience (no rate limit): use it to show stored text
-- to a new audience. Yields. Fails closed like submit.
function Pipeline.filter(
	self: Pipeline,
	text: string,
	fromUserId: number,
	audience: Audience
): (boolean, string, string)
	local ok, result = pcall(self._filter, text, fromUserId, audience)
	if not ok or type(result) ~= "string" then
		self._env.report(
			string.format(
				"TextFilter: filter failed for %d: %s",
				fromUserId,
				if ok then "not a string" else tostring(result)
			)
		)
		return refuse(self, "filter_failed")
	end
	self._counts.ok = (self._counts.ok or 0) + 1
	return true, result, "ok"
end

-- Drops a player's rate state (PlayerRemoving).
function Pipeline.forget(self: Pipeline, player: any)
	local userId = userIdOf(player)
	if userId then
		self._limiter:forget(userId)
	end
end

-- Outcome counts by reason ("ok" for filtered text).
function Pipeline.counts(self: Pipeline): { [string]: number }
	return table.clone(self._counts)
end

return TextFilter
