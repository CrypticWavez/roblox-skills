--!strict
-- G4 probe registry (prefixes ui_ and inputmap_): engine facts the UIKit Lune specs cannot see.
-- Run each in a client play session on the unpublished diagnostic place (tests/engine/<probe>.luau
-- entries); until then they are PENDING. No requires: kit modules come through ctx.kit. Runs
-- without a renderer (the Lune registry spec) supply fakes through ctx.env.services:
--   UIKitEvents  { on, onChanged }   instead of engine events (tests/fakes/FakeUIEvents)
--   UIKitLayout  { measure, textFits, class, static }   instead of AbsoluteSize, TextFits and the
--                device; static = true (a measure that ignores layouts) skips the layout rules
-- In Studio those are absent and the probes use the engine.
--   ui_ease_parity     UIKit/Ease against TweenService:GetValue, 101 samples per style/direction
--   ui_nav_keyboard    Nav focus, modal selection stop and focus restore through GuiService
--   ui_gallery_audit   every gallery story mounted in PlayerGui and audited (AuditRoblox: real
--                      layout, TextFits, pseudo-localisation, legacy fonts)
--   ui_style_sheet     StyleRoblox builds a StyleSheet; a tagged button picks up a token colour
--   inputmap_contexts  InputMapRoblox builds IAS contexts, actions and bindings from the map
local probes = {}

local function services(ctx: any): any
	return ctx.env.services or {}
end

local function playerGui(ctx: any): any?
	local players = services(ctx).Players
	local player = players and players.LocalPlayer
	return player and player:FindFirstChildOfClass("PlayerGui")
end

-- A UIKit build context for this run (engine events in Studio, fakes when supplied).
local function uiContext(ctx: any, extra: { [string]: any }?): any
	local Build = ctx.kit("UIKit/Build")
	local events = services(ctx).UIKitEvents
	local layout = services(ctx).UIKitLayout
	local options: { [string]: any } = { env = ctx.env }
	if events then
		options.on = events.on
		options.onChanged = events.onChanged
	end
	if layout then
		options.measure = layout.measure
		options.class = layout.class
	end
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return Build.context(options)
end

function probes.ui_ease_parity(ctx: any)
	local Ease = ctx.kit("UIKit/Ease")
	local tween = services(ctx).TweenService
	if not ctx.check("tween_service", tween ~= nil, "env.services.TweenService") then
		return
	end
	local enum = ctx.env.roblox.Enum
	local worst = 0
	for _, style in Ease.STYLE_NAMES do
		for _, direction in Ease.DIRECTION_NAMES do
			local maxDiff, at = 0, 0
			for index = 0, 100 do
				local alpha = index / 100
				local ours = Ease.get(style, direction, alpha)
				local theirs = tween:GetValue(alpha, enum.EasingStyle[style], enum.EasingDirection[direction])
				local diff = math.abs(ours - theirs)
				if diff > maxDiff then
					maxDiff, at = diff, alpha
				end
			end
			worst = math.max(worst, maxDiff)
			ctx.check(style .. "_" .. direction, maxDiff < 1e-4, { maxDiff = maxDiff, alpha = at })
		end
	end
	ctx.check("all_within_1e-4", worst < 1e-4, { worst = worst })
end

