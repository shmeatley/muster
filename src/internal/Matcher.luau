--!strict

--[=[
	@class Matcher

	The grouping algorithm. It takes candidates, a policy and the current time;
	it does not read the store or clock itself. Tickets are never split.

	Candidates are visited oldest first, with ticket ID breaking ties. Without
	attribute rules, the subset-sum walk accepts the first target-sized group.
	It compares ratings against the anchor using the anchor's queue time.

	With attribute rules, the search keeps up to eight alternatives per size
	and considers all visible candidates for preferences. Every ticket must
	accept every other ticket, using each one's own wait, and a party's members
	must also be compatible internally. The search is bounded, so it can miss
	valid combinations; it does not find a global optimum.

	The rules path prepares compatibility summaries once per scan and updates
	numeric/equality preference scores incrementally. It skips infeasible anchors
	and proposals that cannot improve a full bucket. A scan-wide compatibility
	check can avoid repeated pair checks. Custom scorers and matrix preferences
	use general fallback paths where those shortcuts do not apply.

	Once the anchor reaches `fallbackAfter`, selection can accept the largest
	viable group from `maxSize` down to `minSize`. Fallback never disables rules.

	This module only sees the candidates discovery supplies. In particular,
	ordinary rule queues use one lane per partition and a 100-ticket scan budget.
	Built-in regions share that budget across regional lanes on fallback scans.
	Discovery alternates oldest-first scans with overlapping forward pages when
	needed. Selection cannot compare players in different windows unless they
	are brought into the same scan.
]=]

local Defaults = require(script.Parent.Parent.Defaults)
local Rules = require(script.Parent.Rules)
local Types = require(script.Parent.Parent.Types)

type Candidate = Types.Candidate
type MatcherPolicy = Types.MatcherPolicy

local Matcher = {}
-- Only scorers created here have the nondecreasing rule-penalty guarantee.
-- Weak keys avoid retaining policies after their queues are destroyed.
local preparedPairs: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
local monotoneScores: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

--[=[
	The default scoring function: rating spread across individual members, then
	total queue time. Both are minimised, compared in that order.

	Spread is measured per member rather than per ticket, so a group with a wide
	internal skill gap is penalised accordingly.

	Returns a spread of 0 when no candidate carries a rating, leaving queue time
	as the whole ordering, which is the behaviour an unrated queue wants.

	@within Matcher
]=]
function Matcher.spreadScore(candidates: { Candidate }, indexes: { number }): (number, number)
	local minimum = math.huge
	local maximum = -math.huge
	local queuedTotal = 0
	local seen = false

	for _, index in indexes do
		local candidate = candidates[index]
		for _, rating in candidate.ratings do
			minimum = math.min(minimum, rating)
			maximum = math.max(maximum, rating)
			seen = true
		end
		queuedTotal += candidate.queuedAt
	end

	return (if seen then maximum - minimum else 0), queuedTotal
end

--[=[
	Builds the [MatcherPolicy] a resolved config implies: a widening rating
	window for ratings, plus all-member attribute checks and preference scoring
	when `rules` is configured. Without either, compatibility is unconditional.

	@within Matcher
]=]
function Matcher.policy(settings: any): MatcherPolicy
	local rating = settings.rating

	local compatible: (Candidate, Candidate, number) -> boolean
	if rating == nil then
		compatible = function(_anchor: Candidate, _candidate: Candidate, _waitSeconds: number): boolean
			return true
		end
	else
		compatible = function(anchor: Candidate, candidate: Candidate, waitSeconds: number): boolean
			local window = Defaults.ratingWindow(rating, waitSeconds)
			if window == math.huge then
				return true
			end
			return math.abs((candidate.rating or 0) - (anchor.rating or 0)) <= window
		end
	end

	local score = if settings.rules then Rules.scorer(settings.rules) else Matcher.spreadScore
	if settings.rules then
		monotoneScores[score] = settings.rules
	end
	local pairCompatible = nil
	if settings.rules then
		pairCompatible = function(a: Candidate, b: Candidate, now: number): boolean
			return a.ruleKey == settings.ruleKey
				and b.ruleKey == settings.ruleKey
				and Rules.compatible(settings.rules, a, b, now)
		end
		preparedPairs[pairCompatible] = { rules = settings.rules, ruleKey = settings.ruleKey }
	end
	return table.freeze({
		minSize = settings.size.min,
		targetSize = settings.size.target,
		maxSize = settings.size.max,
		fallbackAfter = settings.fallbackAfter,
		compatible = compatible,
		pairCompatible = pairCompatible,
		score = score,
	})
end

-- Each reachable total size keeps its best combination alongside that
-- combination's already-computed score. Comparisons reuse that score instead
-- of rescoring the retained combination.
type State = { indexes: { number }, spread: number, queued: number, summary: any? }

