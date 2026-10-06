--!strict
-- @tier T1
-- Countdown: "3, 2, 1, Go" before a round or a race. start() shows from, then from - 1 ... 1
-- every interval s, then the go text (goKey, default uikit.go) for holdGo s, then hides and calls
-- onDone(). Each number pops (scale 1.4 -> 1 on Back.Out, with a fade); reduced motion keeps only
-- the fade. onTick(n) fires for every number and with 0 for go. The schedule is pure
-- (Countdown.schedule); timing runs on the transition runner clock (Build.after), so it pauses
-- with the UI and Lune specs drive it with runner:step. The game decides when to start (for a
-- synchronised start, from a server timestamp). Tree:
--   Countdown (Frame) > Number (TextLabel) > Scale (UIScale)
local Build = require("../Build")
local Transitions = require("../Transitions")

export type Beat = { t: number, value: number }

-- The beats of a countdown: { t = seconds from start, value } for from .. 1 and 0 (go).
local function schedule(from: number, interval: number): { Beat }
	local out = {}
	for index = 0, from do
		table.insert(out, { t = index * interval, value = from - index })
	end
	return out
end

local Countdown = Build.component({
	name = "Countdown",
	schema = Build.schema({
		from = { kind = "integer", min = 1, max = 10, default = 3 },
		interval = { kind = "number", min = 0.2, max = 5, default = 1 },
		holdGo = { kind = "number", min = 0, max = 5, default = 0.8 },
		goKey = { kind = "key", default = "uikit.go" },
		onTick = { kind = "function" },
		onDone = { kind = "function" },
	}),
	build = function(_props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local root = Build.frame(ctx, "Countdown", {
			AnchorPoint = r.Vector2.new(0.5, 0.5),
			Position = r.UDim2.fromScale(0.5, 0.4),
			Size = r.UDim2.fromOffset(240, 120),
			Visible = false,
		})
		Build.tag(root, "Countdown")
		local number = Build.label(ctx, "Number", "display", "", nil, {
			Size = r.UDim2.fromScale(1, 1),
			TextXAlignment = r.Enum.TextXAlignment.Center,
			TextWrapped = false,
		}, root)
		number.TextSize = ctx.tokens.text.display.size * 2
		Build.make(ctx, "UIScale", { Name = "Scale", Scale = 1 }, number)
		return root, { number = number, scale = number:FindFirstChild("Scale") }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local cancels: { () -> () } = {}
		handle.state.running = false

		local function clear()
			for _, cancel in cancels do
				cancel()
			end
			table.clear(cancels)
		end

		local function beat(value: number)
			local p = handle.props
			local parts = handle.parts
			parts.number.Text = if value > 0 then tostring(value) else ctx.text(p.goKey)
			handle.root:SetAttribute("Value", value)
			local motion = ctx.tokens.motion
			Build.play(
				ctx,
				Transitions.make("countdownBeat", "in", {
					Transitions.track(
						"scale",
						"Scale",
						1.4,
						1,
						{ duration = motion.duration.slow, ease = "Back.Out" }
					),
					Transitions.track(
						"number",
						"TextTransparency",
						1,
						0,
						{ duration = motion.duration.fast }
					),
				}),
				{ scale = parts.scale, number = parts.number }
			)
			if p.onTick then
				p.onTick(value)
			end
		end

		function handle.state.start(): boolean
			if handle.state.running then
				return false
			end
			handle.state.running = true
			handle.root.Visible = true
			local p = handle.props
			for _, item in schedule(p.from, p.interval) do
				local value = item.value
				if item.t <= 0 then
					beat(value)
				else
					table.insert(
						cancels,
						Build.after(ctx, item.t, function()
							beat(value)
						end)
					)
				end
			end
			table.insert(
				cancels,
				Build.after(ctx, p.from * p.interval + p.holdGo, function()
					handle.state.running = false
					handle.root.Visible = false
					table.clear(cancels)
					if handle.props.onDone then
						handle.props.onDone()
					end
				end)
			)
			return true
		end

		function handle.state.cancel()
			clear()
			handle.state.running = false
			handle.root.Visible = false
		end
		handle.scope:Add(clear)
	end,
})

Countdown.schedule = schedule

return Countdown
