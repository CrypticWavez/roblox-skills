--!strict
-- @tier T0
-- Breakpoints: device classes (phone, tablet, desktop, console, vr) from the viewport size,
-- the last input type (UserInputService.PreferredInput: Touch, Gamepad, KeyboardAndMouse) and
-- the ten-foot/VR flags, plus the safe-area rectangle from insets and the layout that goes
-- with each class (columns, margins, UI scale, minimum touch target). Pure: the adapter passes
-- ViewportSize, PreferredInput, GuiService:IsTenFootInterface() and the inset rectangle.
-- The thresholds are conventions (not Roblox numbers) and live in Breakpoints.CONVENTION so a
-- game can override them. Breakpoints.queries emits the matching StyleQuery definitions for
-- UIKit/Style's StyleSheet plan, so engine styling and these Lune rules agree.
local Check = require("../GameKit/Check")

local Breakpoints = {}

Breakpoints.DEVICES = table.freeze({ "phone", "tablet", "desktop", "console", "vr" })
Breakpoints.INPUTS = table.freeze({ "KeyboardAndMouse", "Touch", "Gamepad" })

-- Convention: short side below phoneShort px on a touch device is a phone, below tabletShort a
-- tablet; a desktop narrower than compactWidth uses the compact layout. Console (ten-foot) UI
-- is scaled up by consoleScale so text reads from a couch.
Breakpoints.CONVENTION = table.freeze({
	phoneShort = 500,
	tabletShort = 1000,
	compactWidth = 900,
	wideWidth = 1600,
	consoleScale = 1.25,
	vrScale = 1,
	touchMin = 44,
	columns = table.freeze({ phone = 4, tablet = 8, desktop = 12, console = 12, vr = 8 }),
	margin = table.freeze({ phone = 12, tablet = 24, desktop = 32, console = 64, vr = 32 }),
	gutter = table.freeze({ phone = 8, tablet = 12, desktop = 16, console = 24, vr = 16 }),
})

export type Insets = { left: number, top: number, right: number, bottom: number }
export type Rect = { x: number, y: number, w: number, h: number }
export type Info = {
	viewport: { number }, -- { width, height } in px (Camera.ViewportSize)
	input: string?, -- PreferredInput name; default KeyboardAndMouse
	tenFoot: boolean?, -- GuiService:IsTenFootInterface()
	vr: boolean?, -- VRService.VREnabled
	insets: Insets?, -- safe-area insets in px (device notch, Roblox top bar)
	uiScale: number?, -- settings/1 uiScale (0.75-1.5)
	convention: { [string]: any }?, -- overrides of Breakpoints.CONVENTION
}
export type Class = {
	device: string,
	input: string,
	orientation: "portrait" | "landscape",
	compact: boolean,
	wide: boolean,
	touch: boolean,
	viewport: { number },
	safe: Rect,
	columns: number,
	margin: number,
	gutter: number,
	scale: number,
	minTouch: number,
}

local function conventionOf(info: Info): { [string]: any }
	local out: { [string]: any } = table.clone(Breakpoints.CONVENTION :: any)
	for key, value in info.convention or {} :: { [string]: any } do
		if out[key] == nil then
			error("Breakpoints: unknown convention key " .. tostring(key), 3)
		end
		out[key] = value
	end
	return out
end

-- The safe rectangle inside a viewport after insets (never negative).
function Breakpoints.safeRect(viewport: { number }, insets: Insets?): Rect
	local w, h = viewport[1], viewport[2]
	local i = insets or { left = 0, top = 0, right = 0, bottom = 0 }
	local x, y = math.max(i.left, 0), math.max(i.top, 0)
	return {
		x = x,
		y = y,
		w = math.max(w - x - math.max(i.right, 0), 0),
		h = math.max(h - y - math.max(i.bottom, 0), 0),
	}
end

