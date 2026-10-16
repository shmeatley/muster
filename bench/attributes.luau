--!nocheck
-- Run from the repository root: lune run bench/attributes
-- Benchmarks the shipped modules; production code and tuning are not modified.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Harness = require("../test/lib/harness")
local Muster = Harness.muster()
local Matcher = Muster.internal.Matcher

local output = {
	method = {
		runtime = "Lune 0.10.5, headless Luau",
		clock = "os.clock elapsed seconds; fixture creation excluded from matcher timings",
		cpu = "Host-dependent. Record CPU/OS alongside results; not a Roblox server benchmark.",
		queue = "One origin/worker, InMemory store and messaging, synthetic 0.25-second ticks; no IO latency/throttling",
		requestUnits = "Lower bound: range=max(1,returned items), hash update=2, other store calls=1; no retries or messaging units",
		quantiles = "Nearest-rank quantiles. Small per-case sample counts are descriptive, not statistical confidence bounds.",
		maxBatch = Muster.Defaults.MAX_BATCH_SIZE,
		beamWidth = 8,
		instrumentation = "Callback counters wrap policy functions and use the general path; optimized internal work counts are in bench/optimization/profile.luau. Timings use the unwrapped built-in policy.",
	},
	matcher = {},
	bursts = {},
	arrivals = {},
	visibility = {},
}

