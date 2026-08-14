--!strict

--[=[
	@class Serialize

	Validates and copies consumer data on its way into a stored record.

	Deliberately hand-written rather than `HttpService:JSONEncode`: it must
	behave identically under Lune and in Studio, it must report *which* field is
	the problem, and it must be able to stop early once a value is obviously
	over budget. It also copies, so a consumer mutating their table after
	returning it cannot alter a match that has already been committed.

	Rejected: functions, userdata (Instances, Vector3, Color3, ...), threads,
	cycles, NaN and infinity, non-string/number keys, tables mixing array and
	hash keys, and anything nested deeper than `Defaults.MAX_DATA_DEPTH`. Every
	one of those either fails to survive MemoryStore's JSON round trip or comes
	back a different shape than it went in.
]=]

local Defaults = require(script.Parent.Parent.Defaults)

local Serialize = {}

-- Rough JSON byte cost. Deliberately an over-estimate: better to reject a
-- payload slightly under the limit than to write one slightly over it.
local OVERHEAD_PER_ENTRY = 4
local NUMBER_BYTES = 8
local BOOLEAN_BYTES = 5

type Walk = {
	budget: number,
	used: number,
	seen: { [any]: boolean },
	problem: string?,
}

local function fail(walk: Walk, path: string, reason: string): nil
	if walk.problem == nil then
		walk.problem = `{if path == "" then "value" else path} {reason}`
	end
	return nil
end

local function walkValue(walk: Walk, value: any, path: string, depth: number): any
	if walk.problem ~= nil then
		return nil
	end

	local kind = type(value)

	if kind == "string" then
		walk.used += #value + 2
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return fail(walk, path, "must be a finite number")
		end
		walk.used += NUMBER_BYTES
	elseif kind == "boolean" then
		walk.used += BOOLEAN_BYTES
	elseif kind ~= "table" then
		return fail(walk, path, `must be a string, number, boolean or table (got {typeof(value)})`)
	end

	if kind ~= "table" then
		if walk.used > walk.budget then
			return fail(walk, path, "exceeds the size budget")
		end
		return value
	end

	if depth > Defaults.MAX_DATA_DEPTH then
		return fail(walk, path, `is nested deeper than {Defaults.MAX_DATA_DEPTH} levels`)
	end
	if walk.seen[value] then
		return fail(walk, path, "contains a cycle")
	end
	walk.seen[value] = true

	local arrayCount = #value
	local totalCount = 0
	for _ in value do
		totalCount += 1
	end
	if arrayCount > 0 and totalCount ~= arrayCount then
		walk.seen[value] = nil
		return fail(walk, path, "mixes array and dictionary keys, which will not round-trip")
	end

	local copy: any = if arrayCount > 0 then table.create(arrayCount) else {}
	for key, entry in value do
		local keyKind = type(key)
		if keyKind ~= "string" and keyKind ~= "number" then
			walk.seen[value] = nil
			return fail(walk, path, `has a {typeof(key)} key, which will not round-trip`)
		end

		walk.used += OVERHEAD_PER_ENTRY + (if keyKind == "string" then #key else NUMBER_BYTES)
		if walk.used > walk.budget then
			walk.seen[value] = nil
			return fail(walk, path, "exceeds the size budget")
		end

		local childPath = if path == "" then tostring(key) else `{path}.{key}`
		local child = walkValue(walk, entry, childPath, depth + 1)
		if walk.problem ~= nil then
			walk.seen[value] = nil
			return nil
		end
		copy[key] = child
	end

	walk.seen[value] = nil
	return copy
end

--[=[
	Validates `value` and returns a deep copy of it.

	@param budget -- Maximum estimated encoded size, in bytes.
	@return boolean -- Whether the value is storable.
	@return any -- The copy, when valid.
	@return string? -- What was wrong and where, when not.
	@within Serialize
]=]
function Serialize.validate(value: any, budget: number): (boolean, any, string?)
	if value == nil then
		return true, {}, nil
	end
	if type(value) ~= "table" then
		return false, nil, "finalize must return a table (or nothing)"
	end

	local walk: Walk = { budget = budget, used = 0, seen = {}, problem = nil }
	local copy = walkValue(walk, value, "", 1)
	if walk.problem ~= nil then
		return false, nil, walk.problem
	end
	return true, copy, nil
end

--[=[
	The estimated encoded size of an already-validated value. Used to decide
	whether a match envelope fits inside a broadcast payload.

	@within Serialize
]=]
function Serialize.size(value: any): number
	local walk: Walk = { budget = math.huge, used = 0, seen = {}, problem = nil }
	walkValue(walk, value, "", 1)
	return walk.used
end

return table.freeze(Serialize)
