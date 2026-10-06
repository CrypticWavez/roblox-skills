--!strict
-- FakeAnalytics (G1): an AnalyticsService stand-in that records each Log*Event call with its
-- exact argument list (AnalyticsService order) and checks the arguments the way the class
-- reference describes them: a Player first, non-empty names without commas, quotes or newlines,
-- finite numbers, the right Enum items (AnalyticsEconomyFlowType, AnalyticsProgressionType),
-- and customFields keyed by CustomField01..03 with string values. A bad call raises, as the
-- engine would. isClient = true makes every call raise (server only). fail(n) makes the next n
-- calls raise (throttling). calls() and byMethod(name) return what was recorded.
local roblox = require("@lune/roblox")

local FakeAnalytics = {}

local FIELD_KEYS = { CustomField01 = true, CustomField02 = true, CustomField03 = true }

local function name(value: any, what: string)
	if type(value) ~= "string" or value == "" or string.find(value, "[,\"'\n\r]") then
		error(what .. " must be a non-empty string without commas, quotes or newlines", 3)
	end
end

local function finite(value: any, what: string)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error(what .. " must be a finite number", 3)
	end
end

local function enumItem(value: any, enum: any, what: string)
	if typeof(value) ~= "EnumItem" or value.EnumType ~= enum then
		error(what .. " must be an " .. tostring(enum) .. " item", 3)
	end
end

local function customFields(value: any)
	if value == nil then
		return
	end
	if type(value) ~= "table" then
		error("customFields must be a table", 3)
	end
	for key, item in value do
		if not FIELD_KEYS[key] then
			error("customFields key " .. tostring(key) .. " is not CustomField01..03", 3)
		end
		if type(item) ~= "string" then
			error("customFields values must be strings", 3)
		end
	end
end

local function player(value: any)
	if type(value) ~= "table" or type(value.UserId) ~= "number" then
		error("the first argument must be a Player", 3)
	end
end

function FakeAnalytics.new(options: { isClient: boolean? }?): any
	local service = { isClient = options and options.isClient or false, _calls = {}, _failures = 0 } :: any

	local function record(method: string, ...: any)
		if service.isClient then
			error("AnalyticsService." .. method .. " can only be called from the server", 3)
		end
		if service._failures > 0 then
			service._failures -= 1
			error("AnalyticsService: request throttled", 3)
		end
		table.insert(service._calls, { method = method, args = table.pack(...) })
	end

	function service.LogCustomEvent(_self: any, who: any, eventName: any, value: any?, fields: any?)
		player(who)
		name(eventName, "eventName")
		if value ~= nil then
			finite(value, "value")
		end
		customFields(fields)
		record("LogCustomEvent", who, eventName, value, fields)
	end

	function service.LogEconomyEvent(
		_self: any,
		who: any,
		flowType: any,
		currencyType: any,
		amount: any,
		endingBalance: any,
		transactionType: any,
		itemSku: any?,
		fields: any?
	)
		player(who)
		enumItem(flowType, roblox.Enum.AnalyticsEconomyFlowType, "flowType")
		name(currencyType, "currencyType")
		finite(amount, "amount")
		finite(endingBalance, "endingBalance")
		name(transactionType, "transactionType")
		if itemSku ~= nil then
			name(itemSku, "itemSku")
		end
		customFields(fields)
		record(
			"LogEconomyEvent",
			who,
			flowType,
			currencyType,
			amount,
			endingBalance,
			transactionType,
			itemSku,
			fields
		)
	end

	function service.LogProgressionEvent(
		_self: any,
		who: any,
		pathName: any,
		status: any,
		level: any,
		levelName: any?,
		fields: any?
	)
		player(who)
		name(pathName, "pathName")
		enumItem(status, roblox.Enum.AnalyticsProgressionType, "status")
		finite(level, "level")
		if levelName ~= nil then
			name(levelName, "levelName")
		end
		customFields(fields)
		record("LogProgressionEvent", who, pathName, status, level, levelName, fields)
	end

	function service.LogFunnelStepEvent(
		_self: any,
		who: any,
		funnelName: any,
		funnelSessionId: any,
		step: any,
		stepName: any,
		fields: any?
	)
		player(who)
		name(funnelName, "funnelName")
		name(funnelSessionId, "funnelSessionId")
		finite(step, "step")
		name(stepName, "stepName")
		customFields(fields)
		record("LogFunnelStepEvent", who, funnelName, funnelSessionId, step, stepName, fields)
	end

	function service.LogOnboardingFunnelStepEvent(
		_self: any,
		who: any,
		step: any,
		stepName: any,
		fields: any?
	)
		player(who)
		finite(step, "step")
		name(stepName, "stepName")
		customFields(fields)
		record("LogOnboardingFunnelStepEvent", who, step, stepName, fields)
	end

	function service.fail(self: any, count: number?)
		self._failures += count or 1
	end

	function service.calls(self: any): { any }
		return table.clone(self._calls)
	end

	function service.byMethod(self: any, method: string): { any }
		local out = {}
		for _, call in self._calls do
			if call.method == method then
				table.insert(out, call)
			end
		end
		return out
	end

	return service
end

return FakeAnalytics