-- Problems with an Info table (empty when usable).
function Breakpoints.validate(info: any): { string }
	if type(info) ~= "table" then
		return { "info must be a table" }
	end
	local problems = {}
	local viewport = info.viewport
	if
		type(viewport) ~= "table"
		or not (Check.finite(viewport[1]) and viewport[1] > 0)
		or not (Check.finite(viewport[2]) and viewport[2] > 0)
	then
		table.insert(problems, "viewport must be { width > 0, height > 0 }")
	end
	if info.input ~= nil and not table.find(Breakpoints.INPUTS, info.input) then
		table.insert(problems, "input must be KeyboardAndMouse, Touch or Gamepad")
	end
	if info.insets ~= nil then
		local i = info.insets
		if type(i) ~= "table" then
			table.insert(problems, "insets must be { left, top, right, bottom }")
		else
			for _, side in { "left", "top", "right", "bottom" } do
				if not (Check.finite(i[side]) and i[side] >= 0) then
					table.insert(problems, "insets." .. side .. " must be a number >= 0")
				end
			end
		end
	end
	if info.uiScale ~= nil and not (Check.finite(info.uiScale) and info.uiScale > 0) then
		table.insert(problems, "uiScale must be a number > 0")
	end
	return problems
end

-- The device class and layout for a viewport and input. Raises on invalid info.
function Breakpoints.classify(info: Info): Class
	local problems = Breakpoints.validate(info)
	if #problems > 0 then
		error("Breakpoints.classify: " .. table.concat(problems, "; "), 2)
	end
	local c = conventionOf(info)
	local w, h = info.viewport[1], info.viewport[2]
	local short = math.min(w, h)
	local input = info.input or "KeyboardAndMouse"
	local device
	if info.vr then
		device = "vr"
	elseif info.tenFoot then
		device = "console"
	elseif input == "Touch" then
		device = if short < c.phoneShort then "phone" elseif short < c.tabletShort then "tablet" else "desktop"
	else
		device = "desktop"
	end
	local scale = (info.uiScale or 1)
	if device == "console" then
		scale *= c.consoleScale
	elseif device == "vr" then
		scale *= c.vrScale
	end
	return {
		device = device,
		input = input,
		orientation = if h > w then "portrait" else "landscape",
		compact = device == "phone" or w < c.compactWidth,
		wide = w >= c.wideWidth,
		touch = input == "Touch",
		viewport = { w, h },
		safe = Breakpoints.safeRect(info.viewport, info.insets),
		columns = c.columns[device],
		margin = c.margin[device],
		gutter = c.gutter[device],
		scale = scale,
		minTouch = c.touchMin,
	}
end

-- Width of n grid columns (n of class.columns) inside the safe area, in px.
function Breakpoints.span(class: Class, n: number): number
	local columns = class.columns
	local count = math.clamp(math.floor(n), 1, columns)
	local inner = math.max(class.safe.w - 2 * class.margin, 0)
	local column = (inner - (columns - 1) * class.gutter) / columns
	return math.max(column * count + (count - 1) * class.gutter, 0)
end

export type Query = { name: string, conditions: { [string]: any } }

-- StyleQuery definitions mirroring classify (names become @Name selectors in a StyleSheet).
-- Conditions use StyleQuery property names: MinSize/MaxSize (Vector2 as { x, y }, parent
-- container size), AspectRatioRange ({ min, max }), PreferredInput, PreferredTextSize and
-- ReducedMotionEnabled. Size thresholds compare the container, not the device, so the
-- StyleSheet and classify can disagree inside small panels: that is intended.
function Breakpoints.queries(convention: { [string]: any }?): { Query }
	local c: { [string]: any } = table.clone(Breakpoints.CONVENTION :: any)
	for key, value in convention or {} :: { [string]: any } do
		c[key] = value
	end
	return {
		{ name = "Compact", conditions = { MaxSize = { c.compactWidth - 1, 100000 } } },
		{
			name = "Regular",
			conditions = { MinSize = { c.compactWidth, 0 }, MaxSize = { c.wideWidth - 1, 100000 } },
		},
		{ name = "Wide", conditions = { MinSize = { c.wideWidth, 0 } } },
		{ name = "Portrait", conditions = { AspectRatioRange = { 0, 1 } } },
		{ name = "Touch", conditions = { PreferredInput = "Touch" } },
		{ name = "Gamepad", conditions = { PreferredInput = "Gamepad" } },
		{ name = "TextLarge", conditions = { PreferredTextSize = "Larger" } },
		{ name = "ReducedMotion", conditions = { ReducedMotionEnabled = true } },
	}
end

return Breakpoints
