--!strict
-- @tier T0
-- Inventory: one player's items over an ItemDefs registry. Stackable items live in stacks of
-- at most maxStack; non-stackable items are instances with a uid ("<owner>-<n>", unique across
-- players so trades never collide) and optional plain data. Capacity counts entries (a stack
-- or an instance each), maxWeight is optional, equip slots hold instance uids. equipSlots is a
-- list of slot names (a slot takes items whose def.slot is that name) or a map slot -> kind for
-- several slots of one kind, e.g. { follower_1 = "follower", follower_2 = "follower" }.
-- Changes are ops applied atomically by apply(ops): every op succeeds or the inventory is
-- untouched. prepare / commit / rollback expose the same transaction in two phases so Trade
-- and Crafting can join inventories and wallets into one atomic unit. Ops:
--   { op = "add", item, count?, data?, paid? }         new copies (uids made for instances)
--   { op = "add", instance = { uid, item, data?, paid? } }  an existing instance (trades)
--   { op = "remove", item, count?, paid? }             copies, newest first, never equipped
--   { op = "remove", uid }                             one instance (not while equipped)
--   { op = "move", from, to }                          reorder entries (UI order)
--   { op = "equip", uid, slot }  { op = "unequip", slot }
--   { op = "set_data", uid, data }                     replace an instance's data
-- State persists through an injected key store (store:set after every commit, rolled back when
-- the write raises). Loading never destroys value: entries for retired item ids, broken entries
-- and duplicate uids go to a quarantine that serializes back, and each repair is noted.
local Check = require("./Check")
local ItemDefs = require("./ItemDefs")
local Signal = require("./Signal")

local Inventory = {}
Inventory.__index = Inventory
Inventory.SCHEMA = "inventory/1"
Inventory.OWNER_MAX = 48
-- Nesting allowed in instance data (convention: keeps saves small and shallow).
Inventory.DATA_DEPTH = 4
Inventory.ERRORS = table.freeze({
	"bad_op",
	"unknown_item",
	"invalid_count",
	"invalid_data",
	"no_space",
	"insufficient_items",
	"missing_uid",
	"duplicate_uid",
	"item_equipped",
	"not_equippable",
	"unknown_slot",
	"wrong_slot",
	"over_weight",
	"unique_item",
	"stale",
	"store_failed",
	"invalid_tx",
	"not_committed",
})

export type Entry = {
	item: string,
	count: number,
	uid: string?,
	data: { [string]: any }?,
	paid: boolean?,
}
export type Op = { [string]: any }
export type State = {
	entries: { Entry },
	equipped: { [string]: string },
	nextUid: number,
	quarantine: { any },
}
export type Store = { get: (self: any, key: string) -> any, set: (self: any, key: string, value: any) -> () }
export type Options = {
	items: ItemDefs.Registry,
	owner: string,
	capacity: number,
	maxWeight: number?,
	equipSlots: ({ string } | { [string]: string })?,
	store: Store?,
	storeKey: string?,
	data: any?,
	report: ((message: string) -> ())?,
}
export type Tx = {
	inventory: any,
	version: number,
	before: State,
	after: State,
	created: { string },
	removed: { Entry },
	state: "prepared" | "committed" | "rolled_back",
}

local function token(value: any, max: number?): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= (max or 64)
		and string.match(value, "^[%w_%.:%-]+$") ~= nil
end

-- Plain persisted data: label keys; strings, finite numbers, booleans or nested maps/lists.
local function plainData(value: any, depth: number): boolean
	if type(value) ~= "table" or depth > Inventory.DATA_DEPTH then
		return false
	end
	for key, child in value do
		if not (Check.label(key) or (type(key) == "number" and key >= 1 and key % 1 == 0)) then
			return false
		end
		local kind = type(child)
		if kind == "table" then
			if not plainData(child, depth + 1) then
				return false
			end
		elseif not (kind == "string" or kind == "boolean" or (kind == "number" and Check.finite(child))) then
			return false
		end
	end
	return true
