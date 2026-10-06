--!strict
-- @tier T3
-- probe: action_interact_prompt
-- InteractRoblox: ProximityPrompt and touch wiring for an Interact server.
--   * prompt(def, roblox, text?) builds a ProximityPrompt from a prompt target
--     (MaxActivationDistance, HoldDuration, RequiresLineOfSight; ActionText/ObjectText come from
--     the caller, they are UI copy). The client prompt is only a request: the server re-checks
--     everything through Interact.
--   * connect(server, { prompts = { [id] = prompt }, touchParts = { [id] = part }, players }, env)
--     wires PromptButtonHoldBegan/Ended and Triggered to begin/cancel/finish and BasePart.Touched
--     (resolved with Players:GetPlayerFromCharacter) to touch, passing the player's
--     HumanoidRootPart position as the server sees it. Returns disconnect().
--   * lineOfSight(worldRoot, roblox, exclude?) is the hook for Interact's line-of-sight check.
-- prompt() runs in Lune with @lune/roblox; connect needs Studio (the probe).
local Interact = require("./Interact")

local InteractRoblox = {}

-- A ProximityPrompt for a prompt target. text = { action?, object? } (the game's UI copy).
function InteractRoblox.prompt(
	def: Interact.TargetDef,
	roblox: any,
	text: { action: string?, object: string? }?
): any
	assert((def.kind or "prompt") == "prompt", "InteractRoblox.prompt: target is not a prompt")
	local prompt = roblox.Instance.new("ProximityPrompt")
	prompt.Name = def.id
	prompt.MaxActivationDistance = def.maxDistance or Interact.MAX_DISTANCE
	prompt.HoldDuration = def.holdDuration or 0
	prompt.RequiresLineOfSight = def.lineOfSight ~= false
	if text and text.action then
		prompt.ActionText = text.action
	end
	if text and text.object then
		prompt.ObjectText = text.object
	end
	return prompt
end

-- The server-side root position of a player's character as a plain vector, or nil.
function InteractRoblox.rootPosition(player: any): { x: number, y: number, z: number }?
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil then
		return nil
	end
	local p = root.CFrame.Position
	return { x = p.X, y = p.Y, z = p.Z }
end

-- A line-of-sight hook: true when a ray from the player to the target hits nothing in between
-- (exclude lists the characters and the target's own parts).
function InteractRoblox.lineOfSight(
	worldRoot: any,
	roblox: any,
	exclude: { any }?
): (from: any, to: any, id: string) -> boolean
	local params = roblox.RaycastParams.new()
	params.FilterType = roblox.Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude or {}
	return function(from: any, to: any, _id: string): boolean
		local origin = roblox.Vector3.new(from.x, from.y, from.z)
		local direction = roblox.Vector3.new(to.x - from.x, to.y - from.y, to.z - from.z)
		return worldRoot:Raycast(origin, direction, params) == nil
	end
end

export type Wiring = {
	prompts: { [string]: any }?,
	touchParts: { [string]: any }?,
	players: any,
	onEvent: ((event: any) -> ())?,
	onRefused: ((player: any, id: string, reason: string) -> ())?,
}

-- Wires prompts and touch parts to the server. Returns disconnect().
function InteractRoblox.connect(server: any, wiring: Wiring, _env: any): () -> ()
	local connections = {}
	local function report(player: any, id: string, ok: boolean, reason: string?, event: any?)
		if ok and event and wiring.onEvent then
			wiring.onEvent(event)
		elseif not ok and wiring.onRefused then
			wiring.onRefused(player, id, reason or "refused")
		end
	end
	for id, prompt in wiring.prompts or {} do
		table.insert(
			connections,
			prompt.PromptButtonHoldBegan:Connect(function(player: any)
				local ok, reason = server:begin(player.UserId, id, InteractRoblox.rootPosition(player))
				report(player, id, ok, reason)
			end)
		)
		table.insert(
			connections,
			prompt.PromptButtonHoldEnded:Connect(function(player: any)
				server:cancel(player.UserId, id)
			end)
		)
		table.insert(
			connections,
			prompt.Triggered:Connect(function(player: any)
				local ok, reason, event =
					server:finish(player.UserId, id, InteractRoblox.rootPosition(player))
				report(player, id, ok, reason, event)
			end)
		)
	end
	for id, touchPart in wiring.touchParts or {} do
		table.insert(
			connections,
			touchPart.Touched:Connect(function(hit: any)
				local character = hit and hit:FindFirstAncestorOfClass("Model")
				local player = character and wiring.players:GetPlayerFromCharacter(character)
				if player == nil then
					return
				end
				local ok, reason, event = server:touch(player.UserId, id, InteractRoblox.rootPosition(player))
				-- Touch spam is normal (every limb fires); only accepted touches are reported.
				if ok then
					report(player, id, ok, reason, event)
				end
			end)
		)
	end
	table.insert(
		connections,
		wiring.players.PlayerRemoving:Connect(function(player: any)
			server:forget(player.UserId)
		end)
	)
	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
end

return InteractRoblox
