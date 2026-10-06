--!strict
-- @tier T0
-- Wallet: one player's integer currency balances. Every change is a whole number checked
-- against the currency's cap, floor and the 2^53 exact-integer limit, and emits one kit-event/1
-- economy event (source on credit, sink on debit) to an injected sink after the in-memory state
-- and the optional key store are written. Multi-currency changes are atomic through
-- transact(changes), and other kits (Trade, Crafting, UnlockGraph) join them into larger
-- atomic units through the two-phase prepare / commit / rollback calls. A transaction id
-- (opts.txId) makes a retried credit or debit a no-op: recent ids are kept (ledgerSize) and
-- persisted with the balances. No currency, cap or amount ships here: the game supplies them.
local Check = require("./Check")
local Events = require("./Events")
local Signal = require("./Signal")

local Wallet = {}
Wallet.__index = Wallet
Wallet.SCHEMA = "wallet/1"
Wallet.MAX = Check.MAX_SAFE_INTEGER
-- Recent transaction ids remembered for retry de-duplication (convention, not a Roblox limit).
Wallet.DEFAULT_LEDGER_SIZE = 128
Wallet.ERRORS = table.freeze({
	"unknown_currency",
	"invalid_amount",
	"invalid_reason",
	"invalid_tx",
	"insufficient_funds",
	"at_cap",
	"overflow",
	"stale",
	"store_failed",
	"not_committed",
})

