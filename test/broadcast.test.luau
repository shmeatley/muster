--!nocheck

-- Cross-server delivery: the doorbell, and the polling that makes it optional.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal

return function()
	local Muster = Harness.muster()

	Harness.suite("doorbell")
	do
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local b = world.server("B")

		local delivered = {}
		b.matched:connect(function(match)
			table.insert(delivered, match)
		end)

		a:enqueue(1)
		b:enqueue(2)
		world.tick(1)

		equal("the remote server heard immediately", #delivered, 1)
		equal("addressed to that server alone", world.bus:countFor("mu1:B"), 1)
		equal("and not to the committer", world.bus:countFor("mu1:A"), 0)
		check("small envelopes ride inside the message", world.bus.published[1].payload.envelope ~= nil)
		equal("with the whole envelope", world.bus.published[1].payload.envelope.size, 2)
	end

	Harness.suite("delivery without messaging")
	do
		-- The guarantee that matters: drop every message and the match still
		-- arrives, because MemoryStore is the source of truth.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local b = world.server("B")

		local delivered = {}
		b.matched:connect(function(match)
			table.insert(delivered, match)
		end)

		world.bus:dropNext(10)

		a:enqueue(1)
		b:enqueue(2)
		world.tick(1)
		equal("nothing arrived by message", #delivered, 0)

		-- B's first poll is due two seconds in.
		world.advance(2)
		world.tick(1)
		equal("the poll found it", #delivered, 1)
		equal("with the same match", delivered[1].size, 2)

		check("and delivery is now considered unreliable", not b:health().broadcastHealthy)
	end

	Harness.suite("poll backoff")
	do
		-- A waiting ticket must not poll hot. The interval doubles from 2s, so
		-- a minute of waiting costs a handful of reads, not sixty.
		local world = Harness.world({ size = 4 })
		local server = world.server("A")
		server:enqueue(1)

		local broadcaster = server._engine._broadcaster
		equal("first poll at 2s", broadcaster:pollInterval(0), 2)
		equal("then 4s", broadcaster:pollInterval(1), 4)
		equal("then 8s", broadcaster:pollInterval(2), 8)
		equal("then 16s", broadcaster:pollInterval(3), 16)
		equal("capped at 30s", broadcaster:pollInterval(4), 30)
		equal("and stays there", broadcaster:pollInterval(10), 30)

		-- When the doorbell looks broken, the cap tightens so a match is never
		-- more than a few seconds late.
		broadcaster:markUnhealthy()
		equal("an unhealthy cap is much tighter", broadcaster:pollInterval(10), 5)

		local before = world.store:callCount("get")
		for _ = 1, 30 do
			world.advance(2)
			server:step()
		end
		local polls = world.store:callCount("get") - before
		check("sixty seconds of waiting stays cheap", polls < 40, `{polls} reads`)
	end

	Harness.suite("large decorations")
	do
		-- Too big for a message, so the doorbell carries only the id and the
		-- receiver reads the ledger. Never an error, just one extra read.
		local world = Harness.world({
			size = 2,
			config = {
				finalize = function()
					return { blob = string.rep("x", 1200) }
				end,
			},
		})
		local a = world.server("A")
		local b = world.server("B")

		local delivered = {}
		b.matched:connect(function(match)
			table.insert(delivered, match)
		end)

		a:enqueue(1)
		b:enqueue(2)
		world.tick(1)

		equal("the message carries only the id", world.bus.published[1].payload.envelope, nil)
		equal("it still arrived", #delivered, 1)
		equal("with the full decoration", #delivered[1].data.blob, 1200)
	end

	Harness.suite("duplicate delivery")
	do
		local world = Harness.world({ size = 2 })
		local a = world.server("A")
		local b = world.server("B")

		local delivered = 0
		b.matched:connect(function()
			delivered += 1
		end)

		world.bus:duplicateNext(5)
		a:enqueue(1)
		b:enqueue(2)
		world.tick(1)

		equal("a message delivered twice fires once", delivered, 1)
		equal("even though it was received twice", b._engine._broadcaster.received, 2)

		-- And a later poll must not fire it a third time.
		world.advance(5)
		world.tick(1)
		equal("polling afterwards changes nothing", delivered, 1)
	end

	Harness.suite("broadcast disabled")
	do
		local world = Harness.world({ size = 2, config = { broadcast = false } })
		local a = world.server("A")
		local b = world.server("B")

		local delivered = {}
		b.matched:connect(function(match)
			table.insert(delivered, match)
		end)

		a:enqueue(1)
		b:enqueue(2)
		world.tick(1)
		equal("nothing was published", #world.bus.published, 0)

		world.advance(2)
		world.tick(1)
		equal("polling still delivers", #delivered, 1)
	end

	Harness.suite("unknown recipients")
	do
		-- A member on a server that is gone. The message goes nowhere and the
		-- surviving player is still delivered to.
		local world = Harness.world({ size = 2 })
		local a = world.server("A")

		local delivered = {}
		a.matched:connect(function(match)
			table.insert(delivered, match)
		end)

		a:enqueue(1)
		a:enqueue(2, { serverId = "GHOST" })
		world.tick(1)

		equal("the live server is told", #delivered, 1)
		equal("a message went to the dead one", world.bus:countFor("mu1:GHOST"), 1)
		equal("and nothing errored", #delivered[1].members, 2)
	end

	Harness.suite("dedupe is bounded")
	do
		-- A server can run for days. The set that makes delivery idempotent
		-- must not grow without limit.
		local world = Harness.world({ size = 2 })
		local server = world.server("A")
		local broadcaster = server._engine._broadcaster

		for index = 1, Muster.Defaults.SEEN_CAPACITY + 50 do
			broadcaster:accept(`match-{index}`)
		end

		equal("entries are capped", #broadcaster._seenOrder, Muster.Defaults.SEEN_CAPACITY)
		check("the oldest were evicted", broadcaster:accept("match-1"))
		check("the newest are still remembered", not broadcaster:accept(`match-{Muster.Defaults.SEEN_CAPACITY + 50}`))
	end
end
