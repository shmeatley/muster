--!nocheck

-- Several servers on one queue: lease fencing, concurrent matching, recovery
-- from a worker that stopped mid-commit, and store failures at each step.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal

return function()
	local Muster = Harness.muster()

	Harness.suite("leases")
	do
		local world = Harness.world({ size = 2 })
		local store = world.store
		local keys = "mu1:test:leases"

		local a = Muster.internal.LeaseManager.new(store, keys, "A", { clock = world.clock })
		local b = Muster.internal.LeaseManager.new(store, keys, "B", { clock = world.clock })

		local first = a:acquire("lane")
		check("the first server takes the lane", first ~= nil)
		equal("epochs start at one", first.epoch, 1)
		equal("the second is refused", b:acquire("lane"), nil)

		check("re-acquiring keeps the epoch", a:acquire("lane").epoch, 1)
		check("the holder can renew", a:renew("lane", 1) ~= nil)
		equal("nobody else can renew it", b:renew("lane", 1), nil)
		check("the holder validates", a:validate("lane", 1))
		check("at the wrong epoch it does not", not a:validate("lane", 99))

		-- Takeover after expiry must bump the fence, or a stalled A could still
		-- write once it wakes up.
		world.advance(Muster.Defaults.LEASE_DURATION + 1)
		local stolen = b:acquire("lane")
		check("an expired lane can be taken", stolen ~= nil)
		equal("and the epoch moves on", stolen.epoch, 2)
		check("the old holder is fenced out", not a:validate("lane", 1))

		-- Releasing leaves a tombstone rather than deleting, so the counter
		-- cannot restart and hand a stale token back its authority.
		check("the holder releases", b:release("lane", 2))
		local reacquired = a:acquire("lane")
		equal("the epoch survives a clean handoff", reacquired.epoch, 3)
	end

	Harness.suite("concurrent matching")
	do
		-- Three servers, one lane, twelve players. Whatever the interleaving,
		-- every player must end up in exactly one match.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local b = world.server("B")
		local c = world.server("C")
		local matches = world.collect()

		for user = 1, 4 do
			a:enqueue(user)
		end
		for user = 5, 8 do
			b:enqueue(user)
		end
		for user = 9, 12 do
			c:enqueue(user)
		end

		world.tick(5, 2)

		local seenUsers = {}
		local doubleBooked = nil
		local distinct = {}
		for _, match in matches do
			if not distinct[match.matchId] then
				distinct[match.matchId] = true
				for _, member in match.members do
					if seenUsers[member.userId] then
						doubleBooked = member.userId
					end
					seenUsers[member.userId] = true
				end
			end
		end

		local matchCount = 0
		for _ in distinct do
			matchCount += 1
		end
		local userCount = 0
		for _ in seenUsers do
			userCount += 1
		end

		equal("six matches formed", matchCount, 6)
		equal("all twelve players placed", userCount, 12)
		check("nobody was placed twice", doubleBooked == nil, `user {tostring(doubleBooked)} was in two matches`)
	end

	Harness.suite("adopt, do not steal")
	do
		-- A worker committed a match and then died before marking its tickets.
		-- The next worker must recognise the committed match and finish the job,
		-- not tear it down and rematch players who are already in a game.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local matches = world.collect()

		a:enqueue(1)
		a:enqueue(2)
		world.tick(1)
		equal("a match formed", #matches, 1)

		local matchId = matches[1].matchId
		local keys = a._settings.keys
		local ticketId = matches[1].ticketIds[1]

		-- Rewind the ticket to the state a crash would have left: claimed
		-- against a match that did reach Ready, with the claim now expired.
		local ticket = select(2, world.store:get(keys.tickets, ticketId))
		ticket.state = "Claimed"
		ticket.matchId = nil
		ticket.claim = { matchId = matchId, leaseKey = "all:00", epoch = 1, expiresAt = world.now() - 1 }
		world.store:set(keys.tickets, ticketId, ticket, 180)
		-- Derived rather than hardcoded, so the lane key layout can change
		-- without this test quietly writing into a map nobody reads.
		local map = Muster.internal.Lanes.name(a._settings, "all", ticket.laneCount, ticket.lane)
		world.store:sortedSet(map, ticketId, {
			ticketId = ticketId,
			size = 1,
			ratings = {},
			queuedAt = ticket.queuedAt,
		}, 190, ticket.queuedAt)

		local b = world.server("B")
		b:enqueue(3)
		world.advance(2)
		world.tick(1)

		local recovered = select(2, world.store:get(keys.tickets, ticketId))
		equal("the ticket was finished, not reused", recovered.state, "Matched")
		equal("under the original match", recovered.matchId, matchId)
	end

	Harness.suite("abandoned mid-commit")
	do
		-- The other half: a worker wrote its Claiming record, claimed tickets,
		-- and never committed. Those players must be freed and rematched.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local keys = a._settings.keys

		local first = Muster.Result.unwrap(a:enqueue(1))
		local second = Muster.Result.unwrap(a:enqueue(2))

		local ghostId = "ghost-match"
		world.store:set(keys.matches, ghostId, {
			v = 1,
			id = ghostId,
			state = "Claiming",
			ownerServerId = "DEAD",
			leaseKey = "all:00",
			leaseEpoch = 1,
			createdAt = world.now(),
			expiresAt = world.now() - 1,
			ticketIds = { first.id, second.id },
		}, 300)

		for _, id in { first.id, second.id } do
			local ticket = select(2, world.store:get(keys.tickets, id))
			ticket.state = "Claimed"
			ticket.claim = { matchId = ghostId, leaseKey = "all:00", epoch = 1, expiresAt = world.now() - 1 }
			world.store:set(keys.tickets, id, ticket, 180)
		end

		local matches = world.collect()
		world.advance(2)
		world.tick(2, 2)

		local ghost = select(2, world.store:get(keys.matches, ghostId))
		equal("the abandoned match is aborted", ghost.state, "Aborted")
		equal("and the players were rematched", #matches, 1)
		check("under a new match", matches[1].matchId ~= ghostId)
	end

	Harness.suite("stale tickets")
	do
		-- A ticket whose origin server stopped heartbeating must not be matched.
		-- Doing so produces a match containing a player nobody can deliver to.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local b = world.server("B")
		local matches = world.collect()

		a:enqueue(1)
		-- B queues and then goes away: its instance never steps again, so its
		-- ticket stops being heartbeaten.
		b:enqueue(2)
		table.remove(world.servers, 2)

		world.advance(Muster.Defaults.TICKET_HEARTBEAT_INTERVAL * 2 + 5)
		world.tick(2, 2)

		equal("the dead server's player is not matched", #matches, 0)
	end

	Harness.suite("store failures")
	do
		local world = Harness.world({ size = 2 })
		local server = world.server("A")

		-- A failure writing the ticket must release the user reservation, or the
		-- player is locked out of the queue until the reservation times out.
		world.store:failNext("set", 1)
		local failed = server:enqueue(1)
		equal("the enqueue fails", failed.ok, false)
		equal("and says it is worth retrying", failed.error.retryable, true)

		local retried = server:enqueue(1)
		check("the player is not stuck", retried.ok, if retried.ok then nil else retried.error.message)

		-- The same for the index write, which happens after the ticket exists.
		world.store:failNext("sortedSet", 1)
		local indexFailed = server:enqueue(2)
		equal("an index failure also rolls back", indexFailed.ok, false)
		local indexRetried = server:enqueue(2)
		check("and is recoverable", indexRetried.ok)

		world.tick(1)
		equal("both still match", #world.collect(), 0)
	end

	Harness.suite("compare-and-set conflicts")
	do
		-- MemoryStore may run an update transform more than once. Every
		-- conditional write in Muster tracks its outcome in an upvalue, so a
		-- transform that forgets to reset on re-entry would report a write that
		-- never landed. This forces that path.
		local world = Harness.world({ size = 2 })
		local store = world.store
		local a = Muster.internal.LeaseManager.new(store, "mu1:test:leases", "A", { clock = world.clock })
		local b = Muster.internal.LeaseManager.new(store, "mu1:test:leases", "B", { clock = world.clock })

		-- B slips in and takes the lane between A's read and A's write.
		store:conflictNext("update", 1, function()
			return { ownerServerId = "B", expiresAt = world.now() + 15, epoch = 7 }
		end)

		local lost = a:acquire("lane")
		equal("A does not claim a lane B won", lost, nil)
		check("and B really holds it", b:validate("lane", 7))

		-- And the ordinary case still works once the conflict is spent.
		world.advance(20)
		local won = a:acquire("lane")
		check("A can take it when it is free", won ~= nil)
		equal("with a fenced epoch", won.epoch, 8)
	end
end
