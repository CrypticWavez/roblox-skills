local roblox = require("@lune/roblox")
local Inspector = require("../packages/Pipeline/ImportInspector")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

-- Minimal MeshPart mock (Lune instances do not implement GetPivot/CollisionFidelity). The pivot defaults
-- to the base centre of the part's bounds; tests replace GetPivot to move it.
local function meshPart(name, size, pos, rotY)
	local cf = roblox.CFrame.new(pos[1], pos[2], pos[3])
		* roblox.CFrame.fromOrientation(0, math.rad(rotY or 0), 0)
	local children = {}
	return {
		Name = name,
		Size = roblox.Vector3.new(size[1], size[2], size[3]),
		CFrame = cf,
		CollisionFidelity = "Enum.CollisionFidelity.Hull",
		TextureID = "",
		Children = children,
		IsA = function(_, class)
			return class == "MeshPart"
		end,
		GetDescendants = function()
			return {}
		end,
		GetAttribute = function()
			return nil
		end,
		FindFirstChildOfClass = function(_, class)
			return children[class]
		end,
		GetPivot = function(self)
			return roblox.CFrame.new(pos[1], pos[2] - size[2] / 2, pos[3])
		end,
	}
end

local function pivotAt(part, p)
	part.GetPivot = function()
		return roblox.CFrame.new(p[1], p[2], p[3])
	end
	return part
end

-- The v1 marker as imported correctly (front -Z, up +Y): a body box and a nose box sticking out at -Z.
-- Bounds x -2..2, y 0..7, z -1.75..1.75. Its up offset is tiny, so up-axis cases use STAND below.
local MARKER = {
	{ { -2, 0, -0.25 }, { 2, 7, 1.75 } },
	{ { -0.5, 2.5, -1.75 }, { 0.5, 3.5, -0.25 } },
}
-- A block with a tall post and a nose at -Z: strongly asymmetric along up. Bounds x -2..2, y 0..8,
-- z -2..1 (centre 0, 4, -0.5).
local STAND = {
	{ { -2, 0, -1 }, { 2, 2, 1 } },
	{ { -0.25, 2, -0.25 }, { 0.25, 8, 0.25 } },
	{ { -0.5, 0.5, -2 }, { 0.5, 1.5, -1 } },
}

-- Twelve world-space triangles per axis-aligned box, each corner mapped through `place`.
local function boxTriangles(box, place)
	local lo, hi = box[1], box[2]
	local function corner(i)
		local x = if i % 2 == 1 then hi[1] else lo[1]
		local y = if (i // 2) % 2 == 1 then hi[2] else lo[2]
		local z = if (i // 4) % 2 == 1 then hi[3] else lo[3]
		return place({ x, y, z })
	end
	local quads =
		{ { 0, 1, 3, 2 }, { 4, 5, 7, 6 }, { 0, 1, 5, 4 }, { 2, 3, 7, 6 }, { 0, 2, 6, 4 }, { 1, 3, 7, 5 } }
	local tris = {}
	for _, q in quads do
		table.insert(tris, { corner(q[1]), corner(q[2]), corner(q[3]) })
		table.insert(tris, { corner(q[1]), corner(q[3]), corner(q[4]) })
	end
	return tris
end

local function identity(p)
	return p
end

local function shifted(d)
	return function(p)
		return { p[1] + d[1], p[2] + d[2], p[3] + d[3] }
	end
end

local function reader(boxes, place)
	return function()
		local tris = {}
		for _, box in boxes do
			for _, tri in boxTriangles(box, place or identity) do
				table.insert(tris, tri)
			end
		end
		return tris
	end
end

-- Independent of the inspector's triangle integration: a closed box's surface centroid is its centre.
-- Returns size, bounds centre, front offset (-Z) and up offset (+Y) of a set of boxes.
local function measure(boxes)
	local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
	local sum, total = { 0, 0, 0 }, 0
	for _, box in boxes do
		local d = { box[2][1] - box[1][1], box[2][2] - box[1][2], box[2][3] - box[1][3] }
		local area = 2 * (d[1] * d[2] + d[2] * d[3] + d[3] * d[1])
		total += area
		for i = 1, 3 do
			sum[i] += area * (box[1][i] + box[2][i]) / 2
			lo[i], hi[i] = math.min(lo[i], box[1][i]), math.max(hi[i], box[2][i])
		end
	end
	local size = { hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3] }
	local mid = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2 }
	return size, mid, mid[3] - sum[3] / total, sum[2] / total - mid[2]
