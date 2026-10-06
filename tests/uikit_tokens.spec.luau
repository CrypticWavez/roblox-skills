--!strict
-- G4 specs: UIKit/Tokens (themes, overrides, WCAG contrast), UIKit/Style (FontFace, padding,
-- StyleSheet plan and its validator), UIKit/StyleRoblox (pure instructions, apply with injected
-- setters, retheme, link) and UIKit/Breakpoints (device classes, safe area, spans, queries).
-- The engine half of StyleRoblox (StyleRule:SetProperties, query conditions, precedence) is
-- probe ui_style_sheet.
local roblox = require("@lune/roblox")

local Breakpoints = require("../packages/UIKit/Breakpoints")
local Style = require("../packages/UIKit/Style")
local StyleRoblox = require("../packages/UIKit/StyleRoblox")
local Tokens = require("../packages/UIKit/Tokens")

local env = { roblox = roblox }

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------- Tokens

test("both shipped themes resolve, validate clean and are frozen", function(t)
	for _, theme in { "dark", "light" } do
		local tokens = Tokens.resolve(theme)
		t.eq(Tokens.validate(tokens), {}, theme)
		t.eq(tokens.theme, theme)
		t.eq(tokens.schema, Tokens.SCHEMA)
		t.ok(table.isfrozen(tokens) and table.isfrozen(tokens.color), theme .. " frozen")
		for _, slot in Tokens.SLOTS do
			t.ok(Tokens.isRgb(tokens.color[slot]), theme .. "." .. slot)
		end
		t.eq(tokens.tbd, { "accent", "danger", "success", "warning", "info" })
	end
	t.eq(Tokens.resolve().theme, Tokens.DEFAULT_THEME)
end)

test("the palette is greyscale: every slot of every theme has r = g = b", function(t)
	for theme, colors in Tokens.THEMES do
		for slot, rgb in colors do
			t.ok(rgb[1] == rgb[2] and rgb[2] == rgb[3], theme .. "." .. slot .. " is not grey")
		end
	end
end)

test("token digests are stable per theme and differ between themes", function(t)
	t.eq(Tokens.digest(Tokens.resolve("dark")), Tokens.digest(Tokens.resolve("dark")))
	t.ok(Tokens.digest(Tokens.resolve("dark")) ~= Tokens.digest(Tokens.resolve("light")))
	t.ok(string.match(Tokens.digest(Tokens.resolve()), "^%x%x%x%x%x%x%x%x$") ~= nil)
end)

test("WCAG maths: black on white is 21, same colour is 1, large text needs 3", function(t)
	t.near(Tokens.contrast({ 0, 0, 0 }, { 255, 255, 255 }), 21, 1e-9)
	t.near(Tokens.contrast({ 90, 90, 90 }, { 90, 90, 90 }), 1, 1e-9)
	t.near(Tokens.luminance({ 255, 255, 255 }), 1, 1e-9)
	local tokens = Tokens.resolve()
	t.eq(Tokens.requiredContrast(tokens, 18), 4.5)
	t.eq(Tokens.requiredContrast(tokens, 24), 3)
	t.eq(Tokens.requiredContrast(tokens, 19, true), 3)
	t.eq(Tokens.requiredContrast(tokens, 19, false), 4.5)
	t.throws(function()
		Tokens.luminance({ 256, 0, 0 })
	end, "out-of-range channel")
end)

test("overrides merge deeply, and an overridden hue slot leaves the TBD list", function(t)
	local tokens = Tokens.resolve("dark", { color = { accent = { 200, 200, 200 } }, space = { md = 14 } })
	t.eq(tokens.color.accent, { 200, 200, 200 })
	t.eq(tokens.space.md, 14)
	t.eq(tokens.space.sm, 8, "untouched siblings stay")
	t.eq(tokens.tbd, { "danger", "success", "warning", "info" })
	t.eq(Tokens.resolve().space.md, 12, "the base table is not mutated")
end)

test("resolve rejects unknown themes, unknown keys, wrong types and low contrast", function(t)
	t.ok(string.find(
		errorText(function()
			Tokens.resolve("sepia")
		end),
		"unknown theme sepia",
		1,
		true
	))
	t.ok(string.find(
		errorText(function()
			Tokens.resolve("dark", { space = { huge = 99 } })
		end),
		"space.huge: unknown token",
		1,
		true
	))
	t.ok(string.find(
		errorText(function()
			Tokens.resolve("dark", { space = { md = "12" } })
		end),
		"space.md: expected number, got string",
		1,
		true
	))
	-- Dark text on the dark background fails body contrast.
	t.ok(string.find(
		errorText(function()
			Tokens.resolve("dark", { color = { text = { 40, 40, 40 } } })
		end),
		"contrast text on background",
		1,
		true
	))
end)

