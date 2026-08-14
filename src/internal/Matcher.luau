--!strict

--[=[
	@class Matcher

	The grouping algorithm.

	Pure: no store, no clock, no Roblox globals. It takes candidates and a policy
	and returns groups, so match quality can be tested without a queue.

	Candidates are sorted oldest first, ties broken by ticket id. Each unused
	candidate in turn becomes an *anchor*, and a subset-sum walk over ticket
	sizes looks for a combination that fills the match. Tickets are indivisible,
	so a group is never split across matches.

	A combination reaching `targetSize` is taken immediately. A smaller one is
	accepted only once the anchor has waited `fallbackAfter` seconds, and then
	the largest viable size down to `minSize` wins. Five players waiting for a
	six-player match therefore end up playing five-a-side.

	The rating window widens with the **anchor's** wait rather than each
	candidate's. Because anchors are visited oldest first, the longest-waiting
	player searches the widest, and an unmatched outlier does not block the
	compatible players behind it.

	:::note Which full match wins
	The walk stops at the first combination reaching `targetSize` rather than
	continuing to find a tighter one. Candidates are visited oldest first, so
	this favours the longest wait, and rating spread is already bounded by the
	window each candidate had to pass. Scanning the rest would cost a full pass
	per anchor on every scan of every lane.
	:::
]=]

local Defaults = require(script.Parent.Parent.Defaults)
local Types = require(script.Parent.Parent.Types)

type Candidate = Types.Candidate
type MatcherPolicy = Types.MatcherPolicy

local Matcher = {}

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
	window on a rated queue, or unconditional compatibility on an unrated one.

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

	return table.freeze({
		minSize = settings.size.min,
		targetSize = settings.size.target,
		maxSize = settings.size.max,
		fallbackAfter = settings.fallbackAfter,
		compatible = compatible,
		score = Matcher.spreadScore,
	})
end

-- Each reachable total size keeps its best combination alongside that
-- combination's already-computed score. Scoring on insert rather than on every
-- comparison is what keeps the walk linear in candidates instead of quadratic.
type State = { indexes: { number }, spread: number, queued: number }

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

	for anchorIndex = 1, #ordered do
		if used[anchorIndex] then
			continue
		end
		local selected = chooseForAnchor(ordered, anchorIndex, used, now, policy)
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
