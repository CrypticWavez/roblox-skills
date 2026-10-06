--!strict
-- G4 specs: the G4 probe registries (fixtures/kits/shared/ui_probes.luau and cin_probes.luau) run
-- in Lune through GameKit/Probe against FakeEnv, with fakes for what Lune lacks: TweenService
-- (GetValue backed by UIKit/Ease, so ui_ease_parity here proves only that the probe runs; the
-- parity itself is the Studio run), GuiService (a SelectedObject field), UIKitEvents
-- (FakeUIEvents), UIKitLayout (Audit.staticMeasure on a phone class, static = true), a
-- RunService whose PreRender the spec fires every 1/60 s, and a scriptable camera table. Each
-- probe must finish with the expected checks; seeded faults (a biased TweenService, missing
-- services, text that never fits) must fail the named checks. Passing here is not engine
-- verification: the six probes stay PENDING until they run in Studio.
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Audit = require("../packages/UIKit/Audit")
local Breakpoints = require("../packages/UIKit/Breakpoints")
local Ease = require("../packages/UIKit/Ease")
local FakeEnv = require("./fakes/FakeEnv")
local FakeUIEvents = require("./fakes/FakeUIEvents")
local Probe = require("../packages/GameKit/Probe")
local Signal = require("../packages/GameKit/Signal")

local UI_PROBES = require("../fixtures/kits/shared/ui_probes")
local CIN_PROBES = require("../fixtures/kits/shared/cin_probes")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

-- Kit modules the probes load, required here at the top level: Lune's require yields the first
-- time it loads a module, and a yield inside a FakeEnv thread would park it for good.
local KITS: { [string]: any } = {
	["Cinematics/Cinematics"] = require("../packages/Cinematics/Cinematics"),
	["Cinematics/CinematicsRoblox"] = require("../packages/Cinematics/CinematicsRoblox"),
	["GameKit/InputMap"] = require("../packages/GameKit/InputMap"),
	["GameKit/InputMapRoblox"] = require("../packages/GameKit/InputMapRoblox"),
	["UIKit/AuditRoblox"] = require("../packages/UIKit/AuditRoblox"),
	["UIKit/Build"] = require("../packages/UIKit/Build"),
	["UIKit/Components/Button"] = require("../packages/UIKit/Components/Button"),
	["UIKit/Components/TouchActionButton"] = require("../packages/UIKit/Components/TouchActionButton"),
	["UIKit/Ease"] = Ease,
	["UIKit/Gallery/Stories"] = require("../packages/UIKit/Gallery/Stories"),
	["UIKit/Nav"] = require("../packages/UIKit/Nav"),
	["UIKit/Style"] = require("../packages/UIKit/Style"),
	["UIKit/StyleRoblox"] = require("../packages/UIKit/StyleRoblox"),
	["UIKit/Tokens"] = require("../packages/UIKit/Tokens"),
}

local function kitLoader(path: string): any
	local module = KITS[path]
	if module == nil then
		error("uikit_probes.spec: preload " .. path .. " in KITS", 2)
	end
	return module
end

local PHONE = Breakpoints.classify({
	viewport = { 844, 390 },
	input = "Touch",
	insets = { left = 47, right = 47, top = 0, bottom = 21 },
})

export type Options = {
	tweenBias: number?,
	without: { string }?,
	textFits: ((any) -> boolean?)?,
}