-- Compare an optimistic extension against the worst retained state without
-- copying indexes or scoring it. Rule penalties can only increase as a group
-- grows. Queue totals and lexicographic indexes have their exact final values.
local function canImprove(state: State, index: number, queued: number, worst: State, primary: number?): boolean
	local spread = primary or state.spread
	if spread ~= worst.spread then
		return spread < worst.spread
	end
	if queued ~= worst.queued then
		return queued < worst.queued
	end
	local indexes, other = state.indexes, worst.indexes
	local length = #indexes + 1
	for i = 1, math.min(length, #other) do
		local value = if i == length then index else indexes[i]
		if value ~= other[i] then
			return value < other[i]
		end
	end
	return length < #other
end

local function extend(state: State, index: number): { number }
	local result = table.create(#state.indexes + 1)
	table.move(state.indexes, 1, #state.indexes, 1, result)
	result[#state.indexes + 1] = index
	return result
end

local function chooseForAnchor(
	candidates: { Candidate },
	anchorIndex: number,
	used: { [number]: boolean },
	now: number,
	policy: MatcherPolicy
): { number }?
	local anchor = candidates[anchorIndex]
	local waitSeconds = math.max(0, now - anchor.queuedAt)

	local anchorIndexes = { anchorIndex }
	local anchorSpread, anchorQueued = policy.score(candidates, anchorIndexes)
	local states: { [number]: State } = {
		[anchor.size] = { indexes = anchorIndexes, spread = anchorSpread, queued = anchorQueued },
	}

	for index, candidate in candidates do
		if index == anchorIndex or used[index] or not policy.compatible(anchor, candidate, waitSeconds) then
			continue
		end

		local snapshot = table.clone(states)
		for size, state in snapshot do
			local nextSize = size + candidate.size
			if nextSize > policy.maxSize then
				continue
			end
			local proposed = extend(state, index)
			local spread, queued = policy.score(candidates, proposed)
			local current = states[nextSize]
			if current == nil or spread < current.spread or (spread == current.spread and queued < current.queued) then
				states[nextSize] = { indexes = proposed, spread = spread, queued = queued }
			end
		end

		-- Stop at the first full match. See the note on this class: candidates
		-- arrive oldest-first, so this favours the longest wait, and every
		-- further candidate would cost another clone of every state.
		if states[policy.targetSize] then
			break
		end
	end

	local full = states[policy.targetSize]
	if full then
		return full.indexes
	end
	if waitSeconds < policy.fallbackAfter then
		return nil
	end
	for size = policy.maxSize, policy.minSize, -1 do
		local state = states[size]
		if state then
			return state.indexes
		end
	end
	return nil
end

-- Pairwise constraints invalidate the legacy subset-sum dominance assumption:
-- two equally sized groups can admit different future candidates. Retain a
-- bounded set of alternatives per size, ordered deterministically. This is a
-- beam search, not an exhaustive solver; it prioritizes oldest anchors and
-- evaluates all visible candidates to make soft preferences useful.
local function chooseWithRules(
	candidates: { Candidate },
	anchorIndex: number,
	used: { [number]: boolean },
	now: number,
	policy: MatcherPolicy,
	pair: (number, number) -> boolean,
	plan: any,
	universal: boolean
): { number }?
	local monotone = monotoneScores[policy.score]
	local anchor = candidates[anchorIndex]
	if not pair(anchorIndex, anchorIndex) then
		return nil
	end
	local waitSeconds = math.max(0, now - anchor.queuedAt)
	local eligible = {}
	local available = anchor.size
	for index, candidate in candidates do
		if
			index ~= anchorIndex
			and not used[index]
			and candidate.size + anchor.size <= policy.maxSize
			and pair(index, index)
			and policy.compatible(anchor, candidate, waitSeconds)
			and pair(anchorIndex, index)
		then
			eligible[#eligible + 1] = index
			available += candidate.size
		end
	end
	-- An upper bound, not a packing heuristic: rejecting here cannot discard
	-- a feasible match. Incompatible old anchors otherwise build whole beams
	-- even when their entire compatible neighborhood cannot fill a match.
	local required = if waitSeconds >= policy.fallbackAfter then policy.minSize else policy.targetSize
	if available < required then
		return nil
	end
	local indexes = { anchorIndex }
	local primary, secondary = policy.score(candidates, indexes)
	local states: { [number]: { State } } = {
		[anchor.size] = {
			{
				indexes = indexes,
				spread = primary,
				queued = secondary,
				summary = if plan then plan.seed(anchorIndex) else nil,
			},
		},
	}
	local scratch = {}
	local function better(a: State, b: State): boolean
		if a.spread ~= b.spread then
			return a.spread < b.spread
		end
		if a.queued ~= b.queued then
			return a.queued < b.queued
		end
		for i = 1, math.min(#a.indexes, #b.indexes) do
			if a.indexes[i] ~= b.indexes[i] then
				return a.indexes[i] < b.indexes[i]
			end
		end
		return #a.indexes < #b.indexes
	end
	for _, index in eligible do
		local candidate = candidates[index]
		-- Positive ticket sizes and descending traversal keep source buckets
		-- untouched until visited. No snapshot or destination copy is needed.
		for size = policy.maxSize - candidate.size, anchor.size, -1 do
			local bucket = states[size]
			if bucket == nil then
				continue
			end
			local nextSize = size + candidate.size
			local nextBucket = states[nextSize]
			if nextBucket == nil then
				nextBucket = {}
				states[nextSize] = nextBucket
			end
			for _, state in bucket do
				if
					monotone
					and #nextBucket == Rules.BEAM_WIDTH
					and not canImprove(state, index, state.queued + candidate.queuedAt, nextBucket[Rules.BEAM_WIDTH])
				then
					continue
				end
				local accepts = true
				if not universal then
					for _, memberIndex in state.indexes do
						if not pair(memberIndex, index) then
							accepts = false
							break
						end
					end
				end
				if accepts then
					local proposed, spread, queued
					if plan then
						spread = plan.extend(state.summary, index, scratch)
						queued = state.queued + candidate.queuedAt
						if
							#nextBucket == Rules.BEAM_WIDTH
							and not canImprove(state, index, queued, nextBucket[Rules.BEAM_WIDTH], spread)
						then
							continue
						end
						proposed = extend(state, index)
					else
						proposed = extend(state, index)
						spread, queued = policy.score(candidates, proposed)
					end
					local entry = {
						indexes = proposed,
						spread = spread,
						queued = queued,
						summary = if plan then table.clone(scratch) else nil,
					}
					local count = #nextBucket
					-- Maintain the same best eight states directly. Sorting up to
					-- sixteen entries after every extension repeats comparisons.
					if count < Rules.BEAM_WIDTH or better(entry, nextBucket[count]) then
						local position = math.min(count + 1, Rules.BEAM_WIDTH)
						while position > 1 and better(entry, nextBucket[position - 1]) do
							nextBucket[position] = nextBucket[position - 1]
							position -= 1
						end
						nextBucket[position] = entry
					end
				end
			end
		end
	end
	local full = states[policy.targetSize]
	if full and #full > 0 then
		return full[1].indexes
	end
	if waitSeconds >= policy.fallbackAfter then
		for size = policy.maxSize, policy.minSize, -1 do
			local bucket = states[size]
			if bucket and #bucket > 0 then
				return bucket[1].indexes
			end
		end
	end
	return nil
end

--[=[
	Groups candidates into matches.

	Returned groups are disjoint. A candidate that could not be placed is absent
	from the result and stays queued.

	@param now -- Wall-clock seconds, compared against each candidate's `queuedAt`.
	@within Matcher
]=]
function Matcher.select(candidates: { Candidate }, now: number, policy: MatcherPolicy): { { Candidate } }
	local ordered = table.clone(candidates)
	table.sort(ordered, function(left, right)
		if left.queuedAt == right.queuedAt then
			return left.ticketId < right.ticketId
		end
		return left.queuedAt < right.queuedAt
	end)

	local used: { [number]: boolean } = {}
	local matches = {}
	local preparation = if policy.pairCompatible then preparedPairs[policy.pairCompatible] else nil
	local prepared, universal = nil, false
	if preparation then
		prepared, universal = Rules.preparePairs(preparation.rules, ordered, now, preparation.ruleKey)
	end
	local scoreRules = monotoneScores[policy.score]
	local scorePlan = if scoreRules then Rules.prepareScore(scoreRules, ordered) else nil
	local pairCache: { [number]: { [number]: boolean } } = {}
	local function pair(a: number, b: number): boolean
		local low, high = math.min(a, b), math.max(a, b)
		local row = pairCache[low]
		if row == nil then
			row = {}
			pairCache[low] = row
		end
		if row[high] == nil then
			local check = policy.pairCompatible
			row[high] = if prepared
				then prepared(low, high)
				else check ~= nil and check(ordered[low], ordered[high], now)
		end
		return row[high]
	end

	for anchorIndex = 1, #ordered do
		if used[anchorIndex] then
			continue
		end
		local selected: { number }? = if policy.pairCompatible
			then chooseWithRules(ordered, anchorIndex, used, now, policy, pair, scorePlan, universal)
			else chooseForAnchor(ordered, anchorIndex, used, now, policy)
		if selected == nil then
			continue
		end
		local group = table.create(#selected)
		for _, index in selected do
			used[index] = true
			table.insert(group, ordered[index])
		end
		table.insert(matches, group)
	end

	return matches
end

return table.freeze(Matcher)
