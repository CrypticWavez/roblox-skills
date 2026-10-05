--!strict
-- Shared bounded scheduler for VFX/resources; one caller-owned step loop.
local Lifetime = {}

function Lifetime.new(capacity: number)
	assert(
		type(capacity) == "number" and capacity % 1 == 0 and capacity >= 1 and capacity <= 10000,
		"invalid capacity"
	)
	local api = { dropped = 0, cleanupErrors = 0 }
	local items: { { id: number, remaining: number, priority: number, cleanup: () -> () } } = {}
	local serial, closed, cleanupDepth = 0, false, 0
	local function finish(index: number)
		local entry = assert(table.remove(items, index))
		cleanupDepth += 1
		local ok = pcall(entry.cleanup)
		cleanupDepth -= 1
		if not ok then
			api.cleanupErrors += 1
		end
	end
	function api:add(duration: number, priority: number, cleanup: () -> ()): (number?, string?)
		assert(
			type(duration) == "number" and duration == duration and duration >= 0 and duration <= 300,
			"invalid lifetime"
		)
		assert(type(priority) == "number" and priority >= 0 and priority <= 10, "invalid priority")
		assert(type(cleanup) == "function", "cleanup required")
		if closed then
			return nil, "closed" -- Ownership is transferred only when a token is returned.
		end
		if cleanupDepth > 0 then
			return nil, "cleanup_in_progress"
		end
		if #items >= capacity then
			local weakest = 1
			for index = 2, #items do
				if items[index].priority < items[weakest].priority then
					weakest = index
				end
			end
			if priority <= items[weakest].priority then
				api.dropped += 1
				return nil, "capacity"
			end
			finish(weakest)
			if closed then
				return nil, "closed_during_cleanup"
			end
		end
		serial += 1
		table.insert(items, { id = serial, remaining = duration, priority = priority, cleanup = cleanup })
		return serial, nil
	end
	function api:cancel(id: number)
		for index, item in items do
			if item.id == id then
				finish(index)
				return true
			end
		end
		return false
	end
	function api:step(dt: number)
		assert(type(dt) == "number" and dt == dt and dt >= 0 and dt < math.huge, "invalid dt")
		local expired = {}
		for _, item in items do
			item.remaining -= dt
			if item.remaining <= 0 then
				table.insert(expired, item.id)
			end
		end
		for _, id in expired do
			api:cancel(id)
		end
	end
	function api:count()
		return #items
	end
	function api:destroy()
		if closed then
			return
		end
		closed = true
		while #items > 0 do
			finish(#items)
		end
	end
	return api
end

return Lifetime