test("validate reports each broken group with its path", function(t)
	t.eq(Tokens.validate(nil), { "tokens must be a table" })
	local broken: any = table.clone(Tokens.resolve() :: any)
	broken.schema = "uikit-tokens/0"
	broken.color = table.clone(broken.color)
	broken.color.surface = { 1, 2 }
	broken.textMin = 4
	broken.text = { body = { size = 2, font = "nope", weight = "Chunky", lineHeight = 9 } }
	broken.motion = { duration = { base = 9 }, spring = { soft = { dampingRatio = 0, frequency = 2 } } }
	local problems = Tokens.validate(broken)
	for _, needle in
		{
			"schema must be uikit-tokens/1",
			"color.surface: needs an { r, g, b } triple",
			"textMin must be >= textMinDocs",
			"text.body.size must be >= textMin",
			"text.body.font names no font role",
			"text.body.weight must be a FontWeight name",
			"text.body.lineHeight must be within 1-3",
			"motion.duration.base must be within 0-5 s",
			"motion.spring.soft needs dampingRatio > 0",
		}
	do
		t.ok(contains(problems, needle), needle)
	end
end)

test("colorblind overrides apply only for the named settings/1 mode", function(t)
	local options =
		{ colorblindMode = "deuteranopia", colorblind = { deuteranopia = { fill = { 255, 255, 255 } } } }
	t.eq(Tokens.resolve("dark", nil, options).color.fill, { 255, 255, 255 })
	t.eq(
		Tokens.resolve("dark", nil, { colorblindMode = "none", colorblind = options.colorblind }).color.fill,
		{
			236,
			236,
			236,
		}
	)
	t.throws(function()
		Tokens.resolve(
			"dark",
			nil,
			{ colorblindMode = "protanopia", colorblind = { protanopia = { teal = { 0, 1, 2 } } } }
		)
	end, "unknown slot in a colorblind table")
end)

test("Tokens.space passes numbers through and rejects unknown names", function(t)
	local tokens = Tokens.resolve()
	t.eq(Tokens.space(tokens, "lg"), 16)
	t.eq(Tokens.space(tokens, 7), 7)
	t.throws(function()
		Tokens.space(tokens, "gigantic")
	end)
end)

-- ---------------------------------------------------------------- Style

test("Style.text uses FontFace on a built-in family with the role's weight", function(t)
	local tokens = Tokens.resolve()
	local props = Style.text(tokens, "title", env)
	t.eq(typeof(props.FontFace), "Font")
	t.eq(props.FontFace.Family, "rbxasset://fonts/families/BuilderSans.json")
	t.eq(props.FontFace.Weight, roblox.Enum.FontWeight.Bold)
	t.eq(props.TextSize, 22)
	t.eq(props.TextColor3, roblox.Color3.fromRGB(246, 246, 246))
	t.eq(props.Font, nil, "never the legacy Font enum")
	t.eq(Style.font(tokens, "mono", env).Family, "rbxasset://fonts/families/RobotoMono.json")
	t.throws(function()
		Style.text(tokens, "shout", env)
	end)
	t.throws(function()
		Style.color(tokens, "chartreuse", env)
	end)
	t.ok(string.find(
		errorText(function()
			Style.color(tokens, "text", nil)
		end),
		"env.roblox",
		1,
		true
	))
end)

test("Style.padding expands one, two and four values like CSS", function(t)
	local tokens = Tokens.resolve()
	local one = Style.padding(tokens, "md", env)
	t.eq(one.PaddingLeft, roblox.UDim.new(0, 12))
	local two = Style.padding(tokens, { "sm", "lg" }, env)
	t.eq(
		{ two.PaddingTop.Offset, two.PaddingRight.Offset, two.PaddingBottom.Offset, two.PaddingLeft.Offset },
		{
			8,
			16,
			8,
			16,
		}
	)
	local four = Style.padding(tokens, { 1, 2, 3, 4 }, env)
	t.eq({
		four.PaddingTop.Offset,
		four.PaddingRight.Offset,
		four.PaddingBottom.Offset,
		four.PaddingLeft.Offset,
	}, {
		1,
		2,
		3,
		4,
	})
	t.eq(Style.stroke(tokens, "focus", "focus", env).Thickness, 3)
	t.throws(function()
		Style.stroke(tokens, "focus", "massive", env)
	end)
end)

