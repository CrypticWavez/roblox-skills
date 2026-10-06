--!strict
-- @tier T0
-- AudioMixer: deterministic gain envelopes per channel (user volume x fade x ducks x master),
-- moved from Runtime/AudioMixer (which now re-exports it). step(dt) returns 0..1 gains; the
-- backend writes them to bus AudioFaders (AVKit/AudioGraph, AVKit/AudioGraphRoblox). No asset ids.
local AudioMixer = {}
local function gain(value)
	return type(value) == "number" and value == value and value >= 0 and value <= 1
end

function AudioMixer.new(channels: { string })
	local state: {
		[string]: {
			user: number,
			current: number,
			from: number,
			target: number,
			elapsed: number,
			duration: number,
		},
	} =
		{}
	local ducks: { { id: number, name: string, attenuation: number, remaining: number } } = {}
	local serial, master = 0, 1
	for _, name in channels do
		assert(type(name) == "string" and #name > 0 and state[name] == nil, "unique channel name required")
		state[name] = { user = 1, current = 1, from = 1, target = 1, elapsed = 0, duration = 0 }
	end
	local api = {}
	function api:setMaster(value: number)
		assert(gain(value), "invalid gain")
		master = value
	end
	function api:setVolume(name: string, value: number)
		assert(state[name] and gain(value), "invalid channel/gain")
		state[name].user = value
	end
	function api:fade(name: string, target: number, duration: number)
		assert(
			state[name]
				and gain(target)
				and type(duration) == "number"
				and duration == duration
				and duration >= 0
				and duration <= 60,
			"invalid fade"
		)
		local channel = state[name]
		channel.from, channel.target, channel.duration, channel.elapsed = channel.current, target, duration, 0
		if duration == 0 then
			channel.current = target
		end
	end
	function api:duck(name: string, attenuation: number, duration: number): (number?, string?)
		assert(
			state[name]
				and gain(attenuation)
				and type(duration) == "number"
				and duration == duration
				and duration > 0
				and duration <= 60,
			"invalid duck"
		)
		if #ducks >= 32 then
			return nil, "duck_capacity"
		end
		serial += 1
		table.insert(ducks, { id = serial, name = name, attenuation = attenuation, remaining = duration })
		return serial, nil
	end
	function api:release(id: number)
		for index, duck in ducks do
			if duck.id == id then
				table.remove(ducks, index)
				return true
			end
		end
		return false
	end
	function api:step(dt: number)
		assert(type(dt) == "number" and dt == dt and dt >= 0 and dt < math.huge, "invalid dt")
		for index = #ducks, 1, -1 do
			ducks[index].remaining -= dt
			if ducks[index].remaining <= 0 then
				table.remove(ducks, index)
			end
		end
		local output = {}
		for name, channel in state do
			channel.elapsed = math.min(channel.duration, channel.elapsed + dt)
			local alpha = if channel.duration == 0 then 1 else channel.elapsed / channel.duration
			channel.current = channel.from + (channel.target - channel.from) * alpha
			local attenuation = 1
			for _, duck in ducks do
				if duck.name == name then
					attenuation = math.min(attenuation, duck.attenuation)
				end
			end
			output[name] = master * channel.user * channel.current * attenuation
		end
		return output
	end
	return api
end

return AudioMixer
