--!strict
-- @tier T4
-- MemoryQueueRoblox: a cross-server matchmaking queue on a MemoryStoreQueue
-- (MemoryStoreService:GetQueue), planned by GameKit/Queue. T4: MemoryStore needs a published
-- experience (Studio's memory stores are isolated from production); Lune specs run it against
-- tests/fakes/FakeMemoryStore.
--   new(memoryStoreService, opts, env) -> mq
--   mq:push(ticket)        AddAsync(ticket, expiration, priority) with GameKit/Retry
--   mq:pull(count, wait)   ReadAsync -> (tickets, readId); the items stay invisible to other
--                          readers for `invisibility` seconds, then reappear unless removed
--   mq:ack(readId)         RemoveAsync: deletes every item of that read
--   mq:size()              GetSizeAsync
--   mq:cycle(queueOptions, onMatch, now?)  one matchmaking step (below)
-- cycle reads a batch, rebuilds a GameKit/Queue from it (invalid and duplicate tickets are
-- dropped and reported), takes the plan, and calls onMatch(match) for each match. onMatch yields
-- (reserve a server, record the match where lobbies can see it) and returns true when the match
-- is launched; false or an error puts its tickets back. Then the batch is removed and every
-- ticket not launched is pushed back with its original enqueue time, so waiting time and skill
-- bands carry over. Delivery is at least once: a server that stops between the remove and the
-- re-push loses those tickets from the shared queue, and a lobby that re-pushes a ticket it still
-- has can duplicate it. So lobbies keep their own tickets and re-push one with no result after
-- the expiration, and onMatch must claim each ticket atomically (for example
-- MemoryStoreHashMap:UpdateAsync on the ticket id) before launching, so a duplicate is skipped.
local Queue = require("./Queue")
local Retry = require("./Retry")

local MemoryQueueRoblox = {}

MemoryQueueRoblox.DEFAULTS = table.freeze({
	invisibility = 30, -- seconds a read batch stays hidden (Roblox's default)
	expiration = 600, -- convention: seconds a ticket lives in the queue
	batch = 100, -- items per read (Roblox's maximum)
})
MemoryQueueRoblox.RETRY =
	table.freeze({ attempts = 3, base = 0.5, factor = 2, maxDelay = 4, jitter = "full" })

export type Options = {
	name: string,
	invisibility: number?,
	expiration: number?,
	batch: number?,
	retry: Retry.Options?,
}
export type CycleResult = {
	ok: boolean,
	reason: string?, -- read_failed, ack_failed
	launched: { string }, -- match ids
	requeued: number,
	dropped: { string }, -- reasons for tickets dropped from the batch
	expired: { string },
	lost: number, -- tickets that could not be pushed back
}

function MemoryQueueRoblox.new(memoryStoreService: any, opts: Options, env: any): any
	assert(memoryStoreService ~= nil, "MemoryQueueRoblox.new: MemoryStoreService required")
	assert(
		type(opts) == "table" and type(opts.name) == "string" and #opts.name > 0,
		"MemoryQueueRoblox.new: name required"
	)
	local invisibility = opts.invisibility or MemoryQueueRoblox.DEFAULTS.invisibility
	local expiration = opts.expiration or MemoryQueueRoblox.DEFAULTS.expiration
	local batch = opts.batch or MemoryQueueRoblox.DEFAULTS.batch
	assert(
		type(invisibility) == "number" and invisibility > 0,
		"MemoryQueueRoblox.new: invisibility must be > 0"
	)
	assert(
		type(expiration) == "number" and expiration >= 1 and expiration <= 3888000,
		"MemoryQueueRoblox.new: expiration must be 1..3888000 seconds"
	)
	assert(
		type(batch) == "number" and batch >= 1 and batch <= 100 and batch % 1 == 0,
		"MemoryQueueRoblox.new: batch must be 1..100"
	)
	local retry = opts.retry or MemoryQueueRoblox.RETRY
	local queue = memoryStoreService:GetQueue(opts.name, invisibility)
	local mq = {}

	local function call(fn: () -> any): (boolean, any)
		local ok, result = Retry.run(fn, retry :: any, env)
		return ok, result
	end

	-- Pushes a ticket (stamped with env.clock() when it has no `at`). Returns (ok, error?).
	function mq.push(_self: any, ticket: Queue.Ticket, priority: number?): (boolean, string?)
		if type(ticket) ~= "table" then
			return false, "invalid_ticket"
		end
		local copy = table.clone(ticket)
		if copy.at == nil then
			copy.at = env.clock()
		end
		local ok, err = call(function(): any
			queue:AddAsync(copy, expiration, priority or 0)
			return true
		end)
		return ok, if ok then nil else tostring(err)
	end

	-- Reads up to count tickets (yields up to waitTimeout). Returns (tickets, readId) or ({}, nil)
	-- when nothing was read, and (nil, error) when the read failed.
	function mq.pull(_self: any, count: number?, waitTimeout: number?): (any, any)
		local ok, result = call(function(): any
			local items, readId = queue:ReadAsync(count or batch, false, waitTimeout or 0)
			return { items = items, readId = readId }
		end)
		if not ok then
			return nil, tostring(result)
		end
		return result.items or {}, result.readId
	end

	function mq.ack(_self: any, readId: string): (boolean, string?)
		local ok, err = call(function(): any
			queue:RemoveAsync(readId)
			return true
		end)
		return ok, if ok then nil else tostring(err)
	end

	function mq.size(_self: any): number?
		local ok, result = call(function(): any
			return queue:GetSizeAsync(false)
		end)
		return if ok then result else nil
	end

	function mq.cycle(
		self: any,
		queueOptions: Queue.Options?,
		onMatch: (match: Queue.Match) -> boolean,
		now: number?
	): CycleResult
		assert(type(onMatch) == "function", "MemoryQueueRoblox.cycle: onMatch must be a function")
		local result: CycleResult =
			{ ok = true, reason = nil, launched = {}, requeued = 0, dropped = {}, expired = {}, lost = 0 }
		local items, readId = self:pull(batch, 0)
		if items == nil then
			result.ok, result.reason = false, "read_failed"
			env.report("MemoryQueueRoblox: read failed: " .. tostring(readId))
			return result
		end
		if readId == nil or #items == 0 then
			return result
		end
		local batchQueue = Queue.new(queueOptions, env)
		for _, item in items do
			local added, why = batchQueue:add(item)
			if not added then
				table.insert(result.dropped, why :: string)
			end
		end
		local plan = batchQueue:take(now)
		result.expired = plan.expired
		local back: { Queue.Ticket } = batchQueue:snapshot()
		local snapshot: { [string]: Queue.Ticket } = {}
		for _, item in items do
			if type(item) == "table" and type(item.id) == "string" then
				snapshot[item.id] = snapshot[item.id] or item
			end
		end
		for _, match in plan.matches do
			local ok, launched = pcall(onMatch, match)
			if ok and launched == true then
				table.insert(result.launched, match.id)
			else
				if not ok then
					env.report(
						string.format(
							"MemoryQueueRoblox: onMatch %s failed: %s",
							match.id,
							tostring(launched)
						)
					)
				end
				for _, id in match.tickets do
					table.insert(back, snapshot[id])
				end
			end
		end
		local acked, ackError = self:ack(readId)
		if not acked then
			-- the batch reappears after the invisibility timeout; pushing back would duplicate it
			result.ok, result.reason = false, "ack_failed"
			env.report("MemoryQueueRoblox: remove failed, batch reappears: " .. tostring(ackError))
			return result
		end
		for _, ticket in back do
			if self:push(ticket) then
				result.requeued += 1
			else
				result.lost += 1
			end
		end
		if result.lost > 0 then
			env.report(string.format("MemoryQueueRoblox: %d tickets not pushed back", result.lost))
		end
		return result
	end

	return mq
end

return MemoryQueueRoblox
