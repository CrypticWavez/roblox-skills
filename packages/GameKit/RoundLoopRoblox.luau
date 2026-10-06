--!strict
-- @tier T3
-- probe: action_round_replication
-- RoundLoopRoblox: runs a RoundLoop on the server and replicates it as attributes.
--   * attributes(snapshot, prefix?) maps RoundLoop:snapshot() to six attributes
--     (<prefix>Phase, TimeLeft, Number, Players, Alive, State; prefix "Round"), well inside the
--     64-per-Instance budget; read(holder, prefix?) turns them back into a snapshot on clients.
--   * start(loop, { holder, players, runService }, env) joins present and arriving players by
--     UserId, leaves them on PlayerRemoving, and binds a non-yielding step through
--     AuthorityRoblox.bindStep that calls loop:tick(env.clock()) (time()) and writes only changed
--     attributes. Returns stop().
local AuthorityRoblox = require("./AuthorityRoblox")

local RoundLoopRoblox = {}
RoundLoopRoblox.PREFIX = "Round"

function RoundLoopRoblox.attributes(snapshot: { [string]: any }, prefix: string?): { [string]: any }
	local p = prefix or RoundLoopRoblox.PREFIX
	return {
		[p .. "Phase"] = snapshot.phase,
		[p .. "TimeLeft"] = snapshot.timeLeft,
		[p .. "Number"] = snapshot.round,
		[p .. "Players"] = snapshot.players,
		[p .. "Alive"] = snapshot.alive,
		[p .. "State"] = snapshot.state,
	}
end

-- The client view of a replicated round (nil fields when not yet replicated).
function RoundLoopRoblox.read(holder: any, prefix: string?): { [string]: any }
	local p = prefix or RoundLoopRoblox.PREFIX
	return {
		phase = holder:GetAttribute(p .. "Phase"),
		timeLeft = holder:GetAttribute(p .. "TimeLeft"),
		round = holder:GetAttribute(p .. "Number"),
		players = holder:GetAttribute(p .. "Players"),
		alive = holder:GetAttribute(p .. "Alive"),
		state = holder:GetAttribute(p .. "State"),
	}
end

export type Options = {
	holder: any, -- the Instance that carries the attributes (a Folder in ReplicatedStorage)
	players: any?, -- Players service; omit to manage join/leave yourself
	runService: any,
	prefix: string?,
	allowFallback: boolean?, -- step from PostSimulation where BindToSimulation is missing
	onEvents: ((events: { any }) -> ())?, -- phase events from each tick
}

-- Starts replication. Returns (stop, how) where how is "simulation" or "fallback"; raises when
-- the step cannot be bound.
function RoundLoopRoblox.start(loop: any, options: Options, env: any): (() -> (), string)
	local connections = {}
	local players = options.players
	if players then
		for _, player in players:GetPlayers() do
			loop:join(player.UserId)
		end
		table.insert(
			connections,
			players.PlayerAdded:Connect(function(player: any)
				loop:join(player.UserId)
			end)
		)
		table.insert(
			connections,
			players.PlayerRemoving:Connect(function(player: any)
				loop:leave(player.UserId)
			end)
		)
	end
	local function step(_dt: number)
		local now = env.clock()
		local events = loop:tick(now)
		AuthorityRoblox.writeAttributes(
			options.holder,
			RoundLoopRoblox.attributes(loop:snapshot(now), options.prefix)
		)
		if options.onEvents and #events > 0 then
			options.onEvents(events)
		end
	end
	local unbind, how =
		AuthorityRoblox.bindStep(options.runService, step, { allowFallback = options.allowFallback })
	if unbind == nil then
		for _, connection in connections do
			connection:Disconnect()
		end
		error("RoundLoopRoblox.start: " .. how, 2)
	end
	local release = unbind :: () -> ()
	return function()
		release()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end,
		how
end

return RoundLoopRoblox
