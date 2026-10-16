--!nocheck
-- Differential oracle: preserved pre-optimization sources, loaded in Lune's Luau sandbox.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Harness = require("../../test/lib/harness")
local M = Harness.muster()
local Rules = require("../../test/lib/load").new(".").resolve({ "src", "internal", "Rules" })
local pairComparisons, incrementalScores = 0, 0
local function baseline(path, replacements, ...)
	local source = fs.readFile(path)
	for from, to in replacements do
		source = source:gsub(from, to)
	end
	return luau.load(source, { debugName = path })(...)
end
local oldRules = baseline("bench/optimization/Rules.baseline.luau", {
	["local Serialize = require%(script.Parent.Serialize%)"] = "local Serialize, Hash = ...",
	["local Hash = require%(script.Parent.Parent.Hash%)"] = "",
}, M.internal.Serialize, M.Hash)
local oldMatcher = baseline("bench/optimization/Matcher.baseline.luau", {
	["local Defaults = require%(script.Parent.Parent.Defaults%)"] = "local Defaults, Rules, Types = ...",
	["local Rules = require%(script.Parent.Rules%)"] = "",
	["local Types = require%(script.Parent.Parent.Types%)"] = "",
}, M.Defaults, oldRules, {})
local seed = 78591
local function random(n)
	seed = (seed * 48271) % 2147483647
	return seed % n + 1
end
local function signature(groups)
	local out = {}
	for _, group in groups do
		local ids = {}
		for _, candidate in group do
			table.insert(ids, candidate.ticketId)
		end
		table.insert(out, table.concat(ids, ","))
	end
	return table.concat(out, "|")
end
for trial = 1, 120 do
	local rules = {
		Number = {
			type = "number",
			compare = "distance",
			limit = { { after = 0, value = 3 }, { after = 10, value = 20 } },
			prefer = "closer",
			weight = 0.3,
		},
		Flag = { type = "boolean", compare = "equal", relaxAfter = 5, prefer = "equal", weight = 2 },
		Region = {
			type = "string",
			compare = "distance",
			limit = 3,
			distances = { A = { A = 0, B = 2, C = 7 }, B = { A = 2, B = 0, C = 3 }, C = { A = 7, B = 3, C = 0 } },
			mode = "preference",
			weight = 0.7,
		},
		Zero = { type = "number", compare = "distance", mode = "preference", weight = 0 },
	}
	if trial % 4 == 0 then
		rules.Number.prefer = nil
		rules.Flag.prefer = nil
		rules.Region = nil
	elseif trial % 3 == 0 then
		rules.Region = nil
	end
	local target = random(10) + 2
	local settings = assert(M.Config.resolve({
		name = "diff",
		size = { min = 2, target = target, max = target + 2 },
		fallbackAfter = 10,
		rules = rules,
	}))
	local candidates = {}
	for i = 1, random(16) + 6 do
		local attrs = {}
		local size = random(3)
		for _ = 1, size do
			table.insert(attrs, {
				Number = random(14),
				Flag = random(2) == 1,
				Region = ({ "A", "B", "C" })[random(3)],
				Zero = random(5),
			})
		end
		table.insert(candidates, {
			ticketId = string.format("%04d", i),
			size = size,
			queuedAt = 100 - random(20),
			ratings = {},
			ruleKey = settings.ruleKey,
			attributes = attrs,
		})
	end
	local prepared = Rules.preparePairs(settings.rules, candidates, 100, settings.ruleKey)
	for a, left in candidates do
		for b, right in candidates do
			local expected = oldRules.compatible(settings.rules, left, left, 100)
				and oldRules.compatible(settings.rules, right, right, 100)
				and oldRules.compatible(settings.rules, left, right, 100)
			assert(prepared(a, b) == expected, `prepared pair mismatch {trial}/{a}/{b}`)
			pairComparisons += 1
		end
	end
	local plan = Rules.prepareScore(settings.rules, candidates)
	local policy, oldPolicy = M.internal.Matcher.policy(settings), oldMatcher.policy(settings)
	for _ = 1, 20 do
		local indexes = {}
		for i = 1, #candidates do
			if random(2) == 1 then
				table.insert(indexes, i)
			end
		end
		local a, b = policy.score(candidates, indexes)
		local c, d = oldPolicy.score(candidates, indexes)
		assert(a == c and b == d, `score mismatch trial {trial}: {a}/{c}, {b}/{d}`)
		if plan and #indexes > 0 then
			local summary = plan.seed(indexes[1])
			local scratch = {}
			local primary = nil
			for position = 2, #indexes do
				primary = plan.extend(summary, indexes[position], scratch)
				summary = table.clone(scratch)
			end
			if primary ~= nil then
				assert(primary == a, `incremental score mismatch {trial}: {primary}/{a}`)
				incrementalScores += 1
			end
		end
	end
	for _, now in { 100, 120 } do
		assert(
			signature(M.internal.Matcher.select(candidates, now, policy))
				== signature(oldMatcher.select(candidates, now, oldPolicy)),
			`selection mismatch trial {trial}`
		)
	end
