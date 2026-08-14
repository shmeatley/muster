--!nocheck

-- Cross-server parties: membership exclusivity under races, leadership, and
-- the queue lock that freezes a roster while it is being matched.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal

return function()
	local Muster = Harness.muster()

	local function parties(world)
		return Muster.Party.new(world.store, { clock = world.clock, id = world.nextId })
	end

	Harness.suite("lifecycle")
	do
		local world = Harness.world()
		local party = parties(world)

		local created = Muster.Result.unwrap(party:create(1, "A"))
		equal("the creator leads", created.leaderUserId, 1)
		equal("and is the only member", #created.members, 1)

		local twice = party:create(1, "A")
		equal("a user cannot lead two parties", twice.ok, false)
		equal("and is told why", twice.error.code, "AlreadyInParty")

		local invite = Muster.Result.unwrap(party:invite(1, 2))
		equal("the invite names the party", invite.partyId, created.id)

		local inbox = Muster.Result.unwrap(party:listInvites(2))
		equal("it lands in the target's inbox", #inbox, 1)

		local joined = Muster.Result.unwrap(party:acceptInvite(2, invite.id, "B"))
		equal("accepting adds the member", #joined.members, 2)
		equal("the version bumps", joined.version, 2)

		local consumed = Muster.Result.unwrap(party:listInvites(2))
		equal("the invite is consumed", #consumed, 0)

		local found = Muster.Result.unwrap(party:getForUser(2))
		equal("the member can find their party", found.id, created.id)

		equal("nobody may invite themselves", party:invite(1, 1).error.code, "InvalidTarget")
		equal("a member cannot invite", party:invite(2, 3).error.code, "NotLeader")
	end

	Harness.suite("competing invites")
	do
		-- Two parties on two servers invite the same player, who accepts both.
		-- Exactly one may win, and neither server can see the other.
		local world = Harness.world()
		local party = parties(world)

		Muster.Result.unwrap(party:create(1))
		Muster.Result.unwrap(party:create(2))
		local firstInvite = Muster.Result.unwrap(party:invite(1, 3))
		local secondInvite = Muster.Result.unwrap(party:invite(2, 3))

		local first = party:acceptInvite(3, firstInvite.id)
		local second = party:acceptInvite(3, secondInvite.id)

		check("the first accept wins", first.ok)
		equal("the second is refused", second.ok, false)
		equal("because they are already in a party", second.error.code, "AlreadyInParty")

		local final = Muster.Result.unwrap(party:getForUser(3))
		equal("and only one party has them", #final.members, 2)
		equal("the one they accepted first", final.leaderUserId, 1)
	end

	Harness.suite("leadership")
	do
		local world = Harness.world()
		local party = parties(world)

		local created = Muster.Result.unwrap(party:create(1))
		local inviteTwo = Muster.Result.unwrap(party:invite(1, 2))
		party:acceptInvite(2, inviteTwo.id)
		world.advance(5)
		local inviteThree = Muster.Result.unwrap(party:invite(1, 3))
		party:acceptInvite(3, inviteThree.id)

		equal("a member cannot transfer", party:transferLeader(2, 3).error.code, "NotLeader")
		equal("nor to an outsider", party:transferLeader(1, 99).error.code, "NotMember")

		local transferred = Muster.Result.unwrap(party:transferLeader(1, 3))
		equal("the leader may hand over", transferred.leaderUserId, 3)

		-- When the leader leaves, the longest-standing member inherits. Every
		-- server computes that the same way, so they cannot disagree.
		local remaining = Muster.Result.unwrap(party:leave(3))
		equal("the oldest member inherits", remaining.leaderUserId, 1)
		equal("and the party shrinks", #remaining.members, 2)

		equal("the leader cannot kick themselves", party:kick(1, 1).error.code, "InvalidTarget")
		local kicked = Muster.Result.unwrap(party:kick(1, 2))
		equal("but may kick anyone else", #kicked.members, 1)

		equal("the kicked player is free", party:getForUser(2).value, nil)
		equal("the party still exists", Muster.Result.unwrap(party:get(created.id)).id, created.id)

		check("and can be disbanded", party:disband(1).ok)
		equal("after which it is gone", party:get(created.id).error.code, "PartyNotFound")
	end

	Harness.suite("empty parties disband")
	do
		local world = Harness.world()
		local party = parties(world)
		local created = Muster.Result.unwrap(party:create(1))

		local result = party:leave(1)
		check("the last member may leave", result.ok)
		equal("and the party goes with them", result.value, nil)
		equal("it is really gone", party:get(created.id).error.code, "PartyNotFound")
	end

	Harness.suite("invite expiry")
	do
		local world = Harness.world()
		local party = parties(world)
		Muster.Result.unwrap(party:create(1))
		local invite = Muster.Result.unwrap(party:invite(1, 2))

		world.advance(Muster.Defaults.INVITE_EXPIRATION + 1)
		equal("expired invites vanish from the inbox", #Muster.Result.unwrap(party:listInvites(2)), 0)
		equal("and cannot be accepted", party:acceptInvite(2, invite.id).error.code, "InviteNotFound")
	end

	Harness.suite("queue lock")
	do
		local world = Harness.world({ size = { min = 2, target = 4, max = 4 } })
		local server = world.server("A")
		local party = server.parties
		party._id = world.nextId

		local created = Muster.Result.unwrap(party:create(1, "A"))
		local invite = Muster.Result.unwrap(party:invite(1, 2))
		party:acceptInvite(2, invite.id, "A")

		equal("a member cannot queue the party", server:enqueueParty(created.id, 2).error.code, "NotLeader")

		local ticket = Muster.Result.unwrap(server:enqueueParty(created.id, 1))
		equal("the leader can", ticket.size, 2)
		equal("and the ticket knows its party", ticket.partyId, created.id)

		-- Frozen: the roster the matchmaker is working with cannot change.
		equal("no invites while queued", party:invite(1, 3).error.code, "PartyLocked")
		equal("no leaving while queued", party:leave(2).error.code, "PartyLocked")
		equal("no kicking while queued", party:kick(1, 2).error.code, "PartyLocked")
		equal("no leadership changes", party:transferLeader(1, 2).error.code, "PartyLocked")
		equal("no disbanding", party:disband(1).error.code, "PartyLocked")

		-- Cancelling releases the lock.
		check("the leader can cancel", server:cancel(1, ticket.id).ok)
		check("and the party is editable again", party:invite(1, 3).ok)
	end

	Harness.suite("abandoned queue lock")
	do
		-- A server queued a party and died. Without repair the party would stay
		-- frozen for two hours; instead the next read fixes it.
		local world = Harness.world({ size = { min = 2, target = 4, max = 4 } })
		local server = world.server("A")
		local party = server.parties
		party._id = world.nextId

		local created = Muster.Result.unwrap(party:create(1, "A"))
		local invite = Muster.Result.unwrap(party:invite(1, 2))
		party:acceptInvite(2, invite.id, "A")
		Muster.Result.unwrap(server:enqueueParty(created.id, 1))

		equal("locked while queued", party:invite(1, 3).error.code, "PartyLocked")

		-- Nobody heartbeats the ticket, so the lock ages out.
		world.advance(Muster.Defaults.TICKET_EXPIRATION + 1)
		local repaired = Muster.Result.unwrap(party:get(created.id))
		equal("the stale lock is cleared on read", repaired.queue, nil)
		check("and the party works again", party:invite(1, 3).ok)
	end

	Harness.suite("parties match together")
	do
		local world = Harness.world({ size = { min = 2, target = 4, max = 4 } })
		local server = world.server("A")
		local party = server.parties
		party._id = world.nextId
		local matches = world.collect()

		local created = Muster.Result.unwrap(party:create(1, "A"))
		local invite = Muster.Result.unwrap(party:invite(1, 2))
		party:acceptInvite(2, invite.id, "A")
		Muster.Result.unwrap(server:enqueueParty(created.id, 1))

		server:enqueue(3)
		server:enqueue(4)
		world.tick(1)

		equal("the party and two solos fill a four", #matches, 1)
		equal("four players", matches[1].size, 4)
		equal("from three tickets", #matches[1].ticketIds, 3)
		equal("one of which was a party", #matches[1].partyIds, 1)
		equal("named on the envelope", matches[1].partyIds[1], created.id)

		-- The match releases the party, so it can queue again as a unit.
		local after = Muster.Result.unwrap(party:get(created.id))
		equal("the lock is released once matched", after.queue, nil)
	end
end
