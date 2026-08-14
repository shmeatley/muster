--!nocheck

-- Request cost. A package that quietly burns a game's MemoryStore quota is
-- worse than no package, so the cheap cases are pinned with numbers.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal

return function()
	local Muster = Harness.muster()

	Harness.suite("a two-player match")
	do
		-- The smallest possible useful workload, on the smallest possible game.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local b = world.server("B")
		local matches = world.collect()

		a:enqueue(1)
		b:enqueue(2)
		world.tick(1)

		equal("it matched", #matches, 2)
		local total = world.store:callCount()
		check("the whole thing costs under 30 requests", total < 30, `{total} requests`)
	end

	Harness.suite("idle servers")
	do
		-- A server with nothing queued must wind down to costing nothing. This
		-- is most servers, most of the time.
		local world = Harness.world({ size = 2 })
		local server = world.server("A")

		server:enqueue(1)
		world.tick(1)
		server:cancelForUser(1)

		-- A worker does not drop its lane the instant the queue empties; it
		-- scans a few more times in case something arrives, then hands it back.
		local windingDown = world.store:callCount()
		world.tick(6, 6)
		local spent = world.store:callCount() - windingDown
		check("winding down is cheap", spent < 20, `{spent} requests`)
		equal("the lane was released", server:health().ownedLanes, 0)

		local settled = world.store:callCount()
		world.tick(20, 30)
		equal("and then it costs nothing at all", world.store:callCount() - settled, 0)
	end

	Harness.suite("a waiting player")
	do
		-- One player waiting a full minute. The poll backoff is what keeps this
		-- from being sixty reads.
		local world = Harness.world({ size = 4 })
		local server = world.server("A")
		server:enqueue(1)

		local before = world.store:callCount("get")
		for _ = 1, 30 do
			world.advance(2)
			server:step()
		end
		local reads = world.store:callCount("get") - before

		check("a minute of waiting costs a handful of reads", reads < 40, `{reads} reads`)
	end

	Harness.suite("scale model")
	do
		-- A back-of-the-envelope check that the design survives a large game.
		-- Not a measurement, but it fails loudly if a record grows or the
		-- heartbeat rate changes without anyone thinking about the consequence.
		local Defaults = Muster.Defaults
		local ccu = 100000
		local queuedFraction = 0.2
		local tickets = ccu * queuedFraction

		-- Per queued ticket, per minute: heartbeats (ticket + index + one user
		-- reservation each), plus its own polling.
		local heartbeatsPerMinute = 60 / Defaults.TICKET_HEARTBEAT_INTERVAL
		local writesPerHeartbeat = 3
		local pollsPerMinute = 60 / Defaults.POLL_INTERVAL_MAX
		local perTicket = heartbeatsPerMinute * writesPerHeartbeat + pollsPerMinute
		local ticketRequests = tickets * perTicket

		-- Per lane worker: lease renewals and range scans.
		local lanes = 64
		local scansPerMinute = 60 / Defaults.MIN_SCAN_DELAY
		local renewalsPerMinute = 60 / Defaults.LEASE_RENEW_INTERVAL
		local workerRequests = lanes * (scansPerMinute + renewalsPerMinute)

		local projected = ticketRequests + workerRequests
		-- Roblox's published MemoryStore allowance for a universe of this size.
		local allowance = 1000 + 100 * ccu

		check(
			"projected load stays under half the allowance",
			projected < allowance / 2,
			`projected {math.floor(projected)} against an allowance of {allowance}`
		)

		-- And a ticket has to stay small enough that a lane's range read fits in
		-- one request rather than paging.
		local Serialize = Muster.internal.Serialize
		local candidate = {
			ticketId = string.rep("a", 36),
			partyId = string.rep("b", 36),
			size = 4,
			rating = 1234,
			ratings = { 1200, 1250, 1230, 1260 },
			queuedAt = 1700000000,
		}
		local size = Serialize.size(candidate)
		check("an index entry stays compact", size < 256, `{size} bytes`)
		check(
			"a full batch fits a range read",
			size * Defaults.MAX_BATCH_SIZE < 32 * 1024,
			`{size * Defaults.MAX_BATCH_SIZE} bytes`
		)
	end
end
