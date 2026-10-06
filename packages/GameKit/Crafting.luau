--!strict
-- @tier T0
-- Crafting: recipes as data and atomic crafting over Inventory (and Wallet for currency costs).
--   { id, inputs = { { item, count } }, outputs = { { item, count, data? } },
--     costs? = { [currency] = amount }, seconds? (craft time per batch, default 0) }
-- validate() checks shapes and item ids, and flags duplication loops in the data: recipes with
-- one input item and one output item form a conversion graph, and any cycle whose ratios multiply
-- to more than 1 (1 a -> 2 b, 1 b -> 1 a) would let players multiply items, so it is refused.
-- craft() is instant and atomic: inputs out, outputs in and costs paid in one two-phase unit
-- (inventory and wallet both prepare, then commit; a failed wallet commit rolls the inventory
-- back). Timed recipes use jobs: start() pays inputs and costs now, complete() adds outputs once
-- ready (server time; UTC seconds when jobs must survive a rejoin), cancel() refunds them.
-- No recipes ship here.
local Check = require("./Check")
local ItemDefs = require("./ItemDefs")

local Crafting = {}
Crafting.__index = Crafting
Crafting.SCHEMA = "crafting/1"
Crafting.REASON = "craft" -- wallet transaction type for costs

export type Stack = { item: string, count: number, data: { [string]: any }? }
export type Recipe = {
	id: string,
	inputs: { Stack },
	outputs: { Stack },
	costs: { [string]: number },
	seconds: number,
}
export type Job = { id: number, recipe: string, times: number, readyAt: number }
export type Options = {
	items: ItemDefs.Registry?,
	maxJobs: number?, -- concurrent timed jobs (default 1, convention)
	maxTimes: number?, -- batch size limit per call (default 100, convention)
	data: any?,
}

