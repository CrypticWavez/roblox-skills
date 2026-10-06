--!strict
-- @tier T3
-- probe: action_animset_clip
-- AnimSetRoblox: the engine side of AnimSet.player.
--   * animationHook(ids, roblox) returns AnimSet's `animation` option: one Animation instance
--     per clip, with the AnimationId the game passes in ids[clipName]. This repo ships no ids;
--     a game's own uploads supply them in its own repository.
--   * previewHook(sources, env) is the Studio-only route with no upload: it registers each
--     clip's AnimationClip (from a local Clip Editor import) with AnimationClipProvider for a
--     temporary id (KeyframeSequenceProvider for KeyframeSequence sources) and refuses to run
--     outside an unpublished Studio place (Env.check).
--   * configure(roblox) returns AnimSet's `configure` option: Priority from the
--     Enum.AnimationPriority name, Looped from the slot.
--   * animator(owner, roblox) finds or creates the Animator under a Humanoid or
--     AnimationController.
-- Hooks build in Lune with @lune/roblox; playing tracks needs Studio (the probe).
local Env = require("./Env")

local AnimSetRoblox = {}

-- AnimSet's animation option from caller-supplied ids ({ [clipName] = "rbxassetid://<id>" }).
function AnimSetRoblox.animationHook(ids: { [string]: string }, roblox: any): (clip: any, set: any) -> any
	local cache = {}
	return function(clip: any, _set: any): any
		local cached = cache[clip.name]
		if cached then
			return cached
		end
		local id = ids[clip.name]
		assert(
			type(id) == "string" and #id > 0,
			"AnimSetRoblox: no animation id for clip " .. tostring(clip.name)
		)
		local animation = roblox.Instance.new("Animation")
		animation.Name = clip.name
		animation.AnimationId = id
		cache[clip.name] = animation
		return animation
	end
end

-- AnimSet's animation option for Studio preview: temporary ids from local clip sources
-- ({ [clipName] = AnimationClip or KeyframeSequence }). Raises outside an unpublished Studio
-- place; never uploads.
function AnimSetRoblox.previewHook(sources: { [string]: any }, env: any): (clip: any, set: any) -> any
	Env.assertDiagnostic(env, "AnimSetRoblox.previewHook")
	local roblox = env.roblox
	local ids = {}
	return function(clip: any, set: any): any
		local id = ids[clip.name]
		if id == nil then
			local source = sources[clip.name]
			assert(source ~= nil, "AnimSetRoblox.previewHook: no local clip for " .. tostring(clip.name))
			if source:IsA("KeyframeSequence") then
				id = env.services.KeyframeSequenceProvider:RegisterKeyframeSequence(source)
			else
				id = env.services.AnimationClipProvider:RegisterAnimationClip(source)
			end
			ids[clip.name] = id
		end
		return AnimSetRoblox.animationHook({ [clip.name] = id }, roblox)(clip, set)
	end
end

-- AnimSet's configure option: priority name to Enum.AnimationPriority, looped flag.
function AnimSetRoblox.configure(roblox: any): (track: any, priority: string, looped: boolean) -> ()
	return function(track: any, priority: string, looped: boolean)
		track.Priority = roblox.Enum.AnimationPriority[priority]
		track.Looped = looped
	end
end

-- The Animator under a Humanoid or AnimationController (created when missing).
function AnimSetRoblox.animator(owner: any, roblox: any): any
	local existing = owner:FindFirstChildOfClass("Animator")
	if existing then
		return existing
	end
	local animator = roblox.Instance.new("Animator")
	animator.Parent = owner
	return animator
end

return AnimSetRoblox