end
Inventory.plainData = function(value: any): boolean
	return plainData(value, 1)
end

local function copyState(state: State): State
	return Check.copy(state)
end

type InventoryFields = {
	changed: Signal.Signal,
	notes: { string },
	_items: ItemDefs.Registry,
	_owner: string,
	_capacity: number,
	_maxWeight: number?,
	_slots: { [string]: string }, -- slot -> accepted def.slot
	_state: State,
	_version: number,
	_store: Store?,
	_storeKey: string,
	_report: (message: string) -> (),
}
export type Inventory = typeof(setmetatable({} :: InventoryFields, Inventory))

local function uidNumber(owner: string, uid: string): number?
	local prefix = owner .. "-"
	if string.sub(uid, 1, #prefix) ~= prefix then
		return nil
	end
	return tonumber(string.sub(uid, #prefix + 1))
end

-- Reads inventory/1 data; never drops value silently (see the header).
local function decode(self: Inventory, data: any)
	local state = self._state
	if data == nil then
		return
	end
	if type(data) ~= "table" or data.schema ~= Inventory.SCHEMA or type(data.entries) ~= "table" then
		table.insert(self.notes, "stored data is not inventory/1; starting empty")
		if type(data) == "table" then
			table.insert(state.quarantine, Check.copy(data))
		end
		return
	end
	local uids: { [string]: boolean } = {}
	for index, raw in data.entries do
		local def = type(raw) == "table" and self._items:get(raw.item)
		local reason: string? = nil
		if type(raw) ~= "table" then
			reason = "is not a table"
		elseif not def then
			reason = "names retired item " .. Check.describe(raw.item)
		elseif not (Check.integer(raw.count) and raw.count >= 1) then
			reason = "has an invalid count"
		elseif raw.data ~= nil and not plainData(raw.data, 1) then
			reason = "has invalid data"
		elseif (def :: any).stackable then
			if raw.uid ~= nil then
				reason = "is a stack with a uid"
			elseif raw.count > (def :: any).maxStack then
				reason = "exceeds maxStack"
			end
		else
			if raw.count ~= 1 or not token(raw.uid) then
				reason = "is an instance without a valid uid"
			elseif uids[raw.uid] then
				reason = "duplicates uid " .. raw.uid
			end
		end
		if reason then
			table.insert(self.notes, string.format("entry %d %s; quarantined", index, reason))
			table.insert(state.quarantine, Check.copy(raw))
			continue
		end
		if raw.uid then
			uids[raw.uid] = true
		end
		table.insert(state.entries, {
			item = raw.item,
			count = raw.count,
			uid = raw.uid,
			data = if raw.data then Check.copy(raw.data) else nil,
			paid = if raw.paid == true then true else nil,
		})
	end
	if type(data.quarantine) == "table" then
		for _, item in data.quarantine do
			table.insert(state.quarantine, Check.copy(item))
		end
	end
	local nextUid = if Check.integer(data.nextUid) and data.nextUid >= 1 then data.nextUid else 1
	for uid in uids do
		local number = uidNumber(self._owner, uid)
		if number and number >= nextUid then
			table.insert(self.notes, "nextUid repaired past " .. uid)
			nextUid = number + 1
		end
	end
	state.nextUid = nextUid
	if type(data.equipped) == "table" then
		for slot, uid in data.equipped do
			local entry = nil
			for _, candidate in state.entries do
				if candidate.uid == uid then
					entry = candidate
				end
			end
			local def = entry and self._items:get(entry.item)
			if self._slots[slot] and def and def.slot == self._slots[slot] then
				state.equipped[slot] = uid
			else
				table.insert(
					self.notes,
					string.format("equipped %s dropped (%s)", Check.describe(slot), Check.describe(uid))
				)
			end
		end
	end
	if #state.entries > self._capacity then
		table.insert(self.notes, "over capacity after load; adds refused until entries are removed")
	end
end

-- An inventory for one player. Raises on invalid options. Loads from store:get(storeKey) when
-- it holds data, else options.data. inventory.notes lists load repairs.
function Inventory.new(options: Options, env: any?): Inventory
	assert(type(options) == "table", "Inventory.new: options must be a table")
	local problems = {}
	if not ItemDefs.isRegistry(options.items) then
		table.insert(problems, "items must be an ItemDefs registry")
	end
	if not token(options.owner, Inventory.OWNER_MAX) then
		table.insert(problems, "owner must be 1-48 letters, digits or _ . : - (it prefixes instance uids)")
	end
	if not (Check.integer(options.capacity) and options.capacity >= 1) then
		table.insert(problems, "capacity must be an integer >= 1")
	end
	if options.maxWeight ~= nil and not (Check.finite(options.maxWeight) and options.maxWeight >= 0) then
		table.insert(problems, "maxWeight must be a finite number >= 0")
	end
	local slots: { [string]: string } = {}
	local equipSlots: any = options.equipSlots or {}
	if type(equipSlots) ~= "table" then
		table.insert(problems, "equipSlots must be a list of slots or a map slot -> kind")
	elseif #equipSlots > 0 then
		for _, slot in equipSlots do
			if not Check.label(slot) or slots[slot] then
				table.insert(problems, "equip slot " .. Check.describe(slot) .. " is not a unique label")
			else
				slots[slot] = slot
			end
		end
	else
		for slot, kind in equipSlots do
			if not Check.label(slot) or not Check.label(kind) then
				table.insert(
					problems,
					"equip slot " .. Check.describe(slot) .. " needs a label name and a label kind"
				)
			else
				slots[slot] = kind
			end
		end
	end
	local store = options.store
	if
		store ~= nil
		and (type(store) ~= "table" or type(store.get) ~= "function" or type(store.set) ~= "function")
	then
		table.insert(problems, "store must have get and set methods")
	end
	if #problems > 0 then
		error("Inventory.new: " .. table.concat(problems, "; "), 2)
	end
	local self = setmetatable({
		changed = Signal.new(env),
		notes = {},
		_items = options.items,
		_owner = options.owner,
		_capacity = options.capacity,
		_maxWeight = options.maxWeight,
		_slots = slots,
		_state = { entries = {}, equipped = {}, nextUid = 1, quarantine = {} },
		_version = 0,
		_store = store,
		_storeKey = options.storeKey or "inventory",
		_report = options.report
			or (env and type(env.report) == "function" and env.report)
			or function(_message: string) end,
	}, Inventory)
	local data = options.data
	if store then
		local ok, stored = pcall(store.get, store, self._storeKey)
		if not ok then
			error("Inventory.new: store:get failed: " .. tostring(stored), 2)
		end
		if stored ~= nil then
			data = stored
		end
	end
	decode(self, data)
	return self
end

-- ---------------------------------------------------------------- op engine (on a state copy)

local function findUid(state: State, uid: any): (number?, Entry?)
	for index, entry in state.entries do
		if entry.uid == uid then
			return index, entry
		end
	end
	return nil, nil
end

local function isEquipped(state: State, uid: string): boolean
	for _, equipped in state.equipped do
		if equipped == uid then
			return true
		end
	end
	return false
end

local function total(state: State, item: string): number
	local n = 0
	for _, entry in state.entries do
		if entry.item == item then
			n += entry.count
		end
	end
	return n
end

local function applyOp(
	self: Inventory,
	state: State,
	op: any,
	created: { string },
	removed: { Entry }
): string?
	if type(op) ~= "table" then
		return "bad_op"
	end
	local kind = op.op
	if kind == "add" then
		if op.instance ~= nil then
			local instance = op.instance
			if type(instance) ~= "table" then
				return "bad_op"
			end
			local def = self._items:get(instance.item)
			if def == nil then
				return "unknown_item"
			end
			if def.stackable then
				return "bad_op"
			end
			if not token(instance.uid) then
				return "missing_uid"
			end
			if findUid(state, instance.uid) then
				return "duplicate_uid"
			end
			if instance.data ~= nil and not plainData(instance.data, 1) then
				return "invalid_data"
			end
			table.insert(state.entries, {
				item = instance.item,
				count = 1,
				uid = instance.uid,
				data = if instance.data then Check.copy(instance.data) else nil,
				paid = if instance.paid == true or def.paid then true else nil,
			})
			return nil
		end
		local def = self._items:get(op.item)
		if def == nil then
			return "unknown_item"
		end
		local count = if op.count == nil then 1 else op.count
		if not (Check.integer(count) and count >= 1) then
			return "invalid_count"
		end
		if op.data ~= nil and (def.stackable or not plainData(op.data, 1)) then
			return "invalid_data"
		end
		local paid = if op.paid == true or def.paid then true else nil
		if def.stackable then
			local left = count
			for _, entry in state.entries do
				if left == 0 then
					break
				end
				if entry.item == def.id and entry.paid == paid and entry.count < def.maxStack then
					local moved = math.min(left, def.maxStack - entry.count)
					entry.count += moved
					left -= moved
				end
			end
			-- An op that alone needs more entries than capacity plus every existing entry can
			-- never fit, whatever later ops remove; refusing it here bounds the loop.
			if math.ceil(left / def.maxStack) > self._capacity + #state.entries then
				return "no_space"
			end
			while left > 0 do
				local moved = math.min(left, def.maxStack)
				table.insert(state.entries, { item = def.id, count = moved, paid = paid })
				left -= moved
			end
		else
			if count > self._capacity + #state.entries then
				return "no_space"
			end
			for _ = 1, count do
				local uid = self._owner .. "-" .. string.format("%d", state.nextUid)
				state.nextUid += 1
				table.insert(state.entries, {
					item = def.id,
					count = 1,
					uid = uid,
					data = if op.data then Check.copy(op.data) else nil,
					paid = paid,
				})
				table.insert(created, uid)
			end
		end
		return nil
	elseif kind == "remove" then
		if op.uid ~= nil then
			local index, entry = findUid(state, op.uid)
			if index == nil then
				return "missing_uid"
			end
			if isEquipped(state, op.uid) then
				return "item_equipped"
			end
			table.insert(removed, Check.copy(entry :: Entry))
			table.remove(state.entries, index)
			return nil
		end
		local def = self._items:get(op.item)
		if def == nil then
			return "unknown_item"
		end
		local count = if op.count == nil then 1 else op.count
		if not (Check.integer(count) and count >= 1) then
			return "invalid_count"
		end
		local left = count
		for index = #state.entries, 1, -1 do
			if left == 0 then
				break
			end
			local entry = state.entries[index]
			if
				entry.item == def.id
				and (op.paid == nil or (entry.paid == true) == (op.paid == true))
				and not (entry.uid and isEquipped(state, entry.uid))
			then
				local taken = math.min(left, entry.count)
				local piece = Check.copy(entry)
				piece.count = taken
				table.insert(removed, piece)
				entry.count -= taken
				left -= taken
				if entry.count == 0 then
					table.remove(state.entries, index)
				end
			end
		end
		if left > 0 then
			return "insufficient_items"
		end
		return nil
	elseif kind == "move" then
		local n = #state.entries
		if not (Check.integer(op.from) and Check.integer(op.to) and op.from >= 1 and op.to >= 1) then
			return "bad_op"
		end
		if op.from > n or op.to > n then
			return "bad_op"
		end
		local entry = table.remove(state.entries, op.from)
		table.insert(state.entries, op.to, entry :: Entry)
		return nil
	elseif kind == "equip" then
		if not self._slots[op.slot] then
			return "unknown_slot"
		end
		local _, entry = findUid(state, op.uid)
		if entry == nil then
			return "missing_uid"
		end
		local def = self._items:get(entry.item)
		if def == nil or def.slot == nil then
			return "not_equippable"
		end
		if def.slot ~= self._slots[op.slot] then
			return "wrong_slot"
		end
		for slot, uid in state.equipped do
			if uid == op.uid then
				state.equipped[slot] = nil
			end
		end
		state.equipped[op.slot] = op.uid
		return nil
	elseif kind == "unequip" then
		if not self._slots[op.slot] then
			return "unknown_slot"
		end
		state.equipped[op.slot] = nil
		return nil
	elseif kind == "set_data" then
		local _, entry = findUid(state, op.uid)
		if entry == nil then
			return "missing_uid"
		end
		if op.data ~= nil and not plainData(op.data, 1) then
			return "invalid_data"
		end
		entry.data = if op.data then Check.copy(op.data) else nil
		return nil
	end
	return "bad_op"
end

local function weightOf(self: Inventory, state: State): number
	local sum = 0
	for _, entry in state.entries do
		local def = self._items:get(entry.item)
		sum += (if def then def.weight else 0) * entry.count
	end
	return sum
end

-- Problems with a state after ops (capacity, weight, unique items).
local function finalCheck(self: Inventory, state: State, before: State): string?
	if #state.entries > self._capacity and #state.entries > #before.entries then
		return "no_space"
	end
	local maxWeight = self._maxWeight
	if maxWeight then
		local weight = weightOf(self, state)
		if weight > maxWeight + 1e-9 and weight > weightOf(self, before) then
			return "over_weight"
		end
	end
	for _, entry in state.entries do
		local def = self._items:get(entry.item)
		if def and def.unique and total(state, entry.item) > 1 then
			return "unique_item"
		end
	end
	return nil
end

-- Prepares ops without applying them: (tx) or (nil, error, index of the failing op; 0 for a
-- whole-state check such as capacity).
function Inventory.prepare(self: Inventory, ops: { Op }): (Tx?, string?, number?)
	if type(ops) ~= "table" or #ops == 0 then
		return nil, "bad_op", 0
	end
	local state = copyState(self._state)
	local created, removed = {}, {}
	for index, op in ops do
		local err = applyOp(self, state, op, created, removed)
		if err then
			return nil, err, index
		end
	end
	local err = finalCheck(self, state, self._state)
	if err then
		return nil, err, 0
	end
	return {
		inventory = self,
		version = self._version,
		before = copyState(self._state),
		after = state,
		created = created,
		removed = removed,
		state = "prepared",
	},
		nil,
		nil
end

local function persist(self: Inventory): boolean
	local store = self._store
	if store == nil then
		return true
	end
	local ok, err = pcall(store.set, store, self._storeKey, self:serialize())
	if not ok then
		self._report("Inventory: store:set failed: " .. tostring(err))
	end
	return ok
end

-- Applies a prepared tx ("stale" when the inventory changed since prepare; "store_failed" with
-- the state restored when the store write raised).
function Inventory.commit(self: Inventory, tx: Tx): (boolean, string?)
	if type(tx) ~= "table" or tx.inventory ~= self or tx.state ~= "prepared" then
		return false, "invalid_tx"
	end
	if tx.version ~= self._version then
		return false, "stale"
	end
	local previous = self._state
	self._state = copyState(tx.after)
	if not persist(self) then
		self._state = previous
		return false, "store_failed"
	end
	self._version += 1
	tx.state = "committed"
	self.changed:Fire(tx)
	return true, nil
end

-- Undoes a committed tx when nothing changed since (else "stale").
function Inventory.rollback(self: Inventory, tx: Tx): (boolean, string?)
	if type(tx) ~= "table" or tx.inventory ~= self then
		return false, "invalid_tx"
	end
	if tx.state ~= "committed" then
		return false, "not_committed"
	end
	if self._version ~= tx.version + 1 then
		return false, "stale"
	end
	local previous = self._state
	self._state = copyState(tx.before)
	if not persist(self) then
		self._state = previous
		return false, "store_failed"
	end
	self._version += 1
	tx.state = "rolled_back"
	self.changed:Fire(tx)
	return true, nil
end

-- Applies ops atomically. (true, nil, { created = uids, removed = entries }) or
-- (false, error, { index = failing op, 0 for a whole-state check }).
function Inventory.apply(self: Inventory, ops: { Op }): (boolean, string?, any)
	local tx, err, index = self:prepare(ops)
	if tx == nil then
		return false, err, { index = index }
	end
	local ok, commitErr = self:commit(tx)
	if not ok then
		return false, commitErr, { index = 0 }
	end
	return true, nil, { created = tx.created, removed = tx.removed }
end

function Inventory.canApply(self: Inventory, ops: { Op }): (boolean, string?, number?)
	local tx, err, index = self:prepare(ops)
	return tx ~= nil, err, index
end

-- Convenience: add count copies of item (instances get data). Returns apply's results.
function Inventory.add(self: Inventory, item: string, count: number?, data: any?): (boolean, string?, any)
	return self:apply({ { op = "add", item = item, count = count, data = data } })
end

function Inventory.remove(self: Inventory, item: string, count: number?): (boolean, string?, any)
	return self:apply({ { op = "remove", item = item, count = count } })
end

-- ---------------------------------------------------------------- reads

-- Copies of item held (paid = true/false filters by paid origin; nil counts all).
function Inventory.count(self: Inventory, item: string, paid: boolean?): number
	local n = 0
	for _, entry in self._state.entries do
		if entry.item == item and (paid == nil or (entry.paid == true) == paid) then
			n += entry.count
		end
	end
	return n
end

function Inventory.has(self: Inventory, item: string, count: number?): boolean
	return self:count(item) >= (count or 1)
end

-- A copy of the instance with uid, or nil.
function Inventory.get(self: Inventory, uid: string): Entry?
	local _, entry = findUid(self._state, uid)
	return if entry then Check.copy(entry) else nil
end

function Inventory.entries(self: Inventory): { Entry }
	return Check.copy(self._state.entries)
end

-- The uid in slot, or (with no slot) a copy of the slot -> uid map.
function Inventory.equipped(self: Inventory, slot: string?): any
	if slot ~= nil then
		return self._state.equipped[slot]
	end
	return table.clone(self._state.equipped)
end

function Inventory.isEquipped(self: Inventory, uid: string): boolean
	return isEquipped(self._state, uid)
end

function Inventory.used(self: Inventory): number
	return #self._state.entries
end

function Inventory.capacity(self: Inventory): number
	return self._capacity
end

function Inventory.free(self: Inventory): number
	return math.max(self._capacity - #self._state.entries, 0)
end

function Inventory.weight(self: Inventory): number
	return weightOf(self, self._state)
end

function Inventory.owner(self: Inventory): string
	return self._owner
end

function Inventory.items(self: Inventory): ItemDefs.Registry
	return self._items
end

function Inventory.version(self: Inventory): number
	return self._version
end

-- Raises or lowers capacity (an upgrade). Lowering below the used count keeps every entry
-- and refuses adds until enough are removed.
function Inventory.setCapacity(self: Inventory, capacity: number)
	assert(Check.integer(capacity) and capacity >= 1, "Inventory:setCapacity needs an integer >= 1")
	self._capacity = capacity
end

-- Quarantined entries (retired items, broken or duplicate entries found while loading).
function Inventory.quarantine(self: Inventory): { any }
	return Check.copy(self._state.quarantine)
end

-- Plain inventory/1 data for a key store.
function Inventory.serialize(self: Inventory): any
	local state = self._state
	local equipped: any = table.clone(state.equipped)
	return {
		schema = Inventory.SCHEMA,
		entries = Check.copy(state.entries),
		equipped = equipped,
		nextUid = state.nextUid,
		quarantine = Check.copy(state.quarantine),
	}
end

return Inventory