test("the StyleSheet plan validates and every $Token reference resolves", function(t)
	for _, theme in { "dark", "light" } do
		local plan = Style.sheet(Tokens.resolve(theme))
		t.eq(Style.validateSheet(plan), {}, theme)
		t.eq(plan.schema, Style.PLAN_SCHEMA)
		t.eq(plan.tokens.ColorAccent.kind, "Color3")
		t.eq(plan.tokens.SpaceMd.value, { 0, 12 })
		t.eq(plan.tokens.FontBody.value.weight, "Regular")
	end
end)

test("validateSheet flags composed selectors, unknown tokens, bad states and stray children", function(t)
	local plan: any = Style.sheet(Tokens.resolve())
	plan.rules = {
		{ selector = ".Card .Title", priority = 0, properties = {} },
		{ selector = ".Button:Focused", priority = 0, properties = {} },
		{ selector = ".Button", priority = 0.5, properties = { BackgroundColor3 = "$ColorMauve" } },
		{ selector = "@Huge", priority = 0, properties = {} },
		{ selector = ".Panel", priority = 0, properties = {}, children = {} },
		{ selector = "Frame", priority = 0, properties = {} },
	}
	local problems = Style.validateSheet(plan)
	t.ok(contains(problems, "rules[1] .Card .Title: selector only one ::Modifier or :State"))
	t.ok(contains(problems, "rules[2] .Button:Focused: selector state must be a GuiState"))
	t.ok(contains(problems, "rules[3] .Button: priority must be an integer"))
	t.ok(contains(problems, "references unknown token $ColorMauve"))
	t.ok(contains(problems, "rules[4] @Huge: selector names no StyleQuery"))
	t.ok(contains(problems, "rules[5] .Panel: only @Query rules hold child rules"))
	t.ok(contains(problems, "rules[6] Frame: selector must start with .Tag or @Query"))
	t.eq(Style.validateSheet({ schema = "other" }), { "plan must be a uikit-stylesheet/1 table" })
end)

-- ---------------------------------------------------------------- StyleRoblox

