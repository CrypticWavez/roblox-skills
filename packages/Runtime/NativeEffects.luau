--!strict
-- Owned diagnostic/presentation effects. No gameplay damage or interaction.
local NativeEffects = {}
function NativeEffects.new(lifetime, parent, reducedEffects)
	local api = {}
	function api:marker(position, radius, color, duration, priority)
		assert(typeof(position) == "Vector3" and typeof(color) == "Color3", "invalid visual")
		assert(type(radius) == "number" and radius > 0 and radius <= 32, "invalid radius")
		if reducedEffects and priority < 5 then
			return nil, "reduced_effects"
		end
		local part = Instance.new("Part")
		part.Name = "DiagnosticVisualMarker"
		part.Shape, part.Size, part.Position = Enum.PartType.Ball, Vector3.one * radius * 2, position
		part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, false, false, false
		part.Material, part.Color, part.Transparency = Enum.Material.SmoothPlastic, color, 0.65
		local token, reason = lifetime:add(duration, priority, function()
			part:Destroy()
		end)
		if token == nil then
			part:Destroy()
			return nil, reason
		end
		part.Parent = parent
		return token, part
	end
	function api:destroy()
		lifetime:destroy()
	end
	return api
end

return NativeEffects
