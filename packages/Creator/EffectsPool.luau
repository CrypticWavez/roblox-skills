--!strict
-- Engine-independent bounded ownership. Adapter callbacks must not yield.
local EffectsPool = {}
local defaults: any = {
	telegraph = { duration = 0.8, priority = 8, radius = 1, width = 0.08, particleCount = 0 },
	impact = { duration = 0.3, priority = 5, radius = 0.5, width = 0.15, particleCount = 12 },
	reward = { duration = 0.7, priority = 2, radius = 0.4, width = 0.08, particleCount = 8 },
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function normalize(recipe: string, overrides: any, recipes: any): any
	local definition = recipes[recipe]
	assert(definition ~= nil, "unknown recipe")
	assert(overrides == nil or type(overrides) == "table", "invalid overrides")
	local config: any = table.clone(definition)
	for key, value in overrides or {} do
		assert(defaults.telegraph[key] ~= nil, "unknown recipe field")
		config[key] = value
	end
	assert(finite(config.duration) and config.duration >= 0.01 and config.duration <= 5, "invalid duration")
	assert(
		finite(config.priority)
			and config.priority % 1 == 0
			and config.priority >= 0
			and config.priority <= 10,
		"invalid priority"
	)
	assert(finite(config.radius) and config.radius >= 0.05 and config.radius <= 32, "invalid radius")
	assert(finite(config.width) and config.width >= 0.01 and config.width <= 2, "invalid width")
	assert(
		finite(config.particleCount)
			and config.particleCount % 1 == 0
			and config.particleCount >= 0
			and config.particleCount <= 48,
		"invalid particle count"
	)
	return config
end

type Entry = {
	id: number,
	resource: any,
	recipe: string,
	config: any,
	remaining: number,
}

function EffectsPool.new(adapter: any, options: any?)
	assert(options == nil or type(options) == "table", "invalid pool options")
	options = options or {}
	local allowedOptions = { capacity = true, reducedEffects = true, recipes = true }
	for key in options :: any do
		assert(allowedOptions[key] == true, "unknown pool option")
	end
	assert(type(adapter) == "table", "adapter required")
	for _, key in { "create", "activate", "reset", "destroy" } do
		assert(type(adapter[key]) == "function", "missing adapter callback")
	end
	assert(adapter.update == nil or type(adapter.update) == "function", "invalid update callback")
	local capacity = if options.capacity == nil then 24 else options.capacity
	assert(finite(capacity) and capacity % 1 == 0 and capacity >= 1 and capacity <= 256, "invalid capacity")
	assert(
		options.reducedEffects == nil or type(options.reducedEffects) == "boolean",
		"invalid reduced effects"
	)
	local recipes: any = {}
	assert(options.recipes == nil or type(options.recipes) == "table", "invalid recipes")
	for name in options.recipes or {} do
		assert(defaults[name] ~= nil, "unknown configured recipe")
	end
	for name in defaults do
		recipes[name] = normalize(name, (options.recipes or {})[name], defaults)
	end
	local active: { [number]: Entry } = {}
	local idle: { any } = {}
	local serial, allocated, operationDepth = 0, 0, 0
	local reduced = options.reducedEffects == true
	local closed, poisoned = false, false
	local counters =
		{ created = 0, reused = 0, dropped = 0, evicted = 0, cleanupErrors = 0, adapterErrors = 0 }
	local api: any = {}

	local function callback(fn: any, ...: any): (boolean, any)
		operationDepth += 1
		local ok, value = pcall(fn, ...)
		operationDepth -= 1
		return ok, value
	end
	local function dispose(resource: any)
		local ok = callback(adapter.destroy, resource)
		allocated -= 1
		if not ok then
			counters.cleanupErrors += 1
			poisoned = true -- A failed destructor must never permit allocation growth.
		end
	end
	local function finish(id: number): boolean
		local entry = active[id]
		if entry == nil then
			return false
		end
		active[id] = nil -- Reentrant cancellation cannot see transferred ownership.
		local ok = callback(adapter.reset, entry.resource)
		if not ok then
			counters.cleanupErrors += 1
		end
		if closed or not ok then
			dispose(entry.resource)
		else
			table.insert(idle, entry.resource)
		end
		return true
	end
	local function count(): number
		local result = 0
		for _ in active do
			result += 1
		end
		return result
	end

	function api:emit(recipe: string, overrides: any?, context: any?): (any?, string?)
		local config = normalize(recipe, overrides, recipes)
		if closed then
			return nil, "closed"
		end
		if poisoned then
			return nil, "cleanup_failed"
		end
		if operationDepth > 0 then
			return nil, "operation_in_progress"
		end
		if reduced and config.priority < 7 then
			counters.dropped += 1
			return nil, "reduced_effects"
		end
		config.reducedEffects = reduced
		if reduced then
			config.particleCount = 0
		end
		if #idle == 0 and allocated >= capacity then
			local weakest: Entry? = nil
			for _, entry in active do
				if
					weakest == nil
					or entry.config.priority < weakest.config.priority
					or (entry.config.priority == weakest.config.priority and entry.id < weakest.id)
				then
					weakest = entry
				end
			end
			if weakest == nil or config.priority <= weakest.config.priority then
				counters.dropped += 1
				return nil, "capacity"
			end
			counters.evicted += 1
			finish(weakest.id)
			if closed then
				return nil, "closed_during_cleanup"
			end
			if poisoned then
				return nil, "cleanup_failed"
			end
		end
		local resource = table.remove(idle)
		if resource ~= nil then
			counters.reused += 1
		else
			local ok, value = callback(adapter.create)
			if not ok or value == nil then
				counters.adapterErrors += 1
				return nil, "create_failed"
			end
			resource = value
			allocated += 1
			counters.created += 1
			if closed then
				dispose(resource)
				return nil, "closed_during_create"
			end
		end
		serial += 1
		local id = serial
		active[id] =
			{ id = id, resource = resource, recipe = recipe, config = config, remaining = config.duration }
		local ok = callback(adapter.activate, resource, recipe, table.clone(config), context)
		if not ok then
			counters.adapterErrors += 1
			finish(id)
			return nil, "activate_failed"
		end
		if closed or active[id] == nil then
			return nil, "closed_during_activate"
		end
		local token = { id = id, recipe = recipe }
		function token.cancel(_token): boolean
			return finish(id)
		end
		return token, nil
	end

	function api:cancel(id: number): boolean
		assert(finite(id) and id % 1 == 0 and id > 0, "invalid token id")
		return finish(id)
	end
	function api:step(dt: number): (boolean, string?)
		assert(finite(dt) and dt >= 0, "invalid dt")
		if operationDepth > 0 then
			return false, "operation_in_progress"
		end
		local ids = {}
		for id in active do
			table.insert(ids, id)
		end
		for _, id in ids do
			local entry = active[id]
			if entry ~= nil then
				entry.remaining -= dt
				if entry.remaining <= 0 then
					finish(id)
				elseif adapter.update then
					local alpha = 1 - entry.remaining / entry.config.duration
					local ok = callback(adapter.update, entry.resource, alpha, table.clone(entry.config))
					if not ok then
						counters.adapterErrors += 1
						finish(id)
					end
				end
			end
		end
		return true, nil
	end
	function api:setReducedEffects(enabled: boolean)
		assert(type(enabled) == "boolean", "invalid reduced effects")
		reduced = enabled
		local remove = {}
		for id, entry in active do
			entry.config.reducedEffects = enabled
			if enabled and entry.config.priority < 7 then
				table.insert(remove, id)
			end
		end
		for _, id in remove do
			finish(id)
		end
	end
	function api:stats()
		local result: any = table.clone(counters)
		result.active, result.idle, result.allocated = count(), #idle, allocated
		result.closed, result.reducedEffects = closed, reduced
		result.poisoned = poisoned
		return result
	end
	function api:destroy()
		if closed then
			return
		end
		closed = true
		local ids = {}
		for id in active do
			table.insert(ids, id)
		end
		for _, id in ids do
			finish(id)
		end
		while #idle > 0 do
			dispose(table.remove(idle))
		end
	end
	return api
end

return EffectsPool
