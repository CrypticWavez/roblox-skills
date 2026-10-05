--!strict
-- Headless Luau test runner (Lune). Usage: lune run tests/run.luau [filter]
local fs = require("@lune/fs")
local process = require("@lune/process")

local filter = process.args[1]
local passed, failed = 0, 0
local failures = {}

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local t = {}
function t.ok(value: any, message: string?)
	if not value then
		error(message or "expected truthy value", 2)
	end
end
function t.eq(actual: any, expected: any, message: string?)
	if not deepEqual(actual, expected) then
		error(
			string.format("%s: expected %s, got %s", message or "eq", tostring(expected), tostring(actual)),
			2
		)
	end
end
function t.near(actual: number, expected: number, tol: number?, message: string?)
	if math.abs(actual - expected) > (tol or 1e-6) then
		error(string.format("%s: expected %.6f, got %.6f", message or "near", expected, actual), 2)
	end
end
function t.throws(fn: () -> (), message: string?)
	if pcall(fn) then
		error(message or "expected error", 2)
	end
end

local files = {}
for _, name in fs.readDir("tests") do
	if string.match(name, "%.spec%.luau$") and (filter == nil or string.find(name, filter, 1, true)) then
		table.insert(files, name)
	end
end
table.sort(files)

for _, file in files do
	local suite = (require :: any)("./" .. string.gsub(file, "%.luau$", ""))
	for _, case in suite do
		local ok, err = pcall(case.fn, t)
		if ok then
			passed += 1
		else
			failed += 1
			table.insert(failures, string.format("%s > %s\n    %s", file, case.name, tostring(err)))
		end
	end
end

for _, f in failures do
	print("FAIL " .. f)
end
print(string.format("%d passed, %d failed (%d files)", passed, failed, #files))
process.exit(if failed == 0 then 0 else 1)