end

local function expectationFor(boxes)
	local size, mid, front, up = measure(boxes)
	return {
		asset = "SM_RoundTripMarker",
		revision = 1,
		size = size,
		front = "-Z",
		front_offset = front,
		up_offset = up,
		pivot = "base-centre",
		materials = { "MAT_Body", "MAT_Front" },
		triangles = 12 * #boxes,
		tolerance = 0.05,
	},
		mid
end

local expectation = expectationFor(MARKER)
local frontOffset = expectation.front_offset
local correct = { triangles = reader(MARKER) }

-- A correctly imported part whose bounds match `boxes`, moved by `d`, with a baked texture bound.
local function importedPart(boxes, d)
	local size, mid = measure(boxes)
	d = d or { 0, 0, 0 }
	local part = meshPart("SM_RoundTripMarker", size, { mid[1] + d[1], mid[2] + d[2], mid[3] + d[3] })
	part.TextureID = "SETUP_ONLY_baked_texture"
	return part
end

local function check(report, name)
	for _, c in report.checks do
		if c.name == name then
			return c
		end
	end
	error("no check " .. name)
end

test("correct import passes", function(t)
	local report = Inspector.inspect(importedPart(MARKER), expectation, correct)
	for _, c in report.checks do
		t.ok(c.pass, c.name)
	end
	t.ok(report.pass, "report passes")
	t.eq(#report.notChecked, 0, "everything measured")
	t.ok(math.abs(frontOffset) > 0.1, "marker is asymmetric along its front axis")
	t.eq(check(report, "triangle_count").value, 24, "triangle count read from the mesh")
end)

test("asset facing +Z fails the front check", function(t)
	local flipZ = function(p)
		return { p[1], p[2], -p[3] }
	end
	local front = check(
		Inspector.inspect(importedPart(MARKER), expectation, { triangles = reader(MARKER, flipZ) }),
		"orientation_front"
	)
	t.ok(not front.pass)
	t.ok(string.find(front.detail, "faces %+Z"), front.detail)
end)

test("unreadable mesh leaves the front and triangle count undetermined and fails", function(t)
	local part = importedPart(MARKER)
	local unreadable = {
		triangles = function()
			return nil, "no access"
		end,
	}
	local report = Inspector.inspect(part, expectation, unreadable)
	local front = check(report, "orientation_front")
	t.ok(not front.pass)
	t.ok(string.find(front.detail, "undetermined"), front.detail)
	local tris = check(report, "triangle_count")
	t.ok(not tris.pass and tris.checked == false, "triangle count not checked")
	t.ok(string.find(tris.detail, "no access"), tris.detail)
	t.ok(table.find(report.notChecked, "triangle_count"), "listed as not checked")
	t.ok(not report.pass, "an unmeasured check never passes the report")
	local legacy = table.clone(expectation)
	legacy.front_offset = nil
	t.ok(not check(Inspector.inspect(part, legacy, correct), "orientation_front").pass)
end)

test("split import uses the named front part", function(t)
	local root = meshPart("SM_RoundTripMarker", { 4, 7, 3.5 }, { 0, 3.5, 0 })
	local nose = meshPart("Front", { 1, 1, 1.5 }, { 0, 3, -1 })
	root.GetDescendants = function()
		return { nose }
	end
	t.ok(check(Inspector.inspect(root, expectation, correct), "orientation_front").pass)
	nose.CFrame = roblox.CFrame.new(0, 3, 1)
	t.ok(not check(Inspector.inspect(root, expectation, correct), "orientation_front").pass)
end)

test("pivot off the base centre fails at the origin", function(t)
	-- The recorded 2026-10-05 v1 defect: pivot 0.75 studs behind the base centre (base centre z = 0).
	local report = Inspector.inspect(pivotAt(importedPart(MARKER), { 0, 0, 0.75 }), expectation, correct)
	local pivot = check(report, "pivot_base_centre")
	t.ok(not pivot.pass, "0.75 stud pivot error")
	t.ok(not report.pass)
	t.near(pivot.value[3], 0.75, 1e-9, "offset reported in studs")
	t.ok(string.find(pivot.detail, "0.750"), pivot.detail)
	-- Inside the tolerance (0.05 studs) still passes.
	t.ok(
		check(
			Inspector.inspect(pivotAt(importedPart(MARKER), { 0.04, 0, -0.04 }), expectation, correct),
			"pivot_base_centre"
		).pass
	)
end)

test("pivot tolerance does not grow with distance from the origin", function(t)
	for _, d in { { 0, 4.8, 20 }, { 30, 4.8, 0 }, { 0, 70, 0 }, { 5000, 200, -5000 } } do
		local where = `model moved by ({d[1]}, {d[2]}, {d[3]})`
		local options = { triangles = reader(MARKER, shifted(d)) }
		local good =
			Inspector.inspect(pivotAt(importedPart(MARKER, d), { d[1], d[2], d[3] }), expectation, options)
		t.ok(good.pass, where .. ": correct pivot passes")
		local behind = pivotAt(importedPart(MARKER, d), { d[1], d[2], d[3] + 0.75 })
		t.ok(
			not check(Inspector.inspect(behind, expectation, options), "pivot_base_centre").pass,
			where .. ": 0.75 behind"
		)
		-- Pivot at the bounding-box centre (3.5 studs up), the far-placement case the old relative tolerance passed.
		local boxCentre = pivotAt(importedPart(MARKER, d), { d[1], d[2] + 3.5, d[3] })
		t.ok(
			not check(Inspector.inspect(boxCentre, expectation, options), "pivot_base_centre").pass,
			where .. ": box centre"
		)
		local slightly = pivotAt(importedPart(MARKER, d), { d[1], d[2] + 0.1, d[3] })
		t.ok(
			not check(Inspector.inspect(slightly, expectation, options), "pivot_base_centre").pass,
			where .. ": 0.1 up"
		)
	end
end)

test("upside-down import is diagnosed from the up offset", function(t)
	local stand, mid = expectationFor(STAND)
	t.ok(math.abs(stand.up_offset) > 1, "STAND is asymmetric along up")
	t.ok(
		Inspector.inspect(importedPart(STAND), stand, { triangles = reader(STAND) }).pass,
		"upright STAND passes"
	)
	-- Rolled 180 degrees about the front axis: up flips, the front stays on -Z.
	local roll = function(p)
		return { 2 * mid[1] - p[1], 2 * mid[2] - p[2], p[3] }
	end
	local front = check(
		Inspector.inspect(importedPart(STAND), stand, { triangles = reader(STAND, roll) }),
		"orientation_front"
	)
	t.ok(not front.pass)
	t.ok(front.value.up * stand.up_offset < 0, "up offset sign flipped")
	t.eq(front.detail, "asset is upside down: fix the FBX up axis")
	-- Turned 180 degrees about X: up and front both flip.
	local pitch = function(p)
		return { p[1], 2 * mid[2] - p[2], 2 * mid[3] - p[3] }
	end
	front = check(
		Inspector.inspect(importedPart(STAND), stand, { triangles = reader(STAND, pitch) }),
		"orientation_front"
	)
	t.ok(not front.pass)
	t.ok(string.find(front.detail, "upside down and faces %+Z"), front.detail)
end)

test("an up offset too small to tell a flip is reported, not silently passed", function(t)
	local front = check(Inspector.inspect(importedPart(MARKER), expectation, correct), "orientation_front")
	t.ok(front.pass)
	t.ok(string.find(front.detail, "up not verified"), front.detail)
end)

test("metre-scaled import is diagnosed", function(t)
	local report =
		Inspector.inspect(meshPart("M", { 4 * 0.28, 7 * 0.28, 3.5 * 0.28 }, { 0, 1, 0 }), expectation)
	t.ok(not report.pass)
	t.ok(string.find(report.checks[2].detail, "Scale Unit"), report.checks[2].detail)
	-- The other direction: a stud-sized FBX read as metres is 3.571x too big.
	local big =
		Inspector.inspect(meshPart("M", { 4 * 3.571, 7 * 3.571, 3.5 * 3.571 }, { 0, 12.5, 0 }), expectation)
	t.ok(not check(big, "scale").pass)
	t.eq(check(big, "scale").detail, "metre/stud mismatch: set importer Scale Unit = Studs")
end)

test("centimetre-scaled imports (x100 and x0.01) are diagnosed", function(t)
	for _, k in { 100, 0.01 } do
		local part = meshPart("M", { 4 * k, 7 * k, 3.5 * k }, { 0, 3.5 * k, 0 })
		local scale = check(Inspector.inspect(part, expectation), "scale")
		t.ok(not scale.pass, `x{k}`)
		t.eq(scale.detail, "centimetre scale: FBX unit scale not applied", `x{k}`)
	end
	-- A size that matches no known unit mistake is not given a wrong cause.
	local odd = check(Inspector.inspect(meshPart("M", { 8, 14, 7 }, { 0, 7, 0 }), expectation), "scale")
	t.eq(odd.detail, "unexpected size")
end)

test("Y/Z swap is diagnosed", function(t)
	local report = Inspector.inspect(meshPart("M", { 4, 3.5, 7 }, { 0, 1.75, 0 }), expectation)
	t.ok(string.find(report.checks[2].detail, "swapped"))
end)

test("rotated import and precise collision are flagged", function(t)
	local part = meshPart("M", { 4, 7, 3.5 }, { 0, 3.5, 0 }, 90)
	part.CollisionFidelity = "Enum.CollisionFidelity.PreciseConvexDecomposition"
	local report = Inspector.inspect(part, expectation)
	local failed = {}
	for _, c in report.checks do
		if not c.pass then
			failed[c.name] = true
		end
	end
	t.ok(failed.orientation_unrotated and failed.collision_fidelity)
end)

test("triangle count must match Blender's", function(t)
	local more = table.clone(MARKER)
	table.insert(more, { { -1, 7, 0 }, { 1, 7, 0.5 } }) -- a flat extra box inside the same bounds
	local tris = check(
		Inspector.inspect(importedPart(MARKER), expectation, { triangles = reader(more) }),
		"triangle_count"
	)
	t.ok(not tris.pass, "36 vs 24")
	t.eq(tris.value, 36)
	t.ok(string.find(tris.detail, "Blender exported 24"), tris.detail)
	local oneOff = table.clone(expectation)
	oneOff.triangles = 25
	t.ok(
		check(Inspector.inspect(importedPart(MARKER), oneOff, correct), "triangle_count").pass,
		"1 triangle slack"
	)
	oneOff.triangles = 26
	t.ok(
		not check(Inspector.inspect(importedPart(MARKER), oneOff, correct), "triangle_count").pass,
		"2 off fails"
	)
end)

test("missing expectation fields are reported as not checked, never passed", function(t)
	local legacy = table.clone(expectation)
	legacy.triangles, legacy.materials, legacy.pivot, legacy.front = nil, nil, nil, nil
	local report = Inspector.inspect(importedPart(MARKER), legacy, correct)
	t.eq(#report.notChecked, 4, "every missing field listed")
	for _, name in { "triangle_count", "appearance_bound", "pivot_base_centre", "orientation_front" } do
		local c = check(report, name)
		t.ok(not c.pass and c.checked == false, name)
		t.ok(string.find(c.detail, "^not checked"), c.detail)
		t.ok(table.find(report.notChecked, name), name .. " listed")
	end
	t.ok(not report.pass)
end)

test("multi-material asset without a colour binding fails appearance", function(t)
	local grey = importedPart(MARKER)
	grey.TextureID = ""
	local none = function()
		return 0
	end
	local appearance = check(
		Inspector.inspect(grey, expectation, { triangles = reader(MARKER), colours = none }),
		"appearance_bound"
	)
	t.ok(not appearance.pass, "grey import (gap B06)")
	t.ok(string.find(appearance.detail, "material colours lost"), appearance.detail)
	local oneColour = function()
		return 1
	end
	t.ok(
		not check(
			Inspector.inspect(grey, expectation, { triangles = reader(MARKER), colours = oneColour }),
			"appearance_bound"
		).pass
	)
	-- The default Studio reader cannot open a mesh in Lune: unreadable colours and no texture still fail.
	local unread = check(Inspector.inspect(grey, expectation, correct), "appearance_bound")
	t.ok(not unread.pass)
	t.ok(string.find(unread.detail, "vertex colours unreadable"), unread.detail)
	-- Each binding on its own is enough.
	local vertex = function()
		return 2
	end
	t.ok(
		check(
			Inspector.inspect(grey, expectation, { triangles = reader(MARKER), colours = vertex }),
			"appearance_bound"
		).pass
	)
	local surfaced = importedPart(MARKER)
	surfaced.TextureID = ""
	surfaced.Children.SurfaceAppearance = { Name = "SurfaceAppearance" }
	t.ok(
		check(
			Inspector.inspect(surfaced, expectation, { triangles = reader(MARKER), colours = none }),
			"appearance_bound"
		).pass
	)
	local single = table.clone(expectation)
	single.materials = { "MAT_Body" }
	t.ok(
		check(
			Inspector.inspect(grey, single, { triangles = reader(MARKER), colours = none }),
			"appearance_bound"
		).pass
	)
end)

test("revision comparison detects updated geometry", function(t)
	local v1 = Inspector.inspect(meshPart("M", { 4, 7, 3.5 }, { 0, 3.5, 0 }), expectation)
	local v2 = Inspector.inspect(meshPart("M", { 4, 8, 4.5 }, { 0, 4, 0 }), expectation)
	t.ok(Inspector.compareRevisions(v1, v2).changed)
	t.ok(not Inspector.compareRevisions(v1, v1).changed)
end)

test("revision comparison sees a changed mesh inside the same bounds", function(t)
	local before = Inspector.inspect(importedPart(MARKER), expectation, correct)
	-- Same bounds, more triangles (and a different surface centroid).
	local more = table.clone(MARKER)
	table.insert(more, { { -1, 6, 0 }, { 1, 6.5, 0.5 } })
	local after = Inspector.inspect(importedPart(MARKER), expectation, { triangles = reader(more) })
	local cmp = Inspector.compareRevisions(before, after)
	t.ok(cmp.changed)
	t.ok(table.find(cmp.differences, "triangles"), "triangle count compared")
	t.ok(not table.find(cmp.differences, "size"), "bounds unchanged")
	-- Same bounds and triangle count, nose moved down: only the surface offsets change.
	local moved = { MARKER[1], { { -0.5, 1, -1.75 }, { 0.5, 2, -0.25 } } }
	local shiftedNose = Inspector.inspect(importedPart(MARKER), expectation, { triangles = reader(moved) })
	cmp = Inspector.compareRevisions(before, shiftedNose)
	t.ok(cmp.changed)
	t.eq(cmp.differences, { "surface_offsets" })
	t.eq(#Inspector.compareRevisions(before, before).differences, 0)
	t.ok(not Inspector.compareRevisions(before, before).changed)
end)

test("revision comparison never reports a change it could not measure", function(t)
	-- Report shapes as recorded in Studio before triangle_count existed.
	local a = { checks = { { name = "scale", pass = true, value = { 4, 7, 3.5 } } } }
	local b = { checks = { { name = "scale", pass = true, value = { 4, 7, 3.5 } } } }
	local cmp = Inspector.compareRevisions(a, b)
	t.ok(not cmp.changed)
	t.eq(cmp.notCompared, { "triangles", "surface_offsets" })
	t.ok(not Inspector.compareRevisions({ checks = {} }, { checks = {} }).changed, "nothing measured")
	-- The audit probe: same bounds, different surface offsets.
	a.checks[2] = { name = "orientation_front", pass = true, value = { front = -0.62, up = 0 } }
	b.checks[2] = { name = "orientation_front", pass = true, value = { front = -0.30, up = 0.2 } }
	t.ok(Inspector.compareRevisions(a, b).changed)
end)

-- ---------------------------------------------------------------- appearance block (factory bakes)

local function baked(maps)
	local exp = table.clone(expectation)
	exp.materials = { "MAT_SM_RoundTripMarker_v1" }
	exp.appearance = { kind = "palette_atlas", maps = maps, palette = 3 }
	return exp
end

local function surface(part, props)
	part.Children.SurfaceAppearance = props
	return part
end

test("palette atlas: the colour map must arrive (B06)", function(t)
	local exp = baked({ color = "SM_RoundTripMarker_v1_Color.png" })
	local report = Inspector.inspect(importedPart(MARKER), exp, correct)
	t.ok(check(report, "appearance").pass, "TextureID carries the atlas")
	t.ok(report.pass)
	local grey = importedPart(MARKER)
	grey.TextureID = ""
	local lost = check(Inspector.inspect(grey, exp, correct), "appearance")
	t.ok(not lost.pass)
	t.ok(string.find(lost.detail, "B06"), lost.detail)
	-- The Content property (TextureContent) or a SurfaceAppearance ColorMapContent counts too.
	local content = importedPart(MARKER)
	content.TextureID = ""
	content.TextureContent = { Uri = "rbxasset://textures/SETUP_ONLY_atlas.png" }
	t.ok(check(Inspector.inspect(content, exp, correct), "appearance").pass)
	local sa = surface(importedPart(MARKER), { ColorMapContent = { Uri = "rbxasset://x" } })
	sa.TextureID = ""
	t.ok(check(Inspector.inspect(sa, exp, correct), "appearance").pass)
	-- An appearance block replaces the materials-count rule: no appearance_bound check.
	t.ok(not pcall(check, Inspector.inspect(grey, exp, correct), "appearance_bound"))
end)

test("palette atlas with PBR maps: only a TextureID is diagnosed as B02", function(t)
	local exp = baked({ color = "a_Color.png", roughness = "a_Roughness.png", metalness = "a_Metalness.png" })
	local textureOnly = Inspector.inspect(importedPart(MARKER), exp, correct)
	local rough = check(textureOnly, "appearance_roughness")
	t.ok(not rough.pass and string.find(rough.detail, "B02"), rough.detail)
	t.ok(not check(textureOnly, "appearance_metalness").pass)
	t.ok(not textureOnly.pass)
	local full = surface(importedPart(MARKER), {
		ColorMap = "rbxassetid://0",
		RoughnessMap = "rbxassetid://0",
		MetalnessMapContent = { Uri = "rbxasset://m" },
	})
	local report = Inspector.inspect(full, exp, correct)
	t.ok(check(report, "appearance_roughness").pass)
	t.ok(check(report, "appearance_metalness").pass)
	t.ok(report.pass)
	t.ok(not pcall(check, report, "appearance_normal"), "no normal map expected, none checked")
end)

test("vertex-colour route needs colours and a white part", function(t)
	local exp = table.clone(expectation)
	exp.appearance =
		{ kind = "vertex_colors", palette = 2, vertex_colors = "Color", part_color = { 255, 255, 255 } }
	local part = importedPart(MARKER)
	part.TextureID = ""
	part.Color = roblox.Color3.new(1, 1, 1)
	local two = {
		triangles = reader(MARKER),
		colours = function()
			return 2
		end,
	}
	local report = Inspector.inspect(part, exp, two)
	t.ok(check(report, "appearance").pass and check(report, "appearance_part_color").pass)
	part.Color = roblox.Color3.new(0.64, 0.64, 0.64)
	local tinted = check(Inspector.inspect(part, exp, two), "appearance_part_color")
	t.ok(not tinted.pass and string.find(tinted.detail, "multiplies"), tinted.detail)
	part.Color = roblox.Color3.new(1, 1, 1)
	local none = {
		triangles = reader(MARKER),
		colours = function()
			return 0
		end,
	}
	t.ok(not check(Inspector.inspect(part, exp, none), "appearance").pass)
	local unread = check(Inspector.inspect(part, exp, correct), "appearance")
	t.ok(unread.checked == false and string.find(unread.detail, "unreadable"), unread.detail)
end)

test("library route needs the MaterialVariant applied; unknown kinds are not checked", function(t)
	local exp = table.clone(expectation)
	exp.appearance = { kind = "library", materials = { "library:concrete_a" } }
	local part = importedPart(MARKER)
	part.MaterialVariant = ""
	local missing = check(Inspector.inspect(part, exp, correct), "appearance")
	t.ok(not missing.pass and string.find(missing.detail, "SceneKit/Materials"), missing.detail)
	part.MaterialVariant = "concrete_a"
	t.ok(check(Inspector.inspect(part, exp, correct), "appearance").pass)
	exp.appearance = { kind = "hologram" }
	local unknown = Inspector.inspect(part, exp, correct)
	t.ok(table.find(unknown.notChecked, "appearance"), "unknown kind listed as not checked")
	t.ok(not unknown.pass)
end)

-- The marker with a side fin on Roblox -X (Blender +X under the derived mapping): asymmetric in X.
local FINNED = {
	MARKER[1],
	MARKER[2],
	{ { -3, 4, 0.25 }, { -2, 5, 1.25 } },
}

test("side offset catches an import mirrored along X", function(t)
	local size, mid, front, up = measure(FINNED)
	local exp = expectationFor(FINNED)
	-- Area-weighted centroid along +X minus the bounds centre, computed the same way as measure().
	local sum, total = 0, 0
	for _, box in FINNED do
		local d = { box[2][1] - box[1][1], box[2][2] - box[1][2], box[2][3] - box[1][3] }
		local area = 2 * (d[1] * d[2] + d[2] * d[3] + d[3] * d[1])
		total += area
		sum += area * (box[1][1] + box[2][1]) / 2
	end
	exp.side_offset = sum / total - mid[1]
	t.ok(math.abs(exp.side_offset) > 0.1, "fin makes the marker asymmetric in X")
	local part = importedPart(FINNED)
	local good = Inspector.inspect(part, exp, { triangles = reader(FINNED) })
	t.ok(check(good, "orientation_side").pass)
	t.ok(good.pass, "finned marker passes everything")
	local flipX = function(p)
		return { 2 * mid[1] - p[1], p[2], p[3] }
	end
	local mirrored =
		check(Inspector.inspect(part, exp, { triangles = reader(FINNED, flipX) }), "orientation_side")
	t.ok(not mirrored.pass and string.find(mirrored.detail, "mirrored"), mirrored.detail)
	local symmetric = table.clone(exp)
	symmetric.side_offset = 0.02
	local sym =
		check(Inspector.inspect(part, symmetric, { triangles = reader(FINNED, flipX) }), "orientation_side")
	t.ok(sym.pass and string.find(sym.detail, "symmetric"), sym.detail)
	local unreadable = Inspector.inspect(part, exp, {
		triangles = function()
			return nil, "no access"
		end,
	})
	t.ok(table.find(unreadable.notChecked, "orientation_side"), "unreadable mesh: side not checked")
	t.ok(
		not pcall(check, Inspector.inspect(part, expectation, correct), "orientation_side"),
		"older expectations skip it"
	)
	t.ok(size[1] > 0 and front ~= nil and up ~= nil)
end)

-- ---------------------------------------------------------------- clips/1

local function petSidecar()
	return {
		schema = "clips/1",
		asset = "pet_follower",
		rig = "custom",
		fps = 30,
		files = {
			glb = "pet_follower_clips.glb",
			fbx = { idle = "pet_follower_idle.fbx", walk = "pet_follower_walk.fbx" },
		},
		clips = {
			{
				name = "idle",
				slot = "idle",
				start = 0,
				["end"] = 59,
				loop = true,
				root_motion = false,
				priority = "Idle",
				markers = {},
			},
			{
				name = "walk",
				slot = "walk",
				start = 0,
				["end"] = 29,
				loop = true,
				root_motion = false,
				markers = {
					{ name = "footstep", frame = 7, param = "left" },
					{ name = "footstep", frame = 22, param = "right" },
				},
			},
		},
	}
end

test("inspectClips passes matching clips and returns the play plan", function(t)
	local observed = {
		{ name = "idle", length = 59 / 30 },
		{ name = "RIG_PetFollower|walk", length = 29 / 30 },
		{ name = "Take 001", length = 1 },
	}
	local report = Inspector.inspectClips(petSidecar(), observed)
	t.ok(report.pass, "all clips present with their lengths")
	t.eq(report.extra, { "Take 001" })
	t.eq(#report.plan, 2)
	local walk = report.plan[2]
	t.eq(walk.name, "walk")
	t.ok(walk.looped)
	t.near(walk.markers[1].time, 7 / 30, 1e-9)
	t.eq(walk.markers[2].param, "right")
	t.eq(report.plan[1].priority, "Idle")
	local markers = check(report, "clip_markers:walk")
	t.ok(markers.pass and string.find(markers.detail, "plan"), markers.detail)
end)

test("inspectClips fails missing, wrong-length and mis-marked clips", function(t)
	local short = Inspector.inspectClips(petSidecar(), { { name = "idle", length = 1.0 } })
	t.ok(not short.pass)
	t.ok(not check(short, "clip_length:idle").pass, "1.0 s is not 59 frames at 30 fps")
	t.ok(not check(short, "clip_present:walk").pass)
	local marked = Inspector.inspectClips(petSidecar(), {
		{ name = "idle", length = 59 / 30 },
		{
			name = "walk",
			length = 29 / 30,
			markers = { { name = "footstep", time = 7 / 30 }, { name = "footstep", time = 0.9 } },
		},
	})
	local m = check(marked, "clip_markers:walk")
	t.ok(not m.pass and string.find(m.detail, "footstep@0.733"), m.detail)
	local unknown =
		Inspector.inspectClips(petSidecar(), { { name = "idle" }, { name = "walk", length = 29 / 30 } })
	t.ok(table.find(unknown.notChecked, "clip_length:idle"), "no readable length is not a pass")
end)

test("validateClips rejects broken sidecars", function(t)
	t.eq(#Inspector.validateClips(petSidecar()), 0)
	local bad = petSidecar()
	bad.clips[1].slot = "dance"
	bad.clips[2]["end"] = -1
	bad.clips[2].markers[1].frame = 40
	table.insert(bad.clips, table.clone(bad.clips[1]))
	bad.fps = 0
	local problems = Inspector.validateClips(bad)
	local text = table.concat(problems, "\n")
	for _, needle in { "fps", "dance", "end >= start", "duplicate name idle" } do
		t.ok(string.find(text, needle, 1, true), needle .. " in " .. text)
	end
	local report = Inspector.inspectClips(bad, {})
	t.ok(not report.pass and not check(report, "sidecar_valid").pass)
	t.eq(Inspector.validateClips({ schema = "clips/0" }), { "schema must be 'clips/1'" })
end)

-- ---------------------------------------------------------------- T3 probe registries (mocks)

local Probe = require("../packages/GameKit/Probe")
local function runProbe(registry)
	local lines = {}
	local summary = Probe.runAll(registry, {
		emit = function(line)
			table.insert(lines, line)
		end,
		kit = function(path)
			assert(path == "Pipeline/ImportInspector", path)
			return Inspector
		end,
	})
	return summary, lines
end

test("import_appearance probe records every inspector check", function(t)
	local Appearance = require("./engine/import_appearance")
	local exp = baked({ color = "SM_RoundTripMarker_v1_Color.png" })
	local summary, lines = runProbe(Appearance.registry({
		{ asset = "SM_RoundTripMarker", expectation = exp, root = importedPart(MARKER), options = correct },
	}))
	t.ok(summary.ok, lines[#lines])
	t.ok(string.find(lines[#lines], "^ENGINE_DONE "), "one done line")
	local missing = runProbe(Appearance.registry({ { asset = "pickup", expectation = exp } }))
	t.ok(not missing.ok, "a model that was not imported fails")
	t.ok(not runProbe(Appearance.registry({})).ok, "no cases is not a pass")
end)

test("import_clips probe reads KeyframeSequences and checks them against the sidecar", function(t)
	local Clips = require("./engine/import_clips")
	local function sequence(name, times, markers)
		local keyframes = {}
		for _, time in times do
			table.insert(keyframes, {
				Time = time,
				GetMarkers = function()
					return markers[time] or {}
				end,
			})
		end
		return {
			Name = name,
			Loop = true,
			Priority = { Name = "Core" },
			IsA = function(_, class)
				return class == "KeyframeSequence"
			end,
			GetKeyframes = function()
				return keyframes
			end,
		}
	end
	local root = {
		GetDescendants = function()
			return {
				sequence("idle", { 0, 1, 59 / 30 }, {}),
				sequence(
					"walk",
					{ 0, 7 / 30, 29 / 30 },
					{ [7 / 30] = { { Name = "footstep", Value = "left" } } }
				),
			}
		end,
	}
	local summary, lines =
		runProbe(Clips.registry({ { asset = "pet_follower", sidecar = petSidecar(), root = root } }))
	t.ok(not summary.ok, "one of two walk markers arrived: the marker check fails")
	local text = table.concat(lines, "\n")
	t.ok(string.find(text, "animations_found", 1, true), "where the clips were found is recorded")
	local lengthLine = string.match(text, '[^\n]*"pet_follower:clip_length:idle"[^\n]*')
	t.ok(lengthLine and string.find(lengthLine, '"ok":true', 1, true), text)
	local clean = {
		GetDescendants = function()
			return { sequence("idle", { 0, 59 / 30 }, {}), sequence("walk", { 0, 29 / 30 }, {}) }
		end,
	}
	t.ok(runProbe(Clips.registry({ { asset = "pet_follower", sidecar = petSidecar(), root = clean } })).ok)
end)

return cases
