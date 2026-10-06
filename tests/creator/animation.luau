local Inspector = require("../../packages/Creator/AnimationInspector")
local count = 0
local function check(value, message)
	assert(value, message)
	count += 1
end
local function rejects(callback)
	return not pcall(callback)
end
local function probe(x, y, supportX)
	return {
		position = { x, y or 0, 0 },
		support_position = { supportX or 0, 0, 0 },
		surface_y = 0,
		planted = true,
		present = true,
	}
end
local options = { foot_slide_speed = 0.25 }
local copy = Inspector.validateThresholds(options)
options.foot_slide_speed = 1000
check(copy.foot_slide_speed == 0.25, "threshold ownership copied")
for _, invalid in
	{
		{ foot_slide_speed = 0 },
		{ contact_tolerance = -1 },
		{ marker_error = math.huge },
		{ blend_step = 0 / 0 },
		{ max_sample_gap = 2 },
		{ unknown = 1 },
	}
do
	check(
		rejects(function()
			Inspector.validateThresholds(invalid)
		end),
		"invalid threshold fails closed"
	)
end
local stationary = Inspector.contactSegment(probe(0), probe(0), 0.05)
check(
	stationary.usable and stationary.horizontal_speed == 0 and not stationary.slide_candidate,
	"stationary planted probe"
)
local sliding = Inspector.contactSegment(probe(0), probe(0.02), 0.05)
check(
	math.abs(sliding.horizontal_speed - 0.4) < 1e-9 and sliding.slide_candidate,
	"measured 0.4 units/sec slide candidate"
)
local platform = Inspector.contactSegment(probe(0, 0, 0), probe(1, 0, 1), 0.05)
check(
	platform.horizontal_speed == 0 and not platform.slide_candidate,
	"translating support removed from foot drift"
)
local unplanted = probe(1)
unplanted.planted = false
check(not Inspector.contactSegment(probe(0), unplanted, 0.05).usable, "unplanted interval excluded")
local absent = probe(1)
absent.present = false
check(not Inspector.contactSegment(probe(0), absent, 0.05).usable, "missing probe excluded")
local hover = Inspector.contactSegment(probe(0), probe(0, 0.2), 0.05)
check(hover.contact_candidate and hover.plane_error == 0.2, "declared planted hover measured")
local penetration = Inspector.contactSegment(probe(0), probe(0, -0.2), 0.05)
check(
	penetration.contact_candidate and penetration.plane_error == -0.2,
	"declared plane penetration measured"
)
check(not Inspector.contactSegment(probe(0), probe(1), 0.2).usable, "sparse sample gap excluded")
check(
	not Inspector.contactSegment(probe(0), probe(0.0125), 0.05).slide_candidate,
	"threshold equality does not exceed budget"
)
for _, dt in { 0, -1, math.huge, 0 / 0 } do
	check(
		rejects(function()
			Inspector.contactSegment(probe(0), probe(0), dt)
		end),
		"invalid contact time rejected"
	)
end
local invalid = probe(0)
check(
	rejects(function()
		Inspector.contactSegment(probe(0), probe(1), 1e-320)
	end),
	"subnormal interval cannot produce nonfinite derived speed"
)
invalid.position[1] = math.huge
check(
	rejects(function()
		Inspector.contactSegment(probe(0), invalid, 0.05)
	end),
	"nonfinite probe rejected"
)
-- Shared target check (GameKit/Env.check through Env.studio): a fake DataModel stands in for
-- the Roblox globals. A published game or place and a non-Studio session are refused; an
-- unpublished Studio server is accepted (the client-only restriction is gone), so the call
-- gets past the target check and fails on the missing options instead.
local function withGame(fakeGame, callback)
	local globals = getfenv(0)
	local previous = globals.game
	globals.game = fakeGame
	local ok, err = pcall(callback)
	globals.game = previous
	return ok, tostring(err)
end
local function fakeGame(studio, gameId, placeId, client)
	local runService = {
		IsStudio = function()
			return studio
		end,
		IsServer = function()
			return not client
		end,
		IsClient = function()
			return client
		end,
	}
	return {
		GameId = gameId,
		PlaceId = placeId,
		GetService = function(_, name)
			assert(name == "RunService", "unexpected service " .. tostring(name))
			return runService
		end,
	}
end
local function refusal(fake)
	local ok, err = withGame(fake, function()
		Inspector.new(nil)
	end)
	check(not ok, "constructor raised")
	return err
end
check(string.find(refusal(nil), "missing_place", 1, true) ~= nil, "no DataModel (Lune) is refused")
check(
	string.find(refusal(fakeGame(true, 4242, 0, false)), "published_game", 1, true) ~= nil,
	"published GameId refused"
)
check(
	string.find(refusal(fakeGame(true, 0, 4242, true)), "published_place", 1, true) ~= nil,
	"published PlaceId refused"
)
check(string.find(refusal(fakeGame(false, 0, 0, true)), "not_studio", 1, true) ~= nil, "live session refused")
local serverErr = refusal(fakeGame(true, 0, 0, false))
check(
	string.find(serverErr, "refused", 1, true) == nil
		and string.find(serverErr, "animation options required", 1, true) ~= nil,
	"unpublished Studio server passes the target check: " .. serverErr
)
print(
	"PASS "
		.. count
		.. " animation threshold/contact cases (target check included); no engine track playback acceptance"
)
