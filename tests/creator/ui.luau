local UI = require("../../packages/Creator/UI")
local tests = 0
local function expect(value, message)
	assert(value, message or "creator UI contract failed")
end
local function test(name, callback)
	callback()
	tests += 1
	print("PASS " .. name)
end
test("bounded localization rejects missing, invalid UTF8 and excessive text", function()
	expect(not UI.validateStrings({}, { "title" }))
	expect(not UI.validateStrings({ title = string.rep("a", 513) }, { "title" }))
	expect(not UI.validateStrings({ title = "\255" }, { "title" }))
	expect(UI.validateStrings({ title = "Inspection" }, { "title" }))
end)
test("provider failures have bounded honest fallback", function()
	local strings, errors = UI.localize(function()
		error("provider failure")
	end, { "title", "unknown" })
	expect(strings.title == UI.defaults.title and strings.unknown == "[missing: unknown]")
	expect(#errors == 2)
end)
test("item identity, density and counts validated", function()
	expect(UI.validateItems({ { id = "entry", labelKey = "entry", count = 2 } }))
	expect(
		not UI.validateItems({ { id = "entry", labelKey = "entry" }, { id = "entry", labelKey = "entry" } })
	)
	expect(not UI.validateItems({ [2] = { id = "entry", labelKey = "entry" } }))
	expect(not UI.validateItems({ { id = "entry", labelKey = "entry", count = 0 / 0 } }))
end)
test("settings reject nonfinite and wrong boolean values", function()
	expect(UI.validateSettings(0.5, true))
	expect(not UI.validateSettings(0 / 0, false))
	expect(not UI.validateSettings(1.1, false))
	expect(not UI.validateSettings(0.5, "false"))
end)
test("reentrant activation is rejected and errors release the guard", function()
	local guard = UI.guard()
	expect(guard:invoke(function()
		local ok, reason = guard:invoke(function()
			error("must not run")
		end)
		expect(not ok and reason == "busy")
	end))
	expect(not guard:invoke(function()
		error("expected callback failure")
	end))
	expect(guard.failures == 1 and not guard.busy)
	expect(guard:invoke(function() end))
end)
test("cleanup is once-only and prevents activation", function()
	local count = 0
	local guard
	guard = UI.guard(function()
		count += 1
		guard:destroy()
	end)
	guard:destroy()
	guard:destroy()
	expect(count == 1)
	local ok, reason = guard:invoke(function()
		error("must not run")
	end)
	expect(not ok and reason == "closed")
end)
test("destruction during callback closes activation result", function()
	local guard = UI.guard()
	local ok, reason = guard:invoke(function()
		guard:destroy()
	end)
	expect(not ok and reason == "closed_during_callback" and not guard.busy)
end)
test("missing, cross-universe and enabled shop entries never query prices", function()
	local calls = 0
	local provider = function()
		calls += 1
		return { available = true, formattedPrice = "current fixture quote" }
	end
	for _, entry in
		{
			{},
			{ universeId = 2, productId = 3 },
			{ universeId = 1, ownershipVerified = true, enabled = true, kind = "pass", productId = 3 },
		}
	do
		local display = UI.shopDisplay(entry, 1, provider)
		expect(display.state == "unavailable" and display.purchasable == false)
	end
	expect(calls == 0)
end)
test("current quotes remain preview-only and provider failure unavailable", function()
	local entry = { universeId = 1, ownershipVerified = true, enabled = false, kind = "pass", productId = 3 }
	local display = UI.shopDisplay(entry, 1, function(kind, id)
		expect(kind == "pass" and id == 3)
		return { available = true, formattedPrice = "quote supplied now" }
	end)
	expect(display.price == "quote supplied now" and display.purchasable == false)
	expect(UI.shopDisplay(entry, 1, function()
		error("offline")
	end).state == "unavailable")
	expect(UI.shopDisplay(entry, 1, function()
		return { available = true, formattedPrice = string.rep("a", 129) }
	end).state == "unavailable")
end)
print("CREATOR UI PURE TESTS PASSED: " .. tostring(tests))
