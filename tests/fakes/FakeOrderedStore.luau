--!strict
-- FakeOrderedStore: a DataStoreService stand-in exposing GetOrderedDataStore(name, scope) with the
-- OrderedDataStore calls LeaderboardRoblox makes (GetAsync, SetAsync, UpdateAsync, RemoveAsync,
-- GetSortedAsync with DataStorePages). Values must be whole numbers (OrderedDataStore only stores
-- integers); pages hold at most 100 entries and sort by value, then key. failNext(method, message,
-- count) makes the next calls raise (for Retry), and `calls` logs every call. G7-owned fake.
local FakeOrderedStore = {}

local function integer(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and math.abs(value) <= 2 ^ 53
end

function FakeOrderedStore.new(): any
	local service: any = { calls = {}, stores = {}, failures = {} }

	local function fail(method: string)
		local queue = service.failures[method]
		if queue and #queue > 0 then
			local message = table.remove(queue, 1)
			error(message, 0)
		end
	end

	function service.failNext(_, method: string, message: string, count: number?)
		service.failures[method] = service.failures[method] or {}
		for _ = 1, count or 1 do
			table.insert(service.failures[method], message)
		end
	end

	function service.GetOrderedDataStore(_, name: string, scope: string?)
		local id = name .. "/" .. (scope or "global")
		if service.stores[id] then
			return service.stores[id]
		end
		local data: { [string]: number } = {}
		local store: any = { data = data, name = name }
		local function log(method: string, key: any)
			table.insert(service.calls, method .. ":" .. id .. ":" .. tostring(key))
		end
		function store.GetAsync(_, key: string)
			log("GetAsync", key)
			fail("GetAsync")
			return data[key]
		end
		function store.SetAsync(_, key: string, value: number)
			log("SetAsync", key)
			fail("SetAsync")
			if not integer(value) then
				error("104: OrderedDataStore values must be integers", 0)
			end
			data[key] = value
		end
		function store.UpdateAsync(_, key: string, transform: (number?) -> number?)
			log("UpdateAsync", key)
			fail("UpdateAsync")
			local nextValue = transform(data[key])
			if nextValue == nil then
				return data[key]
			end
			if not integer(nextValue) then
				error("104: OrderedDataStore values must be integers", 0)
			end
			data[key] = nextValue
			return nextValue
		end
		function store.RemoveAsync(_, key: string)
			log("RemoveAsync", key)
			fail("RemoveAsync")
			local old = data[key]
			data[key] = nil
			return old
		end
		function store.GetSortedAsync(
			_,
			ascending: boolean,
			pageSize: number,
			minValue: number?,
			maxValue: number?
		)
			log("GetSortedAsync", pageSize)
			fail("GetSortedAsync")
			if not integer(pageSize) or pageSize < 1 or pageSize > 100 then
				error("pageSize must be an integer in [1, 100]", 0)
			end
			local items = {}
			for key, value in data do
				if (minValue == nil or value >= minValue) and (maxValue == nil or value <= maxValue) then
					table.insert(items, { key = key, value = value })
				end
			end
			table.sort(items, function(a, b)
				if a.value ~= b.value then
					return if ascending then a.value < b.value else a.value > b.value
				end
				return a.key < b.key
			end)
			local pages: any = { _index = 1 }
			local function page(): { any }
				local out = {}
				for i = pages._index, math.min(pages._index + pageSize - 1, #items) do
					table.insert(out, items[i])
				end
				return out
			end
			pages.IsFinished = pages._index + pageSize > #items
			function pages.GetCurrentPage(_)
				return page()
			end
			function pages.AdvanceToNextPageAsync(_)
				fail("AdvanceToNextPageAsync")
				pages._index += pageSize
				pages.IsFinished = pages._index + pageSize > #items
			end
			return pages
		end
		service.stores[id] = store
		return store
	end

	return service
end

return FakeOrderedStore
