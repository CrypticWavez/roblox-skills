--!strict
-- FakePathfinding: a PathfindingService stand-in for NavAgentRoblox specs. CreatePath(params)
-- records the agent parameters; ComputeAsync(from, to) sets Status (an enum-like { Name }) from a
-- queue of scripted statuses (default Success) and builds waypoints with route(from, to) (default:
-- a straight line every `spacing` studs; a waypoint whose label is "jump" gets the Jump action).
-- path.Blocked:Connect(fn) works and path:fireBlocked(index) fires it. Vectors are @lune/roblox
-- Vector3s (pass the module as `roblox`). G7-owned fake.
local FakePathfinding = {}

export type Options = {
	roblox: any,
	statuses: { string }?, -- consumed one per ComputeAsync; Success afterwards
	errors: { string }?, -- ComputeAsync raises these first (one per call)
	spacing: number?,
	route: ((from: any, to: any) -> { { pos: any, label: string? } })?,
}

function FakePathfinding.new(options: Options): any
	local roblox = options.roblox
	local statuses = table.clone(options.statuses or {})
	local errors = table.clone(options.errors or {})
	local spacing = options.spacing or 4
	local service: any = { created = {}, computed = {} }

	local function straight(from: any, to: any): { { pos: any, label: string? } }
		local delta = to - from
		local steps = math.max(1, math.ceil(delta.Magnitude / spacing))
		local out = {}
		for i = 0, steps do
			table.insert(out, { pos = from + delta * (i / steps) })
		end
		return out
	end

	function service.CreatePath(_, params: any)
		table.insert(service.created, params)
		local handlers = {}
		local path: any = { Status = { Name = "NoPath" }, _points = {} }
		path.Blocked = {
			Connect = function(_, fn)
				table.insert(handlers, fn)
				return {
					Disconnect = function()
						local i = table.find(handlers, fn)
						if i then
							table.remove(handlers, i)
						end
					end,
				}
			end,
		}
		function path.fireBlocked(_, index: number)
			for _, fn in table.clone(handlers) do
				fn(index)
			end
		end
		function path.ComputeAsync(_, from: any, to: any)
			table.insert(service.computed, { from = from, to = to })
			if #errors > 0 then
				error(table.remove(errors, 1), 0)
			end
			local status = if #statuses > 0 then table.remove(statuses, 1) else "Success"
			path.Status = { Name = status }
			if status == "Success" or status == "ClosestNoPath" or status == "ClosestOutOfRange" then
				path._points = (options.route or straight)(from, to)
			else
				path._points = {}
			end
		end
		function path.GetWaypoints(_)
			local out = {}
			for _, point in path._points do
				table.insert(out, {
					Position = point.pos,
					Action = { Name = if point.label == "jump" then "Jump" else "Walk" },
					Label = point.label or "",
				})
			end
			return out
		end
		service.lastPath = path
		return path
	end

	return service
end

return FakePathfinding
