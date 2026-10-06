--!strict
-- @tier T3
-- probe: platform_party_simulator
-- PartyRoblox: Roblox parties (the Party API: Player.PartyId, SocialService:GetPlayersByPartyId
-- and SocialService:GetPartyAsync) turned into GameKit/Queue tickets. The live Party API does
-- not run in a Studio playtest; Studio's Party Simulator (beta) simulates parties in Server &
-- Clients mode, which is what the platform_party_simulator probe reads. Lune specs use the fake
-- SocialService in tests/fakes/FakePlatformRoblox.
--   partyId(player) -> string?                 nil when the player is in no party ("")
--   membersHere(social, partyId) -> { Player } party members in this server, UserId order
--   members(social, partyId, env, opts?) -> (ok, { { userId, placeId, jobId } } | error)
--                                              every member, wherever they are (GetPartyAsync,
--                                              with GameKit/Retry); field names UNVERIFIED
--   ticket(social, player, opts?) -> Queue.Ticket  the player's party in this server as one
--                                              ticket ("party:<id>"), or a solo ticket
--                                              ("solo:<userId>")
--   bind(queue, players, opts?) -> disconnect  removes a player's ticket when they leave or
--                                              their PartyId changes (a party edit cancels the
--                                              queue entry, so the party re-queues as it is now)
-- PartyId is a client-visible grouping, not an authority: the server still decides who may queue
-- together (for example cap members with Queue's maxPartySize and drop members who left).
local Retry = require("./Retry")

local PartyRoblox = {}

function PartyRoblox.partyId(player: any): string?
	local id = player and player.PartyId
	if type(id) ~= "string" or id == "" then
		return nil
	end
	return id
end

function PartyRoblox.membersHere(social: any, partyId: string?): { any }
	if partyId == nil or partyId == "" or social == nil then
		return {}
	end
	local ok, list = pcall(function(): any
		return social:GetPlayersByPartyId(partyId)
	end)
	if not ok or type(list) ~= "table" then
		return {}
	end
	local out = table.clone(list)
	table.sort(out, function(a: any, b: any): boolean
		return a.UserId < b.UserId
	end)
	return out
end

export type Member = { userId: number, placeId: number?, jobId: string? }

function PartyRoblox.members(
	social: any,
	partyId: string,
	env: any,
	opts: { retry: Retry.Options? }?
): (boolean, any)
	if type(partyId) ~= "string" or partyId == "" then
		return false, "no_party"
	end
	local ok, result = Retry.run(function(): any
		local list = social:GetPartyAsync(partyId)
		if type(list) ~= "table" then
			error("GetPartyAsync returned " .. typeof(list))
		end
		return list
	end, ((opts and opts.retry) or { attempts = 3, base = 0.5, jitter = "none" }) :: any, env)
	if not ok then
		return false, tostring(result)
	end
	local out: { Member } = {}
	for _, entry in result do
		if type(entry) == "table" and type(entry.UserId) == "number" then
			table.insert(out, { userId = entry.UserId, placeId = entry.PlaceId, jobId = entry.JobId })
		end
	end
	table.sort(out, function(a: Member, b: Member): boolean
		return a.userId < b.userId
	end)
	return true, out
end

-- The player's queue ticket: their party members in this server (always including the player)
-- or the player alone. opts.skillOf(players) -> number sets the ticket skill (default: none);
-- opts.pool and opts.at pass through; opts.maxPartySize trims the party to the player plus the
-- lowest UserIds (convention) so a ticket never exceeds what the queue accepts.
function PartyRoblox.ticket(
	social: any,
	player: any,
	opts: {
		skillOf: ((players: { any }) -> number)?,
		pool: string?,
		at: number?,
		maxPartySize: number?,
	}?
): any
	local o = opts or {}
	local partyId = PartyRoblox.partyId(player)
	local members = PartyRoblox.membersHere(social, partyId)
	local list = { player }
	for _, member in members do
		if member ~= player and member.UserId ~= player.UserId then
			table.insert(list, member)
		end
	end
	if o.maxPartySize ~= nil then
		while #list > o.maxPartySize do
			table.remove(list)
		end
	end
	local userIds = {}
	for _, member in list do
		table.insert(userIds, member.UserId)
	end
	local ticket: { [string]: any } = {
		id = if partyId ~= nil and #list > 1 then "party:" .. partyId else "solo:" .. tostring(player.UserId),
		players = userIds,
		pool = o.pool,
		at = o.at,
	}
	if o.skillOf ~= nil then
		ticket.skill = o.skillOf(list)
	end
	return ticket
end

-- Keeps a GameKit/Queue in step with parties: a leaving player or a PartyId change removes the
-- player's ticket (the whole party's). opts.onRemoved(player, ticketId, why) is told, with why
-- "left" or "party_changed". Returns a disconnect function.
function PartyRoblox.bind(
	queue: any,
	players: any,
	opts: { onRemoved: ((player: any, ticketId: string, why: string) -> ())? }?
): () -> ()
	local onRemoved = opts and opts.onRemoved
	local connections: { any } = {}
	local perPlayer: { [any]: any } = {}

	local function drop(player: any, why: string)
		local id = queue:removePlayer(player.UserId)
		if id ~= nil and onRemoved ~= nil then
			pcall(onRemoved, player, id, why)
		end
	end

	local function watch(player: any)
		if perPlayer[player] ~= nil then
			return
		end
		perPlayer[player] = player:GetPropertyChangedSignal("PartyId"):Connect(function()
			drop(player, "party_changed")
		end)
	end

	table.insert(connections, players.PlayerAdded:Connect(watch))
	table.insert(
		connections,
		players.PlayerRemoving:Connect(function(player: any)
			drop(player, "left")
			local connection = perPlayer[player]
			if connection ~= nil then
				connection:Disconnect()
				perPlayer[player] = nil
			end
		end)
	)
	for _, player in players:GetPlayers() do
		watch(player)
	end
	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		for player, connection in perPlayer do
			connection:Disconnect()
			perPlayer[player] = nil
		end
	end
end

return PartyRoblox
