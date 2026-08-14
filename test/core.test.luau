--!nocheck

-- Pure units: hashing, lane assignment, config validation, and the serializer.

local Harness = require("./lib/harness")

local check = Harness.check
local equal = Harness.equal
local throws = Harness.throws

return function()
	local Muster = Harness.muster()

	Harness.suite("hash")
	do
		-- The published FNV-1a 32-bit vectors. If these drift, every server
		-- disagrees about lane assignment and tickets silently stop matching.
		equal("empty string", Muster.hash.string(""), 2166136261)
		equal("a", Muster.hash.string("a"), 0xe40c292c)
		equal("foobar", Muster.hash.string("foobar"), 0xbf9cf968)

		local buckets = {}
		for lane = 0, 63 do
			buckets[lane] = 0
		end
		for index = 1, 100000 do
			local lane = Muster.hash.partition(`ticket-{index}`, 64)
			buckets[lane] += 1
		end
		local lowest, highest = math.huge, 0
		for _, count in buckets do
			lowest = math.min(lowest, count)
			highest = math.max(highest, count)
		end
		check("64 lanes stay balanced", highest - lowest < 200, `spread was {highest - lowest}`)

		throws("partition rejects a zero count", function()
			Muster.hash.partition("x", 0)
		end, "positive integer")
	end

	Harness.suite("lanes")
	do
		local settings = Muster.Config.resolve({ name = "q", size = 2 })
		equal("one lane by default", settings.lanes, 1)

		local Lanes = Muster.internal.Lanes
		equal("every ticket lands in lane 0", Lanes.laneFor(settings, "anything"), 0)
		equal("descriptor names the map", Lanes.forTicket(settings, "all", "t1").map, "mu1:q:idx:all:00")

		local sharded = Muster.Config.resolve({ name = "q", size = 2, lanes = 8 })
		equal("eight lanes are enumerable", #Lanes.allFor(sharded, "all"), 8)
		local lane = Lanes.laneFor(sharded, "ticket-1")
		check("sharded lanes are in range", lane >= 0 and lane < 8, `got {lane}`)
	end

	Harness.suite("config")
	do
		local settings = Muster.Config.resolve({ name = "duels", size = 2 })
		equal("size shorthand fills min", settings.size.min, 2)
		equal("size shorthand fills target", settings.size.target, 2)
		equal("size shorthand fills max", settings.size.max, 2)
		equal("unrated by default", settings.rated, false)
		equal("broadcast on by default", settings.broadcast, true)
		check("a server id is always resolved", type(settings.serverId) == "string" and settings.serverId ~= "")

		local sized = Muster.Config.resolve({ name = "q", size = { min = 4, max = 8 } })
		equal("target defaults to max", sized.size.target, 8)

		local _, problem = Muster.Config.resolve({ name = "q", size = { min = 8, target = 2, max = 4 } })
		check("rejects min > target", problem ~= nil and string.find(problem, "min <= target") ~= nil, problem)

		local _, nameProblem = Muster.Config.resolve({ name = "has spaces", size = 2 })
		check("rejects an unusable name", nameProblem ~= nil, nameProblem)

		local _, longProblem = Muster.Config.resolve({ name = string.rep("a", 40), size = 2 })
		check("rejects an over-long name", longProblem ~= nil, longProblem)

		local _, timeoutProblem =
			Muster.Config.resolve({ name = "q", size = 2, finalize = print, finalizeTimeout = 60 })
		check("rejects an over-long finalize timeout", timeoutProblem ~= nil, timeoutProblem)

		local _, abortProblem = Muster.Config.resolve({ name = "q", size = 2, onAbort = print })
		check("rejects onAbort without finalize", abortProblem ~= nil, abortProblem)

		local withHook = Muster.Config.resolve({ name = "q", size = 2, finalize = print, finalizeTimeout = 5 })
		equal("claim window covers the hook", withHook.claimDuration, Muster.Defaults.CLAIM_DURATION + 5)
		local withoutHook = Muster.Config.resolve({ name = "q", size = 2 })
		equal("claim window stays tight without a hook", withoutHook.claimDuration, Muster.Defaults.CLAIM_DURATION)

		equal("short partitions pass through", Muster.Config.normalizePartition("EMEA"), "EMEA")
		local folded = Muster.Config.normalizePartition(string.rep("x", 80))
		check("long partitions fold to a hash", #folded <= 12 and string.sub(folded, 1, 1) == "h", folded)
		local awkward = Muster.Config.normalizePartition("has spaces")
		check("awkward partitions fold too", string.sub(awkward, 1, 1) == "h", awkward)
	end

	Harness.suite("serialize")
	do
		local Serialize = Muster.internal.Serialize

		local ok, copy = Serialize.validate({ accessCode = "abc", map = "dust", scores = { 1, 2, 3 } }, 4096)
		check("accepts plain data", ok)
		equal("copies strings", copy.accessCode, "abc")
		equal("copies nested arrays", copy.scores[3], 3)

		local source = { nested = { value = 1 } }
		local _, copied = Serialize.validate(source, 4096)
		source.nested.value = 99
		equal("the copy is deep", copied.nested.value, 1)

		local cyclic = {}
		cyclic.self = cyclic
		local cycleOk, _, cycleWhy = Serialize.validate(cyclic, 4096)
		check("rejects cycles", not cycleOk and string.find(cycleWhy, "cycle") ~= nil, cycleWhy)

		local fnOk, _, fnWhy = Serialize.validate({ callback = print }, 4096)
		check("rejects functions", not fnOk and string.find(fnWhy, "callback") ~= nil, fnWhy)

		local nanOk, _, nanWhy = Serialize.validate({ value = 0 / 0 }, 4096)
		check("rejects NaN", not nanOk and string.find(nanWhy, "finite") ~= nil, nanWhy)

		local infOk = Serialize.validate({ value = math.huge }, 4096)
		check("rejects infinity", not infOk)

		local mixedOk, _, mixedWhy = Serialize.validate({ 1, 2, named = true }, 4096)
		check("rejects mixed keys", not mixedOk and string.find(mixedWhy, "round-trip", 1, true) ~= nil, mixedWhy)

		local deep = {}
		local cursor = deep
		for _ = 1, 12 do
			cursor.child = {}
			cursor = cursor.child
		end
		local deepOk, _, deepWhy = Serialize.validate(deep, 4096)
		check("rejects excessive nesting", not deepOk and string.find(deepWhy, "nested") ~= nil, deepWhy)

		local bigOk, _, bigWhy = Serialize.validate({ blob = string.rep("x", 5000) }, 4096)
		check("rejects over-budget data", not bigOk and string.find(bigWhy, "budget") ~= nil, bigWhy)

		local emptyOk, emptyCopy = Serialize.validate(nil, 4096)
		check("nil becomes an empty table", emptyOk and next(emptyCopy) == nil)

		local scalarOk = Serialize.validate("just a string", 4096)
		check("rejects a non-table return", not scalarOk)

		check("size grows with content", Serialize.size({ a = string.rep("x", 100) }) > 100)
	end

	Harness.suite("matcher")
	do
		local Matcher = Muster.internal.Matcher

		local function candidate(id: string, size: number, rating: number?, queuedAt: number)
			return {
				ticketId = id,
				size = size,
				rating = rating,
				ratings = if rating then table.create(size, rating) else {},
				queuedAt = queuedAt,
			}
		end

		local unrated = Matcher.policy(Muster.Config.resolve({ name = "q", size = 2 }))
		local groups = Matcher.select({
			candidate("c", 1, nil, 30),
			candidate("a", 1, nil, 10),
			candidate("b", 1, nil, 20),
		}, 100, unrated)
		equal("unrated pairs everyone it can", #groups, 1)
		equal("oldest first", groups[1][1].ticketId, "a")
		equal("then next oldest", groups[1][2].ticketId, "b")

		local six = Matcher.policy(Muster.Config.resolve({ name = "q", size = { min = 2, target = 6, max = 6 } }))
		local parties = Matcher.select({
			candidate("duo", 2, nil, 10),
			candidate("quad", 4, nil, 20),
		}, 100, six)
		equal("a 2 and a 4 fill a 6", #parties, 1)
		equal("without splitting either", #parties[1], 2)

		-- 5 + 2 overflows a 6, and the only way to make it fit would be to split
		-- the party. Before the fallback opens up, that means nothing matches.
		local oversized = Matcher.select({
			candidate("five", 5, nil, 10),
			candidate("duo", 2, nil, 10),
		}, 15, six)
		equal("a party is never split to fill a match", #oversized, 0)

		-- Once the fallback opens, both are individually large enough to play,
		-- and they go as two matches rather than one broken-up one.
		local relaxed = Matcher.select({
			candidate("five", 5, nil, 10),
			candidate("duo", 2, nil, 10),
		}, 100, six)
		equal("they settle as separate matches", #relaxed, 2)
		local fiveGroup = nil
		for _, group in relaxed do
			if group[1].ticketId == "five" then
				fiveGroup = group
			end
		end
		check("the party of five is still there", fiveGroup ~= nil)
		equal("alone in its match", #fiveGroup, 1)
		equal("and still five players", fiveGroup[1].size, 5)

		local waiting = Matcher.select({
			candidate("a", 1, nil, 90),
			candidate("b", 1, nil, 90),
		}, 95, six)
		equal("below target waits for the fallback", #waiting, 0)
		local settled = Matcher.select({
			candidate("a", 1, nil, 50),
			candidate("b", 1, nil, 50),
		}, 100, six)
		equal("below target settles after it", #settled, 1)

		local rated = Matcher.policy(Muster.Config.resolve({
			name = "q",
			size = 2,
			rating = { window = 100, relax = 0, unbounded = 1e9 },
		}))
		local apart = Matcher.select({
			candidate("low", 1, 1000, 100),
			candidate("high", 1, 2000, 100),
		}, 100, rated)
		equal("a wide gap does not match", #apart, 0)

		local together = Matcher.select({
			candidate("low", 1, 1000, 100),
			candidate("close", 1, 1050, 100),
		}, 100, rated)
		equal("a narrow gap matches", #together, 1)

		-- The outlier anchors first, fails, and must not consume or block the
		-- compatible pair sitting behind it.
		local blocked = Matcher.select({
			candidate("outlier", 1, 4000, 10),
			candidate("a", 1, 1000, 50),
			candidate("b", 1, 1010, 50),
		}, 60, rated)
		equal("an outlier does not block others", #blocked, 1)
		equal("the compatible pair still matches", blocked[1][1].ticketId, "a")

		local widening = Matcher.policy(Muster.Config.resolve({
			name = "q",
			size = 2,
			rating = { window = 100, relax = 100, unbounded = 1e9 },
		}))
		local patient = Matcher.select({
			candidate("low", 1, 1000, 0),
			candidate("high", 1, 1400, 0),
		}, 5, widening)
		equal("the window widens with the wait", #patient, 1)
	end
end
