--!strict
-- Validate.course (exposed through ProcGen/Validate): proves a course/1 manifest playable from its
-- geometry alone, with the character profile the course was built for. Values are measured
-- here (gaps from pad footprints, radii from track samples), never read from the generator's own
-- notes, so a hand-edited or broken course fails with the segment, the number and the limit.
-- Checks per kind:
--   linear, tower  jumpable_gaps, reachability, checkpoint_gating, checkpoint_spacing,
--                  difficulty_curve, landing_size, pad_overlap, headroom, hazard_placement,
--                  spawn_clearance
--   race_loop      loop_closed, min_turn_radius, max_grade, max_bank, track_clearance,
--                  gate_spacing, gate_coverage, grid_slots
--   lanes          lane_connectivity, lanes_disjoint, lane_balance, slot_balance, slot_access,
--                  lane_width
--   micro_arena    spawn_fairness, spawn_symmetry, spawn_separation, spawn_edge_clearance,
--                  area_per_player, spawn_clear, spawn_on_floor, piece_overlap
-- Every kind also gets course_hash (the manifest still hashes to its hash). Limits marked
-- "convention" are level-design choices with a reason, not Roblox numbers.
local Course = require("./Course")
local Measure = require("../SceneKit/Measure")

local CourseValidate = {}

export type Check = { name: string, pass: boolean, value: any, limit: any?, detail: string? }

CourseValidate.DEFAULTS = table.freeze({
	maxCheckpointSpacing = 160, -- studs of route between checkpoints (convention: about 30 s of retries)
	-- challenges between checkpoints (convention: a tower floor is one checkpoint stretch and
	-- short-jump profiles need up to 15 pads to circle it)
	maxCheckpointSegments = 16,
	difficultyTolerance = 0.12, -- how far a challenge may fall below the hardest one before it
	minLanding = 1.5, -- narrowest landing dimension, studs (convention; R15 stands on 1.5)
	minSpawnSide = 8, -- spawn pad side, studs (convention: several players spawn at once)
	maxRiseShare = 0.8, -- a rise may use at most this share of the jump height (convention)
	maxGateSpacing = 400, -- race: studs between gates (convention; a course may record its own)
	laneBalance = 0.05, -- lanes: (longest - shortest) / longest
	coverageBalance = 0.25, -- lanes: spread of summed slot coverage
	spawnSpread = 0.05, -- arena: (farthest - nearest) / mean spawn distance to the centre
	symmetryTolerance = 0.5, -- arena: studs every spawn's view of cover and hazards may differ
	minSpawnSeparation = 8, -- arena: studs between spawns (convention)
	minAreaPerPlayer = 100, -- arena: square studs per player (convention, scaled by body size)
	maxAreaPerPlayer = 400,
	spawnClear = 4, -- arena: studs from a spawn to the nearest cover or hazard (convention)
})

local function rule(rules: any, key: string): number
	local value = rules and rules[key]
	if value == nil then
		return (CourseValidate.DEFAULTS :: any)[key]
	end
	return value
end

local function check(name: string, pass: boolean, value: any, limit: any?, detail: string?): Check
	return { name = name, pass = pass, value = value, limit = limit, detail = detail }
end

local function round2(value: number): number
	return math.round(value * 100) / 100
end

