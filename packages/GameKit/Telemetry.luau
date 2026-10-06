--!strict
-- @tier T0
-- Telemetry: the server's kit-event/1 gate in front of a sink (TelemetryRoblox.live in a
-- published game, TelemetryRoblox.recorder in Studio, Events.recorder in Lune). Every event is
-- validated (GameKit/Events), checked against Roblox's AnalyticsService limits before Roblox
-- would silently bucket it as "Other" (100 custom names, 10 funnels of 100 steps, the 10 most
-- recent funnel sessions per player and funnel, 5 currencies, 20 transaction types, 3 string
-- fields), checked for step order (funnels and onboarding), optionally checked against a
-- declared catalog, metered by a per-server budget, and then emitted. Analytics never breaks
-- gameplay: rejects return (false, reason) and are counted (strict mode raises, for specs),
-- sink errors are caught and reported. Telemetry is itself a sink (emit), so producers that
-- take a sink accept it. Emit economy events after the durable write (docs/runtime-kits.md).
-- Conventions: the budget default (per server) and the 64-character field values.
local Check = require("./Check")
local Events = require("./Events")
local RateLimit = require("./RateLimit")

local Telemetry = {}

Telemetry.DEFAULT_BUDGET = table.freeze({ capacity = 120, refillPerSec = 2 }) -- convention, per server
Telemetry.FUNNEL_SESSIONS = 10 -- Roblox tracks the 10 most recent funnelSessionIds per user per funnel
Telemetry.FIELD_VALUES = 8000 -- Roblox: combined values across the three custom fields
Telemetry.FIELD_WARN_RATIO = 0.8
Telemetry.PURCHASE_PREFIX = "purchase_" -- purchase_intent events count as custom names purchase_<stage>
Telemetry.REASONS = table.freeze({
	"invalid", -- not a kit-event/1 record (Events.validate)
	"undeclared_name", -- catalog given and the custom event or funnel is not in it
	"undeclared_field", -- a field the catalog does not declare for this custom event
	"unknown_currency",
	"unknown_transaction_type",
	"unknown_path",
	"too_many_custom_names",
	"too_many_funnels",
	"too_many_currencies",
	"too_many_transaction_types",
	"step_mismatch", -- step number and name disagree with the catalog order
	"funnel_not_started", -- a step after 1 in a funnel session never started (or evicted)
	"funnel_repeat", -- the same step again (Roblox counts it once)
	"funnel_out_of_order", -- a step before the last one in the session
	"funnel_skipped", -- a gap, only with allowGaps = false
	"onboarding_not_started",
	"onboarding_repeat",
	"onboarding_out_of_order",
	"budget", -- over the per-server budget: dropped
	"sink_error", -- the sink raised
	"sink_rejected", -- the sink returned false
})
-- Reasons that are a caller's mistake (strict mode raises on these, never on budget or sink).
local CALLER_ERRORS: { [string]: boolean } = {}
for _, reason in Telemetry.REASONS do
	if reason ~= "budget" and reason ~= "sink_error" and reason ~= "sink_rejected" then
		CALLER_ERRORS[reason] = true
	end
end

export type Catalog = {
	custom: { [string]: { fields: { string }? } }?, -- <= 100 names; <= 3 declared fields each
	onboarding: { string }?, -- ordered onboarding step names (<= 100)
	funnels: { [string]: { steps: { string } } }?, -- <= 10 funnels of <= 100 steps
	economy: { currencies: { string }, transactionTypes: { string }? }?, -- <= 5 currencies, <= 20 types
	progression: { [string]: boolean }?, -- declared path names
}

export type Options = {
	sink: Events.Sink,
	catalog: Catalog?,
	envelope: Events.Envelope?, -- stamped on every event (environment, synthetic)
	strict: boolean?, -- raise on caller errors (specs)
	budget: ({ capacity: number, refillPerSec: number } | false)?,
	allowGaps: boolean?, -- funnel and onboarding steps may skip ahead (default true)
	newId: (() -> string)?, -- funnel session ids (default: hex ids from env.rng())
}

