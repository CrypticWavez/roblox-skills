--!strict
-- Polyline paths, roads and fences built from oriented segments with joint pads.
local Scene = require("./Scene")
local Vec = require("./Vec")

local Paths = {}
type Scene = Scene.Scene
type V3 = Vec.V3

local function segments(points: { V3 }, body: (a: V3, b: V3, length: number, yaw: number) -> ())
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local d = Vec.sub(b, a)
		local length = math.sqrt(d.x ^ 2 + d.z ^ 2)
		if length > 1e-3 then
			body(a, b, length, math.deg(math.atan2(-d.z, d.x)))
		end
	end
end

function Paths.path(
	scene: Scene,
	points: { V3 },
	options: { width: number?, thickness: number?, role: string? }?
)
	local width = options and options.width or 6
	local thickness = options and options.thickness or 0.4
	local role = options and options.role or "road"
	scene:group("Path", function()
		segments(points, function(a, b, length, yaw)
			local mid = Vec.lerp(a, b, 0.5)
			scene:add({
				role = role,
				size = { x = length, y = thickness, z = width },
				pos = { x = mid.x, y = mid.y + thickness / 2, z = mid.z },
				rot = { x = 0, y = yaw, z = 0 },
			})
		end)
		-- Round joints so bends have no gaps.
		for index = 2, #points - 1 do
			local p = points[index]
			scene:add({
				role = role,
				shape = "Cylinder",
				size = { x = thickness, y = width, z = width },
				pos = { x = p.x, y = p.y + thickness / 2, z = p.z },
				rot = { x = 0, y = 0, z = 90 },
			})
		end
	end)
end

function Paths.road(scene: Scene, points: { V3 }, options: { width: number?, kerb: boolean? }?)
	local width = options and options.width or 16
	Paths.path(scene, points, { width = width, thickness = 0.4, role = "road" })
	if options and options.kerb then
		scene:group("Kerb", function()
			segments(points, function(a, b, length, yaw)
				local mid = Vec.lerp(a, b, 0.5)
				for _, side in { -1, 1 } do
					local offset = Vec.rotateY({ x = 0, y = 0, z = side * (width / 2 + 0.5) }, yaw)
					scene:add({
						role = "trim",
						size = { x = length, y = 0.8, z = 1 },
						pos = { x = mid.x + offset.x, y = mid.y + 0.4, z = mid.z + offset.z },
						rot = { x = 0, y = yaw, z = 0 },
					})
				end
			end)
		end)
	end
end

function Paths.fence(
	scene: Scene,
	points: { V3 },
	options: { height: number?, spacing: number?, rails: number? }?
)
	local height = options and options.height or 4
	local spacing = options and options.spacing or 6
	local rails = options and options.rails or 2
	scene:group("Fence", function()
		segments(points, function(a, b, length, yaw)
			local posts = math.max(1, math.ceil(length / spacing))
			for index = 0, posts - 1 do
				local p = Vec.lerp(a, b, index / posts)
				scene:add({
					role = "fence",
					size = { x = 0.6, y = height, z = 0.6 },
					pos = { x = p.x, y = p.y + height / 2, z = p.z },
				})
			end
			local mid = Vec.lerp(a, b, 0.5)
			for rail = 1, rails do
				scene:add({
					role = "fence",
					size = { x = length, y = 0.4, z = 0.3 },
					pos = { x = mid.x, y = mid.y + height * rail / (rails + 1), z = mid.z },
					rot = { x = 0, y = yaw, z = 0 },
				})
			end
		end)
		local last = points[#points]
		scene:add({
			role = "fence",
			size = { x = 0.6, y = height, z = 0.6 },
			pos = { x = last.x, y = last.y + height / 2, z = last.z },
		})
	end)
end

return Paths
