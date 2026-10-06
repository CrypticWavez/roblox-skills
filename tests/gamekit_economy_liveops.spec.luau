--!strict
-- GameKit/LiveOps: ISO 8601 UTC parsing and formatting, one-off and recurring windows across
-- day and week boundaries, next(), from/until limits, and seeded rotations.
local LiveOps = require("../packages/GameKit/LiveOps")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local DAY = 86400
local T0 = 1791244800 -- 2026-10-06T00:00:00Z, a Tuesday

local function ids(list: { any }): { string }
	local out = {}
	for _, item in list do
		table.insert(out, item.id)
	end
	return out
end

test("parseUtc and formatUtc round-trip and refuse impossible dates", function(t)
	t.eq(LiveOps.parseUtc("2026-10-06T00:00:00Z"), T0)
	t.eq(LiveOps.parseUtc("1970-01-01T00:00:00Z"), 0)
	t.eq(LiveOps.parseUtc("2024-02-29T12:30:15Z"), 1709209815)
	t.eq(LiveOps.formatUtc(T0 + 3661), "2026-10-06T01:01:01Z")
	t.eq(LiveOps.formatUtc(1709209815), "2024-02-29T12:30:15Z")
	for _, bad in
		{
			"2026-02-29T00:00:00Z",
			"2026-13-01T00:00:00Z",
			"2026-10-06T24:00:00Z",
			"2026-10-06 00:00:00",
			"2026-10-06T00:00:00+01:00",
			"yesterday",
		}
	do
		t.eq(LiveOps.parseUtc(bad), nil, bad)
	end
	t.eq(LiveOps.parseUtc(5 :: any), nil)
	for day = 0, 3000, 37 do
		local utc = T0 + day * DAY + day * 13
		t.eq(LiveOps.parseUtc(LiveOps.formatUtc(utc)), utc)
	end
end)

