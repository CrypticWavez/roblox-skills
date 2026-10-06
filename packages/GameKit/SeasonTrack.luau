--!strict
-- @tier T0
-- SeasonTrack: a season pass as data with no prices. A season is
--   { id, tiers = { { xp, free?, premium? } }, start?, ["end"]? }
-- where tiers[i].xp is the XP to go from tier i-1 to tier i (tier 0 is the start) and free and
-- premium are reward data the game grants. Premium is a flag the game sets from an entitlement
-- it owns (a pass or product handled by G1 CommerceRoblox); this module never prices, prompts or
-- grants. XP only counts inside the season window (server UTC). Claims are per tier and track,
-- once each; premium claims stay available retroactively once the flag is set. Data from an
-- earlier season resets (a new season id). Events: kit-event/1 progression (path = season id,
-- level = tier reached) and a custom season_claim event with the track.
local Check = require("./Check")
local Events = require("./Events")
local LiveOps = require("./LiveOps")

local SeasonTrack = {}
SeasonTrack.SCHEMA = "season/1"
SeasonTrack.TRACKS = table.freeze({ "free", "premium" })

export type Tier = { xp: number, free: any?, premium: any? }
export type Spec = { id: string, tiers: { Tier }, cumulative: { number }, start: number?, finish: number? }

local function utc(value: any): number?
	if type(value) == "string" then
		return LiveOps.parseUtc(value)
	end
	return if Check.finite(value) then value else nil
end

-- Problems with a season definition (empty when valid).
function SeasonTrack.validate(season: any): { string }
	if type(season) ~= "table" then
		return { "season must be a table" }
	end
	local problems = {}
	if not Check.label(season.id, 48) then
		table.insert(problems, "id must be a label of at most 48 characters")
	end
	if type(season.tiers) ~= "table" or #season.tiers == 0 then
		table.insert(problems, "tiers must be a non-empty list")
	else
		local total = 0
		for index, tier in season.tiers do
			if type(tier) ~= "table" or not (Check.integer(tier.xp) and tier.xp >= 1) then
				table.insert(problems, string.format("tier %d: xp must be an integer >= 1", index))
			else
				total += tier.xp
			end
			if type(tier) == "table" then
				for key in tier do
					if key ~= "xp" and key ~= "free" and key ~= "premium" then
						table.insert(
							problems,
							string.format(
								"tier %d: unknown key %s (no prices here)",
								index,
								Check.describe(key)
							)
						)
					end
				end
			end
		end
		if total > Check.MAX_SAFE_INTEGER then
			table.insert(problems, "total xp passes 2^53")
		end
	end
	local start, finish = season.start, season["end"]
	if (start ~= nil and utc(start) == nil) or (finish ~= nil and utc(finish) == nil) then
		table.insert(problems, "start and end must be UTC seconds or YYYY-MM-DDTHH:MM:SSZ")
	elseif start ~= nil and finish ~= nil and (utc(finish) :: number) <= (utc(start) :: number) then
		table.insert(problems, "end must be after start")
	end
	return problems
end

-- A validated, frozen season. Raises with every problem listed.
function SeasonTrack.define(season: any): Spec
	local problems = SeasonTrack.validate(season)
	if #problems > 0 then
		error("SeasonTrack.define: " .. table.concat(problems, "; "), 2)
	end
	local cumulative = { 0 }
	for index, tier in season.tiers do
		cumulative[index + 1] = cumulative[index] + tier.xp
	end
	return Check.freeze({
		id = season.id,
		tiers = Check.copy(season.tiers),
		cumulative = cumulative,
		start = utc(season.start),
		finish = utc(season["end"]),
	})
end

local Pass = {}
Pass.__index = Pass
type PassFields = {
	notes: { string },
	_spec: Spec,
	_xp: number,
	_premium: boolean,
	_claimed: { free: { [number]: boolean }, premium: { [number]: boolean } },
	_sink: Events.Sink?,
	_player: string?,
}
export type Pass = typeof(setmetatable({} :: PassFields, Pass))
export type Options = { premium: boolean?, data: any?, sink: Events.Sink?, player: string? }

