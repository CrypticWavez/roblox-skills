--!strict
-- @tier T0
-- Offers: when to show which purchase offer (offers/1 data, docs/monetization.md). It decides
-- and records; it never prompts. The game shows the offer UI (UIKit/Components/OfferPopup or
-- ShopCard) and runs its own guarded prompt (GameKit/CommerceRoblox.prompt) when the player
-- chooses to buy. Data:
--   { schema = "offers/1",
--     rules = { maxPerSession?, minSpacing?, grace?, quietAfterPurchase? },
--     offers = { { key, productKey, trigger, priority?, cooldown?, maxShows?,
--                  maxShowsPerSession?, untilBought?, audience?, window?, duration?, ribbon? } } }
-- trigger is a label the game fires (Offers.TRIGGERS lists the conventional ones). audience
-- narrows who sees it: { payer = "any" | "payer" | "non_payer", minSessions?, maxSessions?,
-- minLevel?, maxLevel? }. window = { start, ["end"] } in UTC seconds limits a limited-time
-- offer to a calendar window; duration (seconds) makes a personal timer that starts at the
-- first show (a starter pack that lasts 24 h for each player) and expiresAt reports its end.
-- Rules keep offers from becoming spam (the Roblox guidance: contextual and inviting, not
-- pushy): at most maxPerSession popups a session, minSpacing seconds between popups, none in
-- the first grace seconds of a player's first session, none for quietAfterPurchase seconds after
-- a purchase, none while a purchase prompt is open, and never for something the player owns.
-- Times are server UTC seconds passed by the caller (os.time() in Roblox), never a client clock.
-- State per player is a small table (offer-state/1) the game saves with its player data.
local Check = require("./Check")

local Offers = {}
Offers.SCHEMA = "offers/1"
Offers.STATE_SCHEMA = "offer-state/1"
-- Conventional triggers; any label works. Contextual ones convert best (docs/monetization.md).
Offers.TRIGGERS = table.freeze({
	"join", -- after load and onboarding grace
	"death", -- revive or protection offers
	"locked", -- the player reached a locked area, slot or tier
	"low_currency", -- a purchase failed for lack of soft currency
	"level_up",
	"round_end",
	"shop_open", -- the featured offer at the top of the shop
	"idle", -- the player is in a hub with nothing to do
	"event_start", -- a live-ops window opened
})
Offers.RIBBONS = table.freeze({ "best_value", "most_popular", "limited", "new", "sale", "starter" })
Offers.DEFAULT_RULES = table.freeze({
	maxPerSession = 3, -- convention: popups per session
	minSpacing = 180, -- convention: seconds between two popups
	grace = 120, -- convention: seconds of a player's first session with no popup
	quietAfterPurchase = 300, -- convention: seconds after a purchase with no popup
})
Offers.REASONS = table.freeze({
	"unknown_trigger", -- no offer listens to this trigger
	"prompt_open", -- a purchase prompt is already open
	"session_cap", -- maxPerSession reached
	"spacing", -- a popup was shown less than minSpacing ago
	"grace", -- first session, within grace seconds
	"quiet_after_purchase",
	"none_eligible", -- offers listen, but every one is owned, capped, cooling down or out of window
})

local OFFER_KEYS = table.freeze({
	"key",
	"productKey",
	"trigger",
	"priority",
	"cooldown",
	"maxShows",
	"maxShowsPerSession",
	"untilBought",
	"audience",
	"window",
	"duration",
	"ribbon",
})
local RULE_KEYS = table.freeze({ "maxPerSession", "minSpacing", "grace", "quietAfterPurchase" })
local AUDIENCE_KEYS = table.freeze({ "payer", "minSessions", "maxSessions", "minLevel", "maxLevel" })

export type Audience = {
	payer: ("any" | "payer" | "non_payer")?,
	minSessions: number?,
	maxSessions: number?,
	minLevel: number?,
	maxLevel: number?,
}
export type Offer = {
	key: string,
	productKey: string,
	trigger: string,
	priority: number?,
	cooldown: number?,
	maxShows: number?,
	maxShowsPerSession: number?,
	untilBought: boolean?,
	audience: Audience?,
	window: { start: number, ["end"]: number }?,
	duration: number?,
	ribbon: string?,
}
export type Rules = { maxPerSession: number, minSpacing: number, grace: number, quietAfterPurchase: number }
export type Data = { schema: string, rules: Rules?, offers: { Offer } }
export type State = {
	schema: string,
	sessions: number,
	payer: boolean,
	shows: { [string]: number },
	lastShown: { [string]: number },
	firstShown: { [string]: number },
	bought: { [string]: boolean },
}
export type Context = {
	now: number,
	level: number?,
	owned: ((productKey: string) -> boolean)?,
	promptOpen: boolean?,
}