local function quantile(values, fraction)
	if #values == 0 then
		return 0
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.max(1, math.ceil(#sorted * fraction))]
end

local function standardRules(preferences)
	return {
		Age = {
			type = "number",
			compare = "distance",
			limit = {
				{ after = 0, value = 2 },
				{ after = 30, value = 5 },
				{ after = 90, value = 10 },
			},
			prefer = if preferences then "closer" else nil,
		},
		Region = { type = "string", compare = "equal", relaxAfter = 45 },
		IsVerified = { type = "boolean", compare = "equal" },
		IsFlaggedCheater = { type = "boolean", compare = "required", value = false },
	}
end

local function attributes(index, scenario)
	return {
		Age = if scenario == "incompatible" then index * 100 else 20 + index % 3,
		Region = if scenario == "near-fill" then `R{math.floor((index - 1) / 7)}` else "NA",
		IsVerified = if scenario == "mixed" then index % 2 == 0 else true,
		IsFlaggedCheater = false,
	}
end

local function matcherCase(scenario, count, size, partySize, preferences, legacy, manyRules)
	local rules = standardRules(preferences)
	if manyRules then
		for field = 1, 12 do
			rules[`Extra{field}`] = { type = "number", compare = "distance", limit = 5, prefer = "closer" }
		end
	end
	local settings =
		assert(Muster.Config.resolve({ name = "bench", size = size, rules = if legacy then nil else rules }))
	local policy = Matcher.policy(settings)
	local candidates = {}
	for index = 1, count do
		local members = {}
		for member = 1, partySize do
			local data = attributes(index, scenario)
			if manyRules then
				for field = 1, 12 do
					data[`Extra{field}`] = (index + member + field) % 5
				end
			end
			table.insert(members, data)
		end
		table.insert(candidates, {
			ticketId = string.format("%06d", index),
			size = partySize,
			queuedAt = 1000,
			ratings = {},
			ruleKey = settings.ruleKey,
			attributes = if legacy then nil else members,
		})
	end
	local function run()
		local started = os.clock()
		local groups = Matcher.select(candidates, 1000, policy)
		return (os.clock() - started) * 1000, groups
	end
	local warmup = run()
	local samples = math.clamp(math.ceil(600 / math.max(1, warmup)), 3, 9)
	local times, groups = {}, nil
	for _ = 1, samples do
		local elapsed
		elapsed, groups = run()
		table.insert(times, elapsed)
	end
	local players = 0
	for _, group in groups do
		for _, ticket in group do
			players += ticket.size
		end
	end
	local measured = table.clone(policy)
	local pairChecks, scoreCalls = 0, 0
	if policy.pairCompatible then
		measured.pairCompatible = function(...)
			pairChecks += 1
			return policy.pairCompatible(...)
		end
	end
	measured.score = function(...)
		scoreCalls += 1
		return policy.score(...)
	end
	Matcher.select(candidates, 1000, measured) -- instrumentation excluded from timings
	local row = {
		scenario = scenario,
		tickets = count,
		players = count * partySize,
		matchSize = size,
		partySize = partySize,
		ruleCount = if legacy then 0 elseif manyRules then 16 else 4,
		preferences = preferences,
		samples = samples,
		medianMs = quantile(times, 0.5),
		p95Ms = quantile(times, 0.95),
		maxMs = quantile(times, 1),
		rawMs = times,
		matchedPlayers = players,
		groups = #groups,
		pairChecks = pairChecks,
		scoreCalls = scoreCalls,
	}
	table.insert(output.matcher, row)
	print(
		string.format(
			"matcher %-14s %3d tickets %2d seats party=%d: median %8.2f ms; matched %d",
			scenario,
			count,
			size,
			partySize,
			row.medianMs,
			players
		)
	)
end

for _, count in { 8, 16, 25, 50, 75, 100 } do
	for _, scenario in { "compatible", "mixed", "incompatible", "near-fill" } do
		matcherCase(scenario, count, 8, 1, true, false, false)
	end
	matcherCase("constraints", count, 8, 1, false, false, false)
end
for _, size in { 16, 32 } do
	for _, count in { 25, 50, 100 } do
		matcherCase("large-match", count, size, 1, true, false, false)
	end
end
for _, partySize in { 2, 4 } do
	for _, count in { 25, 50, 100 } do
		matcherCase("parties", count, 8, partySize, true, false, false)
	end
end
matcherCase("sixteen-rules", 100, 8, 1, true, false, true)
matcherCase("legacy", 100, 8, 1, false, true, false)

local function meteredWorld()
	local world = Harness.world({ size = 8, config = { rules = standardRules(true), broadcast = false } })
	local units = 0
	for _, name in { "get", "set", "update", "remove", "sortedSet", "sortedRemove", "sortedRange" } do
		local original = world.store[name]
		world.store[name] = function(self, ...)
			local success, result = original(self, ...)
			units += if name == "sortedRange"
				then (if success then math.max(1, #result) else 1)
				elseif name == "update" then 2
				else 1
			return success, result
		end
	end
	local server = world.server("worker")
	local stats = { matched = 0, matches = 0, stepsMs = {}, scansMs = {}, waits = {}, scans = 0, maxVisible = 0 }
	server.matched:connect(function(match)
		stats.matched += match.size
		stats.matches += 1
		for _ = 1, match.size do
			table.insert(stats.waits, world.now() - 1000)
		end
	end)
	local read = server._engine._readCandidates
	server._engine._readCandidates = function(self, ...)
		local candidates, own, core = read(self, ...)
		stats.scans += 1
		stats.maxVisible = math.max(stats.maxVisible, #candidates)
		return candidates, own, core
	end
	local function tick()
		local scans = stats.scans
		local started = os.clock()
		server:step()
		local elapsed = (os.clock() - started) * 1000
		table.insert(stats.stepsMs, elapsed)
		if stats.scans > scans then
			table.insert(stats.scansMs, elapsed)
		end
	end
	return world, server, stats, tick, function()
		return units
	end
end

for _, population in { 100, 1000, 5000 } do
	local world, server, stats, tick, units = meteredWorld()
	local enqueueStarted = os.clock()
	for user = 1, population do
		assert(server:enqueue(user, { attributes = attributes(user, "compatible") }).ok)
	end
	local enqueueMs = (os.clock() - enqueueStarted) * 1000
	local initialUnits, initialCalls = units(), world.store:callCount()
	local target = math.floor(population / 8) * 8
	local started = os.clock()
	while stats.matched < target and world.now() - 1000 < 120 do
		tick()
		if stats.matched < target then
			world.advance(0.25)
		end
	end
	local row = {
		queuedPlayers = population,
		matchedPlayers = stats.matched,
		remaining = population - stats.matched,
		virtualSeconds = world.now() - 1000,
		cpuWallSeconds = os.clock() - started,
		enqueueMs = enqueueMs,
		p50VirtualWaitSeconds = quantile(stats.waits, 0.5),
		p95VirtualWaitSeconds = quantile(stats.waits, 0.95),
		scans = stats.scans,
		maxVisibleTickets = stats.maxVisible,
		scanMedianMs = quantile(stats.scansMs, 0.5),
		scanP95Ms = quantile(stats.scansMs, 0.95),
		scanMaxMs = quantile(stats.scansMs, 1),
		storeCallsAfterEnqueue = world.store:callCount() - initialCalls,
		requestUnitsAfterEnqueueLowerBound = units() - initialUnits,
		enqueueUnitsLowerBound = initialUnits,
	}
	table.insert(output.bursts, row)
	print(
		string.format(
			"burst %d: %d matched in %.2f virtual seconds; scan median %.2f ms",
			population,
			stats.matched,
			row.virtualSeconds,
			row.scanMedianMs
		)
	)
end

-- Fixed-rate arrivals, 20 virtual seconds. All tickets are mutually compatible
-- at the initial age limit. Age is constant to isolate service capacity.
for _, rate in { 50, 200, 400, 600 } do
	local world, server, stats, tick, units = meteredWorld()
	local supplied, trace = 0, {}
	local started = os.clock()
	for step = 0, 79 do
		local desired = math.floor(rate * (step + 1) * 0.25)
		while supplied < desired do
			supplied += 1
			local data = attributes(supplied, "compatible")
			data.Age = 20
			assert(server:enqueue(supplied, { attributes = data }).ok)
		end
		tick()
		if (step + 1) % 20 == 0 then
			table.insert(trace, { seconds = (step + 1) * 0.25, queuedPlayers = supplied - stats.matched })
		end
		world.advance(0.25)
	end
	local row = {
		arrivalsPerVirtualSecond = rate,
		virtualSeconds = 20,
		supplied = supplied,
		matchedPlayers = stats.matched,
		backlog = supplied - stats.matched,
		trace = trace,
		cpuWallSeconds = os.clock() - started,
		scans = stats.scans,
		scanMedianMs = quantile(stats.scansMs, 0.5),
		scanP95Ms = quantile(stats.scansMs, 0.95),
		requestUnitsLowerBound = units(),
	}
	table.insert(output.arrivals, row)
	print(
		string.format(
			"arrivals %d/s: %d matched; backlog %d; %.2f CPU-wall seconds",
			rate,
			row.matchedPlayers,
			row.backlog,
			row.cpuWallSeconds
		)
	)
end

-- An otherwise matchable group is behind 100 incompatible oldest tickets.
-- Discovery must page past the head without relaxing any rule.
-- Every age gap exceeds the final cap, so time cannot rescue the head.
do
	local world, server, stats, tick, units = meteredWorld()
	local firstMatchAt = nil
	server.matched:connect(function()
		firstMatchAt = firstMatchAt or (world.now() - 1000)
	end)
	for user = 1, 100 do
		assert(server:enqueue(user, { attributes = attributes(user, "incompatible") }).ok)
	end
	for user = 101, 108 do
		local data = attributes(user, "compatible")
		data.Age = 20
		assert(server:enqueue(user, { attributes = data }).ok)
	end
	for _ = 1, 401 do
		tick()
		world.advance(0.25)
	end
	output.visibility = {
		queuedPlayers = 108,
		compatiblePlayersBeyondHead = 8,
		firstMatchVirtualSeconds = firstMatchAt,
		virtualSeconds = 100,
		matchedPlayers = stats.matched,
		scans = stats.scans,
		maxVisibleTickets = stats.maxVisible,
		requestUnitsLowerBound = units(),
		scanMedianMs = quantile(stats.scansMs, 0.5),
	}
	assert(stats.matched == 8 and firstMatchAt ~= nil, "forward discovery did not match the hidden group")
	print(`blocked head: {stats.matched}/108 matched after 100 virtual seconds; {stats.scans} scans`)
end

fs.writeFile("bench/attributes-results.json", serde.encode("json", output, true))
print("Saved bench/attributes-results.json")
