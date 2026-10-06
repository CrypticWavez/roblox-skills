--!strict
-- @tier T3
-- probe: ui_gallery_audit
-- AuditRoblox: runs UIKit/Audit on a live ScreenGui in Studio (docs/uikit.md "Audits").
-- Rectangles are the engine's AbsolutePosition/AbsoluteSize (layouts, constraints and
-- AutomaticSize included, which Lune cannot compute), TextFits is the engine's own, the safe
-- area is the rectangle of a probe ScreenGui with ScreenInsets CoreUISafeInsets and the device
-- class comes from the camera viewport and UserInputService.PreferredInput. Two passes the pure
-- audit cannot do alone:
--   pseudo-localisation: every text object briefly shows Localize.pseudo(text) (about 40 percent
--     longer, accented), one frame later TextFits is read and the text restored; overflow is a
--     text_fit warning with detail.pseudo = true;
--   legacy fonts: the legacy_font rule sees the FontFace families of the old Font enum values
--     (LegacyArial, Arial, GothamSSm); this adapter also reads each text object's Font enum and
--     flags legacy values the family check missed. Lune cannot read Font ("malformed property
--     info"), so there only the FontFace rule runs.
-- audit(root, env, options) yields (it waits frames), so call it from a spawned thread or a
-- probe. It only reads and restores what it changed.
local Audit = require("./Audit")
local Breakpoints = require("./Breakpoints")
local Env = require("../GameKit/Env")
local Localize = require("./Localize")

local AuditRoblox = {}

local LEGACY_FONT_ENUMS =
	{ "Legacy", "Arial", "ArialBold", "Gotham", "GothamMedium", "GothamBold", "GothamBlack" }

function AuditRoblox.measure(instance: any): Audit.Rect?
	local position, size = instance.AbsolutePosition, instance.AbsoluteSize
	return { x = position.X, y = position.Y, w = size.X, h = size.Y }
end

local function textObjects(root: any): { any }
	local out = {}
	local list = { root }
	for _, item in root:GetDescendants() do
		table.insert(list, item)
	end
	for _, item in list do
		if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
			table.insert(out, item)
		end
	end
	return out
end

-- Same paths as the snapshot (duplicate sibling names get #2, #3, ...).
local pathOf = Audit.pathOf

-- The device class for the current client (viewport, input, insets as a safe rectangle).
function AuditRoblox.class(env: any): Breakpoints.Class
	local r = env.roblox
	local workspace = Env.service(env, "Workspace")
	local input = Env.service(env, "UserInputService")
	local guiService = Env.service(env, "GuiService")
	local players = Env.service(env, "Players")
	local viewport = workspace.CurrentCamera.ViewportSize
	-- A throwaway ScreenGui with CoreUISafeInsets measures the safe area.
	local probe = r.Instance.new("ScreenGui")
	probe.Name = "UIKitSafeAreaProbe"
	probe.ScreenInsets = r.Enum.ScreenInsets.CoreUISafeInsets
	probe.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	env.wait()
	local p, s = probe.AbsolutePosition, probe.AbsoluteSize
	probe:Destroy()
	return Breakpoints.classify({
		viewport = { viewport.X, viewport.Y },
		input = input.PreferredInput.Name,
		tenFoot = guiService:IsTenFootInterface(),
		insets = {
			left = math.max(p.X, 0),
			top = math.max(p.Y, 0),
			right = math.max(viewport.X - (p.X + s.X), 0),
			bottom = math.max(viewport.Y - (p.Y + s.Y), 0),
		},
	})
end

-- TextFits per path after showing pseudo-localised text for one frame (text restored).
function AuditRoblox.pseudoFits(root: any, env: any, textFits: ((any) -> boolean?)?): { [string]: boolean }
	local read = textFits or function(instance: any): boolean?
		return instance.TextFits
	end
	local objects = textObjects(root)
	local saved = {}
	for _, item in objects do
		saved[item] = item.Text
		if item.Text ~= "" then
			item.Text = Localize.pseudo(item.Text)
		end
	end
	local ok, result = pcall(function()
		env.wait()
		local fits: { [string]: boolean } = {}
		for _, item in objects do
			if saved[item] ~= "" then
				fits[pathOf(root, item)] = read(item) ~= false
			end
		end
		return fits
	end)
	for item, text in saved do
		item.Text = text
	end
	if not ok then
		error(result, 2)
	end
	return result
end

export type Options = {
	class: Breakpoints.Class?,
	pseudo: boolean?,
	rules: { string }?,
	entry: string?,
	-- Overrides for runs without a renderer (Lune specs); Studio uses the engine values.
	measure: ((any) -> Audit.Rect?)?,
	textFits: ((any) -> boolean?)?,
}

-- The ui-audit/1 report for a live tree (yields). options.class defaults to AuditRoblox.class.
function AuditRoblox.audit(root: any, env: any, options: Options?): Audit.Report
	local o = options or {}
	env.wait()
	local class = o.class or AuditRoblox.class(env)
	local textFits = o.textFits or function(instance: any): boolean?
		return instance.TextFits
	end
	local nodes = Audit.fromInstances(root, {
		measure = o.measure or AuditRoblox.measure,
		textFits = textFits,
	})
	local auditOptions: Audit.Options = {
		device = class.device,
		touch = class.touch,
		viewport = class.viewport,
		safe = class.safe,
		minTouch = class.minTouch,
		rules = o.rules,
		entry = o.entry,
		shadows = Audit.countShadows(root),
	}
	local report = Audit.run(nodes, auditOptions)
	local extra: { Audit.Finding } = {}
	if o.pseudo ~= false and (o.rules == nil or table.find(o.rules, "text_fit")) then
		local fits = AuditRoblox.pseudoFits(root, env, o.textFits)
		for _, node in nodes do
			if node.visible and fits[node.path] == false and node.textFits ~= false then
				table.insert(extra, {
					rule = "text_fit",
					severity = "warn",
					path = node.path,
					detail = { pseudo = true },
				})
			end
		end
	end
	if o.rules == nil or table.find(o.rules, "legacy_font") then
		for _, item in textObjects(root) do
			local readable, font = pcall(function(): any
				return item.Font
			end)
			local name = if readable and font ~= nil then font.Name else nil
			if name and table.find(LEGACY_FONT_ENUMS, name) then
				local path = pathOf(root, item)
				local already = false
				for _, finding in report.findings do
					if finding.rule == "legacy_font" and finding.path == path then
						already = true
					end
				end
				if not already then
					table.insert(
						extra,
						{ rule = "legacy_font", severity = "error", path = path, detail = { font = name } }
					)
				end
			end
		end
	end
	for _, finding in extra do
		table.insert(report.findings, finding)
		report.counts[finding.rule] = (report.counts[finding.rule] or 0) + 1
		if finding.severity == "error" then
			report.ok = false
		end
	end
	table.sort(report.findings, function(a: Audit.Finding, b: Audit.Finding): boolean
		if a.rule ~= b.rule then
			return a.rule < b.rule
		end
		return a.path < b.path
	end)
	return report
end

return AuditRoblox
