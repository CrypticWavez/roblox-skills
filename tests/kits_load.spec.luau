--!strict
-- Kit load and boundary checks (contract: docs/runtime-kits.md). For every .luau module under
-- packages/GameKit, UIKit, AVKit, Feel and Cinematics:
--   * line 1 is --!strict and the header comment block holds one "-- @tier T0..T4" line; a T3
--     module also names "-- probe: <name>" with an owner prefix, registered in a
--     fixtures/kits/<side>/*_probes.luau registry or as tests/engine/<name>.luau;
--   * every require is a string require to the same kit, another kit or a leaf (ProcGen/Rng,
--     Grid, Graph, SceneKit/Vec, Lighting) and its target exists; dynamic requires, aliases
--     (@lune, @self, ...) and Runtime/Creator/Pipeline requires fail;
--   * cores (not *Roblox.luau) never call GetService, and load in Lune without error;
--   * *Roblox.luau adapters are checked for the header and requires only (never loaded here);
--   * no init.luau (kits are flat files; a facade is <Kit>.luau).
-- Empty kits pass. The leaves themselves must stay require-free. The checker functions are
-- also fed broken sources, so a checker that accepts them fails here.
local fs = require("@lune/fs")

local ROOT = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."

local KITS = { "GameKit", "UIKit", "AVKit", "Feel", "Cinematics" }
local LEAVES = {
	"packages/ProcGen/Rng",
	"packages/ProcGen/Grid",
	"packages/ProcGen/Graph",
	"packages/SceneKit/Vec",
	"packages/SceneKit/Lighting",
}
-- Probe-name prefixes per owner (docs/runtime-kits.md "Probe contract").
local PROBE_PREFIXES = {
	"foundation_", -- Stage 0
	"platform_", -- G1
	"authority_", -- G2
	"action_", -- G2
	"economy_", -- G3
	"ui_", -- G4
	"cin_", -- G4
	"inputmap_", -- G4
	"lookdev_", -- G5
	"av_", -- G5
	"feel_", -- G5
	"worldcycle_", -- G5
	"import_", -- G6
	"level_", -- G7
	"lvl_", -- G7
	"kitsmoke_", -- G9b
	"perf_", -- G9b
}

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

-- ---------------------------------------------------------------- pure checker

-- Source with comments blanked and string contents replaced by "x", same length and line
-- breaks, so positions found in it slice the original source.
local function mask(source: string): string
	local out: { string } = table.create(#source)
	local length = #source
	local index = 1
	local function blank(from: number, to: number, fill: string)
		for position = from, to do
			local char = string.sub(source, position, position)
			out[position] = if char == "\n" then "\n" else fill
		end
	end
	while index <= length do
		local char = string.sub(source, index, index)
		if char == "-" and string.sub(source, index, index + 1) == "--" then
			local level = string.match(source, "^%[(=*)%[", index + 2)
			local stop
			if level then
				local _, close = string.find(source, "]" .. level .. "]", index, true)
				stop = close or length
			else
				stop = (string.find(source, "\n", index, true) or (length + 1)) - 1
			end
			blank(index, stop, " ")
			index = stop + 1
		elseif char == "[" and string.match(source, "^%[=*%[", index) then
			local level = string.match(source, "^%[(=*)%[", index) :: string
			local open = #level + 2
			local _, close = string.find(source, "]" .. level .. "]", index + open, true)
			local stop = close or length
			blank(index, index + open - 1, "[")
			blank(index + open, stop - open, "x")
			blank(stop - open + 1, stop, "]")
			index = stop + 1
		elseif char == '"' or char == "'" or char == "`" then
			out[index] = char
			local position = index + 1
			while position <= length do
				local c = string.sub(source, position, position)
				if c == "\\" then
					out[position] = "x"
					if position + 1 <= length then
						out[position + 1] = "x"
					end
					position += 2
				elseif c == char then
					break
				else
					out[position] = if c == "\n" then "\n" else "x"
					position += 1
				end
			end
			if position <= length then
				out[position] = char
			end
			index = position + 1
		else
			out[index] = char
			index += 1
		end
	end
	return table.concat(out)
end

export type Require = { target: string?, line: number }

-- Every require call in source: target is the string literal, nil for a dynamic require.
local function findRequires(source: string): { Require }
	local masked = mask(source)
	local found: { Require } = {}
	local init = 1
	while true do
		local start, finish = string.find(masked, "%f[%w_]require%f[^%w_]", init)
		if not start then
			break
		end
		init = finish + 1
		local before = string.match(string.sub(masked, 1, start - 1), "(%S)%s*$")
		if before == "." or before == ":" then
			continue -- a field or method that happens to be called require
		end
		local line = select(2, string.gsub(string.sub(source, 1, start), "\n", "")) + 1
		local rest = string.sub(masked, finish + 1)
		local quoteAt = string.match(rest, "^%s*%(%s*()[\"']")
			or string.match(rest, "^%s*::[^%)]*%)%s*%(%s*()[\"']")
			or string.match(rest, "^%s*()[\"']")
		local target: string? = nil
		if quoteAt then
			local open = finish + (quoteAt :: number)
			local quote = string.sub(masked, open, open)
			local close = string.find(masked, quote, open + 1, true)
			if close then
				local after = string.sub(masked, close + 1)
				local parenthesised = string.match(rest, "^%s*::") or string.match(rest, "^%s*%(")
				if not parenthesised or string.match(after, "^%s*%)") then
					target = string.sub(source, open + 1, close - 1)
				end
			end
		end
		table.insert(found, { target = target, line = line })
	end
	return found
end

-- Normalised repo-relative path for a ./ or ../ target required from file rel.
local function resolve(rel: string, target: string): string?
	if string.sub(target, 1, 2) ~= "./" and string.sub(target, 1, 3) ~= "../" then
		return nil
	end
	local parts = string.split(rel, "/")
	table.remove(parts) -- the file name
	for _, part in string.split(target, "/") do
		if part == ".." then
			if #parts == 0 then
				return nil
			end
			table.remove(parts)
		elseif part ~= "." and part ~= "" then
			table.insert(parts, part)
		end
	end
	return table.concat(parts, "/")
end

local function isAdapter(rel: string): boolean
	return string.match(rel, "Roblox%.luau$") ~= nil
end

local function allowedTarget(path: string): boolean
	if table.find(LEAVES, path) then
		return true
	end
	for _, kit in KITS do
		if string.sub(path, 1, #kit + 10) == "packages/" .. kit .. "/" then
			return true
		end
	end
	return false
end

export type Header = { strict: boolean, tier: string?, probe: string?, problems: { string } }

local function parseHeader(source: string): Header
	local lines = string.split(source, "\n")
	local header: Header = { strict = lines[1] == "--!strict", tier = nil, probe = nil, problems = {} }
	local tiers = 0
	for index = 2, #lines do
		local line = string.gsub(lines[index], "\r$", "")
		if string.sub(line, 1, 2) ~= "--" then
			break
		end
		local tier = string.match(line, "^%-%- @tier (T%d)%s*$")
		if tier then
			tiers += 1
			header.tier = tier
		elseif string.match(line, "^%-%-%s*@tier") then
			table.insert(header.problems, "malformed tier line: " .. line)
		end
		local probe = string.match(line, "^%-%- probe: (%S+)%s*$")
		if probe then
			header.probe = probe
		end
	end
	if tiers > 1 then
		table.insert(header.problems, "more than one @tier line")
	end
	return header
end

export type Context = {
	exists: (path: string) -> boolean, -- repo-relative path without extension
	registered: (probe: string) -> boolean,
}

-- Problems with one kit module (rel is repo-relative, e.g. packages/GameKit/Signal.luau).
local function inspectModule(rel: string, source: string, ctx: Context): { string }
	local problems = {}
	if string.match(rel, "/init%.luau$") then
		table.insert(problems, "init.luau is not used in kits (flat module files; a facade is <Kit>.luau)")
	end
	local header = parseHeader(source)
	if not header.strict then
		table.insert(problems, "line 1 must be --!strict")
	end
	for _, problem in header.problems do
		table.insert(problems, problem)
	end
	local tier = header.tier
	if tier == nil then
		table.insert(problems, "header needs a '-- @tier T0..T4' line")
	elseif not string.match(tier, "^T[0-4]$") then
		table.insert(problems, "tier " .. tier .. " is not T0..T4")
	end
	if tier == "T3" and header.probe == nil then
		table.insert(problems, "a T3 module names its probe: '-- probe: <name>'")
	end
	local probe = header.probe
	if probe then
		local prefixed = false
		for _, prefix in PROBE_PREFIXES do
			if string.sub(probe, 1, #prefix) == prefix then
				prefixed = true
			end
		end
		if not string.match(probe, "^[a-z][a-z0-9_]+$") or not prefixed then
			table.insert(problems, "probe " .. probe .. " needs a lower_snake name with an owner prefix")
		elseif not ctx.registered(probe) then
			table.insert(
				problems,
				"probe "
					.. probe
					.. " is not registered (fixtures/kits/<side>/*_probes.luau or tests/engine/<probe>.luau)"
			)
		end
	end
	for _, item in findRequires(source) do
		local where = string.format("line %d: ", item.line)
		local target = item.target
		if target == nil then
			table.insert(problems, where .. "dynamic or non-string require")
			continue
		end
		if string.sub(target, 1, 1) == "@" then
			table.insert(problems, where .. "require alias " .. target .. " is not allowed in kits")
			continue
		end
		local path = resolve(rel, target)
		if path == nil then
			table.insert(problems, where .. "require " .. target .. " must start with ./ or ../")
		elseif not allowedTarget(path) then
			table.insert(
				problems,
				where
					.. "require "
					.. target
					.. " leaves the allowlist (kits and the ProcGen/SceneKit leaves)"
			)
		elseif not ctx.exists(path) then
			table.insert(problems, where .. "require " .. target .. " has no module at " .. path .. ".luau")
		end
	end
	if not isAdapter(rel) and string.find(mask(source), "GetService", 1, true) then
		table.insert(problems, "cores never call GetService; move it into a <Name>Roblox.luau adapter")
	end
	return problems
end

-- ---------------------------------------------------------------- repository walk

local function walk(dir: string, prefix: string, out: { string })
	if not fs.isDir(dir) then
		return
	end
	local names = fs.readDir(dir)
	table.sort(names)
	for _, name in names do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path, prefix .. name .. "/", out)
		elseif string.match(name, "%.luau$") then
			table.insert(out, prefix .. name)
		end
	end
end

local function exists(path: string): boolean
	return fs.isFile(ROOT .. "/" .. path .. ".luau") or fs.isFile(ROOT .. "/" .. path .. "/init.luau")
end

local registryCache: { string }? = nil
local function registrySources(): { string }
	if registryCache then
		return registryCache
	end
	local sources = {}
	for _, side in { "server", "client", "shared" } do
		local files = {}
		walk(ROOT .. "/fixtures/kits/" .. side, "", files)
		for _, file in files do
			if string.match(file, "_probes%.luau$") then
				table.insert(sources, fs.readFile(ROOT .. "/fixtures/kits/" .. side .. "/" .. file))
			end
		end
	end
	registryCache = sources
	return sources
end

local function registered(probe: string): boolean
	if fs.isFile(ROOT .. "/tests/engine/" .. probe .. ".luau") then
		return true
	end
	for _, source in registrySources() do
		if string.find(source, "%f[%w_]" .. probe .. "%f[^%w_]") then
			return true
		end
	end
	return false
end

local REPO: Context = { exists = exists, registered = registered }

for _, kit in KITS do
	local modules = {}
	walk(ROOT .. "/packages/" .. kit, "", modules)
	test(kit .. ": package folder exists (" .. #modules .. " modules)", function(t)
		t.ok(fs.isDir(ROOT .. "/packages/" .. kit), "packages/" .. kit .. " is missing")
		t.ok(
			fs.isFile(ROOT .. "/packages/" .. kit .. "/README.md"),
			"packages/" .. kit .. "/README.md is missing"
		)
	end)
	for _, file in modules do
		local rel = "packages/" .. kit .. "/" .. file
		test(
			rel .. (if isAdapter(rel) then " (adapter): header and requires" else ": header, requires, loads"),
			function(t)
				local problems = inspectModule(rel, fs.readFile(ROOT .. "/" .. rel), REPO)
				t.ok(#problems == 0, table.concat(problems, "; "))
				if not isAdapter(rel) then
					local ok, result = pcall(require :: any, "../" .. string.gsub(rel, "%.luau$", ""))
					t.ok(ok, "load failed: " .. tostring(result))
					t.ok(
						type(result) == "table" or type(result) == "function",
						"module returns " .. type(result)
					)
				end
			end
		)
	end
end

test("leaves exist and stay require-free", function(t)
	for _, leaf in LEAVES do
		t.ok(exists(leaf), leaf .. ".luau is missing")
		local requires = findRequires(fs.readFile(ROOT .. "/" .. leaf .. ".luau"))
		t.eq(#requires, 0, leaf .. " has requires")
	end
end)

-- ---------------------------------------------------------------- checker self-test

local GOOD_HEADER = "--!strict\n-- @tier T0\n-- A module.\n"
local SELF: Context = {
	exists = function(path: string): boolean
		return path ~= "packages/GameKit/Missing"
	end,
	registered = function(probe: string): boolean
		return probe == "platform_known"
	end,
}

local function problemsFor(rel: string, source: string): { string }
	return inspectModule(rel, source, SELF)
end

local function mentions(problems: { string }, needle: string): boolean
	for _, problem in problems do
		if string.find(problem, needle, 1, true) then
			return true
		end
	end
	return false
end

test("checker accepts allowed requires and ignores comments, strings and fields", function(t)
	local source = GOOD_HEADER
		.. 'local A = require("./Signal")\n'
		.. "local B = require('../UIKit/Tokens')\n"
		.. 'local C = require("../ProcGen/Rng")\n'
		.. 'local D = (require :: any)("../SceneKit/Lighting")\n'
		.. '-- local E = require("../Runtime/NativeUI")\n'
		.. "--[[ require(script.Parent) ]]\n"
		.. 'local text = "call require(x) later"\n'
		.. "local F = loader.require(name)\n"
		.. 'local G = require "./Check"\n'
	t.eq(problemsFor("packages/GameKit/Thing.luau", source), {})
	t.eq(#findRequires(source), 5)
end)

test("checker rejects requires outside the allowlist", function(t)
	local function bad(line: string, needle: string)
		local problems = problemsFor("packages/UIKit/Button.luau", GOOD_HEADER .. line .. "\n")
		t.ok(mentions(problems, needle), line .. " -> " .. table.concat(problems, "; "))
	end
	bad('local X = require("../Runtime/NativeUI")', "leaves the allowlist")
	bad('local X = require("../Creator/UI")', "leaves the allowlist")
	bad('local X = require("../ProcGen/Dungeon")', "leaves the allowlist")
	bad('local X = require("../../tests/fakes/FakeEnv")', "leaves the allowlist")
	bad("local X = require(script.Parent.Tokens)", "dynamic or non-string require")
	bad("local X = require(path)", "dynamic or non-string require")
	bad('local X = require("@lune/roblox")', "require alias @lune/roblox")
	bad('local X = require("@self/Child")', "require alias @self/Child")
	bad('local X = require("Tokens")', "must start with ./ or ../")
	bad('local X = require("../GameKit/Missing")', "has no module at packages/GameKit/Missing.luau")
end)

test("checker rejects bad headers, probes, GetService in cores and init.luau", function(t)
	t.ok(mentions(problemsFor("packages/Feel/A.luau", "-- @tier T0\n"), "line 1 must be --!strict"))
	t.ok(mentions(problemsFor("packages/Feel/A.luau", "--!strict\n-- no tier\n"), "needs a '-- @tier"))
	t.ok(mentions(problemsFor("packages/Feel/A.luau", "--!strict\n-- @tier T7\n"), "tier T7 is not T0..T4"))
	t.ok(mentions(problemsFor("packages/Feel/A.luau", "--!strict\n-- @tier: T1\n"), "malformed tier line"))
	t.ok(
		mentions(
			problemsFor("packages/Feel/A.luau", "--!strict\n-- @tier T0\n-- @tier T1\n"),
			"more than one"
		)
	)
	t.ok(mentions(problemsFor("packages/Feel/ARoblox.luau", "--!strict\n-- @tier T3\n"), "names its probe"))
	t.ok(
		mentions(
			problemsFor("packages/Feel/ARoblox.luau", "--!strict\n-- @tier T3\n-- probe: mystery_check\n"),
			"owner prefix"
		)
	)
	t.ok(
		mentions(
			problemsFor("packages/Feel/ARoblox.luau", "--!strict\n-- @tier T3\n-- probe: platform_unknown\n"),
			"is not registered"
		)
	)
	t.eq(
		problemsFor(
			"packages/GameKit/RemoteGuardRoblox.luau",
			"--!strict\n-- @tier T3\n-- probe: platform_known\nlocal s = game:GetService('Players')\n"
		),
		{}
	)
	t.ok(
		mentions(
			problemsFor("packages/GameKit/Core.luau", GOOD_HEADER .. "local s = game:GetService('Players')\n"),
			"cores never call GetService"
		)
	)
	t.eq(problemsFor("packages/GameKit/Core.luau", GOOD_HEADER .. "-- game:GetService is for adapters\n"), {})
	t.ok(mentions(problemsFor("packages/UIKit/Components/init.luau", GOOD_HEADER), "init.luau"))
end)

test("checker masks long strings and escapes without losing positions", function(t)
	local source = 'local a = [[\nrequire("x")\n]]\nlocal b = "q\\"require(y)"\nlocal c = require("./Z")\n'
	local masked = mask(source)
	t.eq(#masked, #source)
	local found = findRequires(source)
	t.eq(#found, 1)
	t.eq(found[1].target, "./Z")
	t.eq(found[1].line, 5)
end)

return cases
