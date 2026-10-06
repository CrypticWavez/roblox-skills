--!strict
-- @tier T0
-- Trade: a server-side escrow between two players' Inventory and Wallet objects (same server).
-- State machine (GameKit/Fsm, serialize() gives "fsm/1:trade:<state>"):
--   proposed --both accept--> locked --countdown, both confirm--> confirmed --commit--> committed
--   any state --cancel--> cancelled
-- Any change to either offer bumps the revision and clears both accepts and confirmations (a
-- locked trade drops back to proposed); accept(side, revision) must name the revision the
-- player saw, so an offer cannot change under a click. Confirmation opens only after the
-- countdown (seconds from lock). Commit is a two-phase commit: every participant (both
-- inventories, both wallets) prepares first; then each commits, and a failure rolls the
-- committed ones back in reverse order, so items and currency are never duplicated or lost.
-- Wallet events are emitted only after the whole trade committed. Idempotency: commit on a
-- committed trade is a no-op, and an injected journal (key store) records committed trade ids
-- so a new Trade object with the same id never applies twice. Policy (fail closed): items
-- marked paid (ItemDefs paid, or an instance's paid origin) need both players' policyAllows
-- ("trading") to be true; untradable items and currencies outside options.currencies are
-- refused. Trade.book() keeps one active trade per player. Server only: clients send requests,
-- the server calls these methods.
local Check = require("./Check")
local Events = require("./Events")
local Fsm = require("./Fsm")
local Signal = require("./Signal")

local Trade = {}
Trade.__index = Trade
Trade.SIDES = table.freeze({ "a", "b" })
Trade.POLICY_FEATURE = "trading"
-- Seconds between both accepting and confirmation opening (convention; games tune it).
Trade.DEFAULT_COUNTDOWN = 3

Trade.SPEC = Fsm.define({
	name = "trade",
	initial = "proposed",
	states = {
		proposed = {},
		locked = {},
		confirmed = {},
		committed = { terminal = true },
		cancelled = { terminal = true },
	},
	transitions = {
		{ from = "proposed", event = "change", to = "proposed" },
		{ from = "locked", event = "change", to = "proposed" },
		{ from = "proposed", event = "lock", to = "locked" },
		{ from = "locked", event = "unlock", to = "proposed" },
		{ from = "locked", event = "confirm", to = "confirmed" },
		{ from = "confirmed", event = "commit", to = "committed" },
		{ from = "*", event = "journal", to = "committed" },
		{ from = "*", event = "cancel", to = "cancelled" },
	},
})

export type Party = {
	key: string,
	inventory: any, -- GameKit/Inventory
	wallet: any?, -- GameKit/Wallet
	policyAllows: any?, -- true, or (feature) -> boolean
}
export type Offer = {
	instances: { string },
	stacks: { { item: string, count: number, paid: boolean } },
	currency: { [string]: number },
}
export type Options = {
	id: string,
	a: Party,
	b: Party,
	countdown: number?,
	autoConfirm: boolean?, -- tick() confirms for both once the countdown ends
	autoCommit: boolean?, -- commit as soon as confirmed (default true)
	expireSeconds: number?, -- cancel after this long without activity
	currencies: { string }?, -- currencies allowed in offers (default none)
	maxEntries: number?, -- offer entries per side
	journal: { get: (self: any, key: string) -> any, set: (self: any, key: string, value: any) -> () }?,
	sink: Events.Sink?,
	report: ((message: string) -> ())?,
}

type TradeFields = {
	id: string,
	ended: Signal.Signal,
	changed: Signal.Signal,
	_machine: Fsm.Machine,
	_parties: { [string]: Party },
	_offers: { [string]: Offer },
	_accepted: { [string]: boolean },
	_confirmed: { [string]: boolean },
	_revision: number,
	_lockedAt: number?,
	_lastActivity: number,
	_reason: string?,
	_options: Options,
	_clock: (() -> number)?,
	_currencies: { [string]: boolean },
	_report: (message: string) -> (),
}
export type Trade = typeof(setmetatable({} :: TradeFields, Trade))

local function token(value: any): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 64
		and string.match(value, "^[%w_%.:%-]+$") ~= nil
end

local function emptyOffer(): Offer
	return { instances = {}, stacks = {}, currency = {} }
end

local function validParty(party: any): boolean
	return type(party) == "table"
		and token(party.key)
		and type(party.inventory) == "table"
		and type(party.inventory.prepare) == "function"
		and (party.wallet == nil or type(party.wallet.prepare) == "function")
end

-- A trade between options.a and options.b. Raises on invalid options. Time comes from env.clock
-- unless a method is given `now`.
function Trade.new(options: Options, env: any?): Trade
	assert(type(options) == "table", "Trade.new: options must be a table")
	local problems = {}
	if not token(options.id) then
		table.insert(problems, "id must be 1-64 letters, digits or _ . : -")
	end
	for _, side in Trade.SIDES do
		if not validParty((options :: any)[side]) then
			table.insert(problems, side .. " must be { key, inventory, wallet?, policyAllows? }")
		end
	end
	if validParty(options.a) and validParty(options.b) then
		if options.a.key == options.b.key then
			table.insert(problems, "a player cannot trade with themselves")
		end
		if options.a.inventory == options.b.inventory then
			table.insert(problems, "the two parties share an inventory")
		end
	end
	if options.countdown ~= nil and not (Check.finite(options.countdown) and options.countdown >= 0) then
		table.insert(problems, "countdown must be a finite number >= 0")
	end
	if
		options.expireSeconds ~= nil
		and not (Check.finite(options.expireSeconds) and options.expireSeconds > 0)
	then
		table.insert(problems, "expireSeconds must be a finite number > 0")
	end
	if options.maxEntries ~= nil and not (Check.integer(options.maxEntries) and options.maxEntries >= 1) then
		table.insert(problems, "maxEntries must be an integer >= 1")
	end
	local currencies: { [string]: boolean } = {}
	for _, currency in options.currencies or {} do
		if not Check.label(currency) then
			table.insert(problems, "currency " .. Check.describe(currency) .. " is not a label")
		end
		currencies[currency] = true
	end
	local journal = options.journal
	if
		journal ~= nil
		and (type(journal) ~= "table" or type(journal.get) ~= "function" or type(journal.set) ~= "function")
	then
		table.insert(problems, "journal must have get and set methods")
	end
	if #problems > 0 then
		error("Trade.new: " .. table.concat(problems, "; "), 2)
	end
	local clock = env and env.clock
	local self = setmetatable({
		id = options.id,
		ended = Signal.new(env),
		changed = Signal.new(env),
		_machine = Fsm.new(Trade.SPEC, nil, env),
		_parties = { a = options.a, b = options.b },
		_offers = { a = emptyOffer(), b = emptyOffer() },
		_accepted = { a = false, b = false },
		_confirmed = { a = false, b = false },
		_revision = 0,
		_lockedAt = nil,
		_lastActivity = if clock then clock() else 0,
		_reason = nil,
		_options = options,
		_clock = clock,
		_currencies = currencies,
		_report = options.report
			or (env and type(env.report) == "function" and env.report)
			or function(_message: string) end,
	}, Trade)
	-- A trade id the journal already holds as committed is committed from the start.
	if journal then
		local ok, record = pcall(journal.get, journal, Trade.journalKey(options.id))
		if ok and type(record) == "table" and record.state == "committed" then
			self._machine:send("journal")
		end
	end
	return self
end

function Trade.journalKey(id: string): string
	return "trade:" .. id
end

local function now(self: Trade, at: number?): number
	if at ~= nil then
		return at
	end
	local clock = self._clock
	return if clock then clock() else 0
end

local function emit(self: Trade, name: string, fields: { [string]: string }?)
	local sink = self._options.sink
	if sink == nil then
		return
	end
	local event = Events.custom(name, nil, fields)
	event.event_id = self.id
	pcall(function()
		(sink :: any):emit(event)
	end)
end

function Trade.state(self: Trade): string
	return self._machine:state()
end

function Trade.revision(self: Trade): number
	return self._revision
end

-- Why the trade was cancelled (nil otherwise).
function Trade.reason(self: Trade): string?
	return self._reason
end

function Trade.serialize(self: Trade): string
	return self._machine:serialize()
end

local function isOpen(self: Trade): boolean
	local state = self._machine:state()
	return state == "proposed" or state == "locked"
end

local function finish(self: Trade, event: string, reason: string?)
	self._reason = reason
	self._machine:send(event)
	self.ended:Fire(self._machine:state(), reason)
end

-- Cancels an open or confirmed trade (reason is a label; default "cancelled").
function Trade.cancel(self: Trade, reason: string?): (boolean, string?)
	local state = self._machine:state()
	if state == "committed" or state == "cancelled" then
		return false, state
	end
	local label = if reason ~= nil and Check.label(reason) then reason else "cancelled"
	finish(self, "cancel", label)
	emit(self, "trade_cancelled", { reason = label })
	return true, nil
end

-- ---------------------------------------------------------------- offer checks

local function policyAllows(party: Party): boolean
	local policy = party.policyAllows
	if policy == true then
		return true
	end
	if type(policy) == "function" then
		local ok, allowed = pcall(policy, Trade.POLICY_FEATURE)
		return ok and allowed == true
	end
	return false
end

local function entryCount(offer: Offer): number
	local n = #offer.instances + #offer.stacks
	for _ in offer.currency do
		n += 1
	end
	return n
end

-- Whether an offer holds anything paid (item def paid or instance paid origin).
local function offerHasPaid(party: Party, offer: Offer): boolean
	local items = party.inventory:items()
	for _, uid in offer.instances do
		local entry = party.inventory:get(uid)
		local def = entry and items:get(entry.item)
		if (entry and entry.paid) or (def and def.paid) then
			return true
		end
	end
	for _, stack in offer.stacks do
		local def = items:get(stack.item)
		if stack.paid or (def and def.paid) then
			return true
		end
	end
	return false
end

-- Problems with one side's offer against its owner's current holdings (nil when fine).
local function checkOffer(self: Trade, side: string, offer: Offer): string?
	local party = self._parties[side]
	local inventory = party.inventory
	local items = inventory:items()
	local maxEntries = self._options.maxEntries
	if maxEntries and entryCount(offer) > maxEntries then
		return "too_many_entries"
	end
	-- Structure first: the same uid or the same (item, paid) stack twice is never valid.
	local seen: { [string]: boolean } = {}
	for _, uid in offer.instances do
		if seen[uid] then
			return "duplicate_entry"
		end
		seen[uid] = true
	end
	for _, stack in offer.stacks do
		local key = stack.item .. (if stack.paid then ":paid" else ":free")
		if seen[key] then
			return "duplicate_entry"
		end
		seen[key] = true
	end
	for _, uid in offer.instances do
		local entry = inventory:get(uid)
		if entry == nil then
			return "missing_item"
		end
		if inventory:isEquipped(uid) then
			return "item_equipped"
		end
		local def = items:get(entry.item)
		if def == nil or not def.tradable then
			return "untradable"
		end
	end
	for _, stack in offer.stacks do
		local def = items:get(stack.item)
		if def == nil then
			return "missing_item"
		end
		if not def.stackable then
			return "bad_offer"
		end
		if not def.tradable then
			return "untradable"
		end
		local paidFilter = stack.paid or def.paid
		if inventory:count(stack.item, paidFilter) < stack.count then
			return "missing_item"
		end
	end
	for currency, amount in offer.currency do
		if not self._currencies[currency] then
			return "currency_not_tradable"
		end
		if not (Check.integer(amount) and amount > 0) then
			return "bad_offer"
		end
		local wallet = party.wallet
		if wallet == nil then
			return "no_wallet"
		end
		if not wallet:canTransact({ { currency = currency, delta = -amount, reason = "trade" } }) then
			return "insufficient_funds"
		end
	end
	return nil
end

-- Policy over both offers: anything paid needs both players' trading policy.
local function checkPolicy(self: Trade): string?
	local a, b = self._parties.a, self._parties.b
	if offerHasPaid(a, self._offers.a) or offerHasPaid(b, self._offers.b) then
		if not (policyAllows(a) and policyAllows(b)) then
			return "policy_denied"
		end
	end
	return nil
end

-- Normalises an offer table: { instances?, stacks?, currency? } -> Offer, or nil and a reason.
local function normalize(raw: any): (Offer?, string?)
	if type(raw) ~= "table" then
		return nil, "bad_offer"
	end
	local offer = emptyOffer()
	for _, uid in raw.instances or {} do
		if not token(uid) then
			return nil, "bad_offer"
		end
		table.insert(offer.instances, uid)
	end
	for _, stack in raw.stacks or {} do
		if
			type(stack) ~= "table"
			or not Check.label(stack.item)
			or not (Check.integer(stack.count) and stack.count >= 1)
			or (stack.paid ~= nil and type(stack.paid) ~= "boolean")
		then
			return nil, "bad_offer"
		end
		table.insert(offer.stacks, { item = stack.item, count = stack.count, paid = stack.paid == true })
	end
	for currency, amount in raw.currency or {} do
		if not Check.label(currency) or not (Check.integer(amount) and amount >= 0) then
			return nil, "bad_offer"
		end
		if amount > 0 then
			offer.currency[currency] = amount
		end
	end
	return offer, nil
end

local function side_(side: any): boolean
	return side == "a" or side == "b"
end

-- Replaces one side's offer. Any accepted change clears both accepts and confirmations and
-- bumps the revision. Returns (ok, reason).
function Trade.setOffer(self: Trade, side: string, raw: any, at: number?): (boolean, string?)
	if not side_(side) then
		return false, "bad_side"
	end
	if not isOpen(self) then
		return false, self._machine:state()
	end
	local offer, err = normalize(raw)
	if offer == nil then
		return false, err
	end
	local problem = checkOffer(self, side, offer)
	if problem then
		return false, problem
	end
	local previous = self._offers[side]
	self._offers[side] = offer
	local policyProblem = checkPolicy(self)
	if policyProblem then
		self._offers[side] = previous
		return false, policyProblem
	end
	self._revision += 1
	self._accepted = { a = false, b = false }
	self._confirmed = { a = false, b = false }
	self._lockedAt = nil
	self._lastActivity = now(self, at)
	self._machine:send("change")
	self.changed:Fire(self._revision)
	return true, nil
end

-- A copy of one side's offer.
function Trade.offer(self: Trade, side: string): Offer
	return Check.copy(self._offers[side])
end

-- Adds an instance (by uid) to a side's offer.
function Trade.addInstance(self: Trade, side: string, uid: string, at: number?): (boolean, string?)
	if not side_(side) then
		return false, "bad_side"
	end
	local offer = Check.copy(self._offers[side])
	table.insert(offer.instances, uid)
	return self:setOffer(side, offer, at)
end

-- Adds count copies of a stackable item (paid = true offers paid-origin copies).
function Trade.addStack(
	self: Trade,
	side: string,
	item: string,
	count: number,
	paid: boolean?,
	at: number?
): (boolean, string?)
	if not side_(side) then
		return false, "bad_side"
	end
	local offer = Check.copy(self._offers[side])
	local merged = false
	for _, stack in offer.stacks do
		if stack.item == item and stack.paid == (paid == true) then
			stack.count += count
			merged = true
		end
	end
	if not merged then
		table.insert(offer.stacks, { item = item, count = count, paid = paid == true })
	end
	return self:setOffer(side, offer, at)
end

-- Sets the amount of a currency in a side's offer (0 removes it).
function Trade.setCurrency(
	self: Trade,
	side: string,
	currency: string,
	amount: number,
	at: number?
): (boolean, string?)
	if not side_(side) then
		return false, "bad_side"
	end
	local offer = Check.copy(self._offers[side])
	offer.currency[currency] = amount
	return self:setOffer(side, offer, at)
end

-- Removes an instance from a side's offer.
function Trade.removeInstance(self: Trade, side: string, uid: string, at: number?): (boolean, string?)
	if not side_(side) then
		return false, "bad_side"
	end
	local offer = Check.copy(self._offers[side])
	local index = table.find(offer.instances, uid)
	if index == nil then
		return false, "not_offered"
	end
	table.remove(offer.instances, index)
	return self:setOffer(side, offer, at)
end

-- ---------------------------------------------------------------- commit helpers

type Step = { participant: any, tx: any, kind: string }

-- Inventory ops for one side: give its offer, receive the other side's.
local function inventoryOps(self: Trade, side: string, other: string): { any }?
	local giver = self._parties[side].inventory
	local receiverOffer = self._offers[other]
	local otherInventory = self._parties[other].inventory
	local ops = {}
	for _, uid in self._offers[side].instances do
		table.insert(ops, { op = "remove", uid = uid })
	end
	local items = giver:items()
	for _, stack in self._offers[side].stacks do
		local def = items:get(stack.item)
		table.insert(
			ops,
			{ op = "remove", item = stack.item, count = stack.count, paid = stack.paid or (def and def.paid) }
		)
	end
	for _, uid in receiverOffer.instances do
		local entry = otherInventory:get(uid)
		if entry == nil then
			return nil
		end
		table.insert(ops, {
			op = "add",
			instance = { uid = entry.uid, item = entry.item, data = entry.data, paid = entry.paid },
		})
	end
	for _, stack in receiverOffer.stacks do
		table.insert(ops, { op = "add", item = stack.item, count = stack.count, paid = stack.paid })
	end
	return ops
end

local function walletChanges(self: Trade, side: string, other: string): { any }
	local changes = {}
	local mine, theirs = self._offers[side].currency, self._offers[other].currency
	local keys = {}
	for currency in mine do
		table.insert(keys, currency)
	end
	for currency in theirs do
		if mine[currency] == nil then
			table.insert(keys, currency)
		end
	end
	table.sort(keys)
	for _, currency in keys do
		local delta = (theirs[currency] or 0) - (mine[currency] or 0)
		if delta ~= 0 then
			table.insert(changes, { currency = currency, delta = delta, reason = "trade" })
		end
	end
	return changes
end

-- Phase 1 of the commit: checks policy and holdings, then prepares every participant (both
-- inventories, both wallets) without applying anything. (steps) or (nil, reason).
local function prepareAll(self: Trade): ({ Step }?, string?)
	local policyProblem = checkPolicy(self)
	if policyProblem then
		return nil, policyProblem
	end
	local steps: { Step } = {}
	for _, pair in { { "a", "b" }, { "b", "a" } } do
		local side, other = pair[1], pair[2]
		if checkOffer(self, side, self._offers[side]) then
			return nil, "offer_unavailable"
		end
		local ops = inventoryOps(self, side, other)
		if ops == nil then
			return nil, "offer_unavailable"
		end
		if #ops > 0 then
			local inventory = self._parties[side].inventory
			local tx, err = inventory:prepare(ops)
			if tx == nil then
				return nil,
					(if err == "no_space"
							or err == "over_weight"
							or err == "unique_item"
						then err
						else "prepare_failed") .. "_" .. side
			end
			table.insert(steps, { participant = inventory, tx = tx, kind = "inventory_" .. side })
		end
	end
	for _, pair in { { "a", "b" }, { "b", "a" } } do
		local side, other = pair[1], pair[2]
		local changes = walletChanges(self, side, other)
		if #changes > 0 then
			local wallet = self._parties[side].wallet
			if wallet == nil then
				return nil, "no_wallet_" .. side
			end
			local tx, err = wallet:prepare(changes, { txId = self.id .. ":" .. side })
			if tx == nil then
				return nil,
					(if err == "at_cap" or err == "insufficient_funds" then err else "prepare_failed")
						.. "_"
						.. side
			end
			table.insert(steps, { participant = wallet, tx = tx, kind = "wallet_" .. side })
		end
	end
	return steps, nil
end

-- ---------------------------------------------------------------- accept, confirm, tick

-- Accepts the offers as of revision (what the player saw). Both accepts lock the trade and
-- start the countdown. Returns (ok, reason) with stale_offer, bad_side or a state name.
function Trade.accept(self: Trade, side: string, revision: number, at: number?): (boolean, string?)
	if not side_(side) then
		return false, "bad_side"
	end
	if self._machine:state() ~= "proposed" then
		return false, self._machine:state()
	end
	if revision ~= self._revision then
		return false, "stale_offer"
	end
	local time = now(self, at)
	self._accepted[side] = true
	self._lastActivity = time
	if self._accepted.a and self._accepted.b then
		-- Dry-run phase 1 so a trade that cannot commit (no space, funds gone) never locks.
		local steps, problem = prepareAll(self)
		if steps == nil then
			self._accepted = { a = false, b = false }
			return false, problem
		end
		self._lockedAt = time
		self._machine:send("lock")
		self.changed:Fire(self._revision)
	end
	return true, nil
end

-- Withdraws a side's accept (a locked trade returns to proposed; confirmations clear).
function Trade.unaccept(self: Trade, side: string, at: number?): (boolean, string?)
	if not side_(side) then
		return false, "bad_side"
	end
	if not isOpen(self) then
		return false, self._machine:state()
	end
	self._accepted[side] = false
	self._confirmed = { a = false, b = false }
	self._lastActivity = now(self, at)
	if self._machine:state() == "locked" then
		self._lockedAt = nil
		self._machine:send("unlock")
	end
	self.changed:Fire(self._revision)
	return true, nil
end

-- Seconds left on the confirm countdown (0 when open; nil when not locked).
function Trade.countdownLeft(self: Trade, at: number?): number?
	if self._machine:state() ~= "locked" or self._lockedAt == nil then
		return nil
	end
	local countdown = self._options.countdown or Trade.DEFAULT_COUNTDOWN
	return math.max((self._lockedAt :: number) + countdown - now(self, at), 0)
end

local function reachConfirmed(self: Trade): (boolean, string?)
	self._machine:send("confirm")
	self.changed:Fire(self._revision)
	if self._options.autoCommit ~= false then
		return self:commit()
	end
	return true, nil
end

-- Confirms for a side after the countdown. Both confirmations reach confirmed (and commit,
-- unless autoCommit = false). Returns (ok, reason) with countdown, bad_side or a state name.
function Trade.confirm(self: Trade, side: string, at: number?): (boolean, string?)
	if not side_(side) then
		return false, "bad_side"
	end
	if self._machine:state() ~= "locked" then
		return false, self._machine:state()
	end
	local left = self:countdownLeft(at) :: number
	if left > 0 then
		return false, "countdown"
	end
	self._confirmed[side] = true
	self._lastActivity = now(self, at)
	if self._confirmed.a and self._confirmed.b then
		return reachConfirmed(self)
	end
	return true, nil
end

-- Step function (never yields): expires idle trades and, with autoConfirm, confirms a locked
-- trade once its countdown has run. Returns the state.
function Trade.tick(self: Trade, at: number?): string
	local time = now(self, at)
	local expire = self._options.expireSeconds
	if expire and isOpen(self) and time - self._lastActivity >= expire then
		self:cancel("expired")
		return self._machine:state()
	end
	if
		self._options.autoConfirm
		and self._machine:state() == "locked"
		and (self:countdownLeft(time) :: number) <= 0
	then
		self._confirmed = { a = true, b = true }
		reachConfirmed(self)
	end
	return self._machine:state()
end

-- ---------------------------------------------------------------- commit

local function rollbackAll(self: Trade, done: { Step })
	for index = #done, 1, -1 do
		local step = done[index]
		local ok, err = step.participant:rollback(step.tx)
		if not ok then
			self._report(
				string.format(
					"Trade %s: rollback of %s failed (%s); manual repair needed",
					self.id,
					step.kind,
					tostring(err)
				)
			)
		end
	end
end

-- Commits a confirmed trade atomically (see the header). Returns (true, nil),
-- (true, "already_committed") for a trade or journal entry that already committed, or
-- (false, reason) after cancelling with that reason (prepare_failed ones name the side).
function Trade.commit(self: Trade): (boolean, string?)
	local state = self._machine:state()
	if state == "committed" then
		return true, "already_committed"
	end
	local journal = self._options.journal
	local key = Trade.journalKey(self.id)
	if journal then
		local ok, record = pcall(journal.get, journal, key)
		if not ok then
			return false, "journal_unavailable"
		end
		if type(record) == "table" and record.state == "committed" then
			finish(self, "journal", nil)
			return true, "already_committed"
		end
	end
	if state ~= "confirmed" then
		return false, if state == "cancelled" then "cancelled" else "not_confirmed"
	end
	-- Phase 1: prepare every participant against current state.
	local steps, reason = prepareAll(self)
	if steps == nil then
		self:cancel(reason)
		return false, reason
	end
	-- Phase 2: commit in order; undo on the first failure.
	local done: { Step } = {}
	for _, step in steps do
		local ok, err
		if string.sub(step.kind, 1, 6) == "wallet" then
			ok, err = step.participant:commit(step.tx, { emit = false })
		else
			ok, err = step.participant:commit(step.tx)
		end
		if not ok then
			self._report(
				string.format(
					"Trade %s: %s commit failed (%s); rolling back",
					self.id,
					step.kind,
					tostring(err)
				)
			)
			rollbackAll(self, done)
			self:cancel("commit_failed")
			return false, "commit_failed"
		end
		table.insert(done, step)
	end
	if journal then
		local ok, err = pcall(journal.set, journal, key, { state = "committed", revision = self._revision })
		if not ok then
			self._report(
				string.format("Trade %s: journal write failed (%s); rolling back", self.id, tostring(err))
			)
			rollbackAll(self, done)
			self:cancel("journal_failed")
			return false, "journal_failed"
		end
	end
	for _, step in done do
		if string.sub(step.kind, 1, 6) == "wallet" then
			step.participant:emit(step.tx)
		end
	end
	finish(self, "commit", nil)
	emit(self, "trade_committed", nil)
	return true, nil
end

-- A plain view for UI replication: state, revision, offers, accepts, confirmations, countdown.
function Trade.view(self: Trade, at: number?): any
	return {
		id = self.id,
		state = self._machine:state(),
		revision = self._revision,
		offers = { a = Check.copy(self._offers.a), b = Check.copy(self._offers.b) },
		accepted = table.clone(self._accepted),
		confirmed = table.clone(self._confirmed),
		countdown = self:countdownLeft(at),
		reason = self._reason,
	}
end

-- ---------------------------------------------------------------- book

-- A per-server book that allows one open trade per player: book:open(options, env) ->
-- (trade?, reason "party_busy"); a trade leaves the book when it commits or cancels.
function Trade.book(): any
	local book = { _byKey = {} :: { [string]: any } }
	function book.open(self: any, options: Options, env: any?): (Trade?, string?)
		for _, side in Trade.SIDES do
			local party = (options :: any)[side]
			if type(party) == "table" and self._byKey[party.key] then
				return nil, "party_busy"
			end
		end
		local trade = Trade.new(options, env)
		if trade:state() == "committed" then
			return trade, "already_committed"
		end
		self._byKey[options.a.key] = trade
		self._byKey[options.b.key] = trade
		trade.ended:Connect(function()
			if self._byKey[options.a.key] == trade then
				self._byKey[options.a.key] = nil
			end
			if self._byKey[options.b.key] == trade then
				self._byKey[options.b.key] = nil
			end
		end)
		return trade, nil
	end
	function book.active(self: any, key: string): Trade?
		return self._byKey[key]
	end
	return book
end

return Trade