test("StyleRoblox.instructions lists rules depth-first, then one query per breakpoint", function(t)
	local plan = Style.sheet(Tokens.resolve())
	local list = StyleRoblox.instructions(plan)
	t.eq(#list, #plan.rules + 1 + #plan.queries, "12 rules, 1 child rule, 8 queries")
	t.eq(list[1].name, "01_UIKitSurface")
	t.eq(list[12].name, "12_Compact")
	t.eq(list[13].parent, "12_Compact")
	t.eq(list[13].selector, ".UIKitTitle")
	t.eq(list[14].kind, "query")
	t.eq(list[14].name, "Compact")
	local bad: any = Style.sheet(Tokens.resolve())
	bad.rules = { { selector = ".A .B", priority = 0, properties = {} } }
	t.throws(function()
		StyleRoblox.instructions(bad)
	end, "an invalid plan is refused")
end)

test("StyleRoblox.apply builds the sheet tree with injected setters and rethemes in place", function(t)
	local plan = Style.sheet(Tokens.resolve("dark"))
	local properties: { [string]: any } = {}
	local conditions: { [string]: any } = {}
	local sheet = StyleRoblox.apply(plan, env, {
		setProperties = function(rule, props)
			properties[rule.Name] = props
		end,
		setConditions = function(query, values)
			conditions[query.Name] = values
		end,
	})
	t.eq(sheet.ClassName, "StyleSheet")
	t.eq(sheet.Name, "UIKit_dark")
	t.eq(sheet:GetAttribute("ColorAccent"), roblox.Color3.fromRGB(218, 218, 218))
	t.eq(sheet:GetAttribute("SpaceMd"), roblox.UDim.new(0, 12))
	t.eq(typeof(sheet:GetAttribute("FontBody")), "Font")
	local rules = 0
	for _, item in sheet:GetDescendants() do
		if item:IsA("StyleRule") then
			rules += 1
		end
	end
	t.eq(rules, 13)
	t.eq(properties["05_Primary"], { BackgroundColor3 = "$ColorAccent" }, "token references stay references")
	local compact = sheet:FindFirstChild("12_Compact")
	t.ok(compact and compact:FindFirstChild("01_UIKitTitle"), "query rule holds its child rule")
	t.eq(conditions.Compact.MaxSize, roblox.Vector2.new(899, 100000))
	t.eq(conditions.Touch.PreferredInput, roblox.Enum.PreferredInput.Touch)
	t.eq(conditions.Portrait.AspectRatioRange, roblox.NumberRange.new(0, 1))
	StyleRoblox.retheme(sheet, Style.sheet(Tokens.resolve("light")), env)
	t.eq(sheet:GetAttribute("ColorAccent"), roblox.Color3.fromRGB(50, 50, 50), "light accent after retheme")
	local gui = roblox.Instance.new("ScreenGui")
	local link = StyleRoblox.link(sheet, gui, env)
	t.eq(link.ClassName, "StyleLink")
	t.ok(link.StyleSheet == sheet and link.Parent == gui)
	t.throws(function()
		StyleRoblox.apply(plan, {})
	end, "env.roblox is required")
end)

-- ---------------------------------------------------------------- Breakpoints

test("classify maps viewport and input to phone, tablet, desktop, console and vr", function(t)
	local phone = Breakpoints.classify({ viewport = { 844, 390 }, input = "Touch" })
	t.eq(
		{ phone.device, phone.orientation, phone.compact, phone.touch, phone.columns },
		{ "phone", "landscape", true, true, 4 }
	)
	local portrait = Breakpoints.classify({ viewport = { 390, 844 }, input = "Touch" })
	t.eq(portrait.orientation, "portrait")
	t.eq(Breakpoints.classify({ viewport = { 1180, 820 }, input = "Touch" }).device, "tablet")
	t.eq(Breakpoints.classify({ viewport = { 2732, 2048 }, input = "Touch" }).device, "desktop")
	local desktop = Breakpoints.classify({ viewport = { 1920, 1080 } })
	t.eq({ desktop.device, desktop.compact, desktop.wide, desktop.input }, {
		"desktop",
		false,
		true,
		"KeyboardAndMouse",
	})
	t.eq(Breakpoints.classify({ viewport = { 800, 600 } }).compact, true, "narrow desktop is compact")
	local console = Breakpoints.classify({ viewport = { 1920, 1080 }, input = "Gamepad", tenFoot = true })
	t.eq({ console.device, console.scale, console.margin }, { "console", 1.25, 64 })
	t.eq(Breakpoints.classify({ viewport = { 1920, 1080 }, vr = true }).device, "vr")
	t.eq(Breakpoints.classify({ viewport = { 1920, 1080 }, uiScale = 1.5 }).scale, 1.5)
end)

test("safe area subtracts insets and spans fit the safe width", function(t)
	t.eq(
		Breakpoints.safeRect({ 844, 390 }, { left = 47, top = 0, right = 47, bottom = 21 }),
		{ x = 47, y = 0, w = 750, h = 369 }
	)
	t.eq(
		Breakpoints.safeRect({ 100, 100 }, { left = 80, top = 0, right = 80, bottom = 0 }).w,
		0,
		"never negative"
	)
	local class = Breakpoints.classify({ viewport = { 1920, 1080 } })
	t.near(Breakpoints.span(class, 12), 1920 - 64)
	t.near(Breakpoints.span(class, 99), Breakpoints.span(class, 12), 1e-9, "clamped to the column count")
	t.ok(Breakpoints.span(class, 6) < Breakpoints.span(class, 12) / 2 + 1)
end)

test("classify rejects bad info and unknown convention keys", function(t)
	local problems = Breakpoints.validate({
		viewport = { 0, 100 },
		input = "Mouse",
		insets = { left = -1, top = 0, right = 0, bottom = 0 },
		uiScale = 0,
	})
	t.ok(contains(problems, "viewport must be { width > 0, height > 0 }"))
	t.ok(contains(problems, "input must be KeyboardAndMouse, Touch or Gamepad"))
	t.ok(contains(problems, "insets.left must be a number >= 0"))
	t.ok(contains(problems, "uiScale must be a number > 0"))
	t.throws(function()
		Breakpoints.classify({ viewport = { 0, 0 } })
	end)
	t.ok(string.find(
		errorText(function()
			Breakpoints.classify({ viewport = { 100, 100 }, convention = { phoneTall = 3 } })
		end),
		"unknown convention key phoneTall",
		1,
		true
	))
	t.eq(
		Breakpoints.classify({ viewport = { 600, 400 }, input = "Touch", convention = { phoneShort = 300 } }).device,
		"tablet",
		"a game can move the threshold"
	)
end)

test("Breakpoints.queries mirror the classify thresholds the StyleSheet plan uses", function(t)
	local names = {}
	for _, query in Breakpoints.queries() do
		table.insert(names, query.name)
	end
	t.eq(
		names,
		{ "Compact", "Regular", "Wide", "Portrait", "Touch", "Gamepad", "TextLarge", "ReducedMotion" }
	)
	local queries = Breakpoints.queries({ compactWidth = 700 })
	t.eq(queries[1].conditions.MaxSize[1], 699)
	t.eq(queries[2].conditions.MinSize[1], 700)
end)

return cases
