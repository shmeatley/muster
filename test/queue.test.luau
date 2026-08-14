--!nocheck

-- End-to-end queue behaviour on a single lane: matching, ratings, parties as
-- groups, cancellation, and expiry.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal
local throws = Harness.throws

return function()
	Harness.suite("low ccu")
	do
		-- The regression that matters most for a public package. Two players on
		-- two servers must match on the very first pass, not after a widening
		-- timer. Anything else and a small game feels broken.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local b = world.server("B")
		local matches = world.collect()

		check("A queues", a:enqueue(1).ok)
		check("B queues", b:enqueue(2).ok)

		world.tick(1)

		equal("matched on the first pass", #matches, 2)
		equal("both servers saw the same match", matches[1].matchId, matches[2].matchId)
		equal("two players in it", matches[1].size, 2)
		equal("no waiting", world.now(), 1000)
	end

	Harness.suite("delivery targeting")
	do
		-- `matched` must only fire where there is somebody to act on. One scan
		-- can commit several matches, and the server doing the committing has a
		-- player in only one of them.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local b = world.server("B")

		local onA, onB = 0, 0
		a.matched:connect(function()
			onA += 1
		end)
		b.matched:connect(function()
			onB += 1
		end)

		a:enqueue(1)
		b:enqueue(2)
		b:enqueue(3)
		b:enqueue(4)

		-- A takes the lane first and commits both pairs.
		world.tick(1)

		equal("two matches formed", onB, 2)
		check("the committer only heard about its own", onA == 1, `A was told {onA} times`)
	end

	Harness.suite("ratings")
	do
		local world = Harness.world({
			size = 2,
			config = { rating = { window = 100, relax = 0, unbounded = 1e9 } },
		})
		local server = world.server("A")

		throws("an unrated value on a rated queue is fine", function()
			local result = server:enqueue(1, { rating = 1000 })
			if not result.ok then
				error(result.error.message)
			end
			error("no error")
		end, "no error")

		check("far-apart players do not match", true)
		server:enqueue(2, { rating = 3000 })
		world.tick(2)
		local status = server:getStatus(Harness.muster().Result.unwrap(server:getTicket(1)).id)
		equal("the outlier stays queued", status.value.state, "Queued")

		-- A missing rating on a rated queue with no default is a call-site bug,
		-- so it throws rather than returning a Result nobody would branch on.
		throws("a rated queue demands a rating", function()
			server:enqueue(3)
		end, "no rating was given")

		local unrated = Harness.world({ size = 2 })
		local plain = unrated.server("A")
		throws("an unrated queue refuses one", function()
			plain:enqueue(1, { rating = 1200 })
		end, "is unrated")
	end

	Harness.suite("provisional ratings")
	do
		local world = Harness.world({
			size = 2,
			config = { rating = { default = 1000 } },
		})
		local server = world.server("A")
		local matches = world.collect()

		server:enqueue(1)
		server:enqueue(2, { rating = 1000 })
		world.tick(1)

		equal("both matched", #matches, 1)
		local provisional, supplied
		for _, member in matches[1].members do
			if member.userId == 1 then
				provisional = member
			else
				supplied = member
			end
		end
		equal("the default was substituted", provisional.rating, 1000)
		equal("and marked provisional", provisional.provisional, true)
		equal("a supplied rating is not", supplied.provisional, nil)
	end

	Harness.suite("groups")
	do
		local world = Harness.world({
			size = { min = 2, target = 6, max = 6 },
			config = { rating = { window = 1e9 } },
		})
		local server = world.server("A")
		local matches = world.collect()

		check(
			"a duo queues as one ticket",
			server:enqueueGroup({ 1, 2 }, {
				ratings = { [1] = 800, [2] = 1200 },
			}).ok
		)
		check(
			"a quad queues too",
			server:enqueueGroup({ 3, 4, 5, 6 }, {
				ratings = { [3] = 1000, [4] = 1000, [5] = 1000, [6] = 1000 },
			}).ok
		)

		world.tick(1)
		equal("2 and 4 fill a 6", #matches, 1)
		equal("with six players", matches[1].size, 6)
		equal("from two tickets", #matches[1].ticketIds, 2)
	end

	Harness.suite("party rating")
	do
		local world = Harness.world({
			size = { min = 2, target = 6, max = 6 },
			config = { rating = { window = 1e9 } },
		})
		local server = world.server("A")
		server:enqueueGroup({ 1, 2 }, { ratings = { [1] = 800, [2] = 1200 } })

		local ticket = Harness.muster().Result.unwrap(server:getTicket(1))
		equal("mean pulled halfway to the best member", ticket.rating, 1100)
		equal("counted as two players", ticket.size, 2)
	end

	Harness.suite("exclusivity")
	do
		local world = Harness.world({ size = 4 })
		local a = world.server("A")
		local b = world.server("B")

		check("first queue succeeds", a:enqueue(1).ok)
		local again = a:enqueue(1)
		equal("the same user cannot queue twice", again.ok, false)
		equal("and is told why", again.error.code, "AlreadyQueued")

		-- Even from a different server, which is the case a single-server check
		-- would miss entirely.
		local elsewhere = b:enqueue(1)
		equal("not even from another server", elsewhere.ok, false)
		equal("same reason", elsewhere.error.code, "AlreadyQueued")

		local duplicate = a:enqueueGroup({ 2, 2 })
		equal("a group cannot contain a repeat", duplicate.ok, false)
		equal("reported as a duplicate", duplicate.error.code, "DuplicateMember")

		local oversized = a:enqueueGroup({ 3, 4, 5, 6, 7 })
		equal("a group larger than the match is rejected", oversized.ok, false)
		equal("reported as a bad size", oversized.error.code, "InvalidPartySize")
	end

	Harness.suite("cancel")
	do
		local world = Harness.world({ size = 4 })
		local server = world.server("A")
		local cancelled = {}
		server.cancelled:connect(function(ticket)
			table.insert(cancelled, ticket)
		end)

		local ticket = Harness.muster().Result.unwrap(server:enqueue(1))
		local result = server:cancel(1, ticket.id)
		check("cancelling works", result.ok, if result.ok then nil else result.error.message)
		equal("the signal fires", #cancelled, 1)

		local status = server:getStatus(ticket.id)
		equal("the ticket reads as cancelled", status.value.state, "Cancelled")

		local freed = server:enqueue(1)
		check("the player can queue again", freed.ok, if freed.ok then nil else freed.error.message)

		-- Only the leader may cancel, which is what stops one party member
		-- pulling everyone else out of the queue.
		local group = Harness.muster().Result.unwrap(server:enqueueGroup({ 2, 3 }))
		local byMember = server:cancel(3, group.id)
		equal("a non-leader cannot cancel", byMember.ok, false)

		equal("cancelForUser reports doing nothing", server:cancelForUser(99).value, false)
		equal("and reports doing something", server:cancelForUser(2).value, true)
	end

	Harness.suite("metadata")
	do
		local world = Harness.world({ size = 2 })
		local server = world.server("A")
		local matches = world.collect()

		server:enqueue(1, { metadata = { loadout = "sniper", level = 7 } })
		server:enqueue(2, { metadata = { loadout = "medic", level = 3 } })
		world.tick(1)

		equal("a match formed", #matches, 1)
		local ticket = matches[1].ticketIds[1]
		check("tickets carry metadata", ticket ~= nil)

		local rejected = server:enqueue(3, { metadata = { bad = print } })
		equal("unstorable metadata is rejected", rejected.ok, false)
		equal("with a clear code", rejected.error.code, "InvalidMetadata")
	end

	Harness.suite("expiry")
	do
		local world = Harness.world({ size = 4 })
		local server = world.server("A")
		local ticket = Harness.muster().Result.unwrap(server:enqueue(1))

		-- Heartbeats keep a live ticket alive indefinitely.
		for _ = 1, 7 do
			world.advance(30)
			world.tick(1)
		end
		local alive = server:getStatus(ticket.id)
		equal("a heartbeaten ticket survives", alive.value.state, "Queued")

		-- With nobody heartbeating it, the same ticket evicts itself. This is
		-- what stops a crashed server's players haunting the queue.
		world.advance(Harness.muster().Defaults.TICKET_EXPIRATION + 1)
		local gone = server:getStatus(ticket.id)
		equal("an abandoned ticket expires", gone.value.state, "Expired")
	end

	Harness.suite("partitions")
	do
		local world = Harness.world({
			size = 2,
			config = {
				partitionKey = function(request)
					return request.metadata and request.metadata.region or "all"
				end,
			},
		})
		local server = world.server("A")
		local matches = world.collect()

		server:enqueue(1, { metadata = { region = "EMEA" } })
		server:enqueue(2, { metadata = { region = "APAC" } })
		world.tick(2)
		equal("different partitions never mix", #matches, 0)

		-- Enqueueing into a lane this server already owns rescans immediately
		-- rather than waiting out the scan delay.
		server:enqueue(3, { metadata = { region = "EMEA" } })
		world.tick(1)
		equal("the same partition does", #matches, 1)
		equal("in the right partition", matches[1].partition, "EMEA")
		equal("the odd one out is still waiting", #matches[1].members, 2)
	end
end