local function stacks(
	list: any,
	where: string,
	key: string,
	problems: { string },
	items: ItemDefs.Registry?,
	allowEmpty: boolean
)
	if type(list) ~= "table" or (#list == 0 and not allowEmpty) then
		table.insert(
			problems,
			string.format(
				"%s: %s must be a %slist of { item, count }",
				where,
				key,
				if allowEmpty then "" else "non-empty "
			)
		)
		return
	end
	for index, stack in list do
		if
			type(stack) ~= "table"
			or not Check.label(stack.item)
			or not (Check.integer(stack.count) and stack.count >= 1)
		then
			table.insert(
				problems,
				string.format(
					"%s: %s[%s] needs an item label and an integer count >= 1",
					where,
					key,
					tostring(index)
				)
			)
		elseif items and not items:has(stack.item) then
			table.insert(
				problems,
				string.format("%s: %s[%s] item %s is not defined", where, key, tostring(index), stack.item)
			)
		end
	end
end

-- Duplication loops over single-input, single-output recipes (Bellman-Ford on -log ratio).
local function loops(recipes: { any }): { string }
	local edges = {}
	local nodes: { [string]: boolean } = {}
	for _, recipe in recipes do
		if #recipe.inputs == 1 and #recipe.outputs == 1 then
			local input, output = recipe.inputs[1], recipe.outputs[1]
			table.insert(edges, {
				from = input.item,
				to = output.item,
				weight = -math.log(output.count / input.count),
				recipe = recipe.id,
			})
			nodes[input.item] = true
			nodes[output.item] = true
		end
	end
	local names = {}
	for name in nodes do
		table.insert(names, name)
	end
	table.sort(names)
	local dist: { [string]: number } = {}
	local via: { [string]: any } = {}
	for _, name in names do
		dist[name] = 0
	end
	local updated: string? = nil
	for _ = 1, #names do
		updated = nil
		for _, edge in edges do
			if dist[edge.from] + edge.weight < dist[edge.to] - 1e-9 then
				dist[edge.to] = dist[edge.from] + edge.weight
				via[edge.to] = edge
				updated = edge.to
			end
		end
		if updated == nil then
			return {}
		end
	end
	-- Walk back into the cycle, then collect it.
	local node = updated :: string
	for _ = 1, #names do
		if via[node] == nil then
			return { "recipes form a loop that multiplies an item (duplication)" }
		end
		node = via[node].from
	end
	local cycle, product, start = {}, 1, node
	repeat
		local edge = via[node]
		if edge == nil then
			return { "recipes form a loop that multiplies an item (duplication)" }
		end
		table.insert(cycle, 1, edge.recipe)
		product *= math.exp(-edge.weight)
		node = edge.from
	until node == start or #cycle > #names
	return {
		string.format(
			"recipes %s form a loop that multiplies %s by %.4g (duplication)",
			table.concat(cycle, " -> "),
			start,
			product
		),
	}
end

-- Problems with recipes (empty when valid). Pass the item registry to check item ids.
function Crafting.validate(recipes: any, items: ItemDefs.Registry?): { string }
	if type(recipes) ~= "table" or #recipes == 0 then
		return { "recipes must be a non-empty list" }
	end
	local problems = {}
	local seen = {}
	for index, recipe in recipes do
		local where = "recipe "
			.. (
				if type(recipe) == "table" and type(recipe.id) == "string"
					then recipe.id
					else "#" .. tostring(index)
			)
		if type(recipe) ~= "table" then
			table.insert(problems, where .. ": must be a table")
			continue
		end
		if not Check.label(recipe.id) then
			table.insert(problems, where .. ": id is not a label")
		elseif seen[recipe.id] then
			table.insert(problems, where .. ": duplicate id")
		end
		seen[recipe.id] = true
		stacks(recipe.inputs, where, "inputs", problems, items, true)
		stacks(recipe.outputs, where, "outputs", problems, items, false)
		if recipe.costs ~= nil then
			if type(recipe.costs) ~= "table" then
				table.insert(problems, where .. ": costs must map currency -> amount")
			else
				for currency, amount in recipe.costs do
					if not Check.label(currency) or not (Check.integer(amount) and amount >= 1) then
						table.insert(
							problems,
							where .. ": costs " .. Check.describe(currency) .. " needs an integer amount >= 1"
						)
					end
				end
			end
		end
		if recipe.seconds ~= nil and not (Check.finite(recipe.seconds) and recipe.seconds >= 0) then
			table.insert(problems, where .. ": seconds must be a finite number >= 0")
		end
		if
			type(recipe.inputs) == "table"
			and #recipe.inputs == 0
			and (recipe.costs == nil or next(recipe.costs) == nil)
		then
			table.insert(problems, where .. ": needs inputs or costs (a free recipe is an item faucet)")
		end
		for key in recipe do
			if not table.find({ "id", "inputs", "outputs", "costs", "seconds" }, key) then
				table.insert(problems, where .. ": unknown key " .. Check.describe(key))
			end
		end
	end
	if #problems == 0 then
		for _, problem in loops(recipes) do
			table.insert(problems, problem)
		end
	end
	return problems
end

type CraftingFields = {
	notes: { string },
	_recipes: { [string]: Recipe },
	_order: { string },
	_jobs: { Job },
	_nextJob: number,
	_maxJobs: number,
	_maxTimes: number,
}
export type Crafting = typeof(setmetatable({} :: CraftingFields, Crafting))

-- A crafter for one player (jobs are per player). Raises on invalid recipes.
function Crafting.new(recipes: { any }, options: Options?, _env: any?): Crafting
	local opts: Options = options or {}
	local problems = Crafting.validate(recipes, opts.items)
	if opts.maxJobs ~= nil and not (Check.integer(opts.maxJobs) and opts.maxJobs >= 1) then
		table.insert(problems, "maxJobs must be an integer >= 1")
	end
	if opts.maxTimes ~= nil and not (Check.integer(opts.maxTimes) and opts.maxTimes >= 1) then
		table.insert(problems, "maxTimes must be an integer >= 1")
	end
	if #problems > 0 then
		error("Crafting.new: " .. table.concat(problems, "; "), 2)
	end
	local byId, order = {}, {}
	for _, raw in recipes do
		local recipe: Recipe = {
			id = raw.id,
			inputs = Check.copy(raw.inputs),
			outputs = Check.copy(raw.outputs),
			costs = if raw.costs then table.clone(raw.costs) else {},
			seconds = raw.seconds or 0,
		}
		byId[recipe.id] = Check.freeze(recipe)
		table.insert(order, recipe.id)
	end
	local self = setmetatable({
		notes = {},
		_recipes = byId,
		_order = order,
		_jobs = {},
		_nextJob = 1,
		_maxJobs = opts.maxJobs or 1,
		_maxTimes = opts.maxTimes or 100,
	}, Crafting)
	local data = opts.data
	if data ~= nil then
		if type(data) ~= "table" or data.schema ~= Crafting.SCHEMA then
			table.insert(self.notes, "stored data is not crafting/1; no jobs restored")
		else
			for _, job in data.jobs or {} do
				if
					type(job) == "table"
					and byId[job.recipe]
					and Check.integer(job.id)
					and Check.integer(job.times)
					and job.times >= 1
					and Check.finite(job.readyAt)
				then
					table.insert(
						self._jobs,
						{ id = job.id, recipe = job.recipe, times = job.times, readyAt = job.readyAt }
					)
					self._nextJob = math.max(self._nextJob, job.id + 1)
				else
					table.insert(
						self.notes,
						"dropped invalid or retired job "
							.. Check.describe(type(job) == "table" and job.recipe or job)
					)
				end
			end
			if Check.integer(data.nextJob) and data.nextJob > self._nextJob then
				self._nextJob = data.nextJob
			end
		end
	end
	return self
end

function Crafting.recipe(self: Crafting, id: string): Recipe?
	return self._recipes[id]
end

function Crafting.list(self: Crafting): { Recipe }
	local out = {}
	for _, id in self._order do
		table.insert(out, self._recipes[id])
	end
	return out
end

local function inputOps(recipe: Recipe, times: number): { any }
	local ops = {}
	for _, stack in recipe.inputs do
		table.insert(ops, { op = "remove", item = stack.item, count = stack.count * times })
	end
	return ops
end

local function outputOps(recipe: Recipe, times: number): { any }
	local ops = {}
	for _, stack in recipe.outputs do
		table.insert(ops, { op = "add", item = stack.item, count = stack.count * times, data = stack.data })
	end
	return ops
end

local function costChanges(recipe: Recipe, times: number, sign: number): { any }
	local changes = {}
	local currencies = {}
	for currency in recipe.costs do
		table.insert(currencies, currency)
	end
	table.sort(currencies)
	for _, currency in currencies do
		table.insert(
			changes,
			{ currency = currency, delta = sign * recipe.costs[currency] * times, reason = Crafting.REASON }
		)
	end
	return changes
end

-- Runs inventory ops and wallet changes as one two-phase unit. (ok, reason, inventoryTx).
local function atomic(inventory: any, ops: { any }, wallet: any?, changes: { any }): (boolean, string?, any)
	local invTx, invErr = nil, nil
	if #ops > 0 then
		invTx, invErr = inventory:prepare(ops)
		if invTx == nil then
			return false, invErr, nil
		end
	end
	local walletTx = nil
	if #changes > 0 then
		if wallet == nil then
			return false, "no_wallet", nil
		end
		local err
		walletTx, err = wallet:prepare(changes)
		if walletTx == nil then
			return false, err, nil
		end
	end
	if invTx then
		local ok, err = inventory:commit(invTx)
		if not ok then
			return false, err, nil
		end
	end
	if walletTx and wallet then -- walletTx is only set once wallet was checked
		local ok, err = wallet:commit(walletTx)
		if not ok then
			if invTx then
				inventory:rollback(invTx)
			end
			return false, err, nil
		end
	end
	return true, nil, invTx
end

local function checkTimes(self: Crafting, times: number?): (number?, string?)
	local n = times or 1
	if not (Check.integer(n) and n >= 1 and n <= self._maxTimes) then
		return nil, "invalid_times"
	end
	return n, nil
end

-- Whether craft(recipeId, inventory, wallet, times) would succeed now: (ok, reason).
function Crafting.can(
	self: Crafting,
	recipeId: string,
	inventory: any,
	wallet: any?,
	times: number?
): (boolean, string?)
	local recipe = self._recipes[recipeId]
	if recipe == nil then
		return false, "unknown_recipe"
	end
	local n, err = checkTimes(self, times)
	if n == nil then
		return false, err
	end
	local ops = inputOps(recipe, n)
	if recipe.seconds == 0 then
		for _, op in outputOps(recipe, n) do
			table.insert(ops, op)
		end
	end
	if #ops > 0 then
		local ok, reason = inventory:canApply(ops)
		if not ok then
			return false, reason
		end
	end
	local changes = costChanges(recipe, n, -1)
	if #changes > 0 then
		if wallet == nil then
			return false, "no_wallet"
		end
		return wallet:canTransact(changes)
	end
	return true, nil
end

-- Crafts an instant recipe times times: (true, nil, { created = uids }) or (false, reason) with
-- unknown_recipe, timed_recipe (use start), invalid_times, an Inventory or Wallet error.
function Crafting.craft(
	self: Crafting,
	recipeId: string,
	inventory: any,
	wallet: any?,
	times: number?
): (boolean, string?, any)
	local recipe = self._recipes[recipeId]
	if recipe == nil then
		return false, "unknown_recipe", nil
	end
	if recipe.seconds > 0 then
		return false, "timed_recipe", nil
	end
	local n, err = checkTimes(self, times)
	if n == nil then
		return false, err, nil
	end
	local ops = inputOps(recipe, n)
	for _, op in outputOps(recipe, n) do
		table.insert(ops, op)
	end
	local ok, reason, tx = atomic(inventory, ops, wallet, costChanges(recipe, n, -1))
	if not ok then
		return false, reason, nil
	end
	return true, nil, { created = if tx then tx.created else {} }
end

-- Starts a timed job at now: inputs and costs are paid now. (true, nil, job) or (false, reason)
-- with jobs_full besides craft's reasons.
function Crafting.start(
	self: Crafting,
	recipeId: string,
	inventory: any,
	wallet: any?,
	now: number,
	times: number?
): (boolean, string?, Job?)
	local recipe = self._recipes[recipeId]
	if recipe == nil then
		return false, "unknown_recipe", nil
	end
	assert(Check.finite(now), "Crafting.start needs a finite time")
	local n, err = checkTimes(self, times)
	if n == nil then
		return false, err, nil
	end
	if #self._jobs >= self._maxJobs then
		return false, "jobs_full", nil
	end
	local ok, reason = atomic(inventory, inputOps(recipe, n), wallet, costChanges(recipe, n, -1))
	if not ok then
		return false, reason, nil
	end
	local job: Job = { id = self._nextJob, recipe = recipe.id, times = n, readyAt = now + recipe.seconds * n }
	self._nextJob += 1
	table.insert(self._jobs, job)
	return true, nil, table.clone(job)
end

local function findJob(self: Crafting, jobId: number): (number?, Job?)
	for index, job in self._jobs do
		if job.id == jobId then
			return index, job
		end
	end
	return nil, nil
end

-- Completes a ready job: outputs go to the inventory. (true, nil, { created }) or (false,
-- reason) with unknown_job, not_ready (third value: seconds left) or an Inventory error (the job
-- stays, e.g. no_space).
function Crafting.complete(
	self: Crafting,
	jobId: number,
	inventory: any,
	now: number
): (boolean, string?, any)
	local index, job = findJob(self, jobId)
	if index == nil or job == nil then
		return false, "unknown_job", nil
	end
	if now < job.readyAt then
		return false, "not_ready", job.readyAt - now
	end
	local recipe = self._recipes[job.recipe]
	local ok, reason, info = inventory:apply(outputOps(recipe, job.times))
	if not ok then
		return false, reason, nil
	end
	table.remove(self._jobs, index)
	return true, nil, { created = info.created }
end

-- Cancels a job and refunds its inputs and costs atomically. (ok, reason).
function Crafting.cancel(self: Crafting, jobId: number, inventory: any, wallet: any?): (boolean, string?)
	local index, job = findJob(self, jobId)
	if index == nil or job == nil then
		return false, "unknown_job"
	end
	local recipe = self._recipes[job.recipe]
	local refunds = {}
	for _, stack in recipe.inputs do
		table.insert(refunds, { op = "add", item = stack.item, count = stack.count * job.times })
	end
	local ok, reason = atomic(inventory, refunds, wallet, costChanges(recipe, job.times, 1))
	if not ok then
		return false, reason
	end
	table.remove(self._jobs, index)
	return true, nil
end

function Crafting.jobs(self: Crafting): { Job }
	return Check.copy(self._jobs)
end

function Crafting.serialize(self: Crafting): any
	return { schema = Crafting.SCHEMA, jobs = Check.copy(self._jobs), nextJob = self._nextJob }
end

return Crafting
