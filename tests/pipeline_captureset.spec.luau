--!strict
-- Pipeline/CaptureSet: named shots from SceneKit Camera framing, input and manifest validation, and
-- the camera adapter. tools/capture_staleness.py (tests/test_capture_staleness.py) reads the
-- manifests these plans become.
local Camera = require("../packages/SceneKit/Camera")
local CaptureSet = require("../packages/Pipeline/CaptureSet")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local BOUNDS = { min = { x = -10, y = 0, z = -6 }, max = { x = 10, y = 8, z = 6 } }

local function input(overrides: { [string]: any }?): any
	local value: { [string]: any } = {
		scene = "dungeon",
		source = "fixture",
		sceneHash = "06ace82c",
		bounds = BOUNDS,
	}
	for key, item in overrides or {} do
		value[key] = item
	end
	return value
end

local function mentions(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

test("a default plan names one shot per angle, sorted, framed by Camera.frame", function(t)
	local plan = CaptureSet.plan(input({ commit = "abc1234" }))
	t.eq(plan.schema, "capture-manifest/1")
	t.eq(plan.scene, { name = "dungeon", hash = "06ace82c", source = "fixture" })
	t.eq(plan.commit, "abc1234")
	local ids = {}
	for _, shot in plan.shots do
		table.insert(ids, shot.id)
	end
	t.eq(ids, {
		"dungeon.inspection-flat.front",
		"dungeon.inspection-flat.side",
		"dungeon.inspection-flat.three-quarter",
		"dungeon.inspection-flat.top",
	})
	local front = plan.shots[1]
	local view = Camera.frame(BOUNDS.min, BOUNDS.max, "front")
	t.near(front.eye.z, view.eye.z, 1e-6)
	t.near(front.focus.y, 4, 1e-9)
	t.eq(front.fov, 70)
	t.eq(front.file, "dungeon.inspection-flat.front.png")
	t.eq(CaptureSet.validate(plan), {})
	t.eq(CaptureSet.plan(input({ commit = "abc1234" })), plan, "same input, same plan")
end)

test("profiles multiply the angles and keep ids unique", function(t)
	local plan = CaptureSet.plan(
		input({ profiles = { "neutral-day", "inspection-flat" }, angles = { "top", "front" } })
	)
	t.eq(#plan.shots, 4)
	t.eq(plan.shots[1].id, "dungeon.inspection-flat.front")
	t.eq(plan.shots[4].id, "dungeon.neutral-day.top")
	t.throws(function()
		CaptureSet.plan(input({ angles = { "front", "front" } }))
	end, "duplicate shot")
end)

test("plan refuses bad input with every problem named", function(t)
	local ok, err = pcall(
		CaptureSet.plan,
		{
			scene = "Bad Scene",
			source = "screenshot",
			sceneHash = "zz",
			bounds = { min = { x = 1, y = 0, z = 0 }, max = { x = 0, y = 1, z = 1 } },
			angles = { "low" },
			profiles = { "Neutral Day" },
			fov = 400,
		} :: any
	)
	t.ok(not ok)
	local message = tostring(err)
	for _, needle in
		{
			"scene must be a lower-case label",
			"source must be fixture or studio-smoke",
			"sceneHash must be a hex digest",
			"bounds min must not exceed max",
			"unknown angle low",
			"profile Neutral Day",
			"fov must be between",
		}
	do
		t.ok(string.find(message, needle, 1, true) ~= nil, needle .. " in " .. message)
	end
	t.throws(function()
		CaptureSet.plan(input({ bounds = { min = { x = 0 } } }))
	end)
	local many = {}
	for index = 1, 17 do
		table.insert(many, "p" .. index)
	end
	t.throws(function()
		CaptureSet.plan(input({ profiles = many }))
	end, "more than 64 shots")
end)

test("validate names problems in a manifest read back from disk", function(t)
	local plan: any = CaptureSet.plan(input())
	plan.schema = "capture-manifest/0"
	plan.shots[2].id = plan.shots[1].id
	plan.shots[3].file = "../escape.png"
	plan.shots[4].angle = "low"
	plan.shots[4].eye = { x = 0 / 0, y = 0, z = 0 }
	local problems = CaptureSet.validate(plan)
	for _, needle in
		{
			"schema must be capture-manifest/1",
			"duplicates",
			"plain .png name",
			"unknown angle",
			"eye, focus and fov",
		}
	do
		t.ok(mentions(problems, needle), needle .. " in " .. table.concat(problems, "; "))
	end
	t.eq(CaptureSet.validate(nil), { "manifest must be a table" })
	t.ok(
		mentions(
			CaptureSet.validate({
				schema = "capture-manifest/1",
				scene = { name = "x", hash = "ab", source = "fixture" },
				shots = {},
			}),
			"non-empty"
		)
	)
end)

test("apply points a camera with the injected datatypes", function(t)
	local shot = CaptureSet.plan(input()).shots[1]
	local camera: any = {}
	local roblox = {
		Vector3 = {
			new = function(x: number, y: number, z: number): any
				return { x, y, z }
			end,
		},
		CFrame = {
			lookAt = function(eye: any, focus: any): any
				return { eye = eye, focus = focus }
			end,
		},
	}
	CaptureSet.apply(camera, shot, roblox)
	t.eq(camera.FieldOfView, shot.fov)
	t.eq(camera.CFrame.focus, { 0, 4, 0 })
	t.eq(camera.CFrame.eye, { shot.eye.x, shot.eye.y, shot.eye.z })
end)

return cases