-- A FakeEnv with every fake the G4 probes look for (minus options.without).
local function probeEnv(options: Options?): (any, any, any)
	local o: Options = options or {}
	local env = FakeEnv.new({ roblox = roblox, seed = "g4-probes" })
	local preRender = Signal.new(env)
	local bias = o.tweenBias or 0
	local services: { [string]: any } = {
		RunService = { PreRender = preRender },
		TweenService = {
			GetValue = function(_self: any, alpha: number, style: any, direction: any): number
				local value = Ease.get(style.Name, direction.Name, alpha)
				return if style.Name == "Quad" then value + bias * math.sin(alpha * math.pi) else value
			end,
		},
		GuiService = { SelectedObject = nil },
		UIKitLayout = {
			measure = Audit.staticMeasure(PHONE.viewport, PHONE.safe),
			textFits = o.textFits or function(): boolean?
				return true
			end,
			class = PHONE,
			static = true,
		},
	}
	local hub = FakeUIEvents.new()
	services.UIKitEvents = { on = hub.on, onChanged = hub.onChanged }
	local camera = {
		CameraType = roblox.Enum.CameraType.Custom,
		CFrame = roblox.CFrame.new(0, 5, 10),
		Focus = roblox.CFrame.new(),
		FieldOfView = 70,
		Destroying = Signal.new(env),
	}
	services.Workspace = { CurrentCamera = camera }
	local playerGui = roblox.Instance.new("Folder")
	playerGui.Name = "PlayerGui"
	services.Players = {
		LocalPlayer = {
			FindFirstChildOfClass = function(_self: any, class: string): any
				return if class == "PlayerGui" then playerGui else nil
			end,
		},
	}
	for _, name in o.without or {} do
		services[name] = nil
	end
	for name, service in services do
		env:register(name, service)
	end
	return env, preRender, playerGui
end

export type Result = { summary: any, checks: { [string]: { ok: boolean, detail: any } }, lines: { string } }