-- One player's pass for spec. data from another season id starts fresh (noted).
function SeasonTrack.new(spec: Spec, options: Options?, _env: any?): Pass
	assert(
		type(spec) == "table" and table.isfrozen(spec) and spec.cumulative,
		"SeasonTrack.new needs a spec from define"
	)
	local opts: Options = options or {}
	local self = setmetatable({
		notes = {},
		_spec = spec,
		_xp = 0,
		_premium = opts.premium == true,
		_claimed = { free = {}, premium = {} },
		_sink = opts.sink,
		_player = opts.player,
	}, Pass)
	local data = opts.data
	if data ~= nil then
		if type(data) ~= "table" or data.schema ~= SeasonTrack.SCHEMA then
			table.insert(self.notes, "stored data is not season/1; starting fresh")
		elseif data.season ~= spec.id then
			table.insert(
				self.notes,
				"stored data is for season " .. Check.describe(data.season) .. "; new season starts fresh"
			)
		else
			local max = spec.cumulative[#spec.cumulative]
			self._xp = if Check.integer(data.xp) and data.xp >= 0 then math.min(data.xp, max) else 0
			for _, track in SeasonTrack.TRACKS do
				for _, tier in (data.claimed and data.claimed[track]) or {} do
					if Check.integer(tier) and tier >= 1 and tier <= #spec.tiers then
						self._claimed[track][tier] = true
					end
				end
			end
		end
	end
	return self
end

-- Whether the season accepts XP at utc (always true without a window).
function Pass.isOpen(self: Pass, utcNow: number?): boolean
	local spec = self._spec
	if spec.start == nil and spec.finish == nil then
		return true
	end
	if utcNow == nil then
		return false
	end
	return (spec.start == nil or utcNow >= spec.start) and (spec.finish == nil or utcNow < spec.finish)
end

-- Highest tier reached (0..#tiers).
function Pass.tier(self: Pass): number
	local cumulative = self._spec.cumulative
	local tier = 0
	for index = 2, #cumulative do
		if self._xp >= cumulative[index] then
			tier = index - 1
		end
	end
	return tier
end

function Pass.xp(self: Pass): number
	return self._xp
end

-- { tier, into, needed, maxed }
function Pass.progress(self: Pass): any
	local tier = self:tier()
	local cumulative = self._spec.cumulative
	if tier >= #self._spec.tiers then
		return { tier = tier, into = 0, needed = 0, maxed = true }
	end
	return {
		tier = tier,
		into = self._xp - cumulative[tier + 1],
		needed = cumulative[tier + 2] - cumulative[tier + 1],
		maxed = false,
	}
end

-- Adds XP (integer > 0) at server UTC utcNow. (true, nil, { from, to, applied }) or (false,
-- reason) with invalid_amount or season_closed.
function Pass.addXp(self: Pass, amount: number, utcNow: number?): (boolean, string?, any)
	if not (Check.integer(amount) and amount > 0) then
		return false, "invalid_amount", nil
	end
	if not self:isOpen(utcNow) then
		return false, "season_closed", nil
	end
	local max = self._spec.cumulative[#self._spec.cumulative]
	local from = self:tier()
	local applied = math.min(amount, max - self._xp)
	self._xp += applied
	local to = self:tier()
	if to > from and self._sink then
		local event =
			Events.progression("season_tier", { path = self._spec.id, status = "complete", level = to })
		if self._player then
			event.player = self._player
		end
		pcall(function()
			(self._sink :: any):emit(event)
		end)
	end
	return true, nil, { from = from, to = to, applied = applied }
end

-- Sets the premium flag from the game's own entitlement check.
function Pass.setPremium(self: Pass, premium: boolean)
	self._premium = premium == true
end

function Pass.isPremium(self: Pass): boolean
	return self._premium
end

-- Rewards claimable now: { { tier, track, reward } } in tier order, free before premium.
function Pass.claimable(self: Pass): { any }
	local out = {}
	for tier = 1, self:tier() do
		local def = self._spec.tiers[tier]
		for _, track in SeasonTrack.TRACKS do
			local reward = (def :: any)[track]
			if reward ~= nil and not self._claimed[track][tier] and (track == "free" or self._premium) then
				table.insert(out, { tier = tier, track = track, reward = Check.copy(reward) })
			end
		end
	end
	return out
end

-- Claims one reward once. (true, nil, reward) or (false, reason) with unknown_tier, bad_track,
-- not_reached, no_reward, premium_required or already_claimed.
function Pass.claim(self: Pass, tier: number, track: string): (boolean, string?, any)
	local def = self._spec.tiers[tier]
	if def == nil then
		return false, "unknown_tier", nil
	end
	if track ~= "free" and track ~= "premium" then
		return false, "bad_track", nil
	end
	if tier > self:tier() then
		return false, "not_reached", nil
	end
	local reward = (def :: any)[track]
	if reward == nil then
		return false, "no_reward", nil
	end
	if track == "premium" and not self._premium then
		return false, "premium_required", nil
	end
	if self._claimed[track][tier] then
		return false, "already_claimed", nil
	end
	self._claimed[track][tier] = true
	if self._sink then
		local event = Events.custom("season_claim", tier, { track = track, season = self._spec.id })
		if self._player then
			event.player = self._player
		end
		pcall(function()
			(self._sink :: any):emit(event)
		end)
	end
	return true, nil, Check.copy(reward)
end

-- Claims everything claimable; returns the claimed { tier, track, reward } list.
function Pass.claimAll(self: Pass): { any }
	local out = {}
	for _, item in self:claimable() do
		local ok, _, reward = self:claim(item.tier, item.track)
		if ok then
			table.insert(out, { tier = item.tier, track = item.track, reward = reward })
		end
	end
	return out
end

-- season/1 data. The premium flag is not stored: it is re-derived from the entitlement.
function Pass.serialize(self: Pass): any
	local claimed = { free = {}, premium = {} }
	for _, track in SeasonTrack.TRACKS do
		for tier = 1, #self._spec.tiers do
			if self._claimed[track][tier] then
				table.insert(claimed[track], tier)
			end
		end
	end
	return { schema = SeasonTrack.SCHEMA, season = self._spec.id, xp = self._xp, claimed = claimed }
end

return SeasonTrack
