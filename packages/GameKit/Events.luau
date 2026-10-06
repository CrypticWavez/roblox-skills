--!strict
-- @tier T0
-- Events: the kit-event/1 record every kit emits (docs/runtime-kits.md "kit-event/1"). One
-- envelope, six categories: custom, economy (source/sink of a currency with amount and ending
-- balance), progression, funnel (ordered steps), onboarding (the onboarding funnel) and
-- purchase_intent (offer viewed, prompt shown or closed, grant, failure; never a receipt).
-- Builders return plain tables; validate lists problems; a sink is any table with
-- :emit(event) -> (accepted, reason?). recorder() (specs, Studio) and null() ship here; the
-- AnalyticsService adapter is GameKit/TelemetryRoblox (G1). Keys are snake_case because the
-- canonical form is a JSONL line (Events.encode) read by Python report tools.
local Check = require("./Check")
local Json = require("./Json")

local Events = {}
Events.SCHEMA = "kit-event/1"

export type Category = "custom" | "economy" | "progression" | "funnel" | "onboarding" | "purchase_intent"
export type Economy = {
	flow: "source" | "sink",
	currency: string,
	amount: number,
	balance: number,
	transaction_type: string,
	sku: string?,
}
export type Progression = {
	path: string,
	status: "start" | "complete" | "fail" | "custom",
	level: number,
	level_name: string?,
}
export type Funnel = { funnel: string, step: number, step_name: string, funnel_session_id: string }
export type Onboarding = { step: number, step_name: string }
export type Purchase = {
	stage: "offer_viewed" | "prompted" | "prompt_closed" | "granted" | "failed",
	product: string,
	kind: "devproduct" | "gamepass" | "subscription",
	surface: string?,
}
export type Event = {
	schema: string,
	category: Category,
	name: string,
	t: number?,
	timestamp: string?,
	event_id: string?,
	player: string?,
	session_id: string?,
	value: number?,
	fields: { [string]: string }?,
	economy: Economy?,
	progression: Progression?,
	funnel: Funnel?,
	onboarding: Onboarding?,
	purchase: Purchase?,
	synthetic: boolean?,
	environment: ("lune" | "studio" | "live")?,
}
export type Sink = { emit: (self: any, event: Event) -> (boolean, string?) }
export type Envelope = {
	t: number?,
	timestamp: string?,
	event_id: string?,
	player: string?,
	session_id: string?,
	synthetic: boolean?,
	environment: string?,
}

-- Limits: Roblox-documented ones cite AnalyticsService; "convention" ones are factory choices.
Events.LIMITS = table.freeze({
	fields = 3, -- custom fields per event (AnalyticsService CustomField01..03)
	currencies = 5, -- distinct currencies (economy events docs; design for 5)
	transactionTypes = 20, -- distinct transaction types before "Other"
	customNames = 100, -- distinct custom event names
	funnels = 10, -- funnels per game
	funnelSteps = 100, -- steps per funnel
	nameLength = 64, -- convention
	fieldValueLength = 64, -- convention (no free text in fields)
})

local CATEGORY_BODY: { [string]: string? } = {
	custom = nil,
	economy = "economy",
	progression = "progression",
	funnel = "funnel",
	onboarding = "onboarding",
	purchase_intent = "purchase",
}
Events.CATEGORIES =
	table.freeze({ "custom", "economy", "progression", "funnel", "onboarding", "purchase_intent" })
-- Standard Enum.AnalyticsEconomyTransactionType names; lower_snake labels are custom types.
Events.TRANSACTION_TYPES =
	table.freeze({ "IAP", "Shop", "Gameplay", "ContextualPurchase", "TimedReward", "Onboarding" })
Events.PROGRESSION_STATUS = table.freeze({ "start", "complete", "fail", "custom" })
Events.PURCHASE_STAGES = table.freeze({ "offer_viewed", "prompted", "prompt_closed", "granted", "failed" })
Events.PRODUCT_KINDS = table.freeze({ "devproduct", "gamepass", "subscription" })
Events.ENVIRONMENTS = table.freeze({ "lune", "studio", "live" })

local ENVELOPE_KEYS = {
	"schema",
	"category",
	"name",
	"t",
	"timestamp",
	"event_id",
	"player",
	"session_id",
	"synthetic",
	"environment",
}
local BODY_KEYS: { [string]: { string } } = {
	economy = { "flow", "currency", "amount", "balance", "transaction_type", "sku" },
	progression = { "path", "status", "level", "level_name" },
	funnel = { "funnel", "step", "step_name", "funnel_session_id" },
	onboarding = { "step", "step_name" },
	purchase = { "stage", "product", "kind", "surface" },
}

local function has(list: { string }, value: any): boolean
	return table.find(list, value) ~= nil
end

-- An id-like string: 1..64 of letters, digits, _ . : - (player keys, session and event ids, skus).
local function token(value: any): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= 64
		and string.match(value, "^[%w_%.:%-]+$") ~= nil
end

-- Short display text: 1..64 characters, no commas, quotes or control characters (Roblox name rules).
local function shortText(value: any): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.find(value, "[%c,\"']") == nil
end

