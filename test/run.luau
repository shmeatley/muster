--!nocheck

--[[
	Runs the whole suite headlessly.

		lune run test/run

	Exits non-zero if anything failed, so CI fails on a regression.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Harness = require("./lib/harness")

local files = {}
for _, entry in fs.readDir("test") do
	if string.match(entry, "%.test%.luau$") then
		table.insert(files, entry)
	end
end
table.sort(files)

if #files == 0 then
	print("no test files found")
	process.exit(1)
end

local crashed = 0
for _, file in files do
	local name = string.gsub(file, "%.test%.luau$", "")
	local suite = require(`./{name}.test`)
	local ok, err = pcall(suite)
	if not ok then
		crashed += 1
		print(`  CRASH  {name}`)
		print(`         {tostring(err)}`)
	end
end

local passed, failed, failures = Harness.results()

print("")
for _, failure in failures do
	print(`  FAIL  {failure}`)
end

print("")
print(`{passed} passed, {failed} failed, {crashed} crashed`)

if failed > 0 or crashed > 0 then
	process.exit(1)
end