local function nonNegative(value: any): boolean
	return Check.finite(value) and value >= 0
end

local function count(value: any): boolean
	return Check.integer(value) and value >= 1
end

-- Problems with offers/1 data (empty when valid). With a catalog/1 table, every productKey must
-- name one of its products; a duration or window needs an offer that can expire.
function Offers.validate(data: any, catalog: any?): { string }
	if type(data) ~= "table" then
		return { "offers must be a table" }
	end
	local problems = {}
	if data.schema ~= Offers.SCHEMA then
		table.insert(problems, "schema must be " .. Offers.SCHEMA)
	end
	for key in data do
		if key ~= "schema" and key ~= "rules" and key ~= "offers" then
			table.insert(problems, "unexpected key " .. Check.describe(key))
		end
	end
	if data.rules ~= nil then
		if type(data.rules) ~= "table" then
			table.insert(problems, "rules must be a table")
		else
			for key, value in data.rules do
				if not table.find(RULE_KEYS, key) then
					table.insert(problems, "rules: unexpected key " .. Check.describe(key))
				elseif key == "maxPerSession" and not count(value) then
					table.insert(problems, "rules.maxPerSession must be an integer >= 1")
				elseif key ~= "maxPerSession" and not nonNegative(value) then
					table.insert(problems, "rules." .. key .. " must be a number >= 0")
				end
			end
		end
	end
	local offers = data.offers
	if type(offers) ~= "table" then
		table.insert(problems, "offers must be a list")
		return problems
	end
	local seen: { [string]: boolean } = {}
	for index, offer in offers do
		local where = "offers[" .. index .. "]"
		if type(offer) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		if Check.label(offer.key) then
			where = offer.key
			if seen[offer.key] then
				table.insert(problems, where .. ": duplicate key")
			end
			seen[offer.key] = true
		else
			table.insert(problems, where .. ".key must be a label")
		end
		for key in offer do
			if
				type(key) == "string"
				and (string.find(string.lower(key), "price") or string.find(string.lower(key), "robux"))
			then
				table.insert(problems, where .. "." .. key .. ": prices are runtime reads, never offer data")
			elseif not table.find(OFFER_KEYS, key) then
				table.insert(problems, where .. ": unexpected key " .. Check.describe(key))
			end
		end
		if not Check.label(offer.productKey) then
			table.insert(problems, where .. ".productKey must be a label")
		elseif catalog ~= nil and type(catalog) == "table" and type(catalog.products) == "table" then
			local found = false
			for _, product in catalog.products do
				if product.key == offer.productKey then
					found = true
					break
				end
			end
			if not found then
				table.insert(
					problems,
					where .. ".productKey " .. offer.productKey .. " is not in the catalog"
				)
			end
		end
		if not Check.label(offer.trigger) then
			table.insert(problems, where .. ".trigger must be a label")
		end
		if offer.priority ~= nil and not Check.integer(offer.priority) then
			table.insert(problems, where .. ".priority must be an integer")
		end
		for _, name in { "cooldown", "duration" } do
			local value = (offer :: any)[name]
			if value ~= nil and not nonNegative(value) then
				table.insert(problems, where .. "." .. name .. " must be a number >= 0")
			end
		end
		for _, name in { "maxShows", "maxShowsPerSession" } do
			local value = (offer :: any)[name]
			if value ~= nil and not count(value) then
				table.insert(problems, where .. "." .. name .. " must be an integer >= 1")
			end
		end
		if offer.untilBought ~= nil and type(offer.untilBought) ~= "boolean" then
			table.insert(problems, where .. ".untilBought must be a boolean")
		end
		if offer.ribbon ~= nil and not table.find(Offers.RIBBONS, offer.ribbon) then
			table.insert(problems, where .. ".ribbon must be one of " .. table.concat(Offers.RIBBONS, ", "))
		end
		local window = offer.window
		if window ~= nil then
			if
				type(window) ~= "table"
				or not Check.integer(window.start)
				or not Check.integer(window["end"])
				or window["end"] <= window.start
			then
				table.insert(
					problems,
					where .. ".window must be { start, end } in UTC seconds with end > start"
				)
			end
		end
		local audience = offer.audience
		if audience ~= nil then
			if type(audience) ~= "table" then
				table.insert(problems, where .. ".audience must be a table")
			else
				for key, value in audience do
					if not table.find(AUDIENCE_KEYS, key) then
						table.insert(problems, where .. ".audience: unexpected key " .. Check.describe(key))
					elseif key == "payer" then
						if value ~= "any" and value ~= "payer" and value ~= "non_payer" then
							table.insert(problems, where .. ".audience.payer must be any, payer or non_payer")
						end
					elseif not (Check.integer(value) and value >= 0) then
						table.insert(problems, where .. ".audience." .. key .. " must be an integer >= 0")
					end
				end
			end
		end
	end
	return problems
