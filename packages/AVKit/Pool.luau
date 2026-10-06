--!strict
-- @tier T0
-- Pool: bounded, priority-admitted ownership of reusable effect resources. Moved from
-- Creator/EffectsPool (which now re-exports this module) and opened up for general use:
--   * legacy mode (no options.fields): the three neutral recipes telegraph/impact/reward with the
--     five numeric fields; options.recipes may only override them (unchanged behaviour);
--   * open mode (options.fields): the caller defines the field schema
--     ({ [field] = { min, max, integer?, default? } }) and the full recipe set; every recipe is
--     validated against it (Pool.validateRecipes lists problems);
--   * keyed (options.keyed = true): idle resources are reused only for the recipe that made them
--     (template clones, as AVKit/VfxPoolRoblox uses); a full pool frees another recipe's idle
--     resource before creating one.
-- Adapter: create(recipe, config) -> resource, activate(resource, recipe, config, context),
-- reset(resource), destroy(resource), optional update(resource, alpha, config). Callbacks must
-- not yield. A destructor that fails poisons the pool (no unbounded growth). Under reduced
-- effects, recipes below reducedThreshold (default 7) are refused and options.reduce (default:
-- particleCount = 0) adjusts the rest. step(dt) never yields. expire(id, seconds) shortens an
-- active entry (a stopped loop lingers while its particles fade); remaining(id) reads it.
local Pool = {}

export type FieldSpec = { min: number, max: number, integer: boolean?, default: number? }

Pool.DEFAULT_FIELDS = table.freeze({
	duration = table.freeze({ min = 0.01, max = 5 }),
	priority = table.freeze({ min = 0, max = 10, integer = true }),
	radius = table.freeze({ min = 0.05, max = 32 }),
	width = table.freeze({ min = 0.01, max = 2 }),
	particleCount = table.freeze({ min = 0, max = 48, integer = true }),
})
Pool.DEFAULT_RECIPES = table.freeze({
	telegraph = table.freeze({ duration = 0.8, priority = 8, radius = 1, width = 0.08, particleCount = 0 }),
	impact = table.freeze({ duration = 0.3, priority = 5, radius = 0.5, width = 0.15, particleCount = 12 }),
	reward = table.freeze({ duration = 0.7, priority = 2, radius = 0.4, width = 0.08, particleCount = 8 }),
})
Pool.REDUCED_THRESHOLD = 7

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- Error message per field, kept from the inherited pool so its specs and callers see the same text.
local LEGACY_MESSAGES = {
	duration = "invalid duration",
	priority = "invalid priority",
	radius = "invalid radius",
	width = "invalid width",
	particleCount = "invalid particle count",
}

local function fieldProblem(name: string, spec: FieldSpec, value: any): string?
	if
		not finite(value)
		or value < spec.min
		or value > spec.max
		or (spec.integer == true and value % 1 ~= 0)
	then
		return LEGACY_MESSAGES[name] or ("invalid " .. name)
	end
	return nil
end

local function validateFields(fields: any): { string }
	local problems = {}
	if type(fields) ~= "table" then
		return { "fields must be a table" }
	end
	for name, spec in fields do
		if type(name) ~= "string" or type(spec) ~= "table" then
			table.insert(problems, "field " .. tostring(name) .. " must map a name to { min, max }")
		elseif not (finite(spec.min) and finite(spec.max) and spec.min <= spec.max) then
			table.insert(problems, "field " .. name .. " needs finite min <= max")
		elseif spec.default ~= nil and fieldProblem(name, spec, spec.default) then
			table.insert(problems, "field " .. name .. " default is out of range")
		end
	end
	if fields.duration == nil or fields.priority == nil then
		table.insert(problems, "fields need duration and priority")
	end
	return problems
end

