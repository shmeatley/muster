--!strict

-- Declarative, immutable rules for new-match formation. Quick Play deliberately
-- does not call this module. No clocks, network calls or user callbacks here.
local Serialize = require(script.Parent.Serialize)
local Hash = require(script.Parent.Parent.Hash)

local Rules = {}
Rules.MAX_ATTRIBUTE_BYTES = 4096 -- total across one ticket's members
Rules.MAX_MATCH_ATTRIBUTE_BYTES = 8192
Rules.BEAM_WIDTH = 8

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function nonnegative(value: any): boolean
	return finite(value) and value >= 0
end

local function canonical(value: any): string
	if type(value) ~= "table" then
		return `{type(value)}:{tostring(value)}`
	end
	local keys = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, key in keys do
		local k, v = canonical(key), canonical(value[key])
		table.insert(parts, `{#k}:{k}{#v}:{v}`)
	end
	return table.concat(parts, "|")
end

local function freeze(value: any): any
	if type(value) == "table" then
		for _, child in value do
			freeze(child)
		end
		table.freeze(value)
	end
	return value
end

function Rules.resolve(raw: any): (any, string?)
	if raw == nil then
		return nil, nil
	end
	local sane, copy, why = Serialize.validate(raw, 16384)
	if not sane then
		return nil, `Muster: rules {why}`
	end
	local count = 0
	for name, rule in copy do
		count += 1
		if type(name) ~= "string" or #name == 0 or #name > 32 or type(rule) ~= "table" then
			return nil, "Muster: rules must map attribute names (1-32 bytes) to rule tables"
		end
		local allowed = {
			type = true,
			compare = true,
			value = true,
			limit = true,
			distances = true,
			relaxAfter = true,
			prefer = true,
			weight = true,
			mode = true,
			scope = true,
			acceptance = true,
		}
		for key in rule do
			if not allowed[key] then
				return nil, `Muster: unknown rules.{name} field {tostring(key)}`
			end
		end
		if rule.type ~= "number" and rule.type ~= "string" and rule.type ~= "boolean" then
			return nil, `Muster: rules.{name}.type must be number, string or boolean`
		end
		if rule.scope ~= nil and rule.scope ~= "allMembers" then
			return nil, `Muster: rules.{name}.scope must be allMembers`
		end
		if rule.acceptance ~= nil and rule.acceptance ~= "mutual" then
			return nil, `Muster: rules.{name}.acceptance must be mutual`
		end
		if rule.mode ~= nil and rule.mode ~= "constraint" and rule.mode ~= "preference" then
			return nil, `Muster: rules.{name}.mode must be constraint or preference`
		end
		if rule.weight ~= nil and not nonnegative(rule.weight) then
			return nil, `Muster: rules.{name}.weight must be finite and nonnegative`
		end
		if rule.prefer ~= nil and rule.prefer ~= "closer" and rule.prefer ~= "equal" then
			return nil, `Muster: rules.{name}.prefer must be closer or equal`
		end
		if rule.compare == "required" then
			if type(rule.value) ~= rule.type or (rule.type == "number" and not finite(rule.value)) then
				return nil, `Muster: rules.{name}.value must have the declared type`
			end
			if rule.relaxAfter ~= nil or rule.mode == "preference" then
				return nil, `Muster: required rules cannot relax or be preferences`
			end
		elseif rule.compare == "equal" then
			if rule.relaxAfter ~= nil and not nonnegative(rule.relaxAfter) then
				return nil, `Muster: rules.{name}.relaxAfter must be finite and nonnegative`
			end
		elseif rule.compare == "distance" then
			if rule.type == "boolean" then
				return nil, `Muster: rules.{name} cannot measure boolean distance`
			end
			if rule.type == "string" then
				if type(rule.distances) ~= "table" or next(rule.distances) == nil then
					return nil, `Muster: rules.{name}.distances must define region/category costs`
				end
				for from, row in rule.distances do
					if type(from) ~= "string" or type(row) ~= "table" then
						return nil, `Muster: rules.{name}.distances must map strings to cost tables`
					end
					for to, cost in row do
						local reverse = rule.distances[to]
						if
							type(to) ~= "string"
							or not nonnegative(cost)
							or type(reverse) ~= "table"
							or reverse[from] ~= cost
							or (from == to and cost ~= 0)
						then
							return nil,
								`Muster: rules.{name}.distances must be symmetric finite nonnegative costs (diagonal zero)`
						end
					end
				end
			elseif rule.distances ~= nil then
				return nil, `Muster: rules.{name}.distances is only for strings`
			end
			if rule.limit == nil then
				rule.limit = 0
			end
			if type(rule.limit) == "table" then
				local previousTime, previousValue = -1, -1
				if #rule.limit == 0 or #rule.limit > 32 then
					return nil, `Muster: rules.{name}.limit needs 1-32 schedule steps`
				end
				for index, step in rule.limit do
					if
						type(index) ~= "number"
						or index % 1 ~= 0
						or index < 1
						or index > #rule.limit
						or type(step) ~= "table"
						or not nonnegative(step.after)
						or not nonnegative(step.value)
						or step.after <= previousTime
						or step.value < previousValue
						or (index == 1 and step.after ~= 0)
					then
						return nil,
							`Muster: rules.{name}.limit must start at zero with increasing times and nondecreasing finite limits`
					end
					previousTime, previousValue = step.after, step.value
				end
			elseif not nonnegative(rule.limit) then
				return nil, `Muster: rules.{name}.limit must be a finite nonnegative number or schedule`
			end
			if rule.relaxAfter ~= nil then
				return nil, `Muster: use limit schedules for distance rules`
			end
		else
			return nil, `Muster: rules.{name}.compare must be distance, equal or required`
		end
		if rule.compare ~= "distance" and (rule.limit ~= nil or rule.distances ~= nil) then
			return nil, `Muster: only distance rules accept limit or distances`
		end
		if rule.compare ~= "required" and rule.value ~= nil then
			return nil, `Muster: only required rules accept value`
		end
		if rule.prefer ~= nil then
			local expected: string = if rule.compare == "distance" then "closer" else "equal"
			if rule.compare == "required" or rule.prefer ~= expected then
				return nil, `Muster: prefer must be closer for distance rules or equal for equality rules`
			end
		end
	end
	if count == 0 or count > 16 then
		return nil, "Muster: rules must contain 1-16 attributes"
	end
	return freeze(copy), nil