test("validation refuses bad windows", function(t)
	t.ok(contains(LiveOps.validate({}), "windows list"))
	local problems = LiveOps.validate({
		windows = {
			{ id = "a", start = "2026-10-06T00:00:00Z", ["end"] = "2026-10-05T00:00:00Z" },
			{ id = "a", start = "soon", ["end"] = 5 },
			{ id = "b", every = "hourly", duration = 10 },
			{ id = "c", every = "daily", at = DAY, duration = 0 },
			{ id = "d", every = 120, duration = 121 },
			{ id = "e", every = "weekly", duration = 60, from = T0, ["until"] = T0 - 1 },
			{ id = "F", start = 0, ["end"] = 1 },
		},
	})
	for _, needle in
		{
			"window a: end must be after start",
			"window a: duplicate id",
			"window a: start and end must be",
			"window b: every must be daily, weekly",
			"window c: at must be whole seconds within the period",
			"window c: duration must be whole seconds",
			"window d: duration must be whole seconds from 1 to the period",
			"window e: until must be after from",
			"window F: id is not a label",
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	t.throws(function()
		LiveOps.define({ windows = { { id = "x" } } })
	end)
end)

test("one-off and recurring windows open and close at exact UTC boundaries", function(t)
	local schedule = LiveOps.define({
		windows = {
			{
				id = "event_a",
				start = "2026-10-06T12:00:00Z",
				["end"] = "2026-10-08T12:00:00Z",
				data = { tag = "a" },
			},
			{ id = "daily_a", every = "daily", at = 18 * 3600, duration = 2 * 3600 },
			{ id = "weekend_a", every = "weekly", at = 5 * DAY, duration = 2 * DAY },
		},
	})
	t.eq(ids(schedule:active(T0 + 12 * 3600 - 1)), {})
	t.eq(ids(schedule:active(T0 + 12 * 3600)), { "event_a" })
	t.eq(schedule:active(T0 + 12 * 3600)[1].data, { tag = "a" })
	t.eq(ids(schedule:active(T0 + 18 * 3600)), { "daily_a", "event_a" })
	t.eq(ids(schedule:active(T0 + 20 * 3600)), { "event_a" }, "end is exclusive")
	t.eq(ids(schedule:active(T0 + 2 * DAY + 12 * 3600)), {})
	-- Saturday 2026-10-10 00:00 UTC opens the weekend window until Monday 00:00.
	t.eq(ids(schedule:active(T0 + 4 * DAY - 1)), {})
	t.eq(ids(schedule:active(T0 + 4 * DAY)), { "weekend_a" })
	t.eq(ids(schedule:active(T0 + 5 * DAY + 19 * 3600)), { "daily_a", "weekend_a" }, "Sunday 19:00")
	t.eq(ids(schedule:active(T0 + 6 * DAY - 1)), { "weekend_a" }, "Sunday 23:59:59")
	t.ok(not schedule:isActive("weekend_a", T0 + 6 * DAY))
	local occurrence = schedule:active(T0 + 5 * DAY + 19 * 3600)[2]
	t.eq({ LiveOps.formatUtc(occurrence.start), LiveOps.formatUtc(occurrence["end"]) }, {
		"2026-10-10T00:00:00Z",
		"2026-10-12T00:00:00Z",
	})
end)

test("next() finds the earliest upcoming start and honours from/until", function(t)
	local schedule = LiveOps.define({
		windows = {
			{ id = "event_a", start = T0 + 5000, ["end"] = T0 + 6000 },
			{
				id = "daily_a",
				every = "daily",
				at = 3600,
				duration = 60,
				from = T0 + 2 * DAY,
				["until"] = T0 + 4 * DAY,
			},
		},
	})
	t.eq(assert(schedule:next(T0)).id, "event_a")
	local daily = assert(schedule:next(T0 + 5000))
	t.eq({ daily.id, daily.start }, { "daily_a", T0 + 2 * DAY + 3600 }, "from skips earlier occurrences")
	t.eq(ids(schedule:active(T0 + DAY + 3600)), {}, "not before from")
	t.eq(ids(schedule:active(T0 + 3 * DAY + 3600)), { "daily_a" })
	t.eq(schedule:next(T0 + 3 * DAY + 3600), nil, "until stops the series")
	t.eq(ids(schedule:active(T0 + 4 * DAY + 3600)), {})
	t.throws(function()
		schedule:active(0 / 0)
	end)
end)

test("rotations are seeded per period and identical across calls", function(t)
	local pool = { "offer_a", "offer_b", "offer_c", "offer_d", "offer_e", "offer_f" }
	local options = { period = DAY, count = 3, seed = "shop" }
	local a = LiveOps.rotation(pool, options, T0 + 10)
	local b = LiveOps.rotation(pool, options, T0 + DAY - 1)
	t.eq(a.picks, b.picks, "same period, same picks")
	t.eq(#a.picks, 3)
	t.eq({ a.startsAt, a.endsAt }, { T0, T0 + DAY })
	local changed = 0
	for day = 1, 10 do
		local next_ = LiveOps.rotation(pool, options, T0 + day * DAY)
		if table.concat(next_.picks) ~= table.concat(a.picks) then
			changed += 1
		end
	end
	t.ok(changed >= 8, "periods reshuffle (" .. changed .. "/10)")
	t.eq(#LiveOps.rotation({ "only" }, options, T0).picks, 1, "count larger than the pool")
	t.ok(
		table.concat(LiveOps.rotation(pool, { period = DAY, count = 6, seed = "other" }, T0).picks)
			~= table.concat(LiveOps.rotation(pool, { period = DAY, count = 6, seed = "shop" }, T0).picks)
	)
	t.throws(function()
		LiveOps.rotation({}, options, T0)
	end)
	t.throws(function()
		LiveOps.rotation(pool, { period = 10, count = 1, seed = 1 }, T0)
	end)
end)

return cases
