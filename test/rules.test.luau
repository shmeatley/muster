--!nocheck
local Harness = require("./lib/harness")
local check, equal = Harness.check, Harness.equal

return function()
	local Muster = Harness.muster()
	local Matcher = Muster.internal.Matcher
	local function policy(rules, size, extra)
		local config = extra or {}
		config.name, config.size, config.rules = "rules", size or 2, rules
		return Matcher.policy(assert(Muster.Config.resolve(config)))
	end
	local function candidate(id, age, region, verified, queuedAt)
		local attributes = { Age = age, Region = region, IsVerified = verified }
		return { ticketId = id, size = 1, ratings = {}, queuedAt = queuedAt or 0, attributes = { attributes } }
	end
	local rules = {
		Age = {
			type = "number",
			compare = "distance",
			limit = {
				{ after = 0, value = 2 },
				{ after = 10, value = 5 },
			},
			prefer = "closer",
		},
		Region = {
			type = "number",
			compare = "distance",
			limit = {
				{ after = 0, value = 0 },
				{ after = 20, value = 1 },
			},
		},
		IsVerified = { type = "boolean", compare = "equal" },
	}
	local settings = assert(Muster.Config.resolve({ name = "rules", size = 2, rules = rules }))
	local function select(candidates, now, selectedPolicy)
		for _, c in candidates do
			c.ruleKey = settings.ruleKey
		end
		return Matcher.select(candidates, now, selectedPolicy or Matcher.policy(settings))
	end

	Harness.suite("independent attribute relaxation")
	equal("age starts narrow", #select({ candidate("a", 20, 1, true), candidate("b", 24, 1, true) }, 0), 0)
	equal("age widens at boundary", #select({ candidate("a", 20, 1, true), candidate("b", 24, 1, true) }, 10), 1)
	equal("region remains narrow", #select({ candidate("a", 20, 1, true), candidate("b", 24, 2, true) }, 10), 0)
	equal("region widens separately", #select({ candidate("a", 20, 1, true), candidate("b", 24, 2, true) }, 20), 1)
	equal("boolean never relaxes", #select({ candidate("a", 20, 1, true), candidate("b", 24, 2, false) }, 1000), 0)
	equal(
		"new player retains narrow window",
		#select({ candidate("a", 20, 1, true), candidate("b", 24, 1, true, 10) }, 10),
		0
	)
	equal("both eventually accept", #select({ candidate("a", 20, 1, true), candidate("b", 24, 1, true, 10) }, 20), 1)

	Harness.suite("all-member constraints and preferences")
	local three = policy(rules, 3)
	equal(
		"anchor star is not a compatible group",
		#select({ candidate("a", 20, 1, true), candidate("b", 18, 1, true), candidate("c", 22, 1, true) }, 0, three),
		0
	)
	local alternative = select({
		candidate("a", 20, 1, true),
		candidate("b", 18, 1, true),
		candidate("c", 22, 1, true),
		candidate("d", 22, 1, true),
	}, 0, three)
	equal("retains alternative states to fill match", #alternative, 1)
	check("alternative excludes incompatible early player", alternative[1][2].ticketId ~= "b")
	local preferred =
		select({ candidate("a", 20, 1, true), candidate("b", 22, 1, true), candidate("c", 20, 1, true) }, 0)
	equal("preference considers candidates after first full combination", preferred[1][2].ticketId, "c")
	local party = candidate("p", 20, 1, true)
	party.size = 2
	table.insert(party.attributes, { Age = 30, Region = 1, IsVerified = true })
	equal("internally incompatible party cannot form even a full match", #select({ party }, 100), 0)
	party.attributes[2].Age = 21
	equal("compatible party can fill target alone", #select({ party }, 0), 1)
	local missing = candidate("missing", 20, 1, true)
	missing.attributes = nil
	equal("missing indexed attributes fail closed", #select({ missing, candidate("a", 20, 1, true) }, 0), 0)

	Harness.suite("categorical and soft rules")
	local categories = {
		Region = {
			type = "string",
			compare = "distance",
			distances = {
				NA = { EU = 80 },
				EU = { NA = 80 },
				AS = {},
			},
			limit = { { after = 0, value = 0 }, { after = 30, value = 100 } },
		},
	}
	local function categorySelect(a, b, now)
		local config = assert(Muster.Config.resolve({ name = "cats", size = 2, rules = categories }))
		local x, y = candidate("a", 0, 0, false), candidate("b", 0, 0, false)
		x.attributes, y.attributes = { { Region = a } }, { { Region = b } }
		x.ruleKey, y.ruleKey = config.ruleKey, config.ruleKey
		return Matcher.select({ x, y }, now, Matcher.policy(config))
	end
	equal("string categories initially separated", #categorySelect("NA", "EU", 0), 0)
	equal("cost matrix widens", #categorySelect("NA", "EU", 30), 1)
	equal("absent matrix edge stays forbidden", #categorySelect("NA", "AS", 100), 0)
	categories.Region = { type = "string", compare = "equal", relaxAfter = 10 }
	equal("equality can relax", #categorySelect("NA", "EU", 10), 1)
	categories.Region = { type = "string", compare = "equal", mode = "preference" }
	equal("soft equality never rejects", #categorySelect("NA", "EU", 0), 1)

	Harness.suite("rule validation")
	local invalid = {
		{},
		{ A = { type = "number", compare = "distance", limit = -1 } },
		{ A = { type = "number", compare = "distance", limit = { { after = 1, value = 1 } } } },
		{
			A = {
				type = "number",
				compare = "distance",
				limit = { { after = 0, value = 2 }, { after = 2, value = 1 } },
			},
		},
		{ A = { type = "boolean", compare = "distance" } },
		{ A = { type = "boolean", compare = "required", value = false, relaxAfter = 10 } },
		{ A = { type = "string", compare = "distance", distances = { NA = { EU = 10 }, EU = {} } } },
		{ A = { type = "number", compare = "equal", relaxation = 5 } },
		{ A = { type = "number", compare = "equal", weight = 0 / 0 } },
	}
	for index, value in invalid do
		local result = Muster.Config.resolve({ name = "bad", size = 2, rules = value })
		equal(`rejects invalid rules {index}`, result, nil)
	end
	for _, extra in { { lanes = 2 }, { matcher = {} }, { layout = {} } } do
		extra.name, extra.size, extra.rules = "bad", 2, rules
		equal("rejects unsupported rule configuration", Muster.Config.resolve(extra), nil)
	end
	equal("auto resolves to fixed single lane", settings.laneMode, "fixed")
	equal("single discovery lane", settings.lanes, 1)
	local changed = table.clone(rules)
	changed.IsVerified = { type = "boolean", compare = "equal", relaxAfter = 10 }
	local changedSettings = assert(Muster.Config.resolve({ name = "rules", size = 2, rules = changed }))
	check("rule changes isolate discovery indexes", settings.indexInfix ~= changedSettings.indexInfix)
	check("legacy discovery indexes stay separate", settings.indexInfix ~= nil)
	local reordered = { IsVerified = rules.IsVerified, Region = rules.Region, Age = rules.Age }
	equal(
		"rule key independent of insertion order",
		assert(Muster.Config.resolve({ name = "rules", size = 2, rules = reordered })).ruleKey,
		settings.ruleKey
	)

	Harness.suite("attribute enqueue and distributed delivery")
	local world = Harness.world({ config = { rules = rules } })
	local a, b = world.server("A"), world.server("B")
	local matches = world.collect()
	local attrs = { Age = 20, Region = 1, IsVerified = false }
	check("attributes enqueue", a:enqueue(1, { attributes = attrs }).ok)
	attrs.Age = 90
	check("second server enqueues", b:enqueue(2, { attributes = { Age = 21, Region = 1, IsVerified = false } }).ok)
	world.tick()
	equal("both origins receive match", #matches, 2)
	equal("matching snapshot copied at enqueue", matches[1].members[1].attributes.Age, 20)
	equal("false survives snapshot", matches[1].members[1].attributes.IsVerified, false)
	local _, mutateError = pcall(function()
		matches[1].members[1].attributes.Age = 99
	end)
	check("local matching snapshots are immutable", mutateError ~= nil)
	local bad = a:enqueue(3, { attributes = { Age = "20", Region = 1, IsVerified = true } })
	equal("bad type returns InvalidAttributes", bad.error.code, "InvalidAttributes")
	equal("missing attributes rejected", a:enqueue(3).error.code, "InvalidAttributes")
	check(
		"failed validation did not reserve user",
		a:enqueue(3, { attributes = { Age = 20, Region = 1, IsVerified = true } }).ok
	)
	local plain = Harness.world().server("plain")
	equal("attributes require rules", plain:enqueue(9, { attributes = attrs }).error.code, "InvalidAttributes")
	local requiredWorld =
		Harness.world({ config = { rules = { Flag = { type = "boolean", compare = "required", value = false } } } })
	local required = requiredWorld.server("required")
	equal(
		"required false rejects true",
		required:enqueue(1, { attributes = { Flag = true } }).error.code,
		"InvalidAttributes"
	)
	check("required false accepts false", required:enqueue(1, { attributes = { Flag = false } }).ok)
	local manyRules, largeAttributes = {}, {}
	for index = 1, 16 do
		manyRules[`Field{index}`] = { type = "string", compare = "equal" }
		largeAttributes[`Field{index}`] = string.rep("x", 128)
	end
	local budgetWorld = Harness.world({ size = 8, config = { rules = manyRules } })
	equal(
		"reserves attribute space across every match seat",
		budgetWorld.server("budget"):enqueue(8, { attributes = largeAttributes }).error.code,
		"InvalidAttributes"
	)
	equal(
		"NaN attribute rejected",
		a:enqueue(4, { attributes = { Age = 0 / 0, Region = 1, IsVerified = true } }).error.code,
		"InvalidAttributes"
	)
	equal(
		"unknown attribute rejected",
		a:enqueue(4, { attributes = { Age = 20, Region = 1, IsVerified = true, Other = 1 } }).error.code,
		"InvalidAttributes"
	)

	Harness.suite("legacy workers cannot consume rule tickets")
	local mixedWorld = Harness.world()
	local legacy, modern = mixedWorld.server("legacy"), mixedWorld.server("modern", { rules = rules })
	local mixedMatches = mixedWorld.collect()
	legacy:enqueue(1)
	modern:enqueue(2, { attributes = { Age = 20, Region = 1, IsVerified = true } })
	mixedWorld.tick()
	equal("legacy and rule tickets stay separate", #mixedMatches, 0)
	legacy:enqueue(3)
	modern:enqueue(4, { attributes = { Age = 20, Region = 1, IsVerified = true } })
	mixedWorld.tick()
	equal("both pools can make their own matches", #mixedMatches, 2)

	Harness.suite("group attributes and partitions")
	local groupsWorld = Harness.world({ config = { rules = rules } })
	local groupServer = groupsWorld.server("group")
	local groupMatches = groupsWorld.collect()
	check(
		"per-member group input",
		groupServer:enqueueGroup({ 10, 11 }, {
			attributes = {
				[10] = { Age = 20, Region = 1, IsVerified = true },
				[11] = { Age = 21, Region = 1, IsVerified = true },
			},
		}).ok
	)
	groupsWorld.tick()
	equal("whole group forms match", #groupMatches, 1)
	groupServer:enqueue(12, { partition = "one", attributes = { Age = 20, Region = 1, IsVerified = true } })
	groupServer:enqueue(13, { partition = "two", attributes = { Age = 20, Region = 1, IsVerified = true } })
	groupsWorld.tick(2, 5)
	equal("hard partitions remain isolated", #groupMatches, 1)

	Harness.suite("queued parties and authoritative validation")
	local partyWorld = Harness.world({ config = { rules = rules } })
	local leader, friend = partyWorld.server("leader"), partyWorld.server("friend")
	local party = Muster.Result.unwrap(leader.parties:create(50, "leader"))
	local invite = Muster.Result.unwrap(leader.parties:invite(50, 51))
	check("friend accepts invitation", friend.parties:acceptInvite(51, invite.id, "friend").ok)
	local failed =
		leader:enqueueParty(party.id, 50, { attributes = { [50] = { Age = 20, Region = 1, IsVerified = true } } })
	equal("party missing member attributes rejected", failed.error.code, "InvalidAttributes")
	equal("validation failure releases party lock", leader.parties:get(party.id).value.queue, nil)
	check(
		"party can retry with full snapshots",
		leader:enqueueParty(party.id, 50, {
			attributes = {
				[50] = { Age = 20, Region = 1, IsVerified = true },
				[51] = { Age = 21, Region = 1, IsVerified = true },
			},
		}).ok
	)
	local partyMatches = partyWorld.collect()
	partyWorld.tick()
	equal("cross-server party delivered to both origins", #partyMatches, 2)
	equal("party remains whole", partyMatches[1].size, 2)

	local staleWorld = Harness.world({ config = { rules = rules } })
	local staleServer = staleWorld.server("stale")
	local staleMatches = staleWorld.collect()
	local first =
		Muster.Result.unwrap(staleServer:enqueue(70, { attributes = { Age = 20, Region = 1, IsVerified = true } }))
	staleServer:enqueue(71, { attributes = { Age = 20, Region = 1, IsVerified = true } })
	staleWorld.store:update(staleServer._settings.keys.tickets, first.id, 180, function(ticket)
		-- Simulate an index that no longer reflects its authoritative record.
		ticket.members[1].attributes = { Age = 20, Region = 1, IsVerified = false }
		return ticket
	end)
	staleWorld.tick()
	equal("claimed snapshots are revalidated before delivery", #staleMatches, 0)
	equal("aborted claims return to queue", staleServer:getStatus(first.id).value.state, "Queued")

	Harness.suite("rules compose with ratings and fallback")
	local ratedSettings = assert(Muster.Config.resolve({
		name = "ratedRules",
		size = 2,
		rules = rules,
		rating = { window = 100, relax = 0, unbounded = 1000 },
	}))
	local low, high = candidate("low", 20, 1, true), candidate("high", 20, 1, true)
	low.rating, high.rating, low.ratings, high.ratings = 1000, 2000, { 1000 }, { 2000 }
	low.ruleKey, high.ruleKey = ratedSettings.ruleKey, ratedSettings.ruleKey
	equal("rating still gates rule groups", #Matcher.select({ low, high }, 0, Matcher.policy(ratedSettings)), 0)
	high.rating = 1050
	equal("rating and attributes both satisfied", #Matcher.select({ low, high }, 0, Matcher.policy(ratedSettings)), 1)
	local fallback = policy(rules, { min = 2, target = 4, max = 4 }, { fallbackAfter = 10 })
	equal(
		"rules wait for fallback",
		#select({ candidate("a", 20, 1, true), candidate("b", 21, 1, true) }, 0, fallback),
		0
	)
	equal(
		"compatible partial group after fallback",
		#select({ candidate("a", 20, 1, true), candidate("b", 21, 1, true) }, 10, fallback),
		1
	)
	equal(
		"fallback never bypasses boolean restriction",
		#select({ candidate("a", 20, 1, true), candidate("b", 21, 1, false) }, 100, fallback),
		0
	)

	Harness.suite("Quick Play bypasses attribute matching")
	local qpRules = table.clone(rules)
	qpRules.Flag = { type = "boolean", compare = "required", value = false }
	local qpWorld = Harness.world({ config = { rules = qpRules, quickPlay = true } })
	local host, guest = qpWorld.server("host"), qpWorld.server("guest")
	check("host listing", host.quickplay:host({ players = 0, capacity = 4, data = {} }).ok)
	local assignments = 0
	guest.quickPlayMatched:connect(function()
		assignments += 1
	end)
	check(
		"rule ticket can request Quick Play",
		guest:quickPlay(100, { attributes = { Age = 20, Region = 9, IsVerified = false, Flag = true } }).ok
	)
	qpWorld.tick()
	equal("backfill does not require a compatible queued opponent", assignments, 1)
end