end
for _, count in { 8, 25, 50, 100 } do
	for _, target in { 8, 16, 32 } do
		for _, partySize in { 1, 2, 4 } do
			local settings = assert(M.Config.resolve({
				name = "dense",
				size = target,
				rules = { Age = { type = "number", compare = "distance", limit = 5, prefer = "closer" } },
			}))
			local candidates = {}
			for i = 1, count do
				local attributes = {}
				for member = 1, partySize do
					attributes[member] = { Age = 20 + (i + member) % 3 }
				end
				candidates[i] = {
					ticketId = string.format("%04d", i),
					size = partySize,
					queuedAt = 100,
					ratings = {},
					ruleKey = settings.ruleKey,
					attributes = attributes,
				}
			end
			assert(
				signature(M.internal.Matcher.select(candidates, 100, M.internal.Matcher.policy(settings)))
					== signature(oldMatcher.select(candidates, 100, oldMatcher.policy(settings))),
				`dense mismatch {count}/{target}/{partySize}`
			)
		end
	end
end
-- Unequal wait windows must constrain only cross-party distances: a wide
-- old party can accept a narrow fresh player at its midpoint.
do
	local settings = assert(M.Config.resolve({
		name = "edge",
		size = 3,
		rules = {
			Age = {
				type = "number",
				compare = "distance",
				limit = { { after = 0, value = 5 }, { after = 10, value = 10 } },
				prefer = "closer",
			},
		},
	}))
	local candidates = {
		{
			ticketId = "a",
			size = 2,
			queuedAt = 0,
			ratings = {},
			ruleKey = settings.ruleKey,
			attributes = {
				{ Age = 0 },
				{ Age = 10 },
			},
		},
		{
			ticketId = "b",
			size = 1,
			queuedAt = 20,
			ratings = {},
			ruleKey = settings.ruleKey,
			attributes = { { Age = 5 } },
		},
	}
	local prepared, universal = Rules.preparePairs(settings.rules, candidates, 20, settings.ruleKey)
	assert(prepared(1, 2) and not universal, "cross-party range must exclude old internal spread under fresh limit")
	assert(#M.internal.Matcher.select(candidates, 20, M.internal.Matcher.policy(settings)) == 1)
	candidates[2].attributes = nil
	assert(
		#M.internal.Matcher.select(candidates, 20, M.internal.Matcher.policy(settings)) == 0,
		"invalid ticket bypassed universal proof"
	)
	candidates[2].attributes = { { Age = 100 } }
	assert(
		#M.internal.Matcher.select(candidates, 20, M.internal.Matcher.policy(settings)) == 0,
		"scan summaries survived changed attributes"
	)
end
do
	local settings = assert(M.Config.resolve({
		name = "custom",
		size = 4,
		rules = { Age = { type = "number", compare = "distance", limit = 100, prefer = "closer" } },
	}))
	local candidates = {}
	for i = 1, 15 do
		candidates[i] = {
			ticketId = tostring(i),
			size = 1,
			queuedAt = 100,
			ratings = {},
			ruleKey = settings.ruleKey,
			attributes = {
				{ Age = i },
			},
		}
	end
	local policy = table.clone(M.internal.Matcher.policy(settings))
	local oldPolicy = table.clone(oldMatcher.policy(settings))
	local function customScore(list, indexes)
		local score = 0
		for _, index in indexes do
			score -= list[index].attributes[1].Age
		end
		return score, 0
	end
	policy.score, oldPolicy.score = customScore, customScore
	assert(
		signature(M.internal.Matcher.select(candidates, 100, policy))
			== signature(oldMatcher.select(candidates, 100, oldPolicy)),
		"custom decreasing score must bypass pruning"
	)
end
print(
	`Differential verification passed: 2400 exact scores, {incrementalScores} incremental scores, {pairComparisons} prepared pairs, and 276 exact match selections; edge cases passed`
)