function probes.ui_nav_keyboard(ctx: any)
	local Nav = ctx.kit("UIKit/Nav")
	local Button = ctx.kit("UIKit/Components/Button")
	local Build = ctx.kit("UIKit/Build")
	local guiService = services(ctx).GuiService
	if not ctx.check("gui_service", guiService ~= nil, "env.services.GuiService") then
		return
	end
	local r = ctx.env.roblox
	local ui = uiContext(ctx)
	local gui = Build.screenGui(ui, "UIKitProbeNav", "panel")
	gui.Parent = playerGui(ctx)
	local function screen(name: string, count: number): (any, { any })
		local root = Build.surface(ui, name, "surface", { Size = r.UDim2.fromOffset(400, 300) }, gui)
		Build.list(ui, root, "Vertical", { gap = "sm" })
		local buttons = {}
		for index = 1, count do
			local handle = Button.mount({ text = name .. " " .. index, layoutOrder = index }, ui, root)
			table.insert(buttons, handle.root)
		end
		return root, buttons
	end
	local rootA, buttonsA = screen("ScreenA", 3)
	local rootB, buttonsB = screen("ModalB", 2)
	rootB.Visible = false
	local nav = Nav.new({
		selection = Nav.guiSelection(guiService),
		preferredInput = function(): string
			return "Gamepad"
		end,
	}, ctx.env)
	ctx.env.wait()
	nav:push({ id = "screen_a", root = rootA })
	ctx.check(
		"push_selects_first",
		guiService.SelectedObject == buttonsA[1],
		tostring(guiService.SelectedObject)
	)
	guiService.SelectedObject = buttonsA[2]
	ctx.check(
		"select_assignable",
		guiService.SelectedObject == buttonsA[2],
		tostring(guiService.SelectedObject)
	)
	nav:modal({ id = "modal_b", root = rootB })
	ctx.check(
		"modal_selects_inside",
		guiService.SelectedObject == buttonsB[1],
		tostring(guiService.SelectedObject)
	)
	ctx.check("modal_group", rootB.SelectionGroup == true)
	ctx.check(
		"modal_stops_edges",
		rootB.SelectionBehaviorUp == r.Enum.SelectionBehavior.Stop
			and rootB.SelectionBehaviorLeft == r.Enum.SelectionBehavior.Stop
	)
	ctx.check("back_closes_modal", nav:back() == true and nav:depth() == 1, nav:ids())
	ctx.check("focus_restored", guiService.SelectedObject == buttonsA[2], tostring(guiService.SelectedObject))
	ctx.check("root_back_unhandled", nav:back() == false)
	nav:destroy()
	guiService.SelectedObject = nil
	gui:Destroy()
end

-- Rules that need no layout engine (colours, sizes, fonts, TextFits).
local BASE_RULES = { "contrast", "text_size", "legacy_font", "text_scaled", "text_fit", "canvas_group_size" }
-- Gallery stories that are a single screen, so overlap and gamepad reachability apply.
local SCREEN_STORIES = { SettingsPanel = true, InventoryGrid = true, Tabs = true, ConfirmDialog = true }

function probes.ui_gallery_audit(ctx: any)
	local Stories = ctx.kit("UIKit/Gallery/Stories")
	local AuditRoblox = ctx.kit("UIKit/AuditRoblox")
	local Build = ctx.kit("UIKit/Build")
	local layout = services(ctx).UIKitLayout
	local r = ctx.env.roblox
	local ui = uiContext(ctx)
	local clock = ui.runner:attach(ctx.env)
	local gui = Build.screenGui(ui, "UIKitProbeGallery", "panel")
	gui.Parent = playerGui(ctx)
	local errors, warnings, built = 0, 0, 0
	for _, story in Stories.list(ui) do
		local frame = Build.frame(ui, story.name, { Size = r.UDim2.fromScale(1, 1) }, gui)
		local ok, cleanup = pcall(story.build, frame)
		ctx.check("builds_" .. story.name, ok, if ok then nil else tostring(cleanup))
		if not ok then
			frame:Destroy()
			continue
		end
		built += 1
		-- Audit the resting state: let enter transitions finish (at most 2 s; a story that keeps
		-- animating, such as Countdown, is audited wherever it is then).
		ctx.env.wait()
		for _ = 1, 120 do
			if ui.runner:count() == 0 then
				break
			end
			ctx.env.wait(1 / 60)
		end
		local rules = table.clone(BASE_RULES)
		if not (layout and layout.static) then
			-- Real layout: sizes and positions are the engine's.
			table.insert(rules, "touch_target")
			table.insert(rules, "safe_area")
			if SCREEN_STORIES[story.name] then
				-- Stories that are one screen; the others stack variants for preview.
				table.insert(rules, "overlap")
				table.insert(rules, "gamepad_reachable")
			end
		end
		local auditOk, report = pcall(AuditRoblox.audit, frame, ctx.env, {
			class = layout and layout.class,
			measure = layout and layout.measure,
			textFits = layout and layout.textFits,
			rules = rules,
		})
		if ctx.check("audits_" .. story.name, auditOk, if auditOk then nil else tostring(report)) then
			for _, finding in report.findings do
				if finding.severity == "error" then
					errors += 1
				else
					warnings += 1
				end
			end
			ctx.check("clean_" .. story.name, report.ok, report.findings)
		end
		cleanup()
		frame:Destroy()
	end
	ctx.check("stories_built", built >= 25, built)
	ctx.check("no_audit_errors", errors == 0, { errors = errors, warnings = warnings })
	clock:Disconnect()
	gui:Destroy()