-- Problems with a recipe table against a field schema (empty when valid). Unknown fields, missing
-- fields without a default, and out-of-range values are problems.
function Pool.validateRecipes(recipes: any, fields: any): { string }
	local problems = validateFields(fields)
	if #problems > 0 then
		return problems
	end
	if type(recipes) ~= "table" then
		return { "recipes must be a table" }
	end
	local names = {}
	for name in recipes do
		table.insert(names, tostring(name))
	end
	table.sort(names)
	if #names == 0 then
		table.insert(problems, "recipes must not be empty")
	end
	for _, name in names do
		local recipe = recipes[name]
		if string.match(name, "^[a-z][a-z0-9_]*$") == nil or #name > 64 then
			table.insert(problems, "recipe " .. name .. " needs a lower_snake name")
		end
		if type(recipe) ~= "table" then
			table.insert(problems, "recipe " .. name .. " must be a table")
			continue
		end
		for key, value in recipe do
			local spec = fields[key]
			if spec == nil then
				table.insert(problems, "recipe " .. name .. ": unknown recipe field " .. tostring(key))
			else
				local problem = fieldProblem(key, spec, value)
				if problem then
					table.insert(problems, "recipe " .. name .. ": " .. problem)
				end
			end
		end
		for key, spec in fields do
			if recipe[key] == nil and spec.default == nil then
				table.insert(problems, "recipe " .. name .. ": missing " .. key)
			end
		end
	end
	return problems
end

local function normalize(recipe: string, overrides: any, recipes: any, fields: any): any
	local definition = recipes[recipe]
	assert(definition ~= nil, "unknown recipe")
	assert(overrides == nil or type(overrides) == "table", "invalid overrides")
	local config: any = table.clone(definition)
	for key, value in overrides or {} do
		assert(fields[key] ~= nil, "unknown recipe field")
		config[key] = value
	end
	-- Legacy order of checks (duration, priority, radius, width, particleCount), then the rest.
	local order = { "duration", "priority", "radius", "width", "particleCount" }
	local extra = {}
	for key in fields do
		if not table.find(order, key) then
			table.insert(extra, key)
		end
	end
	table.sort(extra)
	for _, key in extra do
		table.insert(order, key)
	end
	for _, key in order do
		local spec = fields[key]
		if spec ~= nil then
			if config[key] == nil and spec.default ~= nil then
				config[key] = spec.default
			end
			local problem = fieldProblem(key, spec, config[key])
			assert(problem == nil, problem)
		end
	end
	return config
end

type Entry = {
	id: number,
	resource: any,
	recipe: string,
	config: any,
	remaining: number,
}

