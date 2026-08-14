--!strict

--[=[
	@class Serialize

	Validates and deep-copies data on its way into a stored record: ticket
	metadata and the `finalize` hook's return value.

	Copying means a caller mutating their table afterwards cannot alter a
	committed match.

	Rejected, because none of it survives MemoryStore's JSON round trip
	unchanged: functions, userdata such as Instances and Vector3, threads,
	cycles, NaN and infinity, keys that are not strings or numbers, tables mixing
	array and dictionary keys, and nesting deeper than
	`Defaults.MAX_DATA_DEPTH` (8).

	Written by hand rather than using `HttpService:JSONEncode` so it behaves the
	same under Lune as in Studio, names the offending field, and can stop as soon
	as a value exceeds its budget.
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
	Validates `value` and returns a deep copy of it. `nil` is accepted and
	becomes an empty table.

	@param budget -- Maximum estimated encoded size, in bytes.
	@return boolean -- Whether the value is storable.
	@return any -- The copy, when valid.
	@return string? -- The offending field path and reason, when not.
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
	The estimated encoded size of an already-validated value, used to decide
	whether an envelope fits inside a message payload.

	@within Serialize
]=]
function Serialize.size(value: any): number
	local walk: Walk = { budget = math.huge, used = 0, seen = {}, problem = nil }
	walkValue(walk, value, "", 1)
	return walk.used
end

return table.freeze(Serialize)
