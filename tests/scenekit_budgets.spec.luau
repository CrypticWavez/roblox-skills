--!strict
-- SceneKit/Budgets (perf/1 budgets half): documented and convention limits stay apart, device
-- classes are complete and ordered, check() reports violations with their kind and treats a
-- missing counter as missing (never 0), malformed stats and unknown classes raise, and the
-- budgets document validates.
local Budgets = require("../packages/SceneKit/Budgets")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function stats(class: string, counts: { [string]: number }, extra: { [string]: any }?): any
	local record: any = { schema = "perf/1", kind = "stats", device_class = class, counts = counts }
	for key, value in extra or {} do
		record[key] = value
	end
	return record
end

test("device classes are complete, share counters and tighten towards phone_low", function(t)
	t.eq(Budgets.DEVICE_CLASSES, { "phone_low", "phone", "tablet", "desktop", "console" })
	local keys = {}
	for key in Budgets.CLASSES.desktop do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, class in Budgets.DEVICE_CLASSES do
		local limits = Budgets.CLASSES[class]
		t.ok(limits, class)
		local own = {}
		for key in limits do
			table.insert(own, key)
		end
		table.sort(own)
		t.eq(own, keys, class .. " counters")
	end
	local order = { "phone_low", "phone", "tablet", "desktop" }
	for index = 2, #order do
		local weaker, stronger = Budgets.CLASSES[order[index - 1]], Budgets.CLASSES[order[index]]
		for _, key in keys do
			if key == "frame_ms_p95" then
				t.ok(weaker[key] >= stronger[key], key .. " " .. order[index])
			else
				t.ok(weaker[key] <= stronger[key], key .. " " .. order[index])
			end
		end
	end
end)

test("documented figures are the published ones; conventions stay separate", function(t)
	t.eq(Budgets.DOCUMENTED.light_range_max, 120)
	t.eq(Budgets.DOCUMENTED.particle_rate_max, 400)
	t.eq(Budgets.DOCUMENTED.particle_rate_mobile, 100)
	t.eq(Budgets.DOCUMENTED.particle_lifetime_max, 20)
	t.eq(Budgets.DOCUMENTED.highlights_max, 255)
	t.eq(Budgets.DOCUMENTED.triangles, 1000000)
	t.eq(Budgets.CLASSES.desktop.triangles, Budgets.DOCUMENTED.triangles)
	t.eq(Budgets.CONVENTIONS.light_range_budget, 60)
	for key in Budgets.CONVENTIONS do
		t.eq(Budgets.DOCUMENTED[key], nil, key .. " is in one table only")
	end
	t.ok(table.isfrozen(Budgets.CLASSES.phone) and table.isfrozen(Budgets.DOCUMENTED))
end)

test("check: inside budget passes; violations carry counter, limit and kind", function(t)
	local ok, missing = Budgets.check(
		stats(
			"phone",
			{ parts = 100, triangles = 1000, highlights = 1 },
			{ frame_ms = { p50 = 10, p95 = 15 } }
		),
		"phone"
	)
	t.eq(ok, {})
	t.ok(
		table.find(missing, "playing_sounds") and table.find(missing, "texture_mb_estimate"),
		"unmeasured listed"
	)
	t.ok(not table.find(missing, "parts"))
	local violations = Budgets.check(
		stats("phone_low", { parts = 7000, highlights = 3, triangles = 100 }, {
			texture_mb_estimate = 500,
			memory_mb = { total = 950 },
		}),
		"phone_low"
	)
	local names = {}
	for _, v in violations do
		table.insert(names, v.counter)
		t.eq(v.kind, "convention")
		t.eq(v.class, "phone_low")
	end
	t.eq(names, { "highlights", "memory_mb_total", "parts", "texture_mb_estimate" })
	t.eq(Budgets.describe({ violations[3] }), { "parts 7000 > 6000 (convention, phone_low)" })
	local desktop = Budgets.check(stats("desktop", { triangles = 1200000 }), "desktop")
	t.eq(#desktop, 1)
	t.eq(desktop[1].kind, "documented", "the 1M triangle baseline is published")
	-- A stats record measured on another class can be checked against a stricter one.
	t.eq(#Budgets.check(stats("desktop", { parts = 20000 }), "phone"), 1)
end)

test("a missing counter is missing, never zero", function(t)
	local violations, missing = Budgets.check(stats("tablet", {}), "tablet")
	t.eq(violations, {})
	t.eq(#missing, 11, "every budget counter unmeasured")
end)

test("check raises on unknown classes and malformed stats", function(t)
	t.throws(function()
		Budgets.check(stats("phone", {}), "watch")
	end, "unknown class")
	for _, bad in
		{
			stats("phone", { parts = 0 / 0 }),
			stats("phone", { parts = -1 }),
			stats("phone", { draw_calls = 5 }),
			stats("pager", {}),
			{ schema = "perf/2", kind = "stats", device_class = "phone" },
			{ schema = "perf/1", kind = "budgets", device_class = "phone" },
			stats("phone", {}, { frame_ms = { p95 = math.huge } }),
			stats("phone", {}, { texture_mb_estimate = -3 }),
			"stats",
		}
	do
		t.throws(function()
			Budgets.check(bad, "phone")
		end)
		t.ok(#Budgets.validateStats(bad) > 0)
	end
end)

test("the budgets document validates and rejects edits outside the schema", function(t)
	local doc = Budgets.document()
	t.eq(Budgets.validate(doc), {})
	t.eq(doc.schema, "perf/1")
	t.eq(doc.kind, "budgets")
	t.eq(doc.documented_keys.desktop.triangles ~= nil, true)
	doc.classes.phone.parts = 0
	doc.classes.phone.draw_calls = 900
	doc.classes.watch = { parts = 1 }
	local problems = Budgets.validate(doc)
	t.eq(#problems, 3, table.concat(problems, "; "))
	t.eq(Budgets.validate({ schema = "perf/1", kind = "budgets" }), { "classes must be a table" })
	t.eq(Budgets.validate(nil), { "budgets must be a table" })
end)

return cases