function Pool.new(adapter: any, options: any?)
	assert(options == nil or type(options) == "table", "invalid pool options")
	options = options or {}
	local allowedOptions = {
		capacity = true,
		reducedEffects = true,
		recipes = true,
		fields = true,
		keyed = true,
		reducedThreshold = true,
		reduce = true,
	}
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
	assert(options.keyed == nil or type(options.keyed) == "boolean", "invalid keyed option")
	local threshold = if options.reducedThreshold == nil
		then Pool.REDUCED_THRESHOLD
		else options.reducedThreshold
	assert(finite(threshold), "invalid reduced threshold")
	assert(options.reduce == nil or type(options.reduce) == "function", "invalid reduce callback")
	local reduce = options.reduce
		or function(config: any)
			if config.particleCount ~= nil then
				config.particleCount = 0
			end
		end
	local fields: any
	local recipes: any = {}
	assert(options.recipes == nil or type(options.recipes) == "table", "invalid recipes")
	if options.fields ~= nil then
		local problems = Pool.validateRecipes(options.recipes, options.fields)
		assert(#problems == 0, table.concat(problems, "; "))
		fields = table.clone(options.fields)
		for name, recipe in options.recipes do
			recipes[name] = normalize(name, nil, { [name] = recipe }, fields)
		end
	else
		fields = Pool.DEFAULT_FIELDS
		for name in options.recipes or {} do
			assert(Pool.DEFAULT_RECIPES[name] ~= nil, "unknown configured recipe")
		end
		for name in Pool.DEFAULT_RECIPES do
			recipes[name] = normalize(name, (options.recipes or {})[name], Pool.DEFAULT_RECIPES, fields)
		end
	end
	local keyed = options.keyed == true
	local active: { [number]: Entry } = {}
	local idle: { [string]: { any } } = {}
	local serial, allocated, operationDepth = 0, 0, 0
	local reduced = options.reducedEffects == true
	local closed, poisoned = false, false
	local counters =
		{ created = 0, reused = 0, dropped = 0, evicted = 0, cleanupErrors = 0, adapterErrors = 0 }
	local api: any = {}

	local function idleList(key: string): { any }
		local list = idle[key]
		if list == nil then
			list = {}
			idle[key] = list
		end
		return list
	end
	local function idleCount(): number
		local total = 0
		for _, list in idle do
			total += #list
		end
		return total
	end
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
			table.insert(idleList(if keyed then entry.recipe else "*"), entry.resource)
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
	-- Keyed pools: dispose one idle resource of another recipe to make room (oldest key first).
	local function freeOtherIdle(key: string): boolean
		local keys = {}
		for other, list in idle do
			if other ~= key and #list > 0 then
				table.insert(keys, other)
			end
		end
		table.sort(keys)
		if #keys == 0 then
			return false
		end
		dispose(table.remove(idle[keys[1]], 1))
		return true
	end

	function api:emit(recipe: string, overrides: any?, context: any?): (any?, string?)
		local config = normalize(recipe, overrides, recipes, fields)
		if closed then
			return nil, "closed"
		end
		if poisoned then
			return nil, "cleanup_failed"
		end
		if operationDepth > 0 then
			return nil, "operation_in_progress"
		end
		if reduced and config.priority < threshold then
			counters.dropped += 1
			return nil, "reduced_effects"
		end
		config.reducedEffects = reduced
		if reduced then
			reduce(config)
		end
		local key = if keyed then recipe else "*"
		if #idleList(key) == 0 and allocated >= capacity and keyed then
			freeOtherIdle(key)
			if poisoned then
				return nil, "cleanup_failed"
			end
		end
		if #idleList(key) == 0 and allocated >= capacity then
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
			if keyed and #idleList(key) == 0 then
				freeOtherIdle(key)
				if poisoned then
					return nil, "cleanup_failed"
				end
			end
		end
		local resource = table.remove(idleList(key))
		if resource ~= nil then
			counters.reused += 1
		else
			local ok, value = callback(adapter.create, recipe, table.clone(config))
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
	-- Shortens an active entry so it ends within `seconds` (never extends it): a stopped loop
	-- keeps its resource while its last particles fade. 0 ends it on the next step.
	function api:expire(id: number, seconds: number): boolean
		assert(finite(id) and id % 1 == 0 and id > 0, "invalid token id")
		assert(finite(seconds) and seconds >= 0, "invalid expiry")
		local entry = active[id]
		if entry == nil then
			return false
		end
		entry.remaining = math.min(entry.remaining, seconds)
		return true
	end
	function api:remaining(id: number): number?
		local entry = active[id]
		return if entry then entry.remaining else nil
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
		table.sort(ids)
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
			if enabled and entry.config.priority < threshold then
				table.insert(remove, id)
			end
		end
		table.sort(remove)
		for _, id in remove do
			finish(id)
		end
	end
	function api:recipes(): { string }
		local names = {}
		for name in recipes do
			table.insert(names, name)
		end
		table.sort(names)
		return names
	end
	function api:stats()
		local result: any = table.clone(counters)
		result.active, result.idle, result.allocated = count(), idleCount(), allocated
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
		table.sort(ids)
		for _, id in ids do
			finish(id)
		end
		local keys = {}
		for key in idle do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in keys do
			local list = idle[key]
			while #list > 0 do
				dispose(table.remove(list))
			end
		end
	end
	return api
end

return Pool
