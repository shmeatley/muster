--!nocheck

-- Dynamic lane counts: growing under load, shrinking when over-sharded, and
-- staying correct while the count changes underneath live tickets.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal

return function()
	local Muster = Harness.muster()

	local function laneState(server: any, partition: string?): any
		return select(2, server._store:get(server._settings.keys.lanes, partition or "all"))
	end

	local function setLaneState(server: any, state: any)
		server._store:set(server._settings.keys.lanes, "all", state, 720)
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
		equal("still on one lane while filling", server._engine._scaler:current("all").count, 1)

		-- The batch size ramps 10 -> 100 first, then three full scans in a row
		-- are what trips the resize.
		world.tick(12, 1)

		local state = laneState(server)
		check("the count was raised", state ~= nil and state.count > 1, `state: {tostring(state and state.count)}`)
		equal("it doubled rather than jumping", state.count, 2)
		equal("and it remembers what it replaced", state.previous, 1)

		-- Cooldown: a second resize must not follow immediately, however
		-- saturated the lane still looks.
		world.tick(12, 1)
		equal("a second resize is held off by the cooldown", laneState(server).count, 2)

		-- Past the cooldown it may move again.
		world.advance(Muster.Defaults.TICKET_EXPIRATION + 1)
		world.tick(12, 1)
		check("it can grow again later", laneState(server).count >= 2)
	end

	Harness.suite("shrinks when over-sharded")
	do
		-- The failure worth protecting against: a queue spread across more lanes
		-- than it can fill, where players sit in separate lanes and never meet.
		local world = Harness.world({ size = 2 })
		local server = world.server("A")
		setLaneState(server, { count = 4, previous = nil, changedAt = 0 })

		-- Rated with a window of zero so nothing matches and the lanes stay
		-- occupied but shallow.
		local thin = Harness.world({ size = 2 })
		local shallow = thin.server("A", { rating = { window = 1, relax = 0, unbounded = 1e9 } })
		thin.store:set(shallow._settings.keys.lanes, "all", { count = 4, previous = nil, changedAt = 0 }, 720)

		for user = 1, 4 do
			shallow:enqueue(user, { rating = user * 10000 })
		end
		equal("it picked up the wider count", shallow._engine._scaler:current("all").count, 4)

		thin.tick(10, 6)

		local state = select(2, thin.store:get(shallow._settings.keys.lanes, "all"))
		equal("it halved", state.count, 2)
		equal("remembering the count it left", state.previous, 4)
	end

	Harness.suite("matching survives a resize")
	do
		-- The case that makes naive resharding lose tickets. One player queues
		-- at count 1, the count changes, another queues at count 2 - and they
		-- still have to find each other.
		local world = Harness.world({ size = 2 })
		local server = world.server("A")
		local matches = world.collect()

		server:enqueue(1)
		local first = Muster.Result.unwrap(server:getTicket(1))
		equal("the first ticket recorded its count", first.laneCount, 1)

		setLaneState(server, { count = 2, previous = 1, changedAt = world.now() })
		-- Past the state cache TTL so the next enqueue sees the new count.
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)

		server:enqueue(2)
		local second = Muster.Result.unwrap(server:getTicket(2))
		equal("the second landed on the new count", second.laneCount, 2)

		world.tick(3, 2)

		equal("they matched across the resize", #matches, 1)
		equal("both players", matches[1].size, 2)
	end

	Harness.suite("index cleanup follows the ticket")
	do
		-- A matched ticket's index entry has to be removed from the map it was
		-- actually written to, not the one its lane would hash to today.
		local world = Harness.world({ size = 2 })
		local server = world.server("A")
		local matches = world.collect()

		server:enqueue(1)
		server:enqueue(2)
		world.tick(1)
		equal("matched", #matches, 1)

		local map = Muster.internal.Lanes.name(server._settings, "all", 1, 0)
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
		equal("the count is still what was asked for", server._engine._scaler:current("all").count, 2)
	end

	Harness.suite("survives a broken lane record")
	do
		-- Garbage or an outage must not take the queue down; it falls back to
		-- what it last saw.
		local world = Harness.world({ size = 2 })
		local server = world.server("A")
		local matches = world.collect()

		setLaneState(server, { count = "not a number", previous = {}, changedAt = "nope" })
		world.advance(Muster.Defaults.LANE_STATE_REFRESH + 1)

		equal("it falls back to a sane count", server._engine._scaler:current("all").count, 1)

		world.store:failNext("get", 3)
		server:enqueue(1)
		server:enqueue(2)
		world.tick(2, 2)
		equal("and still matches", #matches, 1)
	end
end
