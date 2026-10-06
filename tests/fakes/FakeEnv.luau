--!strict
-- FakeEnv: a deterministic GameKit Env for Lune specs (shape in packages/GameKit/Env.luau).
-- Time stands still until advance(dt); deferred calls wait in a FIFO until flush(); spawn runs
-- now on a new thread, like task.spawn. wait(s) parks the calling thread until advance passes
-- its wake time; it only works on threads this env started (spawn or defer), because yielding
-- Lune's main thread would end the spec silently. Errors on those threads are collected in
-- env.errors instead of propagating (as in Roblox), and env.report messages in env.reports.
-- rng(seed) is ProcGen/Rng; rng() with no seed draws "<seed>:<n>" from a counter.
-- Shared Stage 0 helper: groups read it, never edit it.
local Rng = require("../../packages/ProcGen/Rng")

local FakeEnv = {}

export type Options = {
	start: number?,
	seed: (number | string)?,
	place: { isStudio: boolean, gameId: number, placeId: number, isServer: boolean?, isClient: boolean? }?,
	services: { [string]: any }?,
	roblox: any?,
	deferLimit: number?,
}

type Sleeper = { thread: thread, wakeAt: number, startedAt: number, order: number }

function FakeEnv.new(options: Options?): any
	local opts: Options = options or {}
	local now = opts.start or 0
	local seed = opts.seed or 0
	local deferLimit = opts.deferLimit or 10000
	local deferred: { { fn: any, args: { n: number, [number]: any } } } = {}
	local sleepers: { Sleeper } = {}
	local owned: { [thread]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local rngCount = 0
	local order = 0

	local env: any = {
		services = table.clone(opts.services or {}),
		place = opts.place or { isStudio = true, gameId = 0, placeId = 0, isServer = true, isClient = false },
		roblox = opts.roblox,
		errors = {} :: { string },
		reports = {} :: { string },
	}

	local function start(target: any, ...: any)
		local thread = if type(target) == "thread" then target else coroutine.create(target)
		owned[thread] = true
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			table.insert(env.errors, tostring(err))
		end
	end

	env.clock = function(): number
		return now
	end
	env.spawn = function(target: any, ...: any)
		start(target, ...)
	end
	env.defer = function(fn: any, ...: any)
		table.insert(deferred, { fn = fn, args = table.pack(...) })
	end
	env.wait = function(seconds: number?): number
		local thread = coroutine.running()
		if not owned[thread] then
			error("FakeEnv.wait: call it on a thread started with env.spawn or env.defer", 2)
		end
		order += 1
		local duration = math.max(seconds or 0, 0)
		table.insert(sleepers, { thread = thread, wakeAt = now + duration, startedAt = now, order = order })
		return coroutine.yield()
	end
	env.rng = function(rngSeed: (number | string)?): Rng.Rng
		if rngSeed == nil then
			rngCount += 1
			return Rng.new(tostring(seed) .. ":" .. rngCount)
		end
		return Rng.new(rngSeed :: number | string)
	end
	env.report = function(message: string)
		table.insert(env.reports, message)
	end

	-- Moves the clock forward by dt, waking sleepers in wake-time order (ties in wait order).
	function env.advance(_self: any, dt: number)
		assert(type(dt) == "number" and dt == dt and dt >= 0, "FakeEnv:advance needs a number >= 0")
		local target = now + dt
		while true do
			local best: Sleeper? = nil
			local bestIndex = 0
			for index, sleeper in sleepers do
				if
					sleeper.wakeAt <= target
					and (
						best == nil
						or sleeper.wakeAt < best.wakeAt
						or (sleeper.wakeAt == best.wakeAt and sleeper.order < best.order)
					)
				then
					best, bestIndex = sleeper, index
				end
			end
			if best == nil then
				break
			end
			table.remove(sleepers, bestIndex)
			now = math.max(now, best.wakeAt)
			start(best.thread, now - best.startedAt)
		end
		now = target
	end

	-- Runs deferred calls in FIFO order, including ones deferred while flushing. Returns how
	-- many ran; raises after deferLimit calls (a defer loop).
	function env.flush(_self: any): number
		local ran = 0
		while #deferred > 0 do
			local item = table.remove(deferred, 1) :: any
			ran += 1
			if ran > deferLimit then
				error(
					string.format("FakeEnv:flush ran more than %d deferred calls (a defer loop?)", deferLimit),
					2
				)
			end
			start(item.fn, table.unpack(item.args, 1, item.args.n))
		end
		return ran
	end

	-- Registers a service or fake under name and returns it.
	function env.register(_self: any, name: string, service: any): any
		env.services[name] = service
		return service
	end

	-- Queued deferred calls and parked threads.
	function env.pending(_self: any): (number, number)
		return #deferred, #sleepers
	end

	return env
end

return FakeEnv
