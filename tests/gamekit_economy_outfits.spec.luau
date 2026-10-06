--!strict
-- GameKit/Outfits: outfit/1 validation (types, ids, duplicates, colors, scale ranges as
-- overridable conventions, limits, allow predicate), description plans, round trips and merge;
-- OutfitsRoblox wiring against tests/fakes/FakeEconomyEngine (description build, apply method
-- choice, read-back). Ids here are fake counters, not Roblox assets.
local Outfits = require("../packages/GameKit/Outfits")
local OutfitsRoblox = require("../packages/GameKit/OutfitsRoblox")
local FakeEconomyEngine = require("./fakes/FakeEconomyEngine")

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

-- Fake ids from a counter (never real catalog assets).
local function fake(n: number): number
	return 10 + n
end

local function outfit(): any
	return {
		schema = "outfit/1",
		accessories = {
			{ type = "Hat", id = fake(1) },
			{ type = "Jacket", id = fake(2), order = 3, puffiness = 0.5 },
			{ type = "Hair", id = fake(3), layered = true },
		},
		body = { Head = 0, Torso = fake(4) },
		clothing = { Shirt = fake(5) },
		animations = { Idle = fake(6) },
		colors = { head = "#FF8000", torso = { r = 1, g = 2, b = 3 } },
		scales = { height = 1, width = 0.8, proportion = 0.5 },
	}
end

test("a full outfit validates and maps to a description plan", function(t)
	t.eq(Outfits.validate(outfit()), {})
	local plan = Outfits.toDescription(outfit())
	t.eq(plan.properties, {
		Head = 0,
		Torso = fake(4),
		Shirt = fake(5),
		IdleAnimation = fake(6),
		HeadColor = { r = 255, g = 128, b = 0 },
		TorsoColor = { r = 1, g = 2, b = 3 },
		HeightScale = 1,
		WidthScale = 0.8,
		ProportionScale = 0.5,
	})
	t.eq(plan.accessories, {
		{ AccessoryType = "Hat", AssetId = fake(1), IsLayered = false },
		{ AccessoryType = "Jacket", AssetId = fake(2), IsLayered = true, Order = 3, Puffiness = 0.5 },
		{ AccessoryType = "Hair", AssetId = fake(3), IsLayered = true, Order = 2 },
	})
	local partial = Outfits.toDescription({ scales = { height = 1.05 } })
	t.eq(partial, { properties = { HeightScale = 1.05 } }, "a partial outfit sets only what it names")
end)

