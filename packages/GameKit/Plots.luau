--!strict
-- @tier T0
-- Plots: per-server plot ownership for tycoon, base-building and garden games. Plots are data
-- ({ id, bounds = { min = {x,y,z}, max = {x,y,z} }, order? }) validated for unique ids, proper
-- boxes and no overlaps. claim(owner, preferred?) is deterministic: the preferred plot when it
-- is free (else, with fallback, the next by policy), one plot per owner, idempotent for an owner
-- who already holds one. Assignment policies: "ordered" (order, then id), "seeded" (a fixed
-- permutation from the seed, so every server with the same seed hands plots out alike) and
-- "nearest" (closest free plot centre to claim's near position). Calls never yield, so racing
-- claims resolve in call order; probe economy_plots_claim_race checks that on a real server.
-- Lookups: ownerOf, plotOf, at(position). No plot layout ships here (ProcGen/SceneKit build it).
local Check = require("./Check")
local Rng = require("../ProcGen/Rng")
local Signal = require("./Signal")

local Plots = {}
Plots.__index = Plots
Plots.ASSIGN = table.freeze({ "ordered", "seeded", "nearest" })

export type V3 = { x: number, y: number, z: number }
export type PlotDef = { id: string, bounds: { min: V3, max: V3 }, order: number? }
export type Options = {
	plots: { PlotDef },
	assign: ("ordered" | "seeded" | "nearest")?,
	seed: (number | string)?,
	fallback: boolean?, -- a taken preferred plot falls back to the policy (default true)
}

local function vec(value: any): boolean
	return type(value) == "table"
		and Check.finite(value.x)
		and Check.finite(value.y)
		and Check.finite(value.z)
end

local function overlaps(a: PlotDef, b: PlotDef): boolean
	local amin, amax, bmin, bmax = a.bounds.min, a.bounds.max, b.bounds.min, b.bounds.max
	return amin.x < bmax.x
		and bmin.x < amax.x
		and amin.y < bmax.y
		and bmin.y < amax.y
		and amin.z < bmax.z
		and bmin.z < amax.z
end

-- Problems with plot definitions (empty when valid): ids, boxes, order, overlaps.
function Plots.validate(plots: any): { string }
	if type(plots) ~= "table" or #plots == 0 then
		return { "plots must be a non-empty list" }
	end
	local problems = {}
	local seen: { [string]: boolean } = {}
	local good = {}
	for index, plot in plots do
		local where = "plot "
			.. (
				if type(plot) == "table" and type(plot.id) == "string"
					then plot.id
					else "#" .. tostring(index)
			)
		if type(plot) ~= "table" then
			table.insert(problems, where .. ": must be a table")
			continue
		end
		if not Check.label(plot.id) then
			table.insert(problems, where .. ": id is not a label")
		elseif seen[plot.id] then
			table.insert(problems, where .. ": duplicate id")
		end
		seen[plot.id] = true
		local bounds = plot.bounds
		if type(bounds) ~= "table" or not vec(bounds.min) or not vec(bounds.max) then
			table.insert(problems, where .. ": bounds needs min and max vectors of finite numbers")
		elseif
			not (bounds.min.x < bounds.max.x and bounds.min.y < bounds.max.y and bounds.min.z < bounds.max.z)
		then
			table.insert(problems, where .. ": bounds min must be below max on every axis")
		else
			table.insert(good, plot)
		end
		if plot.order ~= nil and not Check.integer(plot.order) then
			table.insert(problems, where .. ": order must be an integer")
		end
	end
	for i = 1, #good do
		for j = i + 1, #good do
			if overlaps(good[i], good[j]) then
				table.insert(
					problems,
					string.format("plots %s and %s overlap", tostring(good[i].id), tostring(good[j].id))
				)
			end
		end
	end
	return problems
end

type PlotsFields = {
	claimed: Signal.Signal,
	released: Signal.Signal,
	_plots: { PlotDef },
	_byId: { [string]: PlotDef },
	_sequence: { string },
	_owners: { [string]: string }, -- plot id -> owner
	_plotOf: { [string]: string }, -- owner -> plot id
	_assign: string,
	_fallback: boolean,
}
export type Plots = typeof(setmetatable({} :: PlotsFields, Plots))

-- A plot registry for one server. Raises on invalid options.
function Plots.new(options: Options, env: any?): Plots
	assert(type(options) == "table", "Plots.new: options must be a table")
	local problems = Plots.validate(options.plots)
	local assign = options.assign or "ordered"
	if not table.find(Plots.ASSIGN, assign) then
		table.insert(problems, "assign must be ordered, seeded or nearest")
	end
	if assign == "seeded" and options.seed == nil then
		table.insert(problems, "assign seeded needs a seed")
	end
	if #problems > 0 then
		error("Plots.new: " .. table.concat(problems, "; "), 2)
	end
	local list = {}
	local byId = {}
	for _, plot in options.plots do
		local copy = Check.freeze(Check.copy(plot))
		table.insert(list, copy)
		byId[copy.id] = copy
	end
	table.sort(list, function(a: PlotDef, b: PlotDef): boolean
		local oa, ob = a.order or 0, b.order or 0
		if oa ~= ob then
			return oa < ob
		end
		return a.id < b.id
	end)
	local sequence = {}
	for _, plot in list do
		table.insert(sequence, plot.id)
	end
	if assign == "seeded" then
		local rng = if env and type(env.rng) == "function"
			then env.rng(options.seed)
			else Rng.new(options.seed :: any)
		rng:shuffle(sequence)
	end
	return setmetatable({
		claimed = Signal.new(env),
		released = Signal.new(env),
		_plots = list,
		_byId = byId,
		_sequence = sequence,
		_owners = {},
		_plotOf = {},
		_assign = assign,
		_fallback = options.fallback ~= false,
	}, Plots)
end

local function center(plot: PlotDef): V3
	local min, max = plot.bounds.min, plot.bounds.max
	return { x = (min.x + max.x) / 2, y = (min.y + max.y) / 2, z = (min.z + max.z) / 2 }
end

local function pick(self: Plots, near: V3?): string?
	if self._assign == "nearest" and near and vec(near) then
		local best, bestDistance = nil, math.huge
		for _, id in self._sequence do
			if self._owners[id] == nil then
				local c = center(self._byId[id])
				local d = (c.x - near.x) ^ 2 + (c.y - near.y) ^ 2 + (c.z - near.z) ^ 2
				if d < bestDistance then
					best, bestDistance = id, d
				end
			end
		end
		return best
	end
	for _, id in self._sequence do
		if self._owners[id] == nil then
			return id
		end
	end
	return nil
end

-- Claims a plot for owner (an opaque player key). Returns (true, plotId) — the owner's current
-- plot when they already hold one — or (false, reason) with invalid_owner, unknown_plot, taken
-- (preferred plot held and fallback off) or full. opts.near is the position for "nearest".
function Plots.claim(self: Plots, owner: string, preferred: string?, opts: { near: V3? }?): (boolean, string)
	if type(owner) ~= "string" or #owner == 0 or #owner > 64 then
		return false, "invalid_owner"
	end
	local held = self._plotOf[owner]
	if held then
		return true, held
	end
	local id: string? = nil
	if preferred ~= nil then
		if self._byId[preferred] == nil then
			return false, "unknown_plot"
		end
		if self._owners[preferred] == nil then
			id = preferred
		elseif not self._fallback then
			return false, "taken"
		end
	end
	if id == nil then
		id = pick(self, opts and opts.near)
	end
	if id == nil then
		return false, "full"
	end
	self._owners[id :: string] = owner
	self._plotOf[owner] = id :: string
	self.claimed:Fire(id, owner)
	return true, id :: string
end

-- Releases owner's plot (PlayerRemoving). Returns (true, plotId) or (false, "not_owner").
function Plots.release(self: Plots, owner: string): (boolean, string?)
	local id = self._plotOf[owner]
	if id == nil then
		return false, "not_owner"
	end
	self._plotOf[owner] = nil
	self._owners[id] = nil
	self.released:Fire(id, owner)
	return true, id
end

function Plots.ownerOf(self: Plots, plotId: string): string?
	return self._owners[plotId]
end

function Plots.plotOf(self: Plots, owner: string): string?
	return self._plotOf[owner]
end

-- The plot whose bounds contain position (inclusive), or nil.
function Plots.at(self: Plots, position: V3): string?
	if not vec(position) then
		return nil
	end
	for _, plot in self._plots do
		local min, max = plot.bounds.min, plot.bounds.max
		if
			position.x >= min.x
			and position.x <= max.x
			and position.y >= min.y
			and position.y <= max.y
			and position.z >= min.z
			and position.z <= max.z
		then
			return plot.id
		end
	end
	return nil
end

-- Whether position is inside owner's plot (build permission checks).
function Plots.owns(self: Plots, owner: string, position: V3): boolean
	local id = self:at(position)
	return id ~= nil and self._owners[id] == owner
end

function Plots.get(self: Plots, plotId: string): PlotDef?
	return self._byId[plotId]
end

-- Free plot ids in assignment order.
function Plots.free(self: Plots): { string }
	local out = {}
	for _, id in self._sequence do
		if self._owners[id] == nil then
			table.insert(out, id)
		end
	end
	return out
end

-- Plot id -> owner for every claimed plot.
function Plots.snapshot(self: Plots): { [string]: string }
	return table.clone(self._owners)
end

function Plots.count(self: Plots): number
	return #self._plots
end

return Plots
