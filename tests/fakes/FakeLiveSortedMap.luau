--!strict
-- FakeLiveSortedMap: a MemoryStore sorted map stand-in with the semantics LiveBoard relies on:
-- items { key, value, sortKey } expire `expiration` seconds after their last write (on the
-- clock passed in, usually FakeEnv's), GetRangeAsync returns live items ordered by sortKey then
-- key ("Ascending" / "Descending"), exclusive bounds { key?, sortKey? }, count 1-200, keys up to
-- 128 characters, expiration up to 3,888,000 s; UpdateAsync cancels when the transform returns
-- nil. failNext(method, message) makes the next call raise. G7-owned fake.
local FakeLiveSortedMap = {}

function FakeLiveSortedMap.new(clock: () -> number): any
	local items: { [string]: { value: any, sortKey: any, expires: number } } = {}
	local map: any = { calls = {}, failures = {} }

	local function fail(method: string)
		table.insert(map.calls, method)
		local queue = map.failures[method]
		if queue and #queue > 0 then
			error(table.remove(queue, 1), 0)
		end
	end
	local function checkKey(key: any)
		if type(key) ~= "string" or key == "" or #key > 128 then
			error("key must be a string of 1-128 characters", 0)
		end
	end
	local function checkExpiration(expiration: any)
		if type(expiration) ~= "number" or expiration <= 0 or expiration > 3888000 then
			error("expiration must be in (0, 3888000]", 0)
		end
	end
	local function live(key: string)
		local item = items[key]
		if item and item.expires <= clock() then
			items[key] = nil
			return nil
		end
		return item
	end

	function map.failNext(_, method: string, message: string)
		map.failures[method] = map.failures[method] or {}
		table.insert(map.failures[method], message)
	end

	function map.GetAsync(_, key: string)
		fail("GetAsync")
		checkKey(key)
		local item = live(key)
		if item then
			return item.value, item.sortKey
		end
		return nil
	end

	function map.SetAsync(_, key: string, value: any, expiration: number, sortKey: any?)
		fail("SetAsync")
		checkKey(key)
		checkExpiration(expiration)
		local isNew = live(key) == nil
		items[key] = { value = value, sortKey = sortKey, expires = clock() + expiration }
		return isNew
	end

	function map.UpdateAsync(_, key: string, transform: (any, any) -> (any, any), expiration: number)
		fail("UpdateAsync")
		checkKey(key)
		checkExpiration(expiration)
		local item = live(key)
		local value, sortKey = transform(if item then item.value else nil, if item then item.sortKey else nil)
		if value == nil then
			return if item then item.value else nil, if item then item.sortKey else nil
		end
		items[key] = { value = value, sortKey = sortKey, expires = clock() + expiration }
		return value, sortKey
	end

	function map.RemoveAsync(_, key: string)
		fail("RemoveAsync")
		checkKey(key)
		items[key] = nil
	end

	-- Sort keys: numbers before strings, items without one last; then the key.
	local function rankOf(sortKey: any): number
		return if type(sortKey) == "number" then 1 elseif type(sortKey) == "string" then 2 else 3
	end
	local function less(a: any, b: any): boolean
		local ra, rb = rankOf(a.sortKey), rankOf(b.sortKey)
		if ra ~= rb then
			return ra < rb
		end
		if ra < 3 and a.sortKey ~= b.sortKey then
			return a.sortKey < b.sortKey
		end
		return a.key < b.key
	end

	function map.GetRangeAsync(_, direction: string, count: number, lower: any?, upper: any?)
		fail("GetRangeAsync")
		if direction ~= "Ascending" and direction ~= "Descending" then
			error("direction must be Ascending or Descending", 0)
		end
		if type(count) ~= "number" or count < 1 or count > 200 or count % 1 ~= 0 then
			error("count must be an integer in [1, 200]", 0)
		end
		local list = {}
		for key in items do
			local item = live(key)
			if item then
				table.insert(list, { key = key, value = item.value, sortKey = item.sortKey })
			end
		end
		table.sort(list, less)
		local function bound(entry: any): any
			return { key = entry.key or "", sortKey = entry.sortKey }
		end
		local out = {}
		local start, stop, step = 1, #list, 1
		if direction == "Descending" then
			start, stop, step = #list, 1, -1
		end
		for i = start, stop, step do
			local entry = list[i]
			local inside = (lower == nil or less(bound(lower), entry))
				and (upper == nil or less(entry, bound(upper)))
			if inside then
				table.insert(out, entry)
				if #out == count then
					break
				end
			end
		end
		return out
	end

	return map
end

return FakeLiveSortedMap