export type CurrencyConfig = {
	cap: number?, -- integer maximum balance (default 2^53)
	allowNegative: boolean?, -- default false: debits never go below 0
	floor: number?, -- integer minimum when allowNegative (default -2^53)
	overflow: ("reject" | "clamp")?, -- a credit past the cap: reject (default) or credit what fits
	report: boolean?, -- emit kit-event/1 economy events for this currency (default true)
	initial: number?, -- balance of a new wallet (default 0)
}
export type Store = { get: (self: any, key: string) -> any, set: (self: any, key: string, value: any) -> () }
export type Options = {
	currencies: { [string]: CurrencyConfig },
	sink: Events.Sink?,
	telemetry: Events.Sink?, -- alias of sink (the group plan's name)
	player: string?, -- envelope player key (opaque, never a user name)
	store: Store?,
	storeKey: string?, -- default "wallet"
	data: any?, -- serialized wallet/1 data to start from (ignored when store holds data)
	ledgerSize: number?,
	report: ((message: string) -> ())?,
}
export type Change = { currency: string, delta: number, reason: string, sku: string? }
export type TxOptions = { txId: string?, sku: string?, fields: { [string]: string }? }
export type Tx = {
	wallet: any,
	version: number,
	before: { [string]: number },
	after: { [string]: number },
	changes: { Change },
	applied: { [number]: number },
	txId: string?,
	fields: { [string]: string }?,
	sku: string?,
	state: "prepared" | "committed" | "rolled_back",
	emitted: boolean,
}

local function token(value: any): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 64
		and string.match(value, "^[%w_%.:%-]+$") ~= nil
end

local function validReason(value: any): boolean
	return table.find(Events.TRANSACTION_TYPES, value) ~= nil or Check.label(value)
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- Problems with a currencies table (empty when valid).
function Wallet.validateCurrencies(currencies: any): { string }
	if type(currencies) ~= "table" or next(currencies) == nil then
		return { "currencies must be a non-empty map of label -> config" }
	end
	local problems = {}
	local reported = 0
	for _, id in sortedKeys(currencies) do
		local config = currencies[id]
		if not Check.label(id) then
			table.insert(problems, string.format("currency %s is not a label", Check.describe(id)))
			continue
		end
		if type(config) ~= "table" then
			table.insert(problems, id .. ": config must be a table")
			continue
		end
		local function bounded(key: string, value: any, low: number, high: number)
			if value ~= nil and not (Check.integer(value) and value >= low and value <= high) then
				table.insert(
					problems,
					string.format("%s: %s must be an integer from %d to %d", id, key, low, high)
				)
			end
		end
		bounded("cap", config.cap, 0, Wallet.MAX)
		bounded("floor", config.floor, -Wallet.MAX, 0)
		if config.allowNegative ~= nil and type(config.allowNegative) ~= "boolean" then
			table.insert(problems, id .. ": allowNegative must be a boolean")
		end
		if config.floor ~= nil and config.allowNegative ~= true then
			table.insert(problems, id .. ": floor needs allowNegative = true")
		end
		if config.overflow ~= nil and config.overflow ~= "reject" and config.overflow ~= "clamp" then
			table.insert(problems, id .. ": overflow must be reject or clamp")
		end
		if config.report ~= nil and type(config.report) ~= "boolean" then
			table.insert(problems, id .. ": report must be a boolean")
		end
		local low = if config.allowNegative then (config.floor or -Wallet.MAX) else 0
		local high = config.cap or Wallet.MAX
		bounded("initial", config.initial, low, high)
		if config.report ~= false then
			reported += 1
		end
		for key in config do
			if not table.find({ "cap", "allowNegative", "floor", "overflow", "report", "initial" }, key) then
				table.insert(problems, string.format("%s: unknown key %s", id, Check.describe(key)))
			end
		end
	end
	if reported > Events.LIMITS.currencies then
		table.insert(
			problems,
			string.format(
				"%d currencies report economy events; AnalyticsService tracks at most %d (set report = false on the rest)",
				reported,
				Events.LIMITS.currencies
			)
		)
	end
	return problems
end

type WalletFields = {
	changed: Signal.Signal,
	_currencies: { [string]: CurrencyConfig },
	_balances: { [string]: number },
	_preserved: { [string]: number },
	_recent: { string },
	_recentSet: { [string]: boolean },
	_ledgerSize: number,
	_sink: Events.Sink?,
	_player: string?,
	_store: Store?,
	_storeKey: string,
	_report: (message: string) -> (),
	_version: number,
	notes: { string },
}
export type Wallet = typeof(setmetatable({} :: WalletFields, Wallet))

-- Reads serialized wallet/1 data into balances. Bad values never destroy value silently:
-- unknown currencies are preserved (serialized back, not spendable) and every repair is noted.
local function decode(self: Wallet, data: any)
	if data == nil then
		return
	end
	if type(data) ~= "table" or data.schema ~= Wallet.SCHEMA or type(data.balances) ~= "table" then
		table.insert(self.notes, "stored data is not wallet/1; starting from initial balances")
		return
	end
	for id, value in data.balances do
		local config = self._currencies[id]
		if config == nil then
			if type(id) == "string" and Check.integer(value) then
				self._preserved[id] = value
				table.insert(self.notes, string.format("unknown currency %s preserved, not spendable", id))
			else
				table.insert(
					self.notes,
					string.format("dropped invalid balance entry %s", Check.describe(id))
				)
			end
			continue
		end
		if not Check.finite(value) then
			table.insert(self.notes, string.format("%s: non-finite balance reset to 0", id))
			self._balances[id] = 0
		elseif value % 1 ~= 0 or math.abs(value) > Wallet.MAX then
			local repaired = math.clamp(math.floor(value), -Wallet.MAX, Wallet.MAX)
			table.insert(
				self.notes,
				string.format("%s: balance %s repaired to %d", id, tostring(value), repaired)
			)
			self._balances[id] = repaired
		else
			self._balances[id] = value
		end
		local cap = config.cap or Wallet.MAX
		if self._balances[id] > cap then
			table.insert(
				self.notes,
				string.format("%s: balance above cap kept; credits refused until below", id)
			)
		end
		local floor = if config.allowNegative then (config.floor or -Wallet.MAX) else 0
		if self._balances[id] < floor then
			table.insert(self.notes, string.format("%s: balance below floor kept; debits refused", id))
		end
	end
	if type(data.recent) == "table" then
		for _, id in data.recent do
			if token(id) and not self._recentSet[id] then
				table.insert(self._recent, id)
				self._recentSet[id] = true
			end
		end
		while #self._recent > self._ledgerSize do
			self._recentSet[table.remove(self._recent, 1) :: string] = nil
		end
	end
end

-- A wallet for one player. Raises when the options are invalid. Starting state comes from
-- store:get(storeKey) when a store holds data, else options.data, else each currency's initial.
-- wallet.notes lists repairs made while loading. wallet.changed fires (currency, balance, delta)
-- after every committed change.
function Wallet.new(options: Options, env: any?): Wallet
	assert(type(options) == "table", "Wallet.new: options must be a table")
	local problems = Wallet.validateCurrencies(options.currencies)
	if options.player ~= nil and not token(options.player) then
		table.insert(problems, "player must be 1-64 letters, digits or _ . : -")
	end
	if options.ledgerSize ~= nil and not (Check.integer(options.ledgerSize) and options.ledgerSize >= 0) then
		table.insert(problems, "ledgerSize must be an integer >= 0")
	end
	local sink = options.sink or options.telemetry
	if sink ~= nil and (type(sink) ~= "table" or type((sink :: any).emit) ~= "function") then
		table.insert(problems, "sink must have an emit method")
	end
	local store = options.store
	if
		store ~= nil
		and (type(store) ~= "table" or type(store.get) ~= "function" or type(store.set) ~= "function")
	then
		table.insert(problems, "store must have get and set methods")
	end
	if #problems > 0 then
		error("Wallet.new: " .. table.concat(problems, "; "), 2)
	end
	local reportFn = options.report
		or (env and type(env.report) == "function" and env.report)
		or function(_message: string) end
	local self = setmetatable({
		changed = Signal.new(env),
		_currencies = Check.freeze(Check.copy(options.currencies)),
		_balances = {},
		_preserved = {},
		_recent = {},
		_recentSet = {},
		_ledgerSize = options.ledgerSize or Wallet.DEFAULT_LEDGER_SIZE,
		_sink = sink,
		_player = options.player,
		_store = store,
		_storeKey = options.storeKey or "wallet",
		_report = reportFn,
		_version = 0,
		notes = {},
	}, Wallet)
	for id, config in options.currencies do
		self._balances[id] = config.initial or 0
	end
	local data = options.data
	if store then
		local ok, stored = pcall(store.get, store, self._storeKey)
		if not ok then
			error("Wallet.new: store:get failed: " .. tostring(stored), 2)
		end
		if stored ~= nil then
			data = stored
		end
	end
	decode(self, data)
	return self
end

-- Whole balance of a currency (0 for an unknown one; check has() for existence).
function Wallet.balance(self: Wallet, currency: string): number
	return self._balances[currency] or 0
end

function Wallet.has(self: Wallet, currency: string): boolean
	return self._currencies[currency] ~= nil
end

-- A copy of every spendable balance.
function Wallet.balances(self: Wallet): { [string]: number }
	return table.clone(self._balances)
end

-- Whether a transaction id was already committed (within the remembered window).
function Wallet.seen(self: Wallet, txId: string): boolean
	return self._recentSet[txId] == true
end

function Wallet.version(self: Wallet): number
	return self._version
end

-- New balance for one change, or nil and an error label. Clamped credits report what fits.
local function step(self: Wallet, balances: { [string]: number }, change: any): (number?, string?, number?)
	if type(change) ~= "table" then
		return nil, "invalid_amount", nil
	end
	local config = self._currencies[change.currency]
	if config == nil then
		return nil, "unknown_currency", nil
	end
	local delta = change.delta
	if not (Check.integer(delta) and delta ~= 0) then
		return nil, "invalid_amount", nil
	end
	if not validReason(change.reason) then
		return nil, "invalid_reason", nil
	end
	if change.sku ~= nil and not token(change.sku) then
		return nil, "invalid_reason", nil
	end
	local current = balances[change.currency]
	local cap = config.cap or Wallet.MAX
	local floor = if config.allowNegative then (config.floor or -Wallet.MAX) else 0
	if delta > 0 then
		local room = cap - current
		if room <= 0 then
			return nil, "at_cap", nil
		end
		if delta > room then
			if config.overflow == "clamp" then
				return cap, nil, room
			end
			return nil, if cap == Wallet.MAX then "overflow" else "at_cap", nil
		end
		return current + delta, nil, delta
	end
	local next_ = current + delta
	if next_ < floor then
		return nil, "insufficient_funds", nil
	end
	return next_, nil, delta
end

-- Prepares an atomic change of one or more currencies without applying it. changes is a list
-- of { currency, delta (non-zero integer), reason (transaction type), sku? }. Returns a tx for
-- commit/rollback, or nil and an error label. A txId already seen gives (nil, "duplicate").
function Wallet.prepare(self: Wallet, changes: { Change }, opts: TxOptions?): (Tx?, string?)
	if type(changes) ~= "table" or #changes == 0 then
		return nil, "invalid_amount"
	end
	local txId = opts and opts.txId
	if txId ~= nil then
		if not token(txId) then
			return nil, "invalid_tx"
		end
		if self._recentSet[txId] then
			return nil, "duplicate"
		end
	end
	local balances = table.clone(self._balances)
	local applied = {}
	for index, change in changes do
		local value, err, delta = step(self, balances, change)
		if value == nil then
			return nil, err
		end
		balances[change.currency] = value :: number
		applied[index] = delta :: number
	end
	return {
		wallet = self,
		version = self._version,
		before = table.clone(self._balances),
		after = balances,
		changes = Check.copy(changes),
		applied = applied,
		txId = txId,
		fields = opts and opts.fields and table.clone(opts.fields :: any),
		sku = opts and opts.sku,
		state = "prepared",
		emitted = false,
	} :: any,
		nil
end

local function remember(self: Wallet, txId: string?)
	if txId == nil or self._ledgerSize == 0 then
		return
	end
	table.insert(self._recent, txId)
	self._recentSet[txId] = true
	while #self._recent > self._ledgerSize do
		self._recentSet[table.remove(self._recent, 1) :: string] = nil
	end
end

local function forget(self: Wallet, txId: string?)
	if txId == nil or not self._recentSet[txId] then
		return
	end
	self._recentSet[txId] = nil
	local index = table.find(self._recent, txId)
	if index then
		table.remove(self._recent, index)
	end
end

local function persist(self: Wallet): boolean
	local store = self._store
	if store == nil then
		return true
	end
	local ok: boolean, err: any = pcall(store.set, store, self._storeKey, self:serialize())
	if not ok then
		self._report("Wallet: store:set failed: " .. tostring(err))
	end
	return ok
end

local function emitChange(self: Wallet, tx: Tx, index: number, compensate: boolean)
	local change = tx.changes[index]
	local config = self._currencies[change.currency]
	local sink = self._sink
	if sink == nil or config.report == false then
		return
	end
	local delta = tx.applied[index]
	if compensate then
		delta = -delta
	end
	local balance = if compensate then tx.before[change.currency] else nil
	if balance == nil then
		-- Ending balance after this change, replaying the tx in order.
		local running = tx.before[change.currency]
		for i = 1, index do
			if tx.changes[i].currency == change.currency then
				running += tx.applied[i]
			end
		end
		balance = running
	end
	local fields: { [string]: string }? = tx.fields and table.clone(tx.fields :: any)
	if (balance :: number) < 0 then
		fields = fields or {}
		local count = 0
		for _ in fields :: any do
			count += 1
		end
		if count < Events.LIMITS.fields then
			(fields :: any).balance_sign = "negative"
		end
	end
	local event = Events.economy(if delta > 0 then "wallet_credit" else "wallet_debit", {
		flow = if delta > 0 then "source" else "sink",
		currency = change.currency,
		amount = math.abs(delta),
		balance = math.max(balance :: number, 0),
		transaction_type = if compensate then "rollback" else change.reason,
		sku = change.sku or tx.sku,
	}, fields)
	if self._player then
		event.player = self._player
	end
	local ok, err = pcall(function()
		local accepted, reason = (sink :: any):emit(event)
		if accepted == false then
			self._report("Wallet: sink rejected an event: " .. tostring(reason))
		end
	end)
	if not ok then
		self._report("Wallet: sink error: " .. tostring(err))
	end
end

-- Emits the economy events of a committed tx (once). commit() does this unless told not to.
function Wallet.emit(self: Wallet, tx: Tx)
	if tx.wallet ~= self or tx.state ~= "committed" or tx.emitted then
		return
	end
	tx.emitted = true
	for index in tx.changes do
		emitChange(self, tx, index, false)
	end
end

-- Applies a prepared tx. Fails with "stale" when the wallet changed since prepare, or
-- "store_failed" (state restored) when the store write raised. opts.emit = false defers the
-- events until emit(tx), so a larger unit (a trade) reports only after all parts committed.
function Wallet.commit(self: Wallet, tx: Tx, opts: { emit: boolean? }?): (boolean, string?)
	if type(tx) ~= "table" or tx.wallet ~= self or tx.state ~= "prepared" then
		return false, "invalid_tx"
	end
	if tx.version ~= self._version then
		return false, "stale"
	end
	if tx.txId and self._recentSet[tx.txId] then
		return false, "duplicate"
	end
	local previous = self._balances
	self._balances = table.clone(tx.after)
	remember(self, tx.txId)
	if not persist(self) then
		self._balances = previous
		forget(self, tx.txId)
		return false, "store_failed"
	end
	self._version += 1
	tx.state = "committed"
	for index, change in tx.changes do
		self.changed:Fire(change.currency, self._balances[change.currency], tx.applied[index])
	end
	if not (opts and opts.emit == false) then
		self:emit(tx)
	end
	return true, nil
end

-- Undoes a committed tx when nothing else changed the wallet since (else "stale"). Events
-- already emitted get compensating events with transaction_type "rollback".
function Wallet.rollback(self: Wallet, tx: Tx): (boolean, string?)
	if type(tx) ~= "table" or tx.wallet ~= self then
		return false, "invalid_tx"
	end
	if tx.state ~= "committed" then
		return false, "not_committed"
	end
	if self._version ~= tx.version + 1 then
		return false, "stale"
	end
	local previous = self._balances
	self._balances = table.clone(tx.before)
	forget(self, tx.txId)
	if not persist(self) then
		self._balances = previous
		remember(self, tx.txId)
		return false, "store_failed"
	end
	self._version += 1
	tx.state = "rolled_back"
	for index, change in tx.changes do
		self.changed:Fire(change.currency, self._balances[change.currency], -tx.applied[index])
	end
	if tx.emitted then
		for index = #tx.changes, 1, -1 do
			emitChange(self, tx, index, true)
		end
	end
	return true, nil
end

-- Atomic multi-currency change: all changes apply or none. Returns (true, nil, applied) where
-- applied[i] is the delta actually applied (a clamped credit applies what fits), or
-- (true, "duplicate") for a txId already committed, or (false, error).
function Wallet.transact(self: Wallet, changes: { Change }, opts: TxOptions?): (boolean, string?, { number }?)
	local tx, err = self:prepare(changes, opts)
	if tx == nil then
		if err == "duplicate" then
			return true, "duplicate", nil
		end
		return false, err, nil
	end
	local ok, commitErr = self:commit(tx)
	if not ok then
		return false, commitErr, nil
	end
	return true, nil, tx.applied
end

-- Whether transact(changes) would succeed now.
function Wallet.canTransact(self: Wallet, changes: { Change }, opts: TxOptions?): (boolean, string?)
	local tx, err = self:prepare(changes, opts)
	return tx ~= nil, err
end

-- Adds amount (integer > 0) from source (a standard transaction type or a label).
-- Returns (ok, err, applied).
function Wallet.credit(
	self: Wallet,
	currency: string,
	amount: number,
	source: string,
	opts: TxOptions?
): (boolean, string?, number?)
	if not (Check.integer(amount) and amount > 0) then
		return false, "invalid_amount", nil
	end
	local ok, err, applied = self:transact({ { currency = currency, delta = amount, reason = source } }, opts)
	return ok, err, applied and applied[1]
end

-- Removes amount (integer > 0) into sink (a standard transaction type or a label).
function Wallet.debit(
	self: Wallet,
	currency: string,
	amount: number,
	sinkReason: string,
	opts: TxOptions?
): (boolean, string?, number?)
	if not (Check.integer(amount) and amount > 0) then
		return false, "invalid_amount", nil
	end
	local ok, err, applied =
		self:transact({ { currency = currency, delta = -amount, reason = sinkReason } }, opts)
	return ok, err, applied and applied[1] and -applied[1]
end

-- Whether every cost in costs ({ [currency] = amount }) can be paid at once.
function Wallet.canAfford(self: Wallet, costs: { [string]: number }): boolean
	local changes = {}
	for _, currency in sortedKeys(costs) do
		table.insert(changes, { currency = currency, delta = -costs[currency], reason = "Shop" })
	end
	if #changes == 0 then
		return true
	end
	return (self:canTransact(changes))
end

-- Plain wallet/1 data for a key store (balances, preserved unknown currencies, recent tx ids).
function Wallet.serialize(self: Wallet): any
	local balances = table.clone(self._preserved)
	for id, value in self._balances do
		balances[id] = value
	end
	return { schema = Wallet.SCHEMA, balances = balances, recent = table.clone(self._recent) }
end

return Wallet
