--!strict
-- DEPRECATED: SoundGroup volumes are the legacy route ("Sound, SoundGroup, and SoundEffect objects
-- are now discouraged in favor of ... audio objects", docs audio/objects). Use AVKit/AudioGraph
-- (audio-graph/1 buses on AudioFaders) with AVKit/AudioGraphRoblox. Kept unchanged for the
-- inherited fixtures (fixtures/creator/AudioMovement.client.luau, fixtures/runtime/Diagnostic).
local NativeAudio = {}

function NativeAudio.new(mixer, channelNames, parent)
	local groups, sounds, closed = {}, {}, false
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "WorkbenchAudio", parent
	for _, name in channelNames do
		local group = Instance.new("SoundGroup")
		group.Name, group.Parent = name, folder
		groups[name] = group
	end
	local api = { groups = groups }
	function api:step(dt)
		if closed then
			return
		end
		for name, volume in mixer:step(dt) do
			if groups[name] then
				groups[name].Volume = volume
			end
		end
	end
	function api:register(sound, channel)
		assert(not closed and sound:IsA("Sound") and groups[channel], "invalid sound/channel")
		assert(#sounds < 64, "sound capacity")
		local oldGroup = sound.SoundGroup
		sound.SoundGroup = groups[channel]
		table.insert(sounds, { sound = sound, oldGroup = oldGroup })
	end
	function api:inspect()
		local result = { groups = {}, sounds = {}, audibleVerified = false }
		for name, group in groups do
			result.groups[name] = group.Volume
		end
		for _, record in sounds do
			local sound = record.sound
			table.insert(result.sounds, {
				name = sound.Name,
				configured = sound.SoundId ~= "",
				loaded = sound.IsLoaded,
				duration = sound.TimeLength,
				looping = sound.Looped,
				minimumDistance = sound.RollOffMinDistance,
				maximumDistance = sound.RollOffMaxDistance,
				permission = "unverified",
			})
		end
		return result
	end
	function api:destroy()
		if closed then
			return
		end
		closed = true
		for _, record in sounds do
			if record.sound.Parent then
				record.sound.SoundGroup = record.oldGroup
			end
		end
		folder:Destroy()
	end
	return api
end

return NativeAudio