end

-- Validates, copies and freezes offers/1 data, filling the default rules. Raises on problems.
function Offers.define(data: any, catalog: any?): Data
	local problems = Offers.validate(data, catalog)
	if #problems > 0 then
		error("Offers.define: " .. table.concat(problems, "; "), 2)
	end
	local copy = Check.copy(data)
	local rules = table.clone(Offers.DEFAULT_RULES) :: any
	for key, value in copy.rules or {} do
		rules[key] = value
	end
	copy.rules = rules
	return Check.freeze(copy)
end

-- A fresh offer-state/1 table for a new player.
function Offers.newState(): State
	return {
		schema = Offers.STATE_SCHEMA,
		sessions = 0,
		payer = false,
		shows = {},
		lastShown = {},
		firstShown = {},
		bought = {},
	}
end

-- A saved state checked and repaired: unknown or malformed fields fall back to empty, so a
-- corrupt save never blocks the game (it only forgets offer history).
function Offers.loadState(saved: any): State
	local state = Offers.newState()
	if type(saved) ~= "table" or saved.schema ~= Offers.STATE_SCHEMA then
		return state
	end
	if Check.integer(saved.sessions) and saved.sessions >= 0 then
		state.sessions = saved.sessions
	end
	state.payer = saved.payer == true
	for _, field in { "shows", "lastShown", "firstShown" } do
		local source = saved[field]
		if type(source) == "table" then
			for key, value in source do
				if Check.label(key) and Check.finite(value) then
					(state :: any)[field][key] = value
				end
			end
		end
	end
	if type(saved.bought) == "table" then
		for key, value in saved.bought do
			if Check.label(key) and value == true then
				state.bought[key] = true
			end
		end
	end
	return state
end

local Session = {}
Session.__index = Session

-- Starts a session for one player: state is their offer-state/1 table (Offers.loadState), now
-- the UTC time. The session count goes up by one; the session itself keeps per-session counts.
function Offers.session(data: Data, state: State, now: number): any
	assert(type(data) == "table" and data.schema == Offers.SCHEMA, "Offers.session: data from Offers.define")
	assert(
		type(state) == "table" and state.schema == Offers.STATE_SCHEMA,
		"Offers.session: offer-state/1 required"
	)
	assert(Check.finite(now), "Offers.session: now must be UTC seconds")
	state.sessions += 1
	return setmetatable({
		data = data,
		state = state,
		startedAt = now,
		popups = 0,
		lastPopup = -math.huge,
		lastPurchase = -math.huge,
		sessionShows = {} :: { [string]: number },
	}, Session)
end

local function audienceOk(offer: Offer, state: State, level: number?): boolean
	local audience = offer.audience
	if audience == nil then
		return true
	end
	if audience.payer == "payer" and not state.payer then
		return false
	elseif audience.payer == "non_payer" and state.payer then
		return false
	end
	if audience.minSessions ~= nil and state.sessions < audience.minSessions then
		return false
	end
	if audience.maxSessions ~= nil and state.sessions > audience.maxSessions then
		return false
	end
	if audience.minLevel ~= nil and (level == nil or level < audience.minLevel) then
		return false
	end
	if audience.maxLevel ~= nil and (level == nil or level > audience.maxLevel) then
		return false
	end
	return true
end

-- The UTC time a personal (duration) or windowed offer ends for this player, or nil when it
-- does not expire or has not been shown yet. The earlier of the two wins.
function Session.expiresAt(self: any, key: string): number?
	local offer = self:find(key)
	if offer == nil then
		return nil
	end
	local ends: number? = nil
	if offer.duration ~= nil then
		local first = self.state.firstShown[key]
		if first ~= nil then
			ends = first + offer.duration
		end
	end
	if offer.window ~= nil then
		local windowEnd = offer.window["end"]
		ends = if ends == nil then windowEnd else math.min(ends, windowEnd)
	end
	return ends