end

function Rules.key(rules: any): string
	return `r1-{Hash.string(canonical(rules))}`
end

function Rules.attributes(rules: any, raw: any, quickPlay: boolean?): (any, string?)
	if type(raw) ~= "table" then
		return nil, "attributes must be a table containing every configured attribute"
	end
	local copy = {}
	for name, rule in rules do
		local value = raw[name]
		if type(value) ~= rule.type or (rule.type == "number" and not finite(value)) then
			return nil, `attribute {name} must be a finite {rule.type}`
		end
		if not quickPlay and rule.compare == "required" and value ~= rule.value then
			return nil, `attribute {name} does not meet its required value`
		end
		if rule.type == "string" and (#value > 128 or (rule.distances and rule.distances[value] == nil)) then
			return nil, `attribute {name} is too long or has an unknown category`
		end
		copy[name] = value
	end
	for name in raw do
		if rules[name] == nil then
			return nil, `unknown attribute {tostring(name)}`
		end
	end
	return table.freeze(copy), nil
end

local function limitAt(rule: any, waitSeconds: number): number
	if type(rule.limit) == "number" then
		return rule.limit
	end
	local result = 0
	for _, step in rule.limit do
		if waitSeconds < step.after then
			break
		end
		result = step.value
	end
	return result
end

local function distance(rule: any, a: any, b: any): number
	if a == b then
		return 0
	end
	if rule.compare ~= "distance" then
		return 1
	end
	if rule.type == "number" then
		return math.abs(a - b)
	end
	return rule.distances[a][b] or math.huge -- absent edge is forbidden
end

function Rules.compatible(rules: any, a: any, b: any, now: number): boolean
	if
		type(a.attributes) ~= "table"
		or type(b.attributes) ~= "table"
		or #a.attributes ~= a.size
		or #b.attributes ~= b.size
	then
		return false
	end
	local waitA, waitB = math.max(0, now - a.queuedAt), math.max(0, now - b.queuedAt)
	for _, left in a.attributes do
		for _, right in b.attributes do
			if type(left) ~= "table" or type(right) ~= "table" then
				return false
			end
			for name, rule in rules do
				local x, y = left[name], right[name]
				if type(x) ~= rule.type or type(y) ~= rule.type then
					return false
				end
				if rule.type == "number" and (not finite(x) or not finite(y)) then
					return false
				end
				if rule.distances and (rule.distances[x] == nil or rule.distances[y] == nil) then
					return false
				end
				if rule.compare == "required" then
					if x ~= rule.value or y ~= rule.value then
						return false
					end
				elseif rule.mode ~= "preference" then
					if rule.compare == "equal" then
						if x ~= y and (rule.relaxAfter == nil or math.min(waitA, waitB) < rule.relaxAfter) then
							return false
						end
					elseif distance(rule, x, y) > math.min(limitAt(rule, waitA), limitAt(rule, waitB)) then
						return false
					end
				end
			end
		end
	end
	return true
end

function Rules.score(rules: any, candidates: any, indexes: { number }): (number, number)
	local members, queued = {}, 0
	for _, index in indexes do
		local candidate = candidates[index]
		queued += candidate.queuedAt
		for _, attributes in candidate.attributes do
			table.insert(members, attributes)
		end
	end
	local penalty = 0
	-- Sorted field order keeps floating-point sums deterministic across servers.
	local names = {}
	for name in rules do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local rule = rules[name]
		if rule.prefer ~= nil or rule.mode == "preference" then
			local worst = 0
			for i = 1, #members do
				for j = i + 1, #members do
					worst = math.max(worst, distance(rule, members[i][name], members[j][name]))
				end
			end
			local weight = rule.weight or 1
			if weight > 0 then
				penalty += worst * weight
			end
		end
	end
	return penalty, queued
end

return table.freeze(Rules)
