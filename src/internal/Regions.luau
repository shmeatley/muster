--!strict

-- Regional routing is independent of permanent partitions. A generated rule
-- supplies mutual acceptance and commit-time validation through the normal
-- rules path; discovery supplies candidates from separate regional indexes.
local Regions = {}
Regions.ATTRIBUTE = "__musterRegion"

function Regions.resolve(raw: any): (any, string?)
	if raw == nil then
		return nil, nil
	end
	if type(raw) ~= "table" or type(raw.names) ~= "table" then
		return nil, "Muster: regions needs names and optional fallbackAfter"
	end
	for key in raw do
		if key ~= "names" and key ~= "fallbackAfter" then
			return nil, `Muster: unknown regions field {tostring(key)}`
		end
	end
	local names, seen = {}, {}
	for key, name in raw.names do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #raw.names then
			return nil, "Muster: regions.names must be an array"
		end
		if type(name) ~= "string" or #name == 0 or #name > 32 or not string.match(name, "^[%w_%-]+$") then
			return nil, "Muster: region names need 1-32 letters, digits, underscores or hyphens"
		end
		if seen[name] then
			return nil, "Muster: region names must be unique"
		end
		seen[name] = true
		table.insert(names, name)
	end
	if #names == 0 or #names > 8 or #names ~= #raw.names then
		return nil, "Muster: regions.names needs 1-8 names in a dense array"
	end
	-- Stable ordering makes lane assignment identical across server configs.
	table.sort(names)
	local lanes = {}
	for index, name in names do
		lanes[name] = index - 1
	end
	local after = if raw.fallbackAfter == nil then 30 else raw.fallbackAfter
	if type(after) ~= "number" or after ~= after or after < 0 or after == math.huge then
		return nil, "Muster: regions.fallbackAfter must be finite and nonnegative"
	end
	return table.freeze({ names = table.freeze(names), lanes = table.freeze(lanes), fallbackAfter = after }), nil
end

function Regions.rules(raw: any, regions: any): (any, string?)
	if regions == nil then
		if type(raw) == "table" and raw[Regions.ATTRIBUTE] ~= nil then
			return nil, "Muster: __musterRegion is reserved for built-in regions"
		end
		return raw, nil
	end
	if raw ~= nil and type(raw) ~= "table" then
		return nil, "Muster: rules must be a table"
	end
	local rules = table.clone(raw or {})
	if rules[Regions.ATTRIBUTE] ~= nil then
		return nil, "Muster: __musterRegion is reserved for built-in regions"
	end
	local distances = {}
	for _, name in regions.names do
		local row = {}
		for _, other in regions.names do
			row[other] = if name == other then 0 else 1
		end
		distances[name] = row
	end
	rules[Regions.ATTRIBUTE] = {
		type = "string",
		compare = "distance",
		prefer = "closer",
		distances = distances,
		limit = if regions.fallbackAfter == 0
			then 1
			else {
				{ after = 0, value = 0 },
				{ after = regions.fallbackAfter, value = 1 },
			},
	}
	return rules, nil
end

return Regions