local function count(map: { [any]: any }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

-- Problems with an event (empty when it is a valid kit-event/1 record).
function Events.validate(event: any): { string }
	if type(event) ~= "table" then
		return { "event must be a table" }
	end
	local problems = {}
	local function problem(text: string, ...: any)
		table.insert(problems, string.format(text, ...))
	end
	if event.schema ~= Events.SCHEMA then
		problem("schema must be %s", Events.SCHEMA)
	end
	local category = event.category
	if not has(Events.CATEGORIES :: any, category) then
		problem(
			"category %s is not one of %s",
			Check.describe(category),
			table.concat(Events.CATEGORIES, ", ")
		)
		return problems
	end
	if not Check.label(event.name, Events.LIMITS.nameLength) then
		problem("name %s is not a lower_snake label of at most 64 characters", Check.describe(event.name))
	end
	local bodyKey = CATEGORY_BODY[category]
	local allowed: { [string]: boolean } = {}
	for _, key in ENVELOPE_KEYS do
		allowed[key] = true
	end
	if bodyKey then
		allowed[bodyKey] = true
	end
	if category == "custom" then
		allowed.value = true
	end
	allowed.fields = true
	for key in event do
		if not allowed[key] then
			problem("unexpected key %s for category %s", Check.describe(key), category)
		end
	end
	if event.t ~= nil and not (Check.finite(event.t) and event.t >= 0) then
		problem("t must be a finite number >= 0")
	end
	if
		event.timestamp ~= nil
		and not (
			type(event.timestamp) == "string"
			and string.match(event.timestamp, "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.?%d*Z$") ~= nil
		)
	then
		problem("timestamp must be UTC ISO 8601 like 2026-10-06T12:00:00Z")
	end
	for _, key in { "event_id", "player", "session_id" } do
		if event[key] ~= nil and not token(event[key]) then
			problem("%s must be 1-64 letters, digits or _ . : -", key)
		end
	end
	if event.synthetic ~= nil and type(event.synthetic) ~= "boolean" then
		problem("synthetic must be a boolean")
	end
	if event.environment ~= nil and not has(Events.ENVIRONMENTS :: any, event.environment) then
		problem("environment must be lune, studio or live")
	end
	if event.value ~= nil and not Check.finite(event.value) then
		problem("value must be a finite number")
	end
	local fields = event.fields
	if fields ~= nil then
		if type(fields) ~= "table" then
			problem("fields must be a map of label -> string")
		else
			if count(fields) > Events.LIMITS.fields then
				problem("fields has %d entries (at most %d)", count(fields), Events.LIMITS.fields)
			end
			for key, value in fields do
				if not Check.label(key) then
					problem("field name %s is not a label", Check.describe(key))
				elseif not shortText(value) then
					problem("field %s must be a string of 1-64 characters without commas or quotes", key)
				end
			end
		end
	end
	if bodyKey == nil then
		return problems
	end
	local body = event[bodyKey]
	if type(body) ~= "table" then
		problem("%s events need a %s table", category, bodyKey)
		return problems
	end
	for key in body do
		if not has(BODY_KEYS[bodyKey], key) then
			problem("%s: unexpected key %s", bodyKey, Check.describe(key))
		end
	end
	if bodyKey == "economy" then
		if body.flow ~= "source" and body.flow ~= "sink" then
			problem("economy.flow must be source or sink")
		end
		if not Check.label(body.currency) then
			problem("economy.currency must be a label")
		end
		if not (Check.finite(body.amount) and body.amount > 0) then
			problem("economy.amount must be a finite number > 0")
		end
		if not (Check.finite(body.balance) and body.balance >= 0) then
			problem("economy.balance must be a finite number >= 0 (the ending balance)")
		end
		if
			not (
				has(Events.TRANSACTION_TYPES :: any, body.transaction_type)
				or Check.label(body.transaction_type)
			)
		then
			problem("economy.transaction_type must be a standard type or a label")
		end
		if body.sku ~= nil and not token(body.sku) then
			problem("economy.sku must be 1-64 letters, digits or _ . : -")
		end
	elseif bodyKey == "progression" then
		if not Check.label(body.path) then
			problem("progression.path must be a label")
		end
		if not has(Events.PROGRESSION_STATUS :: any, body.status) then
			problem("progression.status must be start, complete, fail or custom")
		end
		if not (Check.integer(body.level) and body.level >= 0) then
			problem("progression.level must be an integer >= 0")
		end
		if body.level_name ~= nil and not shortText(body.level_name) then
			problem("progression.level_name must be 1-64 characters without commas or quotes")
		end
	elseif bodyKey == "funnel" or bodyKey == "onboarding" then
		if not (Check.integer(body.step) and body.step >= 1 and body.step <= Events.LIMITS.funnelSteps) then
			problem("%s.step must be an integer from 1 to %d", bodyKey, Events.LIMITS.funnelSteps)
		end
		if not Check.label(body.step_name) then
			problem("%s.step_name must be a label", bodyKey)
		end
		if bodyKey == "funnel" then
			if not Check.label(body.funnel) then
				problem("funnel.funnel must be a label")
			end
			if not token(body.funnel_session_id) then
				problem("funnel.funnel_session_id must be 1-64 letters, digits or _ . : -")
			end
		end
	elseif bodyKey == "purchase" then
		if not has(Events.PURCHASE_STAGES :: any, body.stage) then
			problem("purchase.stage must be one of %s", table.concat(Events.PURCHASE_STAGES, ", "))
		end
		if not Check.label(body.product) then
			problem("purchase.product must be a catalog/1 product key")
		end
		if not has(Events.PRODUCT_KINDS :: any, body.kind) then
			problem("purchase.kind must be devproduct, gamepass or subscription")
		end
		if body.surface ~= nil and not Check.label(body.surface) then
			problem("purchase.surface must be a label")
		end
	end
	return problems
end

function Events.isValid(event: any): boolean
	return #Events.validate(event) == 0
end

local function build(category: Category, name: string, bodyKey: string?, body: any, fields: any): Event
	local event: any = { schema = Events.SCHEMA, category = category, name = name, fields = fields }
	if bodyKey then
		event[bodyKey] = table.clone(body)
	end
	return event
end

function Events.custom(name: string, value: number?, fields: { [string]: string }?): Event
	local event = build("custom", name, nil, nil, fields)
	event.value = value
	return event
end

function Events.economy(name: string, body: Economy, fields: { [string]: string }?): Event
	return build("economy", name, "economy", body, fields)
end

function Events.progression(name: string, body: Progression, fields: { [string]: string }?): Event
	return build("progression", name, "progression", body, fields)
end

function Events.funnel(name: string, body: Funnel, fields: { [string]: string }?): Event
	return build("funnel", name, "funnel", body, fields)
end

function Events.onboarding(name: string, body: Onboarding, fields: { [string]: string }?): Event
	return build("onboarding", name, "onboarding", body, fields)
end

function Events.purchaseIntent(name: string, body: Purchase, fields: { [string]: string }?): Event
	return build("purchase_intent", name, "purchase", body, fields)
end

-- A copy of event with envelope fields filled where the event leaves them empty.
function Events.stamp(event: Event, envelope: Envelope): Event
	local out: any = Check.copy(event)
	for key, value in envelope :: any do
		if out[key] == nil then
			out[key] = value
		end
	end
	return out
end

-- The canonical JSONL line (sorted keys, no trailing newline).
function Events.encode(event: Event): string
	return Json.encode(event)
end

export type Recorder = {
	events: { Event },
	rejected: { { event: any, problems: { string } } },
	emit: (self: Recorder, event: Event) -> (boolean, string?),
	count: (self: Recorder, category: string?) -> number,
	named: (self: Recorder, name: string) -> { Event },
	lines: (self: Recorder) -> { string },
	clear: (self: Recorder) -> (),
}

-- An in-memory sink. Each event is stamped with opts.envelope and t = opts.clock() when it has
-- none, then validated: strict (default) raises on an invalid event, otherwise it is kept in
-- `rejected` and emit returns (false, firstProblem).
function Events.recorder(opts: { clock: (() -> number)?, strict: boolean?, envelope: Envelope? }?): Recorder
	local clock = opts and opts.clock
	local strict = not (opts and opts.strict == false)
	local envelope = opts and opts.envelope
	local recorder = { events = {}, rejected = {} } :: any
	function recorder.emit(self: Recorder, event: Event): (boolean, string?)
		local stamped: any = event
		if type(event) == "table" then
			stamped = if envelope then Events.stamp(event, envelope) else Check.copy(event)
			if stamped.t == nil and clock then
				stamped.t = clock()
			end
		end
		local problems = Events.validate(stamped)
		if #problems > 0 then
			if strict then
				error("kit-event/1: " .. table.concat(problems, "; "), 2)
			end
			table.insert(self.rejected, { event = stamped, problems = problems })
			return false, problems[1]
		end
		table.insert(self.events, stamped)
		return true, nil
	end
	function recorder.count(self: Recorder, category: string?): number
		if category == nil then
			return #self.events
		end
		local n = 0
		for _, event in self.events do
			if event.category == category then
				n += 1
			end
		end
		return n
	end
	function recorder.named(self: Recorder, name: string): { Event }
		local out = {}
		for _, event in self.events do
			if event.name == name then
				table.insert(out, event)
			end
		end
		return out
	end
	function recorder.lines(self: Recorder): { string }
		local out = {}
		for _, event in self.events do
			table.insert(out, Events.encode(event))
		end
		return out
	end
	function recorder.clear(self: Recorder)
		self.events = {}
		self.rejected = {}
	end
	return recorder
end

-- A sink that accepts and drops everything (counts what it dropped).
function Events.null(): Sink & { dropped: number }
	local sink = { dropped = 0 } :: any
	function sink.emit(self: any, _event: Event): (boolean, string?)
		self.dropped += 1
		return true, nil
	end
	return sink
end

return Events
