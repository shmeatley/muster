--!nocheck
local Harness = require("./lib/harness")
local check, equal = Harness.check, Harness.equal

return function()
	local Muster = Harness.muster()
	local function world(size, extra)
		local config = { regions = { names = { "NA", "EU" }, fallbackAfter = 10 } }
		for key, value in extra or {} do
			config[key] = value
		end
		return Harness.world({ size = size or 2, config = config })
	end
	local function queued(server, id)
		return server:getStatus(id).value.state == "Queued"
	end

	Harness.suite("regional configuration and validation")
	for _, regions in
		{
			{},
			{ names = {} },
			{ names = { "NA", "NA" } },
			{ names = { "bad:name" } },
			{ names = { "NA" }, fallbackAfter = -1 },
			{ names = { "NA" }, fallbackAfter = math.huge },
			{ names = { "NA" }, fallbackAfter = 0 / 0 },
			{ names = { "NA" }, typo = true },
			{ names = { "A", "B", "C", "D", "E", "F", "G", "H", "I" } },
		}
	do
		local ok = pcall(function()
			world(2, { regions = regions }).server("invalid")
		end)
		check("invalid regional config rejected", not ok)
	end
	do
		local w = world()
		local a = w.server("A")
		local b = w.server("B", { regions = { names = { "EU", "NA" }, fallbackAfter = 10 } })
		equal("name order gives same rule pool", a._settings.ruleKey, b._settings.ruleKey)
		equal("one fixed lane per region", a._settings.lanes, 2)
		equal("missing region", a:enqueue(1).error.code, "InvalidRegion")
		equal("unknown region", a:enqueue(1, { region = "APAC" }).error.code, "InvalidRegion")
		equal(
			"reserved attribute",
			a:enqueue(1, { region = "NA", attributes = { __musterRegion = "EU" } }).error.code,
			"InvalidAttributes"
		)
		local plain = Harness.world().server("plain")
		equal("region without config rejected", plain:enqueue(1, { region = "NA" }).error.code, "InvalidRegion")
		check("validation leaves user available", a:enqueue(1, { region = "NA" }).ok)
	end

	Harness.suite("independent regional workers and local matching")
	do
		local w = world()
		local a, b = w.server("A"), w.server("B")
		local matches = w.collect()
		local na = a:enqueue(1, { region = "NA" }).value
		local eu = b:enqueue(3, { region = "EU" }).value
		check(
			"regional indexes differ",
			a._engine._localTickets[na.id].lane.map ~= b._engine._localTickets[eu.id].lane.map
		)
		a:enqueue(2, { region = "NA" })
		b:enqueue(4, { region = "EU" })
		w.tick()
		equal("both regional matches form before fallback", #matches, 2)
		for _, match in matches do
			equal(
				"local pair stays local",
				match.members[1].attributes.__musterRegion,
				match.members[2].attributes.__musterRegion
			)
		end
	end

	Harness.suite("mutual fallback preserves ticket and queue age")
	do
		local w = world()
		local a = w.server("A")
		local matches = w.collect()
		local first = a:enqueue(1, { region = "NA" }).value
		w.tick()
		w.advance(12)
		local second = a:enqueue(2, { region = "EU" }).value
		w.tick(8, 0.25)
		equal("old ticket cannot override fresh regional preference", #matches, 0)
		check("old ticket still queued", queued(a, first.id))
		local _, record = w.store:get(a._settings.keys.tickets, first.id)
		equal("queue age unchanged", record.queuedAt, first.queuedAt)
		equal("ticket stays on original lane", record.lane, first.lane)
		w.advance(10)
		w.tick(12, 0.25)
		equal("one global match after both waits", #matches, 1)
		equal("original ticket ids retained", #matches[1].ticketIds, 2)
		local found = {}
		for _, id in matches[1].ticketIds do
			found[id] = true
		end
		check("both originals matched", found[first.id] and found[second.id])
	end

	Harness.suite("whole groups and distributed parties cross regions")
	do
		local w = world(4)
		local a, b = w.server("A"), w.server("B")
		local party = a.parties:create(1, "A").value
		local invite = a.parties:invite(1, 2).value
		check("cross-server member joins", b.parties:acceptInvite(2, invite.id, "B").ok)
		local ticket = a:enqueueParty(party.id, 1, { region = "NA" }).value
		check("party queued", ticket ~= nil)
		check("whole other group queued", b:enqueueGroup({ 3, 4 }, { region = "EU" }).ok)
		local matches = w.collect()
		w.tick()
		equal("party waits locally", #matches, 0)
		check("queued party stays locked", not a.parties:leave(1).ok)
		w.advance(11)
		w.tick(16, 0.25)
		-- One committed match is delivered to both origin servers.
		equal("both origins receive match", #matches, 2)
		equal("same committed match", matches[1].matchId, matches[2].matchId)
		equal("all four members stay together", #matches[1].members, 4)
		equal("party identity retained", matches[1].partyIds[1], party.id)
	end

	Harness.suite("regional fallback respects partitions and other rules")
	do
		local w = world(2, { rules = { Verified = { type = "boolean", compare = "equal" } } })
		local a = w.server("A")
		local matches = w.collect()
		a:enqueue(1, { region = "NA", partition = "ranked", attributes = { Verified = true } })
		a:enqueue(2, { region = "EU", partition = "casual", attributes = { Verified = true } })
		a:enqueue(3, { region = "EU", partition = "ranked", attributes = { Verified = false } })
		w.tick()
		w.advance(11)
		w.tick(20, 0.25)
		equal("neither partition nor attribute constraints relax", #matches, 0)
	end

	Harness.suite("zero-delay fallback across several regional lanes")
	do
		local w = world(3, { regions = { names = { "NA", "EU", "ASIA" }, fallbackAfter = 0 } })
		local a = w.server("A")
		local matches = w.collect()
		for user, region in { "NA", "EU", "ASIA" } do
			a:enqueue(user, { region = region })
		end
		w.tick(16, 0.25)
		equal("three regions form one match", #matches, 1)
		equal("all members included", #matches[1].members, 3)
	end

	Harness.suite("regional cancellation and worker takeover")
	do
		local w = world()
		local a, b = w.server("A"), w.server("B")
		local cancelled = a:enqueue(1, { region = "NA" }).value
		check("regional ticket cancels", a:cancel(1, cancelled.id).ok)
		local na = a:enqueue(1, { region = "NA" }).value
		local eu = b:enqueue(2, { region = "EU" }).value
		w.tick()
		-- Simulate a dead lease holder; its tickets remain live on the shared store.
		a._engine._leases:release(a._engine._localTickets[na.id].lane.key, 1)
		w.servers[1] = b
		w.servers[2] = nil
		local matches = w.collect()
		w.advance(11)
		w.tick(24, 0.25)
		equal("surviving region can discover the other region", #matches, 1)
		local ids = {}
		for _, id in matches[1].ticketIds do
			ids[id] = true
		end
		check("cancelled ticket never consumed", not ids[cancelled.id])
		check("original live tickets consumed", ids[na.id] and ids[eu.id])
	end

	Harness.suite("fallback discovery bounds and failed remote reads")
	do
		local names = { "A", "B", "C", "D", "E", "F", "G", "H" }
		local w = world(8, { regions = { names = names, fallbackAfter = 0 } })
		local a = w.server("worker")
		local matches = w.collect()
		for user, region in names do
			a:enqueue(user, { region = region })
		end
		local first = next(a._engine._localTickets)
		local descriptor = a._engine._localTickets[first].lane
		local owned = { descriptor = descriptor, batchSize = 100 }
		local reads, requested = 0, 0
		local range = w.store.sortedRange
		w.store.sortedRange = function(self, name, count, ...)
			reads += 1
			requested += count
			if name ~= descriptor.map then
				return false, nil
			end
			return range(self, name, count, ...)
		end
		local visible = a._engine:_readCandidates(owned, w.now())
		equal("failed remote reads keep local candidates", #visible, 1)
		check("regional read entries capped at 100", requested <= 100)
		check("regional reads bounded by twice the region count", reads <= 16)
		w.store.sortedRange = range
		w.tick(20, 0.25)
		equal("all eight regions match after store recovery", #matches, 1)
	end

	Harness.suite("authoritative regional acceptance rejects stale index hints")
	do
		local w = world()
		local a = w.server("A")
		local matches = w.collect()
		local na = a:enqueue(1, { region = "NA" }).value
		local eu = a:enqueue(2, { region = "EU" }).value
		w.tick()
		w.advance(11)
		-- The index says both tickets are old; the ledger's second ticket is fresh.
		w.store:update(a._settings.keys.tickets, eu.id, 180, function(current)
			current.queuedAt = w.now()
			return current
		end)
		w.tick(4, 0.25)
		equal("fresh authoritative ticket prevents commit", #matches, 0)
		check("aborted claim restores old ticket", queued(a, na.id))
		check("aborted claim restores fresh ticket", queued(a, eu.id))
	end

	Harness.suite("regional queues retain Quick Play's existing scope")
	do
		local w = world(2, { quickPlay = true })
		local a = w.server("A")
		local hosted = a.quickplay:host({
			data = {},
			players = 0,
			playerCount = function()
				return 0
			end,
		}).value
		check("listing hosted", hosted ~= nil)
		local assignments = {}
		a.quickPlayMatched:connect(function(assignment)
			table.insert(assignments, assignment)
		end)
		a:enqueue(1, { region = "EU", quickPlay = true })
		w.tick(8, 0.25)
		equal("backfill bypasses regional rules as documented", #assignments, 1)
	end

	Harness.suite("uneven regional populations use focused fallback")
	do
		local w = world(
			16,
			{ regions = { names = { "NA", "EU", "ASIA", "AU", "SA", "AF", "ME", "OTHER" }, fallbackAfter = 0 } }
		)
		local a = w.server("A")
		local matches = w.collect()
		a:enqueue(1, { region = "NA" })
		for user = 2, 16 do
			a:enqueue(user, { region = "EU" })
		end
		w.tick(32, 0.25)
		equal("one sparse player can match fifteen from a busy peer", #matches, 1)
		equal("full uneven group formed", #matches[1].members, 16)
	end

	Harness.suite("regional paging discovers compatible tickets behind a blocked peer head")
	do
		local w = world(2, { rules = { Age = { type = "number", compare = "distance", limit = 0 } } })
		local a = w.server("A")
		local matches = w.collect()
		a:enqueue(1, { region = "NA", attributes = { Age = 20 } })
		for user = 2, 102 do
			a:enqueue(user, { region = "EU", attributes = { Age = if user == 102 then 20 else 1000 + user } })
		end
		w.tick()
		w.advance(11)
		w.tick(40, 0.25)
		equal("hidden compatible peer found without loosening Age", #matches, 1)
		local users = {}
		for _, member in matches[1].members do
			users[member.userId] = true
		end
		check("only intended users matched", users[1] and users[102])
	end

	Harness.suite("overlapping regional workers commit each ticket once")
	do
		local b, finalized = nil, 0
		local w = world(2, {
			regions = { names = { "NA", "EU" }, fallbackAfter = 0 },
			finalize = function()
				finalized += 1
				-- Another regional worker reads the same hints while this match
				-- holds both claims but has not yet reached Ready.
				b:step()
				return {}
			end,
		})
		local a = w.server("A")
		b = w.server("B")
		local matches = w.collect()
		a:enqueue(1, { region = "NA" })
		b:enqueue(2, { region = "EU" })
		w.tick(16, 0.25)
		equal("finalizer runs once across overlapping workers", finalized, 1)
		equal("one delivery per origin", #matches, 2)
		equal("both deliveries identify the same match", matches[1].matchId, matches[2].matchId)
	end

	Harness.suite("region config snapshots and invalid party requests")
	do
		local supplied = { names = { "NA" } }
		local w = world(2, { regions = supplied })
		local a = w.server("A")
		equal("default fallback is thirty seconds", a._settings.regions.fallbackAfter, 30)
		equal("health reports regional routing", a:health().laneSplit, "region")
		supplied.names[1] = "EU"
		check("caller mutation does not change accepted regions", a:enqueue(9, { region = "NA" }).ok)
		local party = a.parties:create(1, "A").value
		equal(
			"invalid party region rejected",
			a:enqueueParty(party.id, 1, { region = "EU" }).error.code,
			"InvalidRegion"
		)
		check("invalid region releases party lock", a.parties:invite(1, 2).ok)
	end
end
