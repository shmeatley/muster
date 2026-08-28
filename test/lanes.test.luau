--!nocheck

-- Dynamic lane layouts: growing under load, shrinking when over-sharded,
-- splitting a rated queue by rating rather than by hash, and staying correct
-- while the layout changes underneath live tickets.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal

return function()
	local Muster = Harness.muster()
	local Lanes = Muster.internal.Lanes

	local function laneState(server: any, partition: string?): any
		return select(2, server._store:get(server._settings.keys.lanes, partition or "all"))
	end

	local function setLaneState(server: any, state: any)
		server._store:set(server._settings.keys.lanes, "all", state, 720)
	end

	local function record(layout: any, previous: any?, changedAt: number): any
		return { layout = layout, previous = previous, changedAt = changedAt, touchedAt = changedAt }
	end

	Harness.suite("starts small")
	do
		-- The default has to behave exactly like a hand-pinned single lane, or
		-- every small game pays for scaling it will never need.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local b = world.server("B")
		local matches = world.collect()

		a:enqueue(1)
		b:enqueue(2)
		world.tick(1)

		equal("two players still match on the first pass", #matches, 2)
		equal("nothing was written to the lane record yet", laneState(a), nil)
	end

	Harness.suite("grows under load")
	do
		-- A queue nobody can match out of: the target is far larger than the
		-- population, so the lane fills and stays full.
		local world = Harness.world({ size = { min = 150, target = 200, max = 200 } })
		local server = world.server("A")

		for user = 1, 120 do
			server:enqueue(user)
		end
		equal("still on one lane while filling", server._engine._scaler:current("all").layout.count, 1)

		-- The batch size ramps 10 -> 100 first, then three full scans in a row
		-- are what trips the resize.
		world.tick(12, 1)

		local state = laneState(server)
		check(
			"the count was raised",
			state ~= nil and state.layout.count > 1,
			`state: {tostring(state and state.layout.count)}`
		)
		equal("it doubled rather than jumping", state.layout.count, 2)
		equal("and it remembers what it replaced", state.previous.count, 1)
		equal("under a new generation", state.layout.generation, 1)

		-- Cooldown: a second resize must not follow immediately, however
		-- saturated the lane still looks.
		world.tick(12, 1)
		equal("a second resize is held off by the cooldown", laneState(server).layout.count, 2)

		-- Past the cooldown it may move again.
		world.advance(Muster.Defaults.TICKET_EXPIRATION + 1)
		world.tick(12, 1)
		check("it can grow again later", laneState(server).layout.count >= 2)
	end

	Harness.suite("shrinks when over-sharded")
	do
		-- The failure worth protecting against: a queue spread across more lanes
		-- than it can fill, where players sit in separate lanes and never meet.
		local thin = Harness.world({ size = 2 })
		local shallow = thin.server("A")
		thin.store:set(shallow._settings.keys.lanes, "all", record(Lanes.hashed(4, 3), nil, 0), 720)

		for user = 1, 4 do
			shallow:enqueue(user)
		end
		equal("it picked up the wider count", shallow._engine._scaler:current("all").layout.count, 4)

		thin.tick(10, 6)

		local state = laneState(shallow)
		equal("it halved", state.layout.count, 2)
		equal("remembering the layout it left", state.previous.count, 4)
	end

	Harness.suite("matching survives a resize")
	do
		-- The case that makes naive resharding lose tickets. One player queues
		-- under one layout, the layout changes, another queues under the next -
		-- and they still have to find each other.
		local world = Harness.world({ size = 2 })
		local server = world.server("A")
		local matches = world.collect()

		server:enqueue(1)
		local first = Muster.Result.unwrap(server:getTicket(1))
		equal("the first ticket recorded its count", first.laneCount, 1)
		equal("and its generation", first.laneGeneration, 0)

		setLaneState(server, record(Lanes.hashed(2, 1), Lanes.hashed(1, 0), world.now()))
		-- Past the state cache TTL so the next enqueue sees the new layout.
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)

		server:enqueue(2)
		local second = Muster.Result.unwrap(server:getTicket(2))
		equal("the second landed on the new layout", second.laneCount, 2)
		equal("at the new generation", second.laneGeneration, 1)

		world.tick(3, 2)

		equal("they matched across the resize", #matches, 1)
		equal("both players", matches[1].size, 2)
	end

	Harness.suite("index cleanup follows the ticket")
	do
		-- A matched ticket's index entry has to be removed from the map it was
		-- actually written to, not the one its lane would resolve to today.
		local world = Harness.world({ size = 2 })
		local server = world.server("A")
		local matches = world.collect()

		server:enqueue(1)
		server:enqueue(2)
		world.tick(1)
		equal("matched", #matches, 1)

		local map = Lanes.name(server._settings, "all", 1, 0, 0)
		local remaining = select(2, world.store:sortedRange(map, 100))
		equal("the lane is empty afterwards", #remaining, 0)
	end

	Harness.suite("pinned counts never move")
	do
		-- Opting out has to actually opt out: no lane record, no resizes, no
		-- extra reads.
		local world = Harness.world({ size = { min = 150, target = 200, max = 200 } })
		local server = world.server("A", { lanes = 2 })

		equal("mode is fixed", server._settings.laneMode, "fixed")
		for user = 1, 120 do
			server:enqueue(user)
		end
		world.tick(12, 1)

		equal("no lane record was ever written", laneState(server), nil)
		equal("the count is still what was asked for", server._engine._scaler:current("all").layout.count, 2)
	end

	Harness.suite("a pinned odd count works")
	do
		-- Three lanes is not a power of two, so the scaler could not resize across
		-- it. A pinned count never resizes, so it is perfectly usable.
		local world = Harness.world({ size = 2 })
		local server = world.server("A", { lanes = 3 })
		local matches = world.collect()

		equal("pinned at three", server._settings.lanes, 3)

		-- Enough players that some pair shares a lane.
		for user = 1, 12 do
			server:enqueue(user)
		end
		world.tick(6, 2)

		check("players matched", #matches > 0, `{#matches} matches`)

		local occupied = {}
		for lane = 0, 2 do
			local map = Lanes.name(server._settings, "all", 3, 0, lane)
			occupied[lane] = #select(2, world.store:sortedRange(map, 100))
		end
		local spread = 0
		for lane = 0, 2 do
			if occupied[lane] > 0 then
				spread += 1
			end
		end
		check(
			"and the pool really was spread across three lanes",
			spread > 0 or #matches >= 6,
			`leftover per lane: {occupied[0]}, {occupied[1]}, {occupied[2]}`
		)
		equal("no lane record was written", laneState(server), nil)
	end

	Harness.suite("survives a broken lane record")
	do
		-- Garbage or an outage must not take the queue down; it falls back to
		-- what it last saw.
		local world = Harness.world({ size = 2 })
		local server = world.server("A")
		local matches = world.collect()

		setLaneState(server, { layout = { count = "not a number" }, previous = {}, changedAt = "nope" })
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)

		equal("it falls back to a sane count", server._engine._scaler:current("all").layout.count, 1)

		world.store:failNext("get", 3)
		server:enqueue(1)
		server:enqueue(2)
		world.tick(2, 2)
		equal("and still matches", #matches, 1)
	end

	Harness.suite("a rated queue splits by rating")
	do
		-- The point of bands. A rated queue divides its pool along the axis it
		-- already matches on, so which lane a ticket lands in is decided by its
		-- rating and not by the shape of its id.
		local world = Harness.world({ size = 2, config = { rating = { window = 200 } } })
		local server = world.server("A")

		equal("the queue bands rather than hashes", server._settings.laneSplit, "band")
		setLaneState(server, record(Lanes.banded({ 1500 }, 1), nil, 0))
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)

		server:enqueue(1, { rating = 900 })
		server:enqueue(2, { rating = 2400 })
		server:enqueue(3, { rating = 2600 })

		local low = Muster.Result.unwrap(server:getTicket(1))
		local high = Muster.Result.unwrap(server:getTicket(2))
		local alsoHigh = Muster.Result.unwrap(server:getTicket(3))

		equal("the weak player is in the bottom band", low.lane, 0)
		equal("the strong one is in the top band", high.lane, 1)
		equal("and so is every other strong player", alsoHigh.lane, 1)
	end

	Harness.suite("high ratings are never scattered")
	do
		-- The regression this whole scheme exists for. Under a hash split, four
		-- high-rated players arriving into four lanes can land one per lane and
		-- never see each other. Under bands they share a lane by construction.
		local world = Harness.world({ size = 4, config = { rating = { window = 200 } } })
		local server = world.server("A")
		local matches = world.collect()

		-- A layout already carved up for a busy ladder, with the top band open
		-- above 2000 and nobody in it.
		setLaneState(server, record(Lanes.banded({ 800, 1400, 2000 }, 5), nil, 0))
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)
		equal("four lanes are in force", server._engine._scaler:current("all").layout.count, 4)

		for user = 1, 4 do
			server:enqueue(user, { rating = 2400 + user })
		end

		local lanes = {}
		for user = 1, 4 do
			lanes[user] = Muster.Result.unwrap(server:getTicket(user)).lane
		end
		check(
			"all four landed in the same lane",
			lanes[1] == 3 and lanes[2] == 3 and lanes[3] == 3 and lanes[4] == 3,
			`lanes: {lanes[1]}, {lanes[2]}, {lanes[3]}, {lanes[4]}`
		)

		world.tick(3, 1)
		equal("so they matched", #matches, 1)
		equal("as a full game", matches[1].size, 4)
	end

	Harness.suite("a thin band reads its neighbours")
	do
		-- Band boundaries are hard walls, and a wall through a nearly empty pool
		-- costs matches for nothing. A lane too thin to match on its own reads
		-- the bands either side of it.
		local world = Harness.world({ size = 2, config = { rating = { window = 400 } } })
		local server = world.server("A")
		local matches = world.collect()

		-- A boundary sitting right between two players who are well inside each
		-- other's rating window.
		setLaneState(server, record(Lanes.banded({ 1500 }, 2), nil, 0))
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)

		server:enqueue(1, { rating = 1450 })
		server:enqueue(2, { rating = 1550 })
		equal("they are in different bands", Muster.Result.unwrap(server:getTicket(1)).lane, 0)
		equal("either side of the boundary", Muster.Result.unwrap(server:getTicket(2)).lane, 1)

		world.tick(4, 1)
		equal("and still matched across it", #matches, 1)
	end

	Harness.suite("widening the read")
	do
		-- The two reasons a band looks past its own boundaries, checked directly.
		-- The deep-but-stale one is real and awkward to stage through a live
		-- queue, since a band deep enough to stay deep is usually deep enough to
		-- match out of.
		local world = Harness.world({ size = 2, config = { rating = { window = 100, unbounded = 60 } } })
		local server = world.server("A")
		local engine = server._engine
		local band = Lanes.descriptor(server._settings, "all", Lanes.banded({ 1500 }, 1), 0)

		local owned = { descriptor = band, ownCount = 40, oldest = world.now() }
		equal(
			"a busy band still turning players over reads only itself",
			engine:_shouldWiden(owned, world.now()),
			false
		)

		owned.ownCount = 2
		equal("a band with almost nobody in it widens", engine:_shouldWiden(owned, world.now()), true)

		owned.ownCount = 40
		owned.oldest = world.now() - 61
		equal("so does one whose oldest player has outgrown it", engine:_shouldWiden(owned, world.now()), true)

		local hashed = Lanes.descriptor(server._settings, "all", Lanes.hashed(4, 1), 0)
		local spread = { descriptor = hashed, ownCount = 0, oldest = 0 }
		equal("a hashed lane has no neighbour to widen into", engine:_shouldWiden(spread, world.now()), false)
	end

	Harness.suite("a band splits at its median")
	do
		-- A saturated band divides at the middle of what its worker actually
		-- saw, so the boundary lands where the population is rather than at some
		-- fixed rating the game never uses.
		local world = Harness.world({
			size = { min = 150, target = 200, max = 200 },
			config = { rating = { window = 100, relax = 0, unbounded = 1e9 } },
		})
		local server = world.server("A")

		for user = 1, 120 do
			server:enqueue(user, { rating = user * 10 })
		end
		equal("one lane to begin with", server._engine._scaler:current("all").layout.count, 1)

		world.tick(12, 1)

		local state = laneState(server)
		check("the lane split", state ~= nil and state.layout.count == 2, `state: {tostring(state)}`)
		local boundary = state.layout.bounds[1]
		check("at a rating drawn from the queue itself", boundary > 200 and boundary < 1000, `boundary {boundary}`)
		equal("leaving one boundary", #state.layout.bounds, 1)
	end

	Harness.suite("a tight band refuses to split")
	do
		-- The rule that protects the top of the ladder: a lane whose players are
		-- all within a rating window of each other has no boundary that would
		-- not separate players who are supposed to meet, so it stays whole
		-- however deep it gets.
		local world = Harness.world({
			size = { min = 150, target = 200, max = 200 },
			config = { rating = { window = 800, relax = 0, unbounded = 1e9 } },
		})
		local server = world.server("A")

		-- 120 players spanning 600 rating, inside one window of 800.
		for user = 1, 120 do
			server:enqueue(user, { rating = 2000 + user * 5 })
		end
		world.tick(12, 1)

		equal("no split was recorded", laneState(server), nil)
		equal("the queue is still one lane", server._engine._scaler:current("all").layout.count, 1)
	end

	Harness.suite("bands merge back when they thin out")
	do
		-- The counterpart to splitting: once a band cannot fill matches on its
		-- own, its boundary is dropped and it rejoins the pool below.
		local world = Harness.world({ size = 2, config = { rating = { window = 50, relax = 0, unbounded = 1e9 } } })
		local server = world.server("A")

		setLaneState(server, record(Lanes.banded({ 1000, 2000 }, 4), nil, 0))
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)

		-- Two players far enough apart that they cannot match, so the lanes stay
		-- occupied but shallow.
		server:enqueue(1, { rating = 2400 })
		server:enqueue(2, { rating = 2900 })
		equal("both are in the top band", Muster.Result.unwrap(server:getTicket(2)).lane, 2)

		world.tick(10, 6)

		local state = laneState(server)
		check("a boundary was dropped", state ~= nil and state.layout.count == 2, `state: {tostring(state)}`)
		equal("the one below the starved lane", state.layout.bounds[1], 1000)
		equal("and the layout it replaced is remembered", state.previous.count, 3)
	end

	Harness.suite("a rating layout survives its own resize")
	do
		-- Same guarantee as the hash path, on the axis bands actually use: a
		-- ticket written under one set of boundaries must still be visible to a
		-- worker holding the lane those boundaries became.
		local world = Harness.world({ size = 2, config = { rating = { window = 2000, relax = 0, unbounded = 1e9 } } })
		local server = world.server("A")
		local matches = world.collect()

		setLaneState(server, record(Lanes.banded({ 1500 }, 1), nil, 0))
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)
		server:enqueue(1, { rating = 1800 })
		equal("written into the top band of two", Muster.Result.unwrap(server:getTicket(1)).lane, 1)

		-- The top band splits underneath the queued player.
		setLaneState(server, record(Lanes.banded({ 1500, 1900 }, 2), Lanes.banded({ 1500 }, 1), world.now()))
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)

		server:enqueue(2, { rating = 1700 })
		local second = Muster.Result.unwrap(server:getTicket(2))
		equal("the newcomer lands under the new layout", second.laneGeneration, 2)
		equal("in the middle band", second.lane, 1)

		world.tick(3, 2)
		equal("and the two still found each other", #matches, 1)
	end
end