test("bad outfits list every problem", function(t)
	t.ok(contains(Outfits.validate(nil), "outfit must be a table"))
	local bad = outfit()
	bad.schema = "outfit/2"
	bad.extras = {}
	bad.accessories[1].type = "Cape"
	bad.accessories[2].id = 0
	bad.accessories[3].id = fake(1)
	bad.accessories[3].order = -1
	bad.accessories[3].puffiness = 2
	bad.accessories[3].tint = 1
	bad.body.Tail = fake(7)
	bad.clothing.Shirt = -5
	bad.colors.head = "orange"
	bad.colors.wings = "#000000"
	bad.scales.height = 2
	bad.scales.mass = 1
	local problems = Outfits.validate(bad)
	for _, needle in
		{
			"schema must be outfit/1",
			'unknown section "extras"',
			'accessories[1]: type "Cape" is not an AccessoryType',
			"accessories[2]: id must be an integer >= 1",
			"accessories[3]: id 11 appears twice",
			"accessories[3]: order must be an integer >= 0",
			"accessories[3]: puffiness must be in [0, 1]",
			'accessories[3]: unknown key "tint"',
			'body: unknown key "Tail"',
			"clothing.Shirt: id must be an integer >= 0",
			'colors.head must be "#RRGGBB"',
			'colors: unknown key "wings"',
			"scales.height 2 is outside 0.9..1.05",
			'scales: unknown key "mass"',
		}
	do
		t.ok(contains(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	t.throws(function()
		Outfits.toDescription(bad)
	end)
end)

test("rules override scale ranges and add limits and an allow predicate", function(t)
	local wide = { scales = { height = { min = 0.5, max = 2 } } }
	t.eq(Outfits.validate({ scales = { height = 2 } }, wide), {})
	t.eq(Outfits.validate({ scales = { width = 5 } }, wide), {}, "a scale without a rule range is free")
	local limits = {
		maxAccessories = 2,
		perType = { Hat = 1 },
		allow = function(kind: string, id: number): boolean
			return id ~= fake(5) and kind ~= "animations.Idle"
		end,
	}
	local problems = Outfits.validate({
		accessories = {
			{ type = "Hat", id = fake(1) },
			{ type = "Hat", id = fake(2) },
			{ type = "Back", id = fake(3) },
		},
		clothing = { Shirt = fake(5) },
		animations = { Idle = fake(6) },
	}, limits)
	t.ok(contains(problems, "3 accessories pass the limit of 2"))
	t.ok(contains(problems, "2 Hat accessories pass the limit of 1"))
	t.ok(contains(problems, "clothing.Shirt: id 15 is not allowed"))
	t.ok(contains(problems, "animations.Idle: id 16 is not allowed"))
	t.eq(Outfits.validate({ clothing = { Shirt = 0 } }, limits), {}, "0 (default) is always allowed")
end)

test("descriptions round-trip and merge keeps other accessory types", function(t)
	local plan = Outfits.toDescription(outfit())
	local snapshot = { properties = plan.properties, accessories = plan.accessories }
	local back = Outfits.fromDescription(snapshot)
	t.eq(back.scales, { height = 1, width = 0.8, proportion = 0.5 })
	t.eq(back.colors.head, { r = 255, g = 128, b = 0 })
	t.eq(back.body, { Head = 0, Torso = fake(4) })
	t.eq(back.accessories[2], { type = "Jacket", id = fake(2), layered = true, order = 3, puffiness = 0.5 })
	t.eq(Outfits.validate(back), {})
	local uniform = { accessories = { { type = "Hat", id = fake(9) } }, colors = { torso = "#000000" } }
	local merged = Outfits.merge(outfit(), uniform)
	t.eq(#merged.accessories, 3)
	t.eq(merged.accessories[3], { type = "Hat", id = fake(9) }, "the uniform hat replaces the own hat")
	t.eq(merged.colors.torso, "#000000")
	t.eq(merged.colors.head, "#FF8000", "unnamed keys stay")
	t.eq(Outfits.validate(merged), {})
	t.eq(Outfits.color("#zz0000"), nil)
	t.eq(Outfits.color({ r = 256, g = 0, b = 0 }), nil)
end)

test("OutfitsRoblox builds descriptions, applies with the available method and reads back", function(t)
	for _, async in { true, false } do
		local engine = FakeEconomyEngine.new({ applyAsync = async })
		local env = FakeEconomyEngine.env(engine)
		local r = env.roblox
		local players = env.services.Players
		local model = players:CreateHumanoidModelFromDescription(
			OutfitsRoblox.toInstance(Outfits.toDescription({ scales = { width = 0.9 } }), env),
			r.Enum.HumanoidRigType.R15
		)
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local ok, method = OutfitsRoblox.apply(humanoid, outfit(), nil, env)
		t.ok(ok)
		t.eq(method, if async then "ApplyDescriptionAsync" else "ApplyDescription")
		t.eq(engine.applied, { method })
		local worn = OutfitsRoblox.read(humanoid)
		t.eq(worn.scales.height, 1)
		t.eq(worn.colors.torso, { r = 1, g = 2, b = 3 })
		t.eq(worn.accessories[1], { type = "Hat", id = fake(1), layered = false })
		t.eq(worn.clothing, { Shirt = fake(5), Pants = 0, GraphicTShirt = 0 })
		-- A partial outfit patches: width set earlier stays, height changes.
		OutfitsRoblox.apply(humanoid, { scales = { height = 1.05 } }, nil, env)
		local patched = OutfitsRoblox.read(humanoid)
		t.eq({ patched.scales.height, patched.scales.width }, { 1.05, 0.8 })
		t.eq(#patched.accessories, 3, "no accessory list keeps the accessories")
		local refused, reason, problems = OutfitsRoblox.apply(humanoid, { scales = { height = 9 } }, nil, env)
		t.eq({ refused, reason }, { false, "invalid_outfit" })
		t.ok(contains(problems, "scales.height 9 is outside"))
	end
	local engine = FakeEconomyEngine.new()
	local env = FakeEconomyEngine.env(engine)
	t.throws(function()
		OutfitsRoblox.toInstance(
			{ properties = {}, accessories = { { AccessoryType = "Cape", AssetId = fake(1) } } } :: any,
			env
		)
	end)
end)

return cases
