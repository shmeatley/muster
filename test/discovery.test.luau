--!nocheck
local Harness = require("./lib/harness")
local equal, check = Harness.equal, Harness.check

return function()
	local Muster = Harness.muster()
	local function fixture(count, compatible)
		local world = Harness.world({
			size = 8,
			config = {
				rules = { Age = { type = "number", compare = "distance", limit = 0 } },
			},
		})
		local server = world.server("worker")
		local matched, ids = {}, {}
		server.matched:connect(function(match)
			for _, member in match.members do
				check("no user matched twice", not matched[member.userId])
				matched[member.userId] = true
			end
		end)
		for user = 1, count do
			local ticket = server:enqueue(user, { attributes = { Age = if compatible(user) then 20 else 1000 + user } })
			assert(ticket.ok)
			ids[user] = ticket.value.id
		end
		return world, server, matched, ids
	end

	Harness.suite("bounded discovery beyond a blocked head")
	local world, server, matched, ids = fixture(108, function(user)
		return user > 100
	end)
	local maxReads, maxRequested = 0, 0
	local reads, requested = 0, 0
	local range = world.store.sortedRange
	world.store.sortedRange = function(self, name, count, ...)
		reads += 1
		requested += count
		return range(self, name, count, ...)
	end
	for _ = 1, 80 do
		reads, requested = 0, 0
		world.tick()
		maxReads, maxRequested = math.max(maxReads, reads), math.max(maxRequested, requested)
		world.advance(0.25)
	end
	for user = 101, 108 do
		check(`hidden user {user} matched`, matched[user] == true)
	end
	equal("hard-incompatible oldest ticket remains queued", server:getStatus(ids[1]).value.state, "Queued")
	check("at most two reads per single-lane scan", maxReads <= 2)
	check("total requested candidates stays capped at 100", maxRequested <= Muster.Defaults.MAX_BATCH_SIZE)

	Harness.suite("deeper backlog and an old compatible anchor")
	local deep, _, deepMatched = fixture(308, function(user)
		return user > 300
	end)
	deep.tick(100, 0.25)
	for user = 301, 308 do
		check(`deep user {user} matched`, deepMatched[user] == true)
	end
	local anchored, _, anchorMatched = fixture(107, function(user)
		return user == 1 or user > 100
	end)
	anchored.tick(80, 0.25)
	check("old compatible anchor is included with newer players", anchorMatched[1] == true)
	for user = 101, 107 do
		check(`anchor's partner {user} matched`, anchorMatched[user] == true)
	end

	Harness.suite("range pagination with equal timestamps")
	local store = Muster.stores.InMemory.new(function()
		return 1000
	end)
	for _, key in { "a", "b", "c", "d" } do
		store:sortedSet("map", key, {}, 180, 1000)
	end
	local _, first = store:sortedRange("map", 2)
	local cursor = { key = first[2].key, sortKey = first[2].sortKey }
	store:sortedRemove("map", "b")
	local _, nextPage = store:sortedRange("map", 2, 5, cursor)
	equal("cursor survives deletion of its item", nextPage[1].key, "c")
	equal("equal timestamp tie advances by key", nextPage[2].key, "d")
	local _, legacy = store:sortedRange("map", 2)
	equal("calls without a cursor still start at the oldest", legacy[1].key, "a")

	Harness.suite("page overlap, wrap and failed reads")
	local paged, pageServer, _, pageIds = fixture(220, function(user)
		return user >= 165 and user <= 172
	end)
	local engine = pageServer._engine
	local owned = { descriptor = engine._localTickets[pageIds[1]].lane, batchSize = 100 }
	local firstHead = engine:_readCandidates(owned, paged.now())
	equal("normal scan uses full head budget", #firstHead, 100)
	owned.ruleExploreNext = true
	local firstPage = engine:_readCandidates(owned, paged.now())
	equal("exploration stays within candidate cap", #firstPage, 100)
	equal("retains oldest candidate", firstPage[1].ticketId, pageIds[1])
	equal(
		"first page stops before complete boundary group",
		#Muster.internal.Matcher.select(firstPage, paged.now(), engine._matcher),
		0
	)
	local cursor = owned.ruleCursor
	paged.store:failNext("sortedRange", 1)
	engine:_readCandidates(owned, paged.now())
	check("failed read keeps position", owned.ruleCursor == cursor)
	local nextWindow = engine:_readCandidates(owned, paged.now())
	local groups = Muster.internal.Matcher.select(nextWindow, paged.now(), engine._matcher)
	equal("overlap exposes group spanning page boundary", #groups, 1)
	equal("overlapping group has eight whole tickets", #groups[1], 8)
	equal("tail resets cursor for the next sweep", owned.ruleCursor, nil)
	owned.ruleExploreNext = false
	engine:_readCandidates(owned, paged.now())
	owned.ruleExploreNext = true
	local wrapped = engine:_readCandidates(owned, paged.now())
	equal("new sweep revisits first forward window", wrapped[#wrapped].ticketId, firstPage[#firstPage].ticketId)
	-- Fail only the forward read, after a successful oldest-prefix read.
	local originalRange = paged.store.sortedRange
	local calls = 0
	paged.store.sortedRange = function(self, ...)
		calls += 1
		if calls == 2 then
			return false, "injected forward read failure"
		end
		return originalRange(self, ...)
	end
	local saved = owned.ruleCursor
	engine:_readCandidates(owned, paged.now())
	check("failed forward page does not advance", owned.ruleCursor == saved)
	paged.store.sortedRange = originalRange
	local retried = engine:_readCandidates(owned, paged.now())
	equal(
		"retry still discovers the boundary group",
		#Muster.internal.Matcher.select(retried, paged.now(), engine._matcher),
		1
	)

	Harness.suite("explores despite productive older traffic")
	local busy =
		Harness.world({ size = 8, config = { rules = { Age = { type = "number", compare = "distance", limit = 0 } } } })
	local worker = busy.server("busy")
	-- Keep a full productive head available without consuming it, to check that
	-- discovery does not depend solely on a completely stalled scan.
	for user = 1, 108 do
		assert(worker:enqueue(user, { attributes = { Age = 20 } }).ok)
	end
	local scans, explorations = 0, 0
	local readCandidates = worker._engine._readCandidates
	worker._engine._readCandidates = function(self, lane, now)
		local candidates, own, core = readCandidates(self, lane, now)
		scans += 1
		if lane.ruleExploring then
			explorations += 1
		end
		return candidates, own, core
	end
	worker._engine._commit = function()
		return true
	end
	busy.tick(24, 0.25)
	check("productive head still gets exploration scans", scans > 4 and explorations > 0)
end