local function count(map: { [any]: any }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

local function unique(list: { any }): boolean
	local seen = {}
	for _, item in list do
		if seen[item] then
			return false
		end
		seen[item] = true
	end
	return true
end

-- Problems with a catalog (empty when valid).
function Telemetry.validateCatalog(catalog: any): { string }
	if catalog == nil then
		return {}
	end
	if type(catalog) ~= "table" then
		return { "catalog must be a table" }
	end
	local problems = {}
	local function problem(text: string, ...: any)
		table.insert(problems, string.format(text, ...))
	end
	local limits = Events.LIMITS
	if catalog.custom ~= nil then
		if type(catalog.custom) ~= "table" then
			problem("custom must map names to { fields }")
		else
			if count(catalog.custom) > limits.customNames then
				problem("custom declares %d names (at most %d)", count(catalog.custom), limits.customNames)
			end
			for name, spec in catalog.custom do
				if not Check.label(name, limits.nameLength) then
					problem("custom name %s is not a label", Check.describe(name))
				elseif string.sub(name, 1, #Telemetry.PURCHASE_PREFIX) == Telemetry.PURCHASE_PREFIX then
					problem("custom name %s uses the reserved purchase_ prefix", name)
				end
				local fields = type(spec) == "table" and spec.fields
				if fields ~= nil and fields ~= false then
					if type(fields) ~= "table" or #fields > limits.fields or not unique(fields) then
						problem(
							"custom %s: fields must be at most %d unique labels",
							tostring(name),
							limits.fields
						)
					else
						for _, field in fields do
							if not Check.label(field) then
								problem(
									"custom %s: field %s is not a label",
									tostring(name),
									Check.describe(field)
								)
							end
						end
					end
				end
			end
		end
	end
	local function steps(list: any, where: string)
		if type(list) ~= "table" or #list < 1 or #list > limits.funnelSteps or not unique(list) then
			problem("%s must list 1 to %d unique step names", where, limits.funnelSteps)
			return
		end
		for _, step in list do
			if not Check.label(step) then
				problem("%s: step %s is not a label", where, Check.describe(step))
			end
		end
	end
	if catalog.onboarding ~= nil then
		steps(catalog.onboarding, "onboarding")
	end
	if catalog.funnels ~= nil then
		if type(catalog.funnels) ~= "table" then
			problem("funnels must map names to { steps }")
		else
			if count(catalog.funnels) > limits.funnels then
				problem("funnels declares %d funnels (at most %d)", count(catalog.funnels), limits.funnels)
			end
			for name, spec in catalog.funnels do
				if not Check.label(name) then
					problem("funnel name %s is not a label", Check.describe(name))
				end
				steps(type(spec) == "table" and spec.steps, "funnel " .. tostring(name))
			end
		end
	end
	local economy = catalog.economy
	if economy ~= nil then
		local currencies = type(economy) == "table" and economy.currencies
		if
			type(currencies) ~= "table"
			or #currencies < 1
			or #currencies > limits.currencies
			or not unique(currencies)
		then
			problem("economy.currencies must list 1 to %d unique labels", limits.currencies)
		else
			for _, currency in currencies do
				if not Check.label(currency) then
					problem("economy currency %s is not a label", Check.describe(currency))
				end
			end
		end
		local types = type(economy) == "table" and economy.transactionTypes
		if types ~= nil then
			if type(types) ~= "table" or #types > limits.transactionTypes or not unique(types) then
				problem("economy.transactionTypes must list at most %d unique types", limits.transactionTypes)
			else
				for _, kind in types do
					if not (table.find(Events.TRANSACTION_TYPES, kind) or Check.label(kind)) then
						problem(
							"economy transaction type %s is not standard or a label",
							Check.describe(kind)
						)
					end
				end
			end
		end
	end
	if catalog.progression ~= nil then
		if type(catalog.progression) ~= "table" then
			problem("progression must map path names to true")
		else
			for path in catalog.progression do
				if not Check.label(path) then
					problem("progression path %s is not a label", Check.describe(path))
				end
			end
		end
	end
	return problems
end

local Api = {}
Api.__index = Api

type FunnelSession = { id: string, last: number }
type ApiFields = {
	_sink: Events.Sink,
	_catalog: Catalog?,
	_envelope: Events.Envelope?,
	_strict: boolean,
	_allowGaps: boolean,
	_limiter: any,
	_newId: () -> string,
	_env: any,
	_customNames: { [string]: boolean },
	_funnels: { [string]: boolean },
	_currencies: { [string]: boolean },
	_transactionTypes: { [string]: boolean },
	_fieldValues: { [string]: boolean },
	_fieldValueCount: number,
	_fieldWarned: boolean,
	_funnelSessions: { [string]: { FunnelSession } },
	_onboarding: { [string]: number },
	_accepted: number,
	_rejected: { [string]: number },
	_sinkReports: number,
}
export type Telemetry = typeof(setmetatable({} :: ApiFields, Api))

local function zeroClock(): number
	return 0
end

-- Problems with options (empty when valid).
function Telemetry.validate(options: any): { string }
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	local problems = {}
	local sink = options.sink
	if type(sink) ~= "table" or type(sink.emit) ~= "function" then
		table.insert(problems, "sink must have emit(event) (Events.recorder, TelemetryRoblox.live, ...)")
	end
	for _, problem in Telemetry.validateCatalog(options.catalog) do
		table.insert(problems, "catalog: " .. problem)
	end
	local budget = options.budget
	if budget ~= nil and budget ~= false then
		if type(budget) ~= "table" then
			table.insert(problems, "budget must be { capacity, refillPerSec } or false")
		else
			local probe =
				{ capacity = budget.capacity, refillPerSec = budget.refillPerSec, clock = zeroClock }
			for _, problem in RateLimit.validate(probe) do
				table.insert(problems, "budget: " .. problem)
			end
		end
	end
	if options.newId ~= nil and type(options.newId) ~= "function" then
		table.insert(problems, "newId must be a function")
	end
	return problems
end

function Telemetry.new(options: Options, env: any): Telemetry
	local problems = Telemetry.validate(options)
	if env == nil or type(env.clock) ~= "function" or type(env.report) ~= "function" then
		table.insert(problems, "env with clock and report is required")
	end
	if #problems > 0 then
		error("Telemetry.new: " .. table.concat(problems, "; "), 2)
	end
	local limiter = nil
	if options.budget ~= false then
		local budget: any = options.budget or Telemetry.DEFAULT_BUDGET
		limiter = RateLimit.new(
			{ capacity = budget.capacity, refillPerSec = budget.refillPerSec, maxKeys = 1 },
			env
		)
	end
	local newId = options.newId
	if newId == nil then
		local rng: any = nil
		newId = function(): string
			rng = rng or env.rng()
			return string.format("fs_%08x%08x", rng:int(0, 0x7fffffff), rng:int(0, 0x7fffffff))
		end
	end
	local self = setmetatable({
		_sink = options.sink,
		_catalog = options.catalog,
		_envelope = options.envelope,
		_strict = options.strict == true,
		_allowGaps = options.allowGaps ~= false,
		_limiter = limiter,
		_newId = newId :: () -> string,
		_env = env,
		_customNames = {},
		_funnels = {},
		_currencies = {},
		_transactionTypes = {},
		_fieldValues = {},
		_fieldValueCount = 0,
		_fieldWarned = false,
		_funnelSessions = {},
		_onboarding = {},
		_accepted = 0,
		_rejected = {},
		_sinkReports = 0,
	}, Api)
	-- declared names are part of the cardinality from the start
	local catalog = options.catalog
	if catalog then
		for name in catalog.custom or {} do
			self._customNames[name] = true
		end
		for name in catalog.funnels or {} do
			self._funnels[name] = true
		end
		for _, currency in (catalog.economy and catalog.economy.currencies) or {} do
			self._currencies[currency] = true
		end
	end
	return self
end

-- The opaque player key used in events: tostring(UserId) for a Player, or the given key.
function Telemetry.keyOf(player: any): string?
	if type(player) == "string" then
		return player
	elseif type(player) == "number" then
		return tostring(player)
	elseif player ~= nil and (type(player) == "table" or type(player) == "userdata") then
		local ok, userId = pcall(function(): any
			return player.UserId
		end)
		if ok and type(userId) == "number" then
			return tostring(userId)
		end
	end
	return nil
end

local function reject(self: Telemetry, reason: string, detail: string?): (boolean, string?)
	self._rejected[reason] = (self._rejected[reason] or 0) + 1
	if self._strict and CALLER_ERRORS[reason] then
		error(string.format("Telemetry: %s%s", reason, if detail then " (" .. detail .. ")" else ""), 3)
	end
	return false, reason
end

-- Checks that need state. Returns (reason?, detail?, commit?) where commit applies the state
-- change once the event is actually emitted.
local function checkState(self: Telemetry, event: any): (string?, string?, (() -> ())?)
	local catalog = self._catalog
	local limits = Events.LIMITS
	local playerKey = event.player or ""
	local category = event.category
	local commits: { () -> () } = {}
	local function newName(set: { [string]: boolean }, name: string, limit: number, reason: string): string?
		if set[name] then
			return nil
		end
		if count(set) >= limit then
			return reason
		end
		table.insert(commits, function()
			set[name] = true
		end)
		return nil
	end
	if category == "custom" then
		if catalog and catalog.custom then
			local spec = catalog.custom[event.name]
			if spec == nil then
				return "undeclared_name", event.name, nil
			end
			for key in event.fields or {} do
				if not (spec.fields and table.find(spec.fields, key)) then
					return "undeclared_field", key, nil
				end
			end
		end
		local reason = newName(self._customNames, event.name, limits.customNames, "too_many_custom_names")
		if reason then
			return reason, event.name, nil
		end
	elseif category == "purchase_intent" then
		local name = Telemetry.PURCHASE_PREFIX .. event.purchase.stage
		local reason = newName(self._customNames, name, limits.customNames, "too_many_custom_names")
		if reason then
			return reason, name, nil
		end
	elseif category == "economy" then
		local body = event.economy
		if catalog and catalog.economy then
			if not table.find(catalog.economy.currencies, body.currency) then
				return "unknown_currency", body.currency, nil
			end
			local declared = catalog.economy.transactionTypes
			if
				declared
				and not table.find(Events.TRANSACTION_TYPES, body.transaction_type)
				and not table.find(declared, body.transaction_type)
			then
				return "unknown_transaction_type", body.transaction_type, nil
			end
		end
		local reason = newName(self._currencies, body.currency, limits.currencies, "too_many_currencies")
			or newName(
				self._transactionTypes,
				body.transaction_type,
				limits.transactionTypes,
				"too_many_transaction_types"
			)
		if reason then
			return reason, nil, nil
		end
	elseif category == "progression" then
		if catalog and catalog.progression and not catalog.progression[event.progression.path] then
			return "unknown_path", event.progression.path, nil
		end
	elseif category == "funnel" then
		local body = event.funnel
		if catalog and catalog.funnels then
			local spec = catalog.funnels[body.funnel]
			if spec == nil then
				return "undeclared_name", body.funnel, nil
			end
			if spec.steps[body.step] ~= body.step_name then
				return "step_mismatch", string.format("%s step %d", body.funnel, body.step), nil
			end
		end
		local reason = newName(self._funnels, body.funnel, limits.funnels, "too_many_funnels")
		if reason then
			return reason, body.funnel, nil
		end
		local stateKey = playerKey .. "|" .. body.funnel
		local sessions = self._funnelSessions[stateKey] or {}
		local found: FunnelSession? = nil
		for _, entry in sessions do
			if entry.id == body.funnel_session_id then
				found = entry
				break
			end
		end
		if found == nil then
			if body.step ~= 1 then
				return "funnel_not_started", body.funnel_session_id, nil
			end
			table.insert(commits, function()
				local list = self._funnelSessions[stateKey] or {}
				table.insert(list, { id = body.funnel_session_id, last = body.step })
				while #list > Telemetry.FUNNEL_SESSIONS do
					table.remove(list, 1)
				end
				self._funnelSessions[stateKey] = list
			end)
		else
			local session = found :: FunnelSession
			if body.step == session.last then
				return "funnel_repeat", nil, nil
			elseif body.step < session.last then
				return "funnel_out_of_order", string.format("step %d after %d", body.step, session.last), nil
			elseif not self._allowGaps and body.step > session.last + 1 then
				return "funnel_skipped", string.format("step %d after %d", body.step, session.last), nil
			end
			table.insert(commits, function()
				session.last = body.step
			end)
		end
	elseif category == "onboarding" then
		local body = event.onboarding
		if catalog and catalog.onboarding and catalog.onboarding[body.step] ~= body.step_name then
			return "step_mismatch", string.format("onboarding step %d", body.step), nil
		end
		local last = self._onboarding[playerKey]
		if last == nil then
			if body.step ~= 1 then
				return "onboarding_not_started", nil, nil
			end
		elseif body.step == last then
			return "onboarding_repeat", nil, nil
		elseif body.step < last then
			return "onboarding_out_of_order", string.format("step %d after %d", body.step, last), nil
		elseif not self._allowGaps and body.step > last + 1 then
			return "funnel_skipped", string.format("onboarding step %d after %d", body.step, last), nil
		end
		table.insert(commits, function()
			self._onboarding[playerKey] = body.step
		end)
	end
	return nil, nil, function()
		for _, fn in commits do
			fn()
		end
	end
end

local function noteFields(self: Telemetry, fields: { [string]: string }?)
	if fields == nil or self._fieldValueCount >= Telemetry.FIELD_VALUES then
		return
	end
	for key, value in fields do
		local combined = key .. "=" .. value
		if not self._fieldValues[combined] then
			self._fieldValues[combined] = true
			self._fieldValueCount += 1
		end
	end
	if
		not self._fieldWarned
		and self._fieldValueCount >= Telemetry.FIELD_VALUES * Telemetry.FIELD_WARN_RATIO
	then
		self._fieldWarned = true
		self._env.report(
			string.format(
				"Telemetry: %d distinct custom field values on this server (Roblox groups values past %d as Other)",
				self._fieldValueCount,
				Telemetry.FIELD_VALUES
			)
		)
	end
end

-- Validates, checks limits and order, meters and emits one kit-event/1 record. Returns
-- (true) or (false, reason) with a reason from Telemetry.REASONS.
function Api.track(self: Telemetry, event: any): (boolean, string?)
	if type(event) ~= "table" then
		return reject(self, "invalid", "event must be a table")
	end
	local stamped: any = if self._envelope then Events.stamp(event, self._envelope) else Check.copy(event)
	if stamped.t == nil then
		stamped.t = self._env.clock()
	end
	local problems = Events.validate(stamped)
	if #problems > 0 then
		return reject(self, "invalid", problems[1])
	end
	local reason, detail, commit = checkState(self, stamped)
	if reason then
		return reject(self, reason, detail)
	end
	if self._limiter and not self._limiter:take("all") then
		return reject(self, "budget", nil)
	end
	local called, accepted, why = pcall(self._sink.emit, self._sink, stamped)
	if not called then
		self._sinkReports += 1
		if self._sinkReports == 1 or self._sinkReports % 100 == 0 then
			self._env.report(
				string.format("Telemetry sink error (%d so far): %s", self._sinkReports, tostring(accepted))
			)
		end
		return reject(self, "sink_error", nil)
	end
	if accepted == false then
		return reject(self, "sink_rejected", why)
	end
	if commit then
		commit()
	end
	noteFields(self, stamped.fields)
	self._accepted += 1
	return true, nil
end

-- The sink interface: Telemetry can be passed wherever a kit takes a sink.
function Api.emit(self: Telemetry, event: any): (boolean, string?)
	return self:track(event)
end

function Api.custom(
	self: Telemetry,
	player: any,
	name: string,
	value: number?,
	fields: { [string]: string }?
): (boolean, string?)
	local event: any = Events.custom(name, value, fields)
	event.player = Telemetry.keyOf(player)
	return self:track(event)
end

function Api.economy(
	self: Telemetry,
	player: any,
	flow: "source" | "sink",
	currency: string,
	amount: number,
	balance: number,
	transactionType: string,
	sku: string?,
	fields: { [string]: string }?
): (boolean, string?)
	local event: any = Events.economy("economy_" .. tostring(flow), {
		flow = flow,
		currency = currency,
		amount = amount,
		balance = balance,
		transaction_type = transactionType,
		sku = sku,
	}, fields)
	event.player = Telemetry.keyOf(player)
	return self:track(event)
end

function Api.progression(
	self: Telemetry,
	player: any,
	path: string,
	status: "start" | "complete" | "fail" | "custom",
	level: number,
	levelName: string?,
	fields: { [string]: string }?
): (boolean, string?)
	local event: any = Events.progression(
		"progression_" .. tostring(status),
		{ path = path, status = status, level = level, level_name = levelName },
		fields
	)
	event.player = Telemetry.keyOf(player)
	return self:track(event)
end

local function catalogSteps(self: Telemetry, funnel: string?): { string }?
	local catalog = self._catalog
	if catalog == nil then
		return nil
	end
	if funnel == nil then
		return catalog.onboarding
	end
	local spec = catalog.funnels and catalog.funnels[funnel]
	return spec and spec.steps
end

-- Starts a funnel session at the catalog's first step. Returns (sessionId) or (nil, reason).
function Api.funnelStart(
	self: Telemetry,
	player: any,
	funnel: string,
	fields: { [string]: string }?
): (string?, string?)
	local steps = catalogSteps(self, funnel)
	if steps == nil then
		local _, reason = reject(self, "undeclared_name", funnel)
		return nil, reason
	end
	local sessionId = self._newId()
	local event: any = Events.funnel(
		"funnel_step",
		{ funnel = funnel, step = 1, step_name = steps[1], funnel_session_id = sessionId },
		fields
	)
	event.player = Telemetry.keyOf(player)
	local ok, reason = self:track(event)
	if not ok then
		return nil, reason
	end
	return sessionId, nil
end

-- A funnel step by name; the number comes from the catalog order.
function Api.funnelStep(
	self: Telemetry,
	player: any,
	funnel: string,
	sessionId: string,
	stepName: string,
	fields: { [string]: string }?
): (boolean, string?)
	local steps = catalogSteps(self, funnel)
	local step = steps and table.find(steps, stepName)
	if step == nil then
		return reject(self, if steps then "step_mismatch" else "undeclared_name", stepName)
	end
	local event: any = Events.funnel(
		"funnel_step",
		{ funnel = funnel, step = step, step_name = stepName, funnel_session_id = sessionId },
		fields
	)
	event.player = Telemetry.keyOf(player)
	return self:track(event)
end

-- An onboarding step by name; the number comes from catalog.onboarding.
function Api.onboarding(
	self: Telemetry,
	player: any,
	stepName: string,
	fields: { [string]: string }?
): (boolean, string?)
	local steps = catalogSteps(self, nil)
	local step = steps and table.find(steps, stepName)
	if step == nil then
		return reject(self, if steps then "step_mismatch" else "undeclared_name", stepName)
	end
	local event: any = Events.onboarding("onboarding_step", { step = step, step_name = stepName }, fields)
	event.player = Telemetry.keyOf(player)
	return self:track(event)
end

-- A purchase_intent event (offer_viewed, prompted, prompt_closed, granted, failed). granted
-- comes from a processed receipt or a verified ownership change, never from a prompt event.
function Api.purchase(
	self: Telemetry,
	player: any,
	stage: string,
	product: string,
	kind: string,
	surface: string?
): (boolean, string?)
	local event: any = Events.purchaseIntent(
		"purchase_" .. tostring(stage),
		{ stage = stage :: any, product = product, kind = kind :: any, surface = surface }
	)
	event.player = Telemetry.keyOf(player)
	return self:track(event)
end

-- Drops a player's funnel and onboarding state (PlayerRemoving).
function Api.forget(self: Telemetry, player: any)
	local key = Telemetry.keyOf(player)
	if key == nil then
		return
	end
	self._onboarding[key] = nil
	local prefix = key .. "|"
	for stateKey in self._funnelSessions do
		if string.sub(stateKey, 1, #prefix) == prefix then
			self._funnelSessions[stateKey] = nil
		end
	end
end

export type Report = {
	accepted: number,
	rejected: { [string]: number },
	cardinality: {
		customNames: number,
		funnels: number,
		currencies: number,
		transactionTypes: number,
		fieldValues: number,
	},
}

-- Counts since start: accepted, rejected by reason (budget drops included) and cardinality.
function Api.report(self: Telemetry): Report
	return {
		accepted = self._accepted,
		rejected = table.clone(self._rejected),
		cardinality = {
			customNames = count(self._customNames),
			funnels = count(self._funnels),
			currencies = count(self._currencies),
			transactionTypes = count(self._transactionTypes),
			fieldValues = self._fieldValueCount,
		},
	}
end

return Telemetry
