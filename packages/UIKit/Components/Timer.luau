--!strict
-- @tier T1
-- Timer: shows a duration (a round clock, time left, a stopwatch). The game owns time (its own
-- clock or a server-synced one) and sets seconds; Timer only formats and writes the text, and
-- only when the shown text changes, so updating it every frame costs one string compare.
-- Timer.format (pure): clock "m:ss" (minutes keep growing past 59), hours "h:mm:ss", precise
-- "m:ss.t" (tenths). Negative seconds show as 0. warnBelow (seconds) switches the text to the
-- warning slot and adds the "Warning" tag near the end, so the change is not colour alone when
-- a game styles the tag. textKey (optional) wraps the time with {time}. Tree:
--   Timer (TextLabel)
local Build = require("../Build")
local Style = require("../Style")

local function format(seconds: number, style: string?): string
	local s = math.max(seconds, 0)
	if style == "precise" then
		local tenths = math.floor(s * 10 + 1e-6)
		local whole = tenths // 10
		return string.format("%d:%02d.%d", whole // 60, whole % 60, tenths % 10)
	end
	local whole = math.floor(s + 1e-6)
	if style == "hours" then
		return string.format("%d:%02d:%02d", whole // 3600, (whole // 60) % 60, whole % 60)
	end
	return string.format("%d:%02d", whole // 60, whole % 60)
end

local function textFor(props: { [string]: any }, ctx: Build.Context): string
	local time = format(props.seconds, props.style)
	return if props.textKey then ctx.text(props.textKey, { time = time }) else time
end

local function warning(props: { [string]: any }): boolean
	return props.warnBelow ~= nil and props.seconds < props.warnBelow
end

local Timer = Build.component({
	name = "Timer",
	schema = Build.schema({
		seconds = { kind = "number", default = 0 },
		style = { kind = "enum", choices = { "clock", "hours", "precise" }, default = "clock" },
		warnBelow = { kind = "number", min = 0 },
		role = { kind = "enum", choices = { "numeric", "title", "heading", "display" }, default = "numeric" },
		textKey = { kind = "key" },
	}),
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local root = Build.label(ctx, "Timer", props.role, textFor(props, ctx), nil, {
			AutomaticSize = r.Enum.AutomaticSize.XY,
			Size = r.UDim2.new(),
			TextWrapped = false,
		})
		if warning(props) then
			root.TextColor3 = Style.color(ctx.tokens, "warning", ctx.env)
			Build.tag(root, "Warning")
		end
		return root, {}
	end,
	update = function(handle: Build.Handle, _patch: { [string]: any }, ctx: Build.Context)
		local root = handle.root
		local text = textFor(handle.props, ctx)
		if root.Text ~= text then
			root.Text = text
		end
		local warn = warning(handle.props)
		if warn ~= root:HasTag("Warning") then
			root.TextColor3 = Style.color(ctx.tokens, if warn then "warning" else "text", ctx.env)
			if warn then
				root:AddTag("Warning")
			else
				root:RemoveTag("Warning")
			end
		end
	end,
})

Timer.format = format

return Timer
