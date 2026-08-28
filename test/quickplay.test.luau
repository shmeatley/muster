--!nocheck

-- Quick Play: backfilling queued players into matches that are already running.
--
-- The interesting cases are all about two things racing. A seat and a ticket
-- are each single-writer resources, and every test here is really asking
-- whether the right one of two contenders wins.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal

return function()
	local Muster = Harness.muster()
	local Listings = Muster.internal.Listings

	--[[
		A world whose queue has Quick Play on. `size` stays at 2 so the ordinary
		matching path is easy to trigger alongside it.
	]]
	local function quickWorld(options: any?)
		local settings = options or {}
		return Harness.world({
			size = settings.size or 2,
			config = {
				quickPlay = settings.quickPlay or true,
			},
		})
	end

	--[[
		Hosts a listing on `server`, with the player count pinned rather than read
		from a Players service that does not exist under Lune.
	]]
	local function host(server: any, players: number, options: any?)
		local opts = options or {}
		local count = players
		local present = opts.present or {}
		local handle = Muster.Result.unwrap(server.quickplay:host({
			data = opts.data or { accessCode = "code-1", placeId = 42 },
			capacity = opts.capacity or 4,
			partition = opts.partition,
			players = count,
			playerCount = function()
				return count
			end,
			presentUserIds = function()
				return present
			end,
		}))
		return handle,
			function(newCount: number, newPresent: { number }?)
				count = newCount
				present = newPresent or present
			end
	end

	local function assignmentsOf(server: any): { any }
		local seen = {}
		server.quickPlayMatched:connect(function(assignment)
			table.insert(seen, assignment)
		end)
		return seen
	end

	Harness.suite("off by default")
	do
		local world = Harness.world({ size = 2 })
		local server = world.server("A")

		Harness.throws("quickPlay throws without the config", function()
			server:quickPlay(1)
		end, "has no Quick Play")
		Harness.throws("so does the service", function()
			return server.quickplay
		end, "has no Quick Play")
		Harness.throws("and so does the enqueue option", function()
			server:enqueue(1, { quickPlay = true })
		end, "cannot be requested")

		equal("nothing was written", world.store:callCount("set"), 0)
	end

	Harness.suite("backfills into a live match")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		host(arena, 2, { capacity = 4, data = { accessCode = "arena-1", placeId = 7 } })

		local ticket = Muster.Result.unwrap(lobby:quickPlay(101))

		equal("the player was assigned immediately", #assignments, 1)
		equal("carrying the access code", assignments[1].data.accessCode, "arena-1")
		equal("and the place id", assignments[1].data.placeId, 7)
		equal("to the hosting server", assignments[1].serverId, "B")
		equal("naming the ticket it consumed", assignments[1].ticketId, ticket.id)

		local status = Muster.Result.unwrap(lobby:getStatus(ticket.id))
		equal("the ticket is out of the queue", status.state, "QuickPlayed")
		equal("pointing at the listing", status.listingId, assignments[1].listingId)

		local free = Muster.Result.unwrap(lobby:getTicket(101))
		equal("and the player may queue again", free, nil)
	end

	Harness.suite("only one lobby gets the last seat")
	do
		-- 3/4, so exactly one of the two players can be taken.
		local world = quickWorld()
		local one = world.server("A")
		local two = world.server("B")
		local arena = world.server("C")
		local first = assignmentsOf(one)
		local second = assignmentsOf(two)

		host(arena, 3, { capacity = 4 })

		-- The losing claim is forced to re-run its transform against the winner's
		-- write, which is what a real UpdateAsync does under contention. A
		-- transform that failed to reset `claimed` would hand out the seat twice.
		world.store:conflictNext("update", 1)

		one:quickPlay(201)
		two:quickPlay(202)

		equal("exactly one seat was handed out", #first + #second, 1)

		local loser = if #first == 0 then one else two
		local loserId = if #first == 0 then 201 else 202
		local ticket = Muster.Result.unwrap(loser:getTicket(loserId))
		check("the other player is still queued", ticket ~= nil and ticket.state == "Queued")

		local winner = first[1] or second[1]
		local listing = Muster.Result.unwrap(one.quickplay:get(winner.listingId))
		equal("and the match is full", Listings.freeSlots(listing), 0)

		local views = Muster.Result.unwrap(one.quickplay:listings())
		equal("so it is no longer listed", #views, 0)
	end

	Harness.suite("falls through to the normal queue when everything is full")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)
		local matches = world.collect()

		host(arena, 4, { capacity = 4 })

		lobby:quickPlay(301)
		lobby:quickPlay(302)

		equal("nobody was backfilled", #assignments, 0)

		world.tick(2)
		equal("but they matched each other instead", #matches, 1)
		equal("as an ordinary match", matches[1].size, 2)
	end

	Harness.suite("backfills a queued player when a seat opens")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		local _, setPlayers = host(arena, 4, { capacity = 4 })

		lobby:quickPlay(401)
		equal("full, so the player waits", #assignments, 0)

		-- Somebody leaves the arena, and its next heartbeat says so.
		setPlayers(3)
		world.advance(31)
		arena:step()

		local views = Muster.Result.unwrap(lobby.quickplay:listings())
		equal("the match is listed again", #views, 1)
		equal("with one seat", views[1].free, 1)

		lobby:step()
		equal("and the waiting player takes it", #assignments, 1)
	end

	Harness.suite("a seat nobody claims comes back")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")

		local handle = host(arena, 3, { capacity = 4 })
		lobby:quickPlay(501)

		local listing = Muster.Result.unwrap(lobby.quickplay:get(handle.id))
		equal("the seat is held", Listings.freeSlots(listing), 0)
		equal("by a reservation", #listing.reservations, 1)

		-- The player never arrives. The reservation is the only thing keeping the
		-- seat, so it has to lapse or the match is short a player forever.
		world.advance(46)
		arena:step()

		listing = Muster.Result.unwrap(lobby.quickplay:get(handle.id))
		equal("which lapses", #listing.reservations, 0)
		equal("giving the seat back", Listings.freeSlots(listing), 1)
	end

	Harness.suite("an arrived player is not counted twice")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")

		local handle, setPlayers = host(arena, 3, { capacity = 4 })
		lobby:quickPlay(601)

		-- The player lands. The arena now counts them in `players`, so leaving the
		-- reservation up would hold a seat that is already occupied and leave the
		-- match stuck at 4/4 with only 4 real players once one more leaves.
		setPlayers(4, { 601 })
		world.advance(31)
		arena:step()

		local listing = Muster.Result.unwrap(lobby.quickplay:get(handle.id))
		equal("the reservation retired on arrival", #listing.reservations, 0)
		equal("and the count is the truth", listing.players, 4)
		equal("with no phantom seat held", Listings.freeSlots(listing), 0)
	end

	Harness.suite("a ticket claimed for a match is not backfilled too")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		local handle = host(arena, 2, { capacity = 4 })
		local ticket = Muster.Result.unwrap(lobby:enqueue(701, { quickPlay = true }))

		-- A lane worker somewhere claims the ticket a moment before the backfill
		-- search returns. The seat has already been taken by then, so the test is
		-- whether it gets handed back.
		world.store:update(lobby._settings.keys.tickets, ticket.id, 180, function(current)
			current.state = "Claimed"
			current.claim = { matchId = "m-1", leaseKey = "k", epoch = 1, expiresAt = world.now() + 20 }
			return current
		end)

		local backfilled = lobby._engine:_tryQuickPlay(ticket, world.now())
		equal("the backfill gave up", backfilled, false)
		equal("firing nothing", #assignments, 0)

		local listing = Muster.Result.unwrap(lobby.quickplay:get(handle.id))
		equal("and returned the seat", #listing.reservations, 0)
		equal("leaving the match joinable", Listings.freeSlots(listing), 2)
	end

	Harness.suite("a group takes its seats together or not at all")
	do
		local world = quickWorld({ size = { min = 2, target = 4, max = 4 } })
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		local handle = host(arena, 3, { capacity = 4 })

		lobby:quickPlayGroup({ 801, 802 })
		equal("two players do not fit in one seat", #assignments, 0)

		local listing = Muster.Result.unwrap(lobby.quickplay:get(handle.id))
		equal("so nothing was reserved", #listing.reservations, 0)

		local ticket = Muster.Result.unwrap(lobby:getTicket(801))
		check("and the group stays queued", ticket ~= nil and ticket.size == 2)
	end

	Harness.suite("a closed match takes nobody")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		local handle = host(arena, 1, { capacity = 4 })
		handle:setOpen(false)

		local views = Muster.Result.unwrap(lobby.quickplay:listings())
		equal("a closed match is delisted at once", #views, 0)

		lobby:quickPlay(901)
		equal("so nobody joins it", #assignments, 0)

		handle:setOpen(true)
		equal("and it comes back when reopened", #Muster.Result.unwrap(lobby.quickplay:listings()), 1)
	end

	Harness.suite("a host that dies is delisted")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		host(arena, 1, { capacity = 4 })

		-- The arena stops heartbeating. Nothing cleans up after it; the record and
		-- its index entry simply age out.
		world.advance(101)

		local views = Muster.Result.unwrap(lobby.quickplay:listings())
		equal("the listing is gone", #views, 0)

		lobby:quickPlay(1001)
		equal("and nobody is sent to a dead server", #assignments, 0)
	end

	Harness.suite("closing removes a listing immediately")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")

		local handle = host(arena, 1, { capacity = 4 })
		equal("listed", #Muster.Result.unwrap(lobby.quickplay:listings()), 1)

		handle:close()
		equal("delisted", #Muster.Result.unwrap(lobby.quickplay:listings()), 0)
		equal("and the record is gone", Muster.Result.unwrap(lobby.quickplay:get(handle.id)), nil)
	end

	Harness.suite("partitions never mix")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		host(arena, 1, { capacity = 4, partition = "EMEA" })

		lobby:quickPlay(1101, { partition = "NA" })
		equal("a listing in another region is not offered", #assignments, 0)

		lobby:quickPlay(1102, { partition = "EMEA" })
		equal("but one in the right region is", #assignments, 1)
	end

	Harness.suite("survives a store outage")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		host(arena, 2, { capacity = 4 })

		-- Queued for backfill, but the claim itself fails. The player has to stay
		-- in the queue rather than be told they are on their way somewhere.
		local ticket = Muster.Result.unwrap(lobby:enqueue(1201, { quickPlay = true }))
		world.store:failNext("update", 1)
		lobby:step()

		equal("no assignment on a failed claim", #assignments, 0)
		local queued = Muster.Result.unwrap(lobby:getTicket(1201))
		check("the player is still queued", queued ~= nil and queued.state == "Queued")
		equal("holding the same ticket", queued.id, ticket.id)

		world.advance(4)
		lobby:step()
		equal("and gets in once the store recovers", #assignments, 1)
	end

	Harness.suite("configuration is checked at the call site")
	do
		Harness.throws("a listing expiry under one heartbeat is refused", function()
			Muster.new({
				name = "bad",
				size = 2,
				autoStart = false,
				broadcast = false,
				store = Muster.stores.InMemory.new(function()
					return 0
				end),
				quickPlay = { heartbeatInterval = 30, listingExpiration = 10 },
			})
		end, "listingExpiration")

		Harness.throws("as is a nonsense lane count", function()
			Muster.new({
				name = "bad",
				size = 2,
				autoStart = false,
				broadcast = false,
				store = Muster.stores.InMemory.new(function()
					return 0
				end),
				quickPlay = { lanes = 0 },
			})
		end, "quickPlay.lanes")
	end

	Harness.suite("listings survive a lane resize")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		local handle = host(arena, 2, { capacity = 4 })
		local before = handle._map

		-- Force the layout on, as a saturated lane would. Unlike a ticket, a
		-- listing outlives the resize, so it has to move itself rather than wait
		-- to drain.
		world.store:set(lobby._settings.keys.quickplayLanes, "all", {
			layout = { generation = 1, count = 2, mode = "hash", bounds = {} },
			previous = { generation = 0, count = 1, mode = "hash", bounds = {} },
			changedAt = world.now(),
			touchedAt = world.now(),
		}, 720)

		-- Past the layout cache and into the next heartbeat.
		world.advance(31)
		arena:step()

		check("the listing moved to a new lane map", handle._map ~= before)
		equal("the record knows its new lane", handle:record().laneGeneration, 1)

		local views = Muster.Result.unwrap(lobby.quickplay:listings())
		equal("and it is still findable", #views, 1)

		lobby:quickPlay(1301)
		equal("across the resize", #assignments, 1)
	end

	Harness.suite("a server shutting down delists itself")
	do
		local world = quickWorld()
		local lobby = world.server("A")
		local arena = world.server("B")
		local assignments = assignmentsOf(lobby)

		host(arena, 1, { capacity = 4 })
		equal("listed while running", #Muster.Result.unwrap(lobby.quickplay:listings()), 1)

		-- BindToClose. Waiting out `listingExpiration` would keep sending players
		-- at a server that is already going away.
		arena:stop()

		equal("gone on stop", #Muster.Result.unwrap(lobby.quickplay:listings()), 0)
		lobby:quickPlay(1401)
		equal("and nobody is sent there", #assignments, 0)
	end
end