local function list(items: { string }, max: number?): string
	local limit = max or 5
	local shown = table.concat(items, "; ", 1, math.min(#items, limit))
	if #items > limit then
		shown ..= string.format("; ... %d more", #items - limit)
	end
	return shown
end

local function padName(course: any, index: number): string
	local pad = course.pads[index]
	return string.format("pad %d (%s)", index, if pad then pad.id else "missing")
end

-- ---------------------------------------------------------------- jump courses

export type Link = { gap: number, rise: number, walk: boolean, ok: boolean, reason: string? }

-- Whether a player standing on pad a can reach pad b (walk onto it, or jump within the margin).
function CourseValidate.link(a: any, b: any, profile: any, margin: number, rules: any?): Link
	local gap = Course.padGap(a, b)
	local rise = b.pos.y - a.pos.y
	local walk = gap <= Course.WALK_GAP and math.abs(rise) <= Measure.GUIDE.maxStep
	if walk then
		return { gap = gap, rise = rise, walk = true, ok = true }
	end
	local maxRise = profile.jumpHeight * rule(rules, "maxRiseShare")
	if rise > maxRise then
		return {
			gap = gap,
			rise = rise,
			walk = false,
			ok = false,
			reason = string.format("rise %.2f > %.2f", rise, maxRise),
		}
	end
	local jumpGap = math.max(gap, 0)
	if not Measure.canJump(jumpGap, rise, margin, profile) then
		local reach = Measure.jumpReach(rise, profile) or 0
		return {
			gap = gap,
			rise = rise,
			walk = false,
			ok = false,
			reason = string.format(
				"gap %.2f > safe %.2f (reach %.2f, margin %.2f)",
				jumpGap,
				reach * (1 - margin),
				reach,
				margin
			),
		}
	end
	return { gap = gap, rise = rise, walk = false, ok = true }
end

-- Measured difficulty of a link: the share of the safe jump it uses; a walk onto a beam scores
-- by its width (Course.NARROW); other walks are not challenges (nil).
function CourseValidate.difficulty(link: Link, landing: any, profile: any, margin: number): number?
	if link.walk then
		local width = math.min(landing.size.x, landing.size.z)
		if width >= Course.NARROW.wide - 1e-6 then
			return nil
		end
		local t = math.clamp((Course.NARROW.wide - width) / (Course.NARROW.wide - Course.NARROW.narrow), 0, 1)
		return Course.DIFFICULTY.min + (Course.DIFFICULTY.max - Course.DIFFICULTY.min) * t
	end
	local safe = Course.safeGap(link.rise, profile, margin)
	if safe == nil or safe <= 0 then
		return 1
	end
	return math.max(link.gap, 0) / safe
end

local function reachable(
	_course: any,
	edges: { { number } },
	from: number,
	skip: number?
): { [number]: boolean }
	local seen = { [from] = true }
	local queue, head = { from }, 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, other in edges[current] do
			if other ~= skip and not seen[other] then
				seen[other] = true
				table.insert(queue, other)
			end
		end
	end
	return seen
end

local function jumpChecks(course: any, rules: any?, checks: { Check })
	local profile = course.profile
	local margin = (rules and rules.margin) or course.params.margin or Course.MARGIN
	local pads = course.pads
	local bad, links = {}, {}
	for _, segment in course.segments do
		local a, b = pads[segment.from], pads[segment.to]
		if a == nil or b == nil then
			table.insert(bad, string.format("segment %d links missing pads", segment.index))
			continue
		end
		local link = CourseValidate.link(a, b, profile, margin, rules)
		links[segment.index] = link
		if not link.ok then
			table.insert(
				bad,
				string.format(
					"segment %d %s: %s",
					segment.index,
					tostring(segment.kind),
					tostring(link.reason)
				)
			)
		end
	end
	table.insert(
		checks,
		check(
			"jumpable_gaps",
			#bad == 0,
			#bad,
			0,
			if #bad > 0 then list(bad) else "every link walks or jumps"
		)
	)

	-- Directed reachability over every pair of pads (not only the authored order).
	local edges: { { number } } = {}
	local clearance = profile.jumpHeight + profile.characterHeight
	local reachMax = (Measure.jumpReach(-40, profile) or 0) + 12
	for i, a in pads do
		edges[i] = {}
		for j, b in pads do
			if i ~= j and b.pos.y - a.pos.y <= clearance then
				local dx, dz = b.pos.x - a.pos.x, b.pos.z - a.pos.z
				local half = math.max(a.size.x, a.size.z) + math.max(b.size.x, b.size.z)
				if math.sqrt(dx * dx + dz * dz) <= reachMax + half and b.pos.y - a.pos.y > -40 then
					if CourseValidate.link(a, b, profile, margin, rules).ok then
						table.insert(edges[i], j)
					end
				end
			end
		end
	end
	local seen = reachable(course, edges, 1)
	local missing = {}
	for index in pads do
		if not seen[index] then
			table.insert(missing, padName(course, index))
		end
	end
	table.insert(
		checks,
		check(
			"reachability",
			#missing == 0,
			#missing,
			0,
			if #missing > 0 then "unreachable from the spawn: " .. list(missing) else "every pad reachable"
		)
	)

	local finishIndex = course.finish.pad
	local bypassed = {}
	for _, cp in course.checkpoints do
		local around = reachable(course, edges, 1, cp.pad)
		if around[finishIndex] then
			table.insert(bypassed, string.format("checkpoint %d (%s)", cp.index, padName(course, cp.pad)))
		end
	end
	table.insert(
		checks,
		check(
			"checkpoint_gating",
			#bypassed == 0,
			#bypassed,
			0,
			if #bypassed > 0
				then "finish reachable without " .. list(bypassed)
				else "no checkpoint can be skipped"
		)
	)

	-- Route between consecutive checkpoints (spawn first, finish last).
	local stops = { { name = "spawn", pad = 1 } }
	for _, cp in course.checkpoints do
		table.insert(stops, { name = "checkpoint " .. cp.index, pad = cp.pad })
	end
	table.insert(stops, { name = "finish", pad = finishIndex })
	local maxStuds, maxCount = rule(rules, "maxCheckpointSpacing"), rule(rules, "maxCheckpointSegments")
	local far, worst = {}, 0
	for s = 2, #stops do
		local studs, count = 0, 0
		for p = stops[s - 1].pad + 1, stops[s].pad do
			local a, b = pads[p - 1], pads[p]
			studs += math.sqrt((b.pos.x - a.pos.x) ^ 2 + (b.pos.z - a.pos.z) ^ 2)
			count += 1
		end
		worst = math.max(worst, studs)
		if studs > maxStuds or count > maxCount then
			table.insert(
				far,
				string.format(
					"%s -> %s: %.1f studs, %d segments",
					stops[s - 1].name,
					stops[s].name,
					studs,
					count
				)
			)
		end
	end
	table.insert(
		checks,
		check(
			"checkpoint_spacing",
			#far == 0,
			round2(worst),
			{ studs = maxStuds, segments = maxCount },
			if #far > 0 then list(far) else "longest stretch in studs"
		)
	)

	-- Difficulty: no challenge may fall more than the tolerance below the hardest one before it.
	local tolerance = rule(rules, "difficultyTolerance")
	local peak, peakIndex = -math.huge, 0
	local drops = {}
	for _, segment in course.segments do
		local link = links[segment.index]
		if link then
			local s = CourseValidate.difficulty(link, pads[segment.to], profile, margin)
			if s then
				if s < peak - tolerance then
					table.insert(
						drops,
						string.format(
							"segment %d difficulty %.2f drops %.2f below %.2f (segment %d)",
							segment.index,
							s,
							peak - s,
							peak,
							peakIndex
						)
					)
				end
				if s > peak then
					peak, peakIndex = s, segment.index
				end
			end
		end
	end
	table.insert(
		checks,
		check(
			"difficulty_curve",
			#drops == 0,
			#drops,
			tolerance,
			if #drops > 0 then list(drops) else "challenges never ease by more than the tolerance"
		)
	)

	local small = {}
	local minLanding = rule(rules, "minLanding")
	for _, segment in course.segments do
		local b = pads[segment.to]
		if b and math.min(b.size.x, b.size.z) < minLanding - 1e-6 then
			table.insert(
				small,
				string.format("segment %d lands on %.2f studs", segment.index, math.min(b.size.x, b.size.z))
			)
		end
	end
	table.insert(checks, check("landing_size", #small == 0, #small, minLanding, list(small)))

	-- Pads that intersect, and pads hanging inside a jump's arc.
	local overlaps, blocked = {}, {}
	local headroom = profile.jumpHeight + profile.characterHeight
	for i = 1, #pads do
		for j = i + 1, #pads do
			local a, b = pads[i], pads[j]
			if
				math.abs(a.pos.y - b.pos.y) < (a.size.y + b.size.y) / 2 + 0.01
				and Course.footprintsOverlap(a, b, -0.01)
			then
				table.insert(overlaps, padName(course, i) .. " x " .. padName(course, j))
			end
		end
	end
	for _, segment in course.segments do
		local a, b = pads[segment.from], pads[segment.to]
		if a and b then
			local dx, dz = b.pos.x - a.pos.x, b.pos.z - a.pos.z
			local bridge = {
				pos = { x = (a.pos.x + b.pos.x) / 2, y = 0, z = (a.pos.z + b.pos.z) / 2 },
				size = { x = math.sqrt(dx * dx + dz * dz), y = 1, z = math.min(a.size.z, b.size.z) },
				yaw = math.deg(math.atan2(-dz, dx)),
			}
			-- The head peaks a jump height above the take-off, or stands on the landing.
			local floorY = math.min(a.pos.y, b.pos.y)
			local ceiling = math.max(a.pos.y + profile.jumpHeight, b.pos.y) + profile.characterHeight
			for k, p in pads do
				if k ~= segment.from and k ~= segment.to then
					local bottom = p.pos.y - p.size.y
					if
						bottom > floorY
						and bottom < ceiling
						and (
							Course.footprintsOverlap(p, a, -0.01)
							or Course.footprintsOverlap(p, b, -0.01)
							or Course.footprintsOverlap(p, bridge :: any, -0.01)
						)
					then
						table.insert(
							blocked,
							string.format(
								"segment %d: %s %.2f above the take-off",
								segment.index,
								padName(course, k),
								bottom - a.pos.y
							)
						)
					end
				end
			end
		end
	end
	for _, structure in course.structures or {} do
		local box = { pos = structure.pos, size = structure.size, yaw = 0 }
		for k, p in pads do
			local top = structure.pos.y + structure.size.y / 2
			local bottom = structure.pos.y - structure.size.y / 2
			if
				p.pos.y > bottom
				and p.pos.y - p.size.y < top
				and Course.footprintsOverlap(p, box :: any, 0)
			then
				table.insert(overlaps, padName(course, k) .. " x " .. structure.role)
			end
		end
	end
	table.insert(checks, check("pad_overlap", #overlaps == 0, #overlaps, 0, list(overlaps)))
	table.insert(checks, check("headroom", #blocked == 0, #blocked, headroom, list(blocked)))

	local hazardProblems = {}
	for index, hazard in course.hazards or {} do
		local top = hazard.pos.y + hazard.size.y / 2
		local box = { pos = hazard.pos, size = hazard.size, yaw = hazard.yaw }
		for k, p in pads do
			if math.abs(p.pos.y - top) < 2 and Course.footprintsOverlap(p, box :: any, -0.01) then
				table.insert(hazardProblems, string.format("hazard %d under %s", index, padName(course, k)))
			end
		end
		local segment = course.segments[hazard.segment]
		if segment then
			local low = math.min(pads[segment.from].pos.y, pads[segment.to].pos.y)
			if top > low - 0.3 then
				table.insert(
					hazardProblems,
					string.format("hazard %d top %.2f is not below the pads (%.2f)", index, top, low)
				)
			end
		end
	end
	table.insert(
		checks,
		check("hazard_placement", #hazardProblems == 0, #hazardProblems, 0, list(hazardProblems))
	)

	local spawn = pads[course.spawn.pad]
	local side = if spawn then math.min(spawn.size.x, spawn.size.z) else 0
	table.insert(
		checks,
		check(
			"spawn_clearance",
			side >= rule(rules, "minSpawnSide"),
			side,
			rule(rules, "minSpawnSide"),
			"spawn pad side"
		)
	)
end

-- ---------------------------------------------------------------- race loop

local function raceChecks(course: any, rules: any?, checks: { Check })
	local samples = course.samples
	local n = #samples
	local params = course.params
	local width = params.width
	local spacing = course.lapLength / n
	local function horizontal(a: any, b: any): number
		return math.sqrt((b.pos.x - a.pos.x) ^ 2 + (b.pos.z - a.pos.z) ^ 2)
	end

	-- Closed: the last sample leads back to the first like any other step, without a kink.
	local closing = horizontal(samples[n], samples[1])
	local function heading(a: any, b: any): number
		return math.deg(math.atan2(b.pos.x - a.pos.x, b.pos.z - a.pos.z))
	end
	local function turn(a: number, b: number): number
		return math.abs((b - a + 180) % 360 - 180)
	end
	local kink = turn(heading(samples[n - 1], samples[n]), heading(samples[n], samples[1]))
		+ turn(heading(samples[n], samples[1]), heading(samples[1], samples[2]))
	local closed = n >= 8 and closing <= spacing * 1.5 and kink <= 20
	table.insert(
		checks,
		check(
			"loop_closed",
			closed,
			round2(closing),
			round2(spacing * 1.5),
			string.format("last-to-first step %.2f studs, heading change %.1f degrees", closing, kink)
		)
	)

	local minTurn = (rules and rules.minTurnRadius) or params.minTurnRadius
	local tightest, tightAt = math.huge, 0
	for i = 1, n do
		local r =
			math.abs(Course.turnRadius(samples[(i - 2) % n + 1].pos, samples[i].pos, samples[i % n + 1].pos))
		if r < tightest then
			tightest, tightAt = r, i
		end
	end
	table.insert(
		checks,
		check(
			"min_turn_radius",
			tightest >= minTurn,
			round2(tightest),
			minTurn,
			string.format("tightest at sample %d", tightAt)
		)
	)

	local maxGrade = (rules and rules.maxGrade) or params.maxGrade
	local steepest, steepAt = 0, 0
	for i = 1, n do
		local a, b = samples[i], samples[i % n + 1]
		local grade = math.abs(b.pos.y - a.pos.y) / math.max(horizontal(a, b), 1e-9)
		if grade > steepest then
			steepest, steepAt = grade, i
		end
	end
	table.insert(
		checks,
		check(
			"max_grade",
			steepest <= maxGrade + 1e-6,
			round2(steepest),
			maxGrade,
			string.format("steepest step after sample %d", steepAt)
		)
	)

	local maxBank = (rules and rules.maxBank) or params.maxBank
	local bankiest, bankAt = 0, 0
	for i, sample in samples do
		if math.abs(sample.bank) > bankiest then
			bankiest, bankAt = math.abs(sample.bank), i
		end
	end
	table.insert(
		checks,
		check(
			"max_bank",
			bankiest <= maxBank + 1e-6,
			round2(bankiest),
			maxBank,
			string.format("steepest bank at sample %d", bankAt)
		)
	)

	-- Two parts of the track closer than a width apart (by arc length) must not touch in plan.
	local skip = math.ceil(width * 3 / spacing)
	local nearest, nearAt = math.huge, ""
	for i = 1, n do
		for j = i + skip, n do
			local cyclic = math.min(j - i, n - (j - i))
			if cyclic > skip and math.abs(samples[i].pos.y - samples[j].pos.y) < 12 then
				local d = horizontal(samples[i], samples[j])
				if d < nearest then
					nearest, nearAt = d, string.format("samples %d and %d", i, j)
				end
			end
		end
	end
	local need = width + 4
	table.insert(
		checks,
		check(
			"track_clearance",
			nearest >= need,
			if nearest == math.huge then "open" else round2(nearest),
			need,
			"closest non-adjacent track centres: " .. nearAt
		)
	)

	local gates = course.checkpoints
	local maxGap = if rules and rules.maxGateSpacing
		then rules.maxGateSpacing
		else course.params.maxGateSpacing or rule(rules, "maxGateSpacing")
	local far, coverage = {}, {}
	for g, gate in gates do
		local nextGate = gates[g % #gates + 1]
		local steps = (nextGate.sample - gate.sample) % n
		if #gates == 1 then
			steps = n
		end
		local studs = steps * spacing
		if studs > maxGap then
			table.insert(far, string.format("gate %d -> %d: %.1f studs", gate.index, nextGate.index, studs))
		end
		if gate.width < width then
			table.insert(
				coverage,
				string.format("gate %d is %.1f wide, track %.1f", gate.index, gate.width, width)
			)
		end
	end
	table.insert(
		checks,
		check(
			"gate_spacing",
			#far == 0 and #gates >= 2,
			#gates,
			maxGap,
			if #far > 0 then list(far) else "gates"
		)
	)
	table.insert(checks, check("gate_coverage", #coverage == 0, #coverage, 0, list(coverage)))

	local slotProblems = {}
	local slots = course.spawn.slots or {}
	for i, slot in slots do
		if math.abs(slot.lateral) > width / 2 - 3 then
			table.insert(slotProblems, string.format("slot %d is %.1f off the centre line", i, slot.lateral))
		end
		local behind = (1 - slot.sample) % n
		if behind == 0 or behind > n * 0.25 then
			table.insert(slotProblems, string.format("slot %d is not just behind the start line", i))
		end
		for j = i + 1, #slots do
			local other = slots[j]
			local d = math.sqrt((other.pos.x - slot.pos.x) ^ 2 + (other.pos.z - slot.pos.z) ^ 2)
			if d < 6 then
				table.insert(slotProblems, string.format("slots %d and %d are %.1f apart", i, j, d))
			end
		end
	end
	table.insert(
		checks,
		check(
			"grid_slots",
			#slots > 0 and #slotProblems == 0,
			#slots,
			"on track, behind the line, 6 studs apart",
			list(slotProblems)
		)
	)
end

-- ---------------------------------------------------------------- lanes

local function laneChecks(course: any, rules: any?, checks: { Check })
	local paths = course.paths
	local rows = course.grid.height
	local broken = {}
	local lengths = {}
	local owner: { [string]: number } = {}
	for lane, cells in paths do
		lengths[lane] = #cells
		if #cells == 0 or cells[1][2] ~= 1 or cells[#cells][2] ~= rows then
			table.insert(broken, string.format("lane %d does not run from row 1 to row %d", lane, rows))
		end
		for i = 2, #cells do
			local a, b = cells[i - 1], cells[i]
			if math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) ~= 1 then
				table.insert(broken, string.format("lane %d breaks between cells %d and %d", lane, i - 1, i))
				break
			end
		end
		for _, c in cells do
			owner[c[1] .. ":" .. c[2]] = lane
		end
	end
	table.insert(checks, check("lane_connectivity", #broken == 0, #broken, 0, list(broken)))

	local touching = {}
	for lane, cells in paths do
		for _, c in cells do
			for dx = -1, 1 do
				for dy = -1, 1 do
					local other = owner[(c[1] + dx) .. ":" .. (c[2] + dy)]
					if other and other ~= lane then
						table.insert(
							touching,
							string.format("lane %d touches lane %d at %d,%d", lane, other, c[1], c[2])
						)
					end
				end
			end
		end
	end
	table.insert(checks, check("lanes_disjoint", #touching == 0, #touching, 0, list(touching)))

	local longest, shortest = 0, math.huge
	for _, length in lengths do
		longest, shortest = math.max(longest, length), math.min(shortest, length)
	end
	local spread = if longest > 0 then (longest - shortest) / longest else 1
	table.insert(
		checks,
		check(
			"lane_balance",
			spread <= rule(rules, "laneBalance"),
			round2(spread),
			rule(rules, "laneBalance"),
			string.format("lane lengths %d..%d cells", shortest, longest)
		)
	)

	local counts, cover = {}, {}
	local access = {}
	local range = course.params.range
	for _, slot in course.slots do
		counts[slot.lane] = (counts[slot.lane] or 0) + 1
		local covered = 0
		for _, c in paths[slot.lane] do
			if (c[1] - slot.cell[1]) ^ 2 + (c[2] - slot.cell[2]) ^ 2 <= range * range then
				covered += 1
			end
		end
		cover[slot.lane] = (cover[slot.lane] or 0) + covered
		local key = slot.cell[1] .. ":" .. slot.cell[2]
		if owner[key] then
			table.insert(
				access,
				string.format("lane %d slot %d sits on lane %d", slot.lane, slot.index, owner[key])
			)
		else
			local beside = false
			for _, o in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				if owner[(slot.cell[1] + o[1]) .. ":" .. (slot.cell[2] + o[2])] == slot.lane then
					beside = true
				end
			end
			if not beside then
				table.insert(
					access,
					string.format("lane %d slot %d is not beside its lane", slot.lane, slot.index)
				)
			end
		end
	end
	local most, fewest, coverMost, coverFewest = 0, math.huge, 0, math.huge
	for lane in paths do
		most, fewest = math.max(most, counts[lane] or 0), math.min(fewest, counts[lane] or 0)
		coverMost, coverFewest =
			math.max(coverMost, cover[lane] or 0), math.min(coverFewest, cover[lane] or 0)
	end
	local coverSpread = if coverMost > 0 then (coverMost - coverFewest) / coverMost else 0
	table.insert(
		checks,
		check(
			"slot_balance",
			most - fewest <= 1 and coverSpread <= rule(rules, "coverageBalance"),
			{ slots = most - fewest, coverage = round2(coverSpread) },
			{ slots = 1, coverage = rule(rules, "coverageBalance") },
			string.format("slots per lane %d..%d, covered cells %d..%d", fewest, most, coverFewest, coverMost)
		)
	)
	table.insert(checks, check("slot_access", #access == 0, #access, 0, list(access)))
	local minLane = course.profile.characterWidth * 1.6
	table.insert(
		checks,
		check(
			"lane_width",
			course.grid.cellSize >= minLane,
			course.grid.cellSize,
			round2(minLane),
			"lane cell size in studs"
		)
	)
end

-- ---------------------------------------------------------------- micro arena

local function arenaChecks(course: any, rules: any?, checks: { Check })
	local spawns = course.spawn.slots
	local arena = course.arena
	local distances = {}
	local sum = 0
	for _, s in spawns do
		local d = math.sqrt(s.pos.x ^ 2 + s.pos.z ^ 2)
		table.insert(distances, d)
		sum += d
	end
	local mean = sum / math.max(#spawns, 1)
	local lo, hi = math.huge, 0
	for _, d in distances do
		lo, hi = math.min(lo, d), math.max(hi, d)
	end
	local spread = if mean > 0 then (hi - lo) / mean else 1
	table.insert(
		checks,
		check(
			"spawn_fairness",
			spread <= rule(rules, "spawnSpread"),
			round2(spread),
			rule(rules, "spawnSpread"),
			string.format("spawn distance to the centre %.2f..%.2f", lo, hi)
		)
	)

	local pieces = course.segments
	local function view(s: any): { number }
		local out = {}
		for _, piece in pieces do
			table.insert(out, math.sqrt((piece.pos.x - s.pos.x) ^ 2 + (piece.pos.z - s.pos.z) ^ 2))
		end
		table.sort(out)
		return out
	end
	local reference = if #spawns > 0 then view(spawns[1]) else {}
	local worst, worstAt = 0, 0
	for i = 2, #spawns do
		local other = view(spawns[i])
		for k = 1, math.max(#other, #reference) do
			local diff = math.abs((other[k] or math.huge) - (reference[k] or math.huge))
			if diff ~= diff then
				diff = 0
			end
			if diff > worst then
				worst, worstAt = diff, i
			end
		end
	end
	table.insert(
		checks,
		check(
			"spawn_symmetry",
			worst <= rule(rules, "symmetryTolerance"),
			round2(worst),
			rule(rules, "symmetryTolerance"),
			if worstAt > 0
				then string.format("spawn %d sees cover and hazards differently from spawn 1", worstAt)
				else "every spawn sees the same layout"
		)
	)

	local closest = math.huge
	for i = 1, #spawns do
		for j = i + 1, #spawns do
			local a, b = spawns[i].pos, spawns[j].pos
			closest = math.min(closest, math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2))
		end
	end
	table.insert(
		checks,
		check(
			"spawn_separation",
			closest >= rule(rules, "minSpawnSeparation"),
			if closest == math.huge then "single" else round2(closest),
			rule(rules, "minSpawnSeparation")
		)
	)

	local edge = math.huge
	for _, s in spawns do
		local room = if arena.shape == "round"
			then arena.half - math.sqrt(s.pos.x ^ 2 + s.pos.z ^ 2)
			else arena.half - math.max(math.abs(s.pos.x), math.abs(s.pos.z))
		edge = math.min(edge, room)
	end
	local edgeLimit = (rules and rules.edgeClearance) or course.params.edgeClearance
	table.insert(checks, check("spawn_edge_clearance", edge >= edgeLimit - 1e-6, round2(edge), edgeLimit))

	local scale = course.profile.characterWidth / Measure.GUIDE.characterWidth
	local perPlayer = arena.area / #spawns
	local minArea, maxArea =
		rule(rules, "minAreaPerPlayer") * scale ^ 2, rule(rules, "maxAreaPerPlayer") * scale ^ 2
	table.insert(
		checks,
		check(
			"area_per_player",
			perPlayer >= minArea and perPlayer <= maxArea,
			round2(perPlayer),
			{ min = round2(minArea), max = round2(maxArea) }
		)
	)

	local crowded = {}
	local clear = rule(rules, "spawnClear") * scale
	for i, s in spawns do
		for k, piece in pieces do
			local box = { pos = piece.pos, size = piece.size, yaw = piece.yaw }
			if Course.footprintDistance(box :: any, s.pos.x, s.pos.z) < clear - 1e-6 then
				table.insert(crowded, string.format("spawn %d within %.1f of %s %d", i, clear, piece.role, k))
			end
		end
	end
	table.insert(checks, check("spawn_clear", #crowded == 0, #crowded, clear, list(crowded)))

	local overlapping = {}
	for i = 1, #pieces do
		for k = i + 1, #pieces do
			if Course.footprintsOverlap(pieces[i], pieces[k]) then
				table.insert(
					overlapping,
					string.format("%s %d overlaps %s %d", pieces[i].role, i, pieces[k].role, k)
				)
			end
		end
	end
	table.insert(checks, check("piece_overlap", #overlapping == 0, #overlapping, 0, list(overlapping)))

	local unsupported = {}
	if #course.tiles > 0 then
		for i, s in spawns do
			local on = false
			for _, tile in course.tiles do
				if
					Course.onPad({ pos = tile.pos, size = tile.size, yaw = 0 } :: any, s.pos.x, s.pos.z, 0)
				then
					on = true
					break
				end
			end
			if not on then
				table.insert(unsupported, "spawn " .. i)
			end
		end
	end
	table.insert(checks, check("spawn_on_floor", #unsupported == 0, #unsupported, 0, list(unsupported)))
end

-- ---------------------------------------------------------------- entry

local KIND_CHECKS = {
	linear = jumpChecks,
	tower = jumpChecks,
	race_loop = raceChecks,
	lanes = laneChecks,
	micro_arena = arenaChecks,
}

-- Validates a course/1 manifest; rules override CourseValidate.DEFAULTS (and margin, minTurnRadius,
-- maxGrade, maxBank, edgeClearance override the course's own params).
function CourseValidate.course(course: any, rules: any?): { Check }
	local checks: { Check } = {}
	if type(course) ~= "table" or course.schema ~= Course.SCHEMA or KIND_CHECKS[course.kind] == nil then
		table.insert(
			checks,
			check(
				"course_schema",
				false,
				type(course) == "table" and course.schema or type(course),
				Course.SCHEMA,
				"not a course/1 manifest of a known kind"
			)
		)
		return checks
	end
	local hash = Course.hash(course)
	table.insert(
		checks,
		check(
			"course_hash",
			hash == course.hash,
			course.hash,
			hash,
			"the manifest still hashes to its recorded hash"
		)
	)
	KIND_CHECKS[course.kind](course, rules, checks)
	return checks
end

return CourseValidate
