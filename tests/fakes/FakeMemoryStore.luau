--!strict
-- FakeMemoryStore (G1): a MemoryStoreService stand-in with queues, for Lune specs of
-- GameKit/MemoryQueueRoblox. GetQueue(name, invisibilityTimeout = 30) returns one shared queue
-- per name (servers built on one world see the same queues):
--   AddAsync(value, expiration, priority = 0)    stores a JSON-encoded copy; higher priority reads
--                                                first, then oldest first; expired items vanish
--   ReadAsync(count, allOrNothing, waitTimeout)  returns (items, readId) and hides the items for
--                                                invisibilityTimeout; with fewer items than count
--                                                and allOrNothing it returns ({}, nil); waitTimeout
--                                                > 0 polls every 2 s on env.wait (as documented)
--   RemoveAsync(readId)                          deletes the items of that read
--   GetSizeAsync(excludeInvisible)               counts items
-- world.fail(method, n, message) makes the next n calls of a method raise. Items that are read
-- and not removed become visible again after the invisibility timeout, as on Roblox. Limits
-- checked: count 1..100, expiration 1..3888000 s (45 days), value JSON-encodable.
local serde = require("@lune/serde")

local FakeMemoryStore = {}

local MAX_EXPIRATION = 3888000

function FakeMemoryStore.new(env: any): any
	assert(env ~= nil and type(env.clock) == "function", "FakeMemoryStore.new: env required")
	local world = { queues = {} :: { [string]: any }, failures = {} :: { [string]: any }, calls = {} }
	local sequence = 0

	local function enter(method: string)
		world.calls[method] = (world.calls[method] or 0) + 1
		local failure = world.failures[method]
		if failure ~= nil and failure.n > 0 then
			failure.n -= 1
			error(failure.message, 0)
		end
	end

	function world.fail(_self: any, method: string, n: number?, message: string?)
		world.failures[method] = { n = n or 1, message = message or "Request throttled" }
	end

	local function newQueue(name: string, invisibility: number): any
		local items: { any } = {}
		local reads: { [string]: { any } } = {}
		local queue = { Name = name, items = items }

		local function prune()
			local now = env.clock()
			for index = #items, 1, -1 do
				if items[index].expires <= now then
					table.remove(items, index)
				end
			end
		end

		local function visible(): { any }
			prune()
			local now = env.clock()
			local out = {}
			for _, item in items do
				if item.hiddenUntil <= now then
					table.insert(out, item)
				end
			end
			table.sort(out, function(a: any, b: any): boolean
				if a.priority ~= b.priority then
					return a.priority > b.priority
				end
				return a.seq < b.seq
			end)
			return out
		end

		function queue.AddAsync(_self: any, value: any, expiration: number, priority: number?)
			enter("AddAsync")
			assert(
				type(expiration) == "number" and expiration >= 1 and expiration <= MAX_EXPIRATION,
				"bad expiration"
			)
			local encoded = serde.encode("json", value)
			sequence += 1
			table.insert(items, {
				seq = sequence,
				encoded = encoded,
				priority = priority or 0,
				expires = env.clock() + expiration,
				hiddenUntil = -math.huge,
			})
		end

		function queue.ReadAsync(
			_self: any,
			count: number,
			allOrNothing: boolean?,
			waitTimeout: number?
		): (any, any)
			enter("ReadAsync")
			assert(type(count) == "number" and count >= 1 and count <= 100, "count must be 1..100")
			local deadline = env.clock() + math.max(0, waitTimeout or 0)
			while true do
				local ready = visible()
				if #ready >= count or (#ready > 0 and not allOrNothing) then
					local taken = {}
					local values = {}
					for index = 1, math.min(count, #ready) do
						local item = ready[index]
						item.hiddenUntil = env.clock() + invisibility
						table.insert(taken, item)
						table.insert(values, serde.decode("json", item.encoded))
					end
					sequence += 1
					local readId = "read_" .. tostring(sequence)
					reads[readId] = taken
					return values, readId
				end
				if env.clock() >= deadline then
					return {}, nil
				end
				env.wait(2)
			end
		end

		function queue.RemoveAsync(_self: any, readId: string)
			enter("RemoveAsync")
			local taken = reads[readId]
			if taken == nil then
				return
			end
			reads[readId] = nil
			for _, item in taken do
				local index = table.find(items, item)
				if index then
					table.remove(items, index)
				end
			end
		end

		function queue.GetSizeAsync(_self: any, excludeInvisible: boolean?): number
			enter("GetSizeAsync")
			if excludeInvisible then
				return #visible()
			end
			prune()
			return #items
		end

		-- Test helper: decoded values of every stored item, read order.
		function queue.peek(_self: any): { any }
			prune()
			local out = {}
			local sorted = table.clone(items)
			table.sort(sorted, function(a: any, b: any): boolean
				if a.priority ~= b.priority then
					return a.priority > b.priority
				end
				return a.seq < b.seq
			end)
			for _, item in sorted do
				table.insert(out, serde.decode("json", item.encoded))
			end
			return out
		end

		return queue
	end

	-- The MemoryStoreService a server sees.
	function world.service(_self: any): any
		local service = {}
		function service.GetQueue(_s: any, name: string, invisibilityTimeout: number?): any
			assert(type(name) == "string" and #name > 0, "GetQueue: name required")
			local queue = world.queues[name]
			if queue == nil then
				queue = newQueue(name, invisibilityTimeout or 30)
				world.queues[name] = queue
			end
			return queue
		end
		return service
	end

	return world
end

return FakeMemoryStore