-- Runs the named probes on a spawned thread, driving time and PreRender at 60 Hz.
local function run(registry: any, only: { string }, options: Options?): Result
	local env, preRender = probeEnv(options)
	local lines = {}
	local summary = nil
	env.spawn(function()
		summary = Probe.runAll(registry, {
			env = env,
			kit = kitLoader,
			only = only,
			emit = function(line: string)
				table.insert(lines, line)
			end,
		})
	end)
	local frames = 0
	while summary == nil and frames < 3000 do
		env:flush()
		env:advance(1 / 60)
		preRender:Fire(1 / 60)
		frames += 1
	end
	assert(
		summary ~= nil,
		"probe run did not finish: " .. table.concat(lines, "\n") .. table.concat(env.errors, "\n")
	)
	local checks = {}
	for _, line in lines do
		if string.sub(line, 1, #Probe.CHECK_PREFIX) == Probe.CHECK_PREFIX then
			local data = serde.decode("json", string.sub(line, #Probe.CHECK_PREFIX + 1))
			checks[data.check] = { ok = data.ok, detail = data.detail }
		end
	end
	return { summary = summary, checks = checks, lines = lines }
end

local function failedChecks(result: Result): { string }
	local out = {}
	for name, check in result.checks do
		if not check.ok then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

-- ---------------------------------------------------------------- passes with fakes

test("ui_ease_parity runs every style and direction (fake GetValue)", function(t)
	local result = run(UI_PROBES, { "ui_ease_parity" })
	t.eq(failedChecks(result), {}, table.concat(result.lines, "\n"))
	t.eq(result.summary.checks, #Ease.STYLE_NAMES * #Ease.DIRECTION_NAMES + 2)
	t.ok(result.checks["Quad_InOut"].ok)
	t.ok(result.summary.ok)
end)

test("ui_ease_parity fails the styles that drift and names where (failure case)", function(t)
	local result = run(UI_PROBES, { "ui_ease_parity" }, { tweenBias = 1e-3 })
	t.eq(failedChecks(result), { "Quad_In", "Quad_InOut", "Quad_Out", "all_within_1e-4" })
	t.near(result.checks.Quad_In.detail.alpha, 0.5, 1e-9, "the worst sample is reported")
	t.eq(result.summary.ok, false)
	local missing = run(UI_PROBES, { "ui_ease_parity" }, { without = { "TweenService" } })
	t.eq(failedChecks(missing), { "tween_service" })
end)

test("ui_nav_keyboard: push selects, modal stops edges, back restores focus", function(t)
	local result = run(UI_PROBES, { "ui_nav_keyboard" })
	t.eq(failedChecks(result), {}, table.concat(result.lines, "\n"))
	for _, name in
		{
			"push_selects_first",
			"select_assignable",
			"modal_selects_inside",
			"modal_group",
			"modal_stops_edges",
			"back_closes_modal",
			"focus_restored",
			"root_back_unhandled",
		}
	do
		t.ok(result.checks[name] and result.checks[name].ok, name)
	end
	local missing = run(UI_PROBES, { "ui_nav_keyboard" }, { without = { "GuiService" } })
	t.eq(failedChecks(missing), { "gui_service" })
end)

test("ui_gallery_audit builds and audits every story (layout-free rules in Lune)", function(t)
	local result = run(UI_PROBES, { "ui_gallery_audit" })
	t.eq(failedChecks(result), {}, table.concat(result.lines, "\n"))
	t.ok(result.checks.stories_built.ok)
	t.ok(result.checks.stories_built.detail >= 25, "stories built")
	t.ok(result.checks.no_audit_errors.ok)
end)

test("ui_gallery_audit flags text that does not fit (failure case)", function(t)
	local result = run(UI_PROBES, { "ui_gallery_audit" }, {
		textFits = function(): boolean?
			return false
		end,
	})
	local failed = failedChecks(result)
	t.ok(table.find(failed, "no_audit_errors") ~= nil, "text_fit errors counted")
	t.ok(table.find(failed, "clean_Button") ~= nil, "a story with text is not clean")
	local detail = result.checks.clean_Button.detail
	t.ok(type(detail) == "table" and #detail > 0 and detail[1].rule == "text_fit", "the rule is named")
	t.eq(result.checks.builds_Button.ok, true, "building still worked")
end)

test("ui_style_sheet: apply needs the engine (SetProperties); everything else waits for Studio", function(t)
	local result = run(UI_PROBES, { "ui_style_sheet" })
	local apply = result.checks.apply
	t.ok(apply ~= nil, "the apply check ran")
	if apply.ok then
		-- A Lune that grows StyleRule:SetProperties runs the rest; the colour checks need a renderer.
		t.ok(result.checks.token_attribute.ok, "token attribute")
		t.ok(result.checks.rule_count.ok, "rule count")
	else
		t.ok(string.find(tostring(apply.detail), "SetProperties", 1, true) ~= nil, tostring(apply.detail))
		t.eq(result.summary.checks, 1, "stops after apply")
	end
end)

test("inputmap_contexts builds the IAS tree and binds a TouchActionButton", function(t)
	local result = run(UI_PROBES, { "inputmap_contexts" })
	t.eq(failedChecks(result), {}, table.concat(result.lines, "\n"))
	for _, name in
		{
			"build",
			"priorities",
			"cinematic_sinks_off",
			"every_action_built",
			"back_keys",
			"touch_button_binds",
			"context_toggles",
		}
	do
		t.ok(result.checks[name] and result.checks[name].ok, name)
	end
end)

test("cin_play_sample follows the sample, fires events once, restores the camera, skips", function(t)
	local result = run(CIN_PROBES, { "cin_play_sample" })
	t.eq(failedChecks(result), {}, table.concat(result.lines, "\n"))
	for _, name in
		{
			"follows_sample",
			"aims_at_look_at",
			"fov_follows",
			"scriptable_while_playing",
			"letterbox_shown",
			"finished",
			"overlay_removed",
			"events_once_in_order",
			"camera_type_restored",
			"fov_restored",
			"skip_accepted",
			"skipped",
			"skip_fires_only_fire_events",
			"camera_restored_after_skip",
		}
	do
		t.ok(result.checks[name] and result.checks[name].ok, name)
	end
	local missing = run(CIN_PROBES, { "cin_play_sample" }, { without = { "Workspace" } })
	t.eq(failedChecks(missing), { "camera" })
end)

test("every G4 probe in the registries is covered here and has a Studio entry", function(t)
	local fs = require("@lune/fs")
	local covered = {
		"ui_ease_parity",
		"ui_nav_keyboard",
		"ui_gallery_audit",
		"ui_style_sheet",
		"inputmap_contexts",
		"cin_play_sample",
	}
	local names = {}
	for name in UI_PROBES do
		table.insert(names, name)
	end
	for name in CIN_PROBES do
		table.insert(names, name)
	end
	table.sort(names)
	local sorted = table.clone(covered)
	table.sort(sorted)
	t.eq(names, sorted)
	for _, name in covered do
		t.ok(fs.isFile("tests/engine/" .. name .. ".luau"), "tests/engine/" .. name .. ".luau")
	end
end)

return cases