end

function probes.ui_style_sheet(ctx: any)
	local Style = ctx.kit("UIKit/Style")
	local StyleRoblox = ctx.kit("UIKit/StyleRoblox")
	local Tokens = ctx.kit("UIKit/Tokens")
	local Build = ctx.kit("UIKit/Build")
	local r = ctx.env.roblox
	local plan = Style.sheet(Tokens.resolve("dark"))
	local ok, sheet = pcall(StyleRoblox.apply, plan, ctx.env)
	if not ctx.check("apply", ok, if ok then nil else tostring(sheet)) then
		return
	end
	ctx.check(
		"token_attribute",
		sheet:GetAttribute("ColorAccent") == Style.color(Tokens.resolve("dark"), "accent", ctx.env)
	)
	local rules = 0
	for _, item in sheet:GetDescendants() do
		if item:IsA("StyleRule") then
			rules += 1
		end
	end
	ctx.check("rule_count", rules == #StyleRoblox.instructions(plan) - #plan.queries, rules)
	local ui = uiContext(ctx)
	local gui = Build.screenGui(ui, "UIKitProbeStyle", "panel")
	StyleRoblox.link(sheet, gui, ctx.env)
	sheet.Parent = gui
	-- A bare tagged Frame: only the stylesheet can colour it.
	local frame = Build.make(ui, "Frame", { Name = "Styled", Size = r.UDim2.fromOffset(100, 40) }, gui)
	frame:AddTag("Primary")
	gui.Parent = playerGui(ctx)
	ctx.env.wait()
	ctx.env.wait()
	local expected = Style.color(Tokens.resolve("dark"), "accent", ctx.env)
	ctx.check("rule_applies", frame.BackgroundColor3 == expected, tostring(frame.BackgroundColor3))
	StyleRoblox.retheme(sheet, Style.sheet(Tokens.resolve("light")), ctx.env)
	ctx.env.wait()
	ctx.env.wait()
	local light = Style.color(Tokens.resolve("light"), "accent", ctx.env)
	ctx.check("retheme_applies", frame.BackgroundColor3 == light, tostring(frame.BackgroundColor3))
	gui:Destroy()
end

function probes.inputmap_contexts(ctx: any)
	local InputMap = ctx.kit("GameKit/InputMap")
	local InputMapRoblox = ctx.kit("GameKit/InputMapRoblox")
	local TouchActionButton = ctx.kit("UIKit/Components/TouchActionButton")
	local map = InputMap.defaults()
	local ok, built = pcall(InputMapRoblox.build, map, ctx.env, { parent = playerGui(ctx) })
	if not ctx.check("build", ok, if ok then nil else tostring(built)) then
		return
	end
	local contexts = built.contexts
	ctx.check(
		"priorities",
		contexts.gameplay.Priority == 100
			and contexts.ui.Priority == 200
			and contexts.cinematic.Priority == 300,
		{ contexts.gameplay.Priority, contexts.ui.Priority, contexts.cinematic.Priority }
	)
	ctx.check("cinematic_sinks_off", contexts.cinematic.Sink == true and contexts.cinematic.Enabled == false)
	local missing = {}
	for name, spec in map.actions do
		local action = built.actions[name]
		if action == nil or action.Type ~= ctx.env.roblox.Enum.InputActionType[spec.type] then
			table.insert(missing, name)
		end
	end
	table.sort(missing)
	ctx.check("every_action_built", #missing == 0, missing)
	local back = built.actions["ui.back"]
	local keys = {}
	for _, binding in back:GetChildren() do
		if binding:IsA("InputBinding") then
			table.insert(keys, binding.KeyCode.Name)
		end
	end
	table.sort(keys)
	ctx.check("back_keys", table.find(keys, "Backspace") ~= nil and table.find(keys, "ButtonB") ~= nil, keys)
	local ui = uiContext(ctx)
	local button = TouchActionButton.mount({
		action = "cinematic.skip",
		uiKey = "skip_button",
		labelKey = "input.cinematic.skip",
		glyph = ">",
		alwaysVisible = true,
	}, ui)
	local made = built:bindButton(button.root)
	ctx.check("touch_button_binds", made == 1, made)
	built:setEnabled("cinematic", true)
	ctx.check("context_toggles", contexts.cinematic.Enabled == true)
	button:destroy()
	built:destroy()
end

return probes
