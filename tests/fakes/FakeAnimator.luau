--!strict
-- FakeAnimator: an Animator-like object for Lune specs (the interface in docs/runtime-kits.md
-- section 10: LoadAnimation -> track with Play, Stop, AdjustSpeed, GetMarkerReachedSignal,
-- Length). An "animation" is a table { name, length, looped?, markers = { { name, time,
-- param? } } }. advance(dt) moves playing tracks, fires each marker whose time is crossed
-- (looping tracks wrap and fire again) and ends one-shot tracks at their length. It records
-- loads, plays and stops, and the most tracks that ever played at once (Roblox caps an
-- Animator at 8 playing tracks).
local FakeAnimator = {}

type Handler = (param: any) -> ()

local function signal()
	local handlers: { Handler } = {}
	local sig = {}
	function sig:Connect(fn: Handler)
		table.insert(handlers, fn)
		local connection = { Connected = true }
		function connection:Disconnect()
			connection.Connected = false
			local index = table.find(handlers, fn)
			if index then
				table.remove(handlers, index)
			end
		end
		return connection
	end
	function sig:Fire(param: any)
		for _, fn in table.clone(handlers) do
			fn(param)
		end
	end
	function sig:Count(): number
		return #handlers
	end
	return sig
end

function FakeAnimator.new(): any
	local animator: any = {
		loads = {} :: { string },
		log = {} :: { string },
		maxPlaying = 0,
		tracks = {} :: { any },
	}

	local function countPlaying(): number
		local n = 0
		for _, track in animator.tracks do
			if track.IsPlaying then
				n += 1
			end
		end
		return n
	end

	function animator:LoadAnimation(animation: any): any
		assert(
			type(animation) == "table" and type(animation.name) == "string",
			"FakeAnimator: animation needs a name"
		)
		table.insert(animator.loads, animation.name)
		local markers: { [string]: any } = {}
		local track: any = {
			Animation = animation,
			Name = animation.name,
			Length = animation.length or 1,
			Looped = animation.looped == true,
			IsPlaying = false,
			Speed = 1,
			WeightTarget = 1,
			TimePosition = 0,
			Priority = nil,
			Stopped = signal(),
			destroyed = false,
		}
		function track:Play(fadeTime: number?, weight: number?, speed: number?)
			track.IsPlaying = true
			track.TimePosition = 0
			track.WeightTarget = weight or 1
			track.Speed = speed or 1
			table.insert(animator.log, string.format("play %s fade=%g", track.Name, fadeTime or 0.1))
			animator.maxPlaying = math.max(animator.maxPlaying, countPlaying())
		end
		function track:Stop(fadeTime: number?)
			if track.IsPlaying then
				track.IsPlaying = false
				table.insert(animator.log, string.format("stop %s fade=%g", track.Name, fadeTime or 0.1))
				track.Stopped:Fire()
			end
		end
		function track:AdjustSpeed(speed: number)
			track.Speed = speed
		end
		function track:GetMarkerReachedSignal(name: string)
			markers[name] = markers[name] or signal()
			return markers[name]
		end
		function track:Destroy()
			track.destroyed = true
		end
		function track:_advance(dt: number)
			if not track.IsPlaying then
				return
			end
			local from = track.TimePosition
			local to = from + dt * track.Speed
			local length = track.Length
			local function fire(lo: number, hi: number)
				for _, marker in animation.markers or {} do
					if marker.time > lo and marker.time <= hi and markers[marker.name] then
						markers[marker.name]:Fire(marker.param)
					end
				end
			end
			if to >= length then
				fire(from, length)
				if track.Looped then
					local wrapped = to - length
					fire(-1, wrapped)
					track.TimePosition = wrapped
				else
					track.TimePosition = length
					track:Stop(0)
				end
			else
				fire(from, to)
				track.TimePosition = to
			end
		end
		table.insert(animator.tracks, track)
		return track
	end

	function animator:advance(dt: number)
		for _, track in animator.tracks do
			track:_advance(dt)
		end
	end

	function animator:playing(): { string }
		local list = {}
		for _, track in animator.tracks do
			if track.IsPlaying then
				table.insert(list, track.Name)
			end
		end
		table.sort(list)
		return list
	end

	return animator
end

return FakeAnimator
