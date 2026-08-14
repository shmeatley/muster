--!nocheck

-- The finalize hook: what reaches the envelope, and what happens when the hook
-- fails, stalls, over-runs its budget, or loses the lease while it yields.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal

return function()
	local Muster = Harness.muster()

	Harness.suite("decoration")
	do
		local world = Harness.world({
			size = 2,
			config = {
				finalize = function(match)
					return {
						accessCode = `code-{match.matchId}`,
						map = "canyon",
						killer = match.members[1].userId,
					}
				end,
			},
		})
		local a = world.server("A")
		local b = world.server("B")
		local matches = world.collect()

		a:enqueue(1)
		b:enqueue(2)
		world.tick(1)

		equal("both servers were told", #matches, 2)
		equal("the decoration is on the envelope", matches[1].data.map, "canyon")
		equal("including generated values", matches[1].data.accessCode, `code-{matches[1].matchId}`)
		check("the killer is one of the players", matches[1].data.killer ~= nil)

		-- The remote server gets the identical decoration, which is the whole
		-- point: it can teleport without asking anyone anything.
		equal("the remote server got it too", matches[2].data.accessCode, matches[1].data.accessCode)
		equal("byte for byte", matches[2].data.map, "canyon")
	end

	Harness.suite("hook failure")
	do
		local attempts = 0
		local world = Harness.world({
			size = 2,
			config = {
				finalize = function()
					attempts += 1
					if attempts == 1 then
						error("reserve server exploded")
					end
					return { accessCode = "second-time-lucky" }
				end,
				onAbort = function() end,
			},
		})
		local server = world.server("A")
		local matches = world.collect()
		local aborts = {}
		server.aborted:connect(function(context)
			table.insert(aborts, context)
		end)

		local first = Muster.Result.unwrap(server:enqueue(1))
		local second = Muster.Result.unwrap(server:enqueue(2))

		world.tick(1)
		equal("no match was delivered", #matches, 0)
		equal("the abort was reported once", #aborts, 1)
		equal("with the right reason", aborts[1].reason, "FinalizerError")
		check("and the hook's message", string.find(aborts[1].message, "exploded", 1, true) ~= nil, aborts[1].message)

		-- Both players must be back in the queue, not stranded mid-claim.
		equal("the first player is queued again", server:getStatus(first.id).value.state, "Queued")
		equal("and so is the second", server:getStatus(second.id).value.state, "Queued")

		-- The retry is a genuinely new match, which is exactly why consumers
		-- must deduplicate on matchId rather than on the player set.
		world.advance(3)
		world.tick(1)
		equal("the retry succeeds", #matches, 1)
		equal("with the second decoration", matches[1].data.accessCode, "second-time-lucky")
		equal("the hook ran twice for the same players", attempts, 2)
		check("under a different matchId", matches[1].matchId ~= aborts[1].matchId)
	end

	Harness.suite("hook timeout")
	do
		local world = Harness.world({ size = 2 })
		local reached = false
		local server = world.server("A", {
			finalizeTimeout = 4,
			-- A hook that never completes: the thread is simply never run.
			spawn = function() end,
			-- Sleeping has to move the clock, or the deadline never arrives.
			sleep = function(seconds)
				world.advance(seconds)
			end,
			finalize = function()
				reached = true
				return {}
			end,
			onAbort = function() end,
		})
		local matches = world.collect()
		local aborts = {}
		server.aborted:connect(function(context)
			table.insert(aborts, context)
		end)

		local ticket = Muster.Result.unwrap(server:enqueue(1))
		server:enqueue(2)
		world.tick(1)

		check("the hook body never ran", not reached)
		equal("no match was delivered", #matches, 0)
		equal("it timed out", aborts[1].reason, "FinalizerTimeout")
		equal("and the players went back in the queue", server:getStatus(ticket.id).value.state, "Queued")
	end

	Harness.suite("oversized decoration")
	do
		local world = Harness.world({
			size = 2,
			config = {
				maxMatchDataBytes = 256,
				finalize = function()
					return { blob = string.rep("x", 4000) }
				end,
				onAbort = function() end,
			},
		})
		local server = world.server("A")
		local matches = world.collect()
		local aborts = {}
		server.aborted:connect(function(context)
			table.insert(aborts, context)
		end)

		local ticket = Muster.Result.unwrap(server:enqueue(1))
		server:enqueue(2)
		world.tick(1)

		equal("nothing was delivered", #matches, 0)
		equal("rejected for size", aborts[1].reason, "FinalizerTooLarge")
		check("the offending value is handed back", aborts[1].data ~= nil)
		equal("players are requeued", server:getStatus(ticket.id).value.state, "Queued")
	end

	Harness.suite("lease lost mid-yield")
	do
		-- The fence that a naive implementation gets wrong. The hook yields, the
		-- lease times out, another server takes the lane, and this server must
		-- not be able to commit anyway.
		local world = Harness.world({ size = 2 })
		local stealer = nil
		local server
		server = world.server("A", {
			finalize = function()
				-- Time passes inside the hook, exactly as a slow web call would
				-- make it. The lease expires while we are in here.
				world.advance(Muster.Defaults.LEASE_DURATION + 1)
				stealer:acquire("all:00")
				return { accessCode = "never-delivered" }
			end,
			onAbort = function() end,
		})
		stealer = Muster.internal.LeaseManager.new(world.store, server._settings.keys.leases, "B", {
			clock = world.clock,
		})

		local matches = world.collect()
		local aborts = {}
		server.aborted:connect(function(context)
			table.insert(aborts, context)
		end)

		local ticket = Muster.Result.unwrap(server:enqueue(1))
		server:enqueue(2)
		world.tick(1)

		equal("the match was not committed", #matches, 0)
		equal("the fence caught it", aborts[1].reason, "LeaseLost")
		check("the hook's work is reported so it can be released", aborts[1].data ~= nil)
		equal("and players are back in the queue", server:getStatus(ticket.id).value.state, "Queued")

		local record = select(2, world.store:get(server._settings.keys.matches, aborts[1].matchId))
		equal("the match record is aborted, not ready", record.state, "Aborted")
	end

	Harness.suite("exactly once per match")
	do
		local calls = {}
		local world = Harness.world({
			size = 2,
			config = {
				finalize = function(match)
					calls[match.matchId] = (calls[match.matchId] or 0) + 1
					return { at = match.createdAt }
				end,
			},
		})
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

		-- A scan reads a bounded batch, so twelve tickets take more than one
		-- pass, and passes are paced apart.
		world.tick(4, 2)

		local distinct = {}
		for _, match in matches do
			distinct[match.matchId] = true
		end
		local distinctCount = 0
		for _ in distinct do
			distinctCount += 1
		end

		local hookCount = 0
		local ranTwice = false
		for _, count in calls do
			hookCount += 1
			if count > 1 then
				ranTwice = true
			end
		end

		equal("every match formed", distinctCount, 6)
		check("no matchId ran the hook twice", not ranTwice)
		equal("one hook run per match", hookCount, distinctCount)
	end
end
