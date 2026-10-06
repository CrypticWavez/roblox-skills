--!strict
-- @tier T3
-- probe: platform_telemetry_recorder
-- TelemetryRoblox: sinks for GameKit/Telemetry on a Roblox server.
--   toCall(event, options)   pure mapping of a kit-event/1 record to the AnalyticsService method
--                            and its arguments in documented order (enums from options.enums)
--   live(AnalyticsService)   sends real events; published games only (Roblox: "Events can only
--                            be sent from the server and in published games"), so live sending
--                            is T4 and verified only on the owner's dashboards (up to 24 h lag)
--   recorder(print)          Studio and probes: one "TELEMETRY_JSON <kit-event/1 line>" per event,
--                            stamped synthetic = true and environment = studio; collect the lines
--                            with console output and feed them to tools/analytics_report.py
--   forPlace(env)            recorder in Studio, live on a published server, error on a client
-- A live sink never sends synthetic events. purchase_intent maps to LogCustomEvent
-- "purchase_<stage>" with fields product, kind and surface in CustomField01..03 (documented
-- mapping; the five names count toward the 100 custom names).
local Events = require("./Events")

local TelemetryRoblox = {}

TelemetryRoblox.PREFIX = "TELEMETRY_JSON "
TelemetryRoblox.FIELD_KEYS = table.freeze({ "CustomField01", "CustomField02", "CustomField03" })
TelemetryRoblox.METHODS = table.freeze({
	custom = "LogCustomEvent",
	economy = "LogEconomyEvent",
	progression = "LogProgressionEvent",
	funnel = "LogFunnelStepEvent",
	onboarding = "LogOnboardingFunnelStepEvent",
	purchase_intent = "LogCustomEvent",
})
local PROGRESSION = { start = "Start", complete = "Complete", fail = "Fail", custom = "Custom" }
local FLOW = { source = "Source", sink = "Sink" }
local PURCHASE_FIELDS = { "product", "kind", "surface" }

export type CallOptions = {
	enums: any, -- Roblox Enum (env.roblox.Enum); required for economy and progression
	fieldOrder: { [string]: { string } }?, -- event name -> declared field order (pins slots)
	player: any?, -- the Player object passed as the first argument (default: event.player)
}

local function fieldKey(enums: any, slot: number): string
	local item = enums
		and enums.AnalyticsCustomFieldKeys
		and enums.AnalyticsCustomFieldKeys[TelemetryRoblox.FIELD_KEYS[slot]]
	return if item then item.Name else TelemetryRoblox.FIELD_KEYS[slot]
end

-- The customFields dictionary: declared order when given (a field keeps its slot even when an
-- event omits another), else sorted field names. nil when there are no fields.
function TelemetryRoblox.customFields(
	fields: { [string]: string }?,
	order: { string }?,
	enums: any?
): { [string]: string }?
	if fields == nil or next(fields) == nil then
		return nil
	end
	local names = order
	if names == nil then
		local sorted = {}
		for name in fields do
			table.insert(sorted, name)
		end
		table.sort(sorted)
		names = sorted
	end
	local out = {}
	for slot, name in names :: { string } do
		if slot > #TelemetryRoblox.FIELD_KEYS then
			break
		end
		local value = fields[name]
		if value ~= nil then
			out[fieldKey(enums, slot)] = value
		end
	end
	return out
end

-- (method, args) for an event; args is packed (args.n) so optional nils keep their position.
function TelemetryRoblox.toCall(
	event: Events.Event,
	options: CallOptions
): (string, { n: number, [number]: any })
	local enums = options.enums
	local player = if options.player ~= nil then options.player else event.player
	local order = options.fieldOrder and options.fieldOrder[event.name]
	local category = event.category
	local method = TelemetryRoblox.METHODS[category]
	assert(method ~= nil, "TelemetryRoblox.toCall: unknown category " .. tostring(category))
	if category == "custom" then
		return method,
			table.pack(
				player,
				event.name,
				event.value,
				TelemetryRoblox.customFields(event.fields, order, enums)
			)
	elseif category == "economy" then
		local body = event.economy :: Events.Economy
		assert(enums ~= nil, "TelemetryRoblox.toCall: economy events need options.enums")
		local transactionType = body.transaction_type
		local standard = enums.AnalyticsEconomyTransactionType
		if table.find(Events.TRANSACTION_TYPES, transactionType) and standard then
			transactionType = standard[transactionType].Name
		end
		return method,
			table.pack(
				player,
				enums.AnalyticsEconomyFlowType[FLOW[body.flow]],
				body.currency,
				body.amount,
				body.balance,
				transactionType,
				body.sku,
				TelemetryRoblox.customFields(event.fields, order, enums)
			)
	elseif category == "progression" then
		local body = event.progression :: Events.Progression
		assert(enums ~= nil, "TelemetryRoblox.toCall: progression events need options.enums")
		return method,
			table.pack(
				player,
				body.path,
				enums.AnalyticsProgressionType[PROGRESSION[body.status]],
				body.level,
				body.level_name,
				TelemetryRoblox.customFields(event.fields, order, enums)
			)
	elseif category == "funnel" then
		local body = event.funnel :: Events.Funnel
		return method,
			table.pack(
				player,
				body.funnel,
				body.funnel_session_id,
				body.step,
				body.step_name,
				TelemetryRoblox.customFields(event.fields, order, enums)
			)
	elseif category == "onboarding" then
		local body = event.onboarding :: Events.Onboarding
		return method,
			table.pack(
				player,
				body.step,
				body.step_name,
				TelemetryRoblox.customFields(event.fields, order, enums)
			)
	end
	local body = event.purchase :: Events.Purchase
	local fields: { [string]: string } = { product = body.product, kind = body.kind }
	if body.surface then
		fields.surface = body.surface
	end
	return method,
		table.pack(
			player,
			"purchase_" .. body.stage,
			nil,
			TelemetryRoblox.customFields(fields, PURCHASE_FIELDS, enums)
		)
end

-- Field order per custom event name from a Telemetry catalog (pins CustomField slots).
function TelemetryRoblox.fieldOrder(catalog: any): { [string]: { string } }
	local out = {}
	for name, spec in (catalog and catalog.custom) or {} do
		if type(spec) == "table" and type(spec.fields) == "table" then
			out[name] = spec.fields
		end
	end
	return out
end

export type LiveOptions = {
	players: any, -- the Players service (finds the Player for event.player)
	enums: any, -- Enum
	catalog: any?, -- the Telemetry catalog, to pin field slots
	report: ((message: string) -> ())?,
}

-- A sink that calls AnalyticsService. Refuses synthetic or non-live events, events for players
-- who are not in this server, and catches every call error. Server only.
function TelemetryRoblox.live(analytics: any, options: LiveOptions): any
	assert(analytics ~= nil, "TelemetryRoblox.live: AnalyticsService required")
	assert(
		options and options.players ~= nil and options.enums ~= nil,
		"TelemetryRoblox.live: players and enums required"
	)
	local fieldOrder = TelemetryRoblox.fieldOrder(options.catalog)
	local sink = { kind = "live", sent = 0, failed = 0 } :: any
	function sink.emit(self: any, event: any): (boolean, string?)
		if event.synthetic == true or (event.environment ~= nil and event.environment ~= "live") then
			return false, "synthetic"
		end
		local userId = tonumber(event.player)
		local player = userId and options.players:GetPlayerByUserId(userId)
		if player == nil then
			return false, "no_player"
		end
		local method, args =
			TelemetryRoblox.toCall(event, { enums = options.enums, fieldOrder = fieldOrder, player = player })
		local fn = analytics[method]
		local ok, err = pcall(fn, analytics, table.unpack(args, 1, args.n))
		if not ok then
			self.failed += 1
			if options.report then
				options.report(string.format("AnalyticsService.%s failed: %s", method, tostring(err)))
			end
			return false, "call_failed"
		end
		self.sent += 1
		return true, nil
	end
	return sink
end

-- A sink that prints TELEMETRY_JSON lines (stamped synthetic, environment studio by default).
function TelemetryRoblox.recorder(print: (line: string) -> (), options: { environment: string? }?): any
	assert(type(print) == "function", "TelemetryRoblox.recorder: needs a print function")
	local environment = options and options.environment or "studio"
	local sink = { kind = "recorder", lines = 0 } :: any
	function sink.emit(self: any, event: any): (boolean, string?)
		local stamped: any = table.clone(event)
		stamped.synthetic = true
		stamped.environment = environment
		local problems = Events.validate(stamped)
		if #problems > 0 then
			return false, problems[1]
		end
		print(TelemetryRoblox.PREFIX .. Events.encode(stamped))
		self.lines += 1
		return true, nil
	end
	return sink
end

-- The sink for this place and the envelope to give Telemetry: (sink, envelope).
function TelemetryRoblox.forPlace(env: any, options: { catalog: any?, print: ((string) -> ())? }?): (any, any)
	local place = env.place
	assert(place ~= nil, "TelemetryRoblox.forPlace: env.place required")
	if place.isStudio then
		local print = options and options.print or print
		return TelemetryRoblox.recorder(print), { synthetic = true, environment = "studio" }
	end
	if place.isClient and not place.isServer then
		error("TelemetryRoblox.forPlace: analytics events are server only", 2)
	end
	return TelemetryRoblox.live(env.services.AnalyticsService, {
		players = env.services.Players,
		enums = env.roblox and env.roblox.Enum,
		catalog = options and options.catalog,
		report = env.report,
	}),
		{ synthetic = false, environment = "live" }
end

return TelemetryRoblox
