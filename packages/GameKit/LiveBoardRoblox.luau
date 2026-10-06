--!strict
-- @tier T4
-- LiveBoardRoblox: the LiveBoard map interface over a MemoryStore sorted map
-- (env.services.MemoryStoreService:GetSortedMap(name)). Calls go through GameKit/Retry (MemoryStore
-- throttles and transient errors retry); the direction string becomes Enum.SortDirection. Use:
--   local board = LiveBoard.new(LiveBoardRoblox.map("round_scores", env), { ttl = 600 }, env)
-- T4: MemoryStore needs a published place (and its quotas), so this is never verified here
-- (BLOCKED_EXTERNAL); Lune specs drive LiveBoard with tests/fakes/FakeLiveSortedMap. Every call
-- yields: never call one from a simulation step.
local Env = require("./Env")
local Retry = require("./Retry")

local LiveBoardRoblox = {}

-- The Enum name for a direction string (pure, so specs can check the mapping).
function LiveBoardRoblox.direction(direction: string): string
	assert(direction == "Ascending" or direction == "Descending", "direction must be Ascending or Descending")
	return direction
end

function LiveBoardRoblox.map(name: string, env: any, retry: Retry.Options?): any
	assert(type(name) == "string" and name ~= "", "LiveBoardRoblox.map: name must be a non-empty string")
	local service = Env.service(env, "MemoryStoreService")
	local sorted = service:GetSortedMap(name)
	local options = retry or Retry.dataStore(env.rng())
	local enum = (env.roblox and env.roblox.Enum) or Enum

	local function call(fn: () -> ...any): ...any
		local ok, result = Retry.run(function()
			return table.pack(fn())
		end, options, env)
		if not ok then
			error(result, 0)
		end
		return table.unpack(result, 1, result.n)
	end

	local map = {}
	function map.GetAsync(_, key: string)
		return call(function()
			return sorted:GetAsync(key)
		end)
	end
	function map.UpdateAsync(_, key: string, transform: (any, any) -> (any, any), expiration: number)
		return call(function()
			return sorted:UpdateAsync(key, transform, expiration)
		end)
	end
	function map.RemoveAsync(_, key: string)
		return call(function()
			return sorted:RemoveAsync(key)
		end)
	end
	function map.GetRangeAsync(_, direction: string, count: number, lower: any?, upper: any?)
		local sortDirection = enum.SortDirection[LiveBoardRoblox.direction(direction)]
		return call(function()
			return sorted:GetRangeAsync(sortDirection, count, lower, upper)
		end)
	end
	return map
end

return LiveBoardRoblox