end

function Session.find(self: any, key: string): Offer?
	for _, offer in self.data.offers do
		if offer.key == key then
			return offer
		end
	end
	return nil
end

-- (eligible, why) for one offer at ctx.now, ignoring the session-wide rules.
function Session.eligible(self: any, offer: Offer, ctx: Context): (boolean, string?)
	local state: State = self.state
	local now = ctx.now
	if state.bought[offer.productKey] and offer.untilBought ~= false then
		return false, "bought"
	end
	if ctx.owned ~= nil then
		local ok, owned = pcall(ctx.owned, offer.productKey)
		if ok and owned == true then
			return false, "owned"
		end
	end
	if offer.window ~= nil and (now < offer.window.start or now >= offer.window["end"]) then
		return false, "out_of_window"
	end
	if offer.duration ~= nil then
		local first = state.firstShown[offer.key]
		if first ~= nil and now >= first + offer.duration then
			return false, "expired"
		end
	end
	if offer.maxShows ~= nil and (state.shows[offer.key] or 0) >= offer.maxShows then
		return false, "max_shows"
	end
	if
		offer.maxShowsPerSession ~= nil
		and (self.sessionShows[offer.key] or 0) >= offer.maxShowsPerSession
	then
		return false, "max_shows_session"
	end
	local last = state.lastShown[offer.key]
	if offer.cooldown ~= nil and last ~= nil and now - last < offer.cooldown then
		return false, "cooldown"
	end
	if not audienceOk(offer, state, ctx.level) then
		return false, "audience"
	end
	return true, nil
end

-- The offer to show for trigger, or (nil, reason) with a reason from Offers.REASONS. Never
-- yields and records nothing: call shown(key, now) once the popup is actually on screen.
-- trigger "shop_open" ignores the popup rules (the player opened the shop themselves) but still
-- skips owned, expired and capped offers.
function Session.evaluate(self: any, trigger: string, ctx: Context): (Offer?, string?)
	assert(type(ctx) == "table" and Check.finite(ctx.now), "Offers evaluate: ctx.now (UTC seconds) required")
	local listening = false
	for _, offer in self.data.offers do
		if offer.trigger == trigger then
			listening = true
			break
		end
	end
	if not listening then
		return nil, "unknown_trigger"
	end
	if ctx.promptOpen then
		return nil, "prompt_open"
	end
	local rules: Rules = self.data.rules
	local now = ctx.now
	if trigger ~= "shop_open" then
		if self.popups >= rules.maxPerSession then
			return nil, "session_cap"
		end
		if now - self.lastPopup < rules.minSpacing then
			return nil, "spacing"
		end
		if self.state.sessions <= 1 and now - self.startedAt < rules.grace then
			return nil, "grace"
		end
		if now - self.lastPurchase < rules.quietAfterPurchase then
			return nil, "quiet_after_purchase"
		end
	end
	local best: Offer? = nil
	for _, offer in self.data.offers do
		if offer.trigger == trigger and self:eligible(offer, ctx) then
			local priority = offer.priority or 0
			if best == nil or priority > (best.priority or 0) then
				best = offer
			end
		end
	end
	if best == nil then
		return nil, "none_eligible"
	end
	return best, nil
end

-- Records that offer key was shown at now (counts, cooldowns, the personal timer's start).
function Session.shown(self: any, key: string, now: number)
	local offer = self:find(key)
	assert(offer ~= nil, "Offers shown: unknown offer " .. tostring(key))
	local state: State = self.state
	state.shows[key] = (state.shows[key] or 0) + 1
	state.lastShown[key] = now
	if state.firstShown[key] == nil then
		state.firstShown[key] = now
	end
	self.sessionShows[key] = (self.sessionShows[key] or 0) + 1
	if offer.trigger ~= "shop_open" then
		self.popups += 1
		self.lastPopup = now
	end
end

-- Records a confirmed purchase of productKey (from the receipt handler or a confirmed pass
-- purchase on the server): the player becomes a payer, offers for it stop (untilBought), and the
-- quiet period starts.
function Session.purchased(self: any, productKey: string, now: number)
	assert(Check.label(productKey), "Offers purchased: productKey must be a label")
	self.state.bought[productKey] = true
	self.state.payer = true
	self.lastPurchase = now
end

-- The state table to save (the same table the session mutates).
function Session.save(self: any): State
	return self.state
end

Offers.Session = Session

return Offers
