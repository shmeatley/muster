--!strict

--[=[
	@class Engine

	The coordination layer behind [Matchmaker].

	Every server runs the same loop and acts as both producer and worker; there
	is no dedicated matchmaker server.

	### The loop

	1. **Enqueue.** Reserve each member's userId by compare-and-set so a player
	   cannot hold two tickets, write the ticket, then write a denormalized copy
	   into the lane's sorted map, keyed by queue time.
	2. **Acquire.** Take leases on the lanes this server's own tickets landed in.
	   The lease holder does the matching for that lane.
	3. **Scan.** Read the oldest candidates and run [Matcher] over them.
	4. **Commit.** Two-phase and fenced; see `_commit`.
	5. **Deliver.** Announce the match to the servers holding its players. Those
	   servers also poll, so delivery does not depend on the announcement.

	### Recovery

	State is recovered by expiry rather than cleanup:

	| Failure | Recovery |
	| --- | --- |
	| Worker dies holding a lease | The lease expires after 15 s and the next holder takes it at a higher epoch, which rejects any late write from the dead one |
	| Worker dies mid-commit | Claims expire; the next worker adopts the match if it committed, and aborts it if it did not |
	| Producer dies with tickets queued | Heartbeats stop and the tickets expire within `ticketExpiration` |
]=]

local Broadcaster = require(script.Parent.Broadcaster)
local Defaults = require(script.Parent.Parent.Defaults)
local Finalizer = require(script.Parent.Finalizer)
local LaneScaler = require(script.Parent.LaneScaler)
local Lanes = require(script.Parent.Lanes)
local LeaseManager = require(script.Parent.LeaseManager)
local Matcher = require(script.Parent.Matcher)
local Result = require(script.Parent.Parent.Result)
local Serialize = require(script.Parent.Serialize)
local Types = require(script.Parent.Parent.Types)

type Candidate = Types.Candidate
type Member = Types.Member

local ok = Result.ok
local err = Result.err

local Engine = {}
Engine.__index = Engine

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function candidateFor(ticket: any): Candidate
	local ratings = {}
	for _, member in ticket.members do
		if member.rating ~= nil then
			table.insert(ratings, member.rating)
		end
	end
	return {
		ticketId = ticket.id,
		partyId = ticket.partyId,
		size = ticket.size,
		rating = ticket.rating,
		ratings = ratings,
		queuedAt = ticket.queuedAt,
	}
end

--[=[
	@within Engine
	@private
]=]
function Engine.new(settings: any, deps: any)
	local self = setmetatable({
		_settings = settings,
		_store = deps.store,
		_getParties = deps.parties,
		-- Like `parties`, an accessor rather than an instance: the service is only
		-- built once a quickplay ticket or a hosted listing actually needs it.
		_getQuickPlay = deps.quickplay,
		_isThrottled = deps.isThrottled or function()
			return false
		end,

		_clock = settings.clock,
		_monotonic = settings.monotonic,
		_random = settings.random,
		_id = settings.id,
		_serverId = settings.serverId,

		_leases = LeaseManager.new(deps.store, settings.keys.leases, settings.serverId, {
			clock = settings.clock,
		}),
		_matcher = settings.matcher or Matcher.policy(settings),
		_layout = settings.layout or Lanes,
		_scaler = LaneScaler.new(settings, deps.store),

		_localTickets = {},
		_work = {},
		_owned = {},
		_running = false,

		onMatched = nil :: ((any, string) -> ())?,
		onAborted = nil :: ((any) -> ())?,
		onQueued = nil :: ((any) -> ())?,
		onCancelled = nil :: ((any) -> ())?,
		onQuickPlayMatched = nil :: ((any) -> ())?,
	}, Engine)

	-- The broadcaster has already deduplicated by the time it calls back, so
	-- delivery must not consume a second dedupe slot and drop the match.
	self._broadcaster = Broadcaster.new(settings, deps.messaging, function(envelope, source)
		self:_deliver(envelope, source, false)
	end, function(matchId)
		local success, record = self._store:get(settings.keys.matches, matchId, 3)
		if success and record ~= nil and record.state == "Ready" then
			return record.envelope
		end
		return nil
	end)

	return self
end

function Engine._log(self: any, level: string, message: string, fields: any?)
	if self._settings.logger then
		self._settings.logger(level, message, fields or {})
	end
end

function Engine._metric(self: any, name: string, value: number, tags: any?)
	if self._settings.metrics then
		self._settings.metrics(name, value, tags or {})
	end
end

--------------------------------------------------------------------------------
-- Enqueue
--------------------------------------------------------------------------------

function Engine._validateMembers(self: any, members: { Member }): any
	local settings = self._settings
	if #members < 1 or #members > settings.size.max then
		return err("InvalidPartySize", `A ticket must contain 1 to {settings.size.max} players, got {#members}`)
	end

	local seen = {}
	for _, member in members do
		-- Studio's local test clients get negative UserIds, so only zero and
		-- non-integers are rejected.
		if member.userId == 0 or not isFinite(member.userId) or member.userId ~= math.floor(member.userId) then
			return err("InvalidPartySize", `"{tostring(member.userId)}" is not a valid UserId`)
		end
		if seen[member.userId] then
			return err("DuplicateMember", `User {member.userId} appears in the ticket twice`)
		end
		if settings.rated and not isFinite(member.rating) then
			return err("MissingRating", `User {member.userId} has no rating, and this queue is rated`)
		end
		seen[member.userId] = true
	end
	return ok(true)
end

function Engine._reserveUsers(self: any, ticketId: string, members: { Member }): any
	local settings = self._settings
	local now = self._clock()
	local reserved = {}

	-- Sorted so concurrent multi-user reservations always take their locks in
	-- the same order and cannot deadlock against each other.
	local order = table.create(#members)
	for index, member in members do
		order[index] = member.userId
	end
	table.sort(order)

	for _, userId in order do
		local claimed = false
		local success, failure = self._store:update(
			settings.keys.users,
			tostring(userId),
			settings.ticketExpiration,
			function(current: any): any
				claimed = false
				if current ~= nil and current.expiresAt > now and current.ticketId ~= ticketId then
					return nil
				end
				claimed = true
				return { ticketId = ticketId, queue = settings.name, expiresAt = now + settings.ticketExpiration }
			end,
			3
		)

		if not success or not claimed then
			for _, done in reserved do
				self._store:remove(settings.keys.users, tostring(done))
			end
			if success then
				return err("AlreadyQueued", `User {userId} is already in a queue`)
			end
			return err("StoreUnavailable", tostring(failure), true)
		end
		table.insert(reserved, userId)
	end
	return ok(true)
end

function Engine._releaseUsers(self: any, ticket: any)
	local settings = self._settings
	for _, member in ticket.members do
		self._store:update(settings.keys.users, tostring(member.userId), 1, function(current: any): any
			if current ~= nil and current.ticketId == ticket.id then
				return { ticketId = "", queue = settings.name, expiresAt = 0 }
			end
			return nil
		end, 3)
	end
end

--[=[
	Writes a ticket and its lane index, rolling back on any failure so a partial
	enqueue never leaves a user reserved against a ticket that does not exist.

	@within Engine
	@private
]=]
function Engine.enqueue(self: any, request: any): any
	local settings = self._settings
	local members = request.members
	-- The caller may pre-mint the id when it needs to reference the ticket
	-- before it exists, as party queueing does to take its lock first.
	local ticketId = request.ticketId or self._id()

	local validation = self:_validateMembers(members)
	if not validation.ok then
		return validation
	end

	if request.metadata ~= nil then
		local sane, _, why = Serialize.validate(request.metadata, settings.maxMetadataBytes)
		if not sane then
			return err("InvalidMetadata", `metadata {why}`)
		end
	end

	local reservation = self:_reserveUsers(ticketId, members)
	if not reservation.ok then
		return reservation
	end

	local now = self._clock()
	local partition = request.partition or "all"

	local rating: number? = nil
	if settings.rated then
		local ratings = table.create(#members)
		for index, member in members do
			ratings[index] = member.rating
		end
		rating = settings.rating.aggregate(ratings)
	end

	-- Read the partition's current layout (cached) so this ticket lands where
	-- the rest of the fleet is looking. The rating has to be aggregated first:
	-- on a banded queue it is what picks the lane.
	local laneState = self._scaler:current(partition)
	local lane = self._layout.forTicket(
		settings,
		partition,
		laneState.layout,
		ticketId,
		rating,
		self._scaler:draining(laneState)
	)

	local ticket = {
		v = settings.version,
		id = ticketId,
		queue = settings.name,
		partition = partition,
		lane = lane.lane,
		-- Recorded, not recomputed later: the layout can change while this ticket
		-- is queued, and its index entry stays in the map it was written to.
		laneCount = lane.count,
		laneGeneration = lane.generation,
		partyId = request.partyId,
		leaderUserId = request.leaderUserId,
		members = members,
		size = #members,
		rating = rating,
		metadata = request.metadata,
		queuedAt = now,
		expiresAt = now + settings.ticketExpiration,
		state = "Queued",
		claim = nil,
		matchId = nil,
		-- Set only when true, so an ordinary ticket carries no extra bytes.
		quickPlay = if request.quickPlay then true else nil,
	}

	local stored, failure = self._store:set(settings.keys.tickets, ticketId, ticket, settings.ticketExpiration, 3)
	if not stored then
		self:_releaseUsers(ticket)
		return err("StoreUnavailable", tostring(failure), true)
	end

	local indexed, indexFailure =
		self._store:sortedSet(lane.map, ticketId, candidateFor(ticket), settings.indexExpiration, now, 3)
	if not indexed then
		self._store:remove(settings.keys.tickets, ticketId)
		self:_releaseUsers(ticket)
		return err("StoreUnavailable", tostring(indexFailure), true)
	end

	local mono = self._monotonic()
	self._localTickets[ticketId] = {
		ticket = ticket,
		lane = lane,
		polls = 0,
		nextPoll = mono + self._broadcaster:pollInterval(0),
		nextHeartbeat = mono + settings.heartbeatInterval,
		-- Zero, not an interval away: a quickplay ticket looks for a seat on the
		-- very next pass, which is usually the same one the caller is still in.
		nextQuickPlay = 0,
	}
	self._work[lane.key] = self._work[lane.key] or lane

	-- If we already work this lane, the new ticket may complete a match right
	-- now. Sitting out the rest of the scan delay would make a small queue feel
	-- laggy for no reason.
	local owned = self._owned[lane.key]
	if owned then
		owned.nextScan = mono
	end

	self:_metric("muster.enqueued", ticket.size, { queue = settings.name, partition = partition })
	self:_log("info", "ticket queued", {
		ticketId = ticketId,
		queue = settings.name,
		partition = partition,
		lane = lane.lane,
		size = ticket.size,
	})
	if self.onQueued then
		self.onQueued(ticket)
	end
	return ok(ticket)
end

--------------------------------------------------------------------------------
-- Local ticket upkeep
--------------------------------------------------------------------------------

function Engine._pollLocal(self: any, ticketId: string, localState: any, mono: number)
	if mono < localState.nextPoll then
		return
	end
	localState.polls += 1
	localState.nextPoll = mono + self._broadcaster:pollInterval(localState.polls)

	local success, ticket = self._store:get(self._settings.keys.tickets, ticketId, 5)
	if not success then
		return
	end

	if ticket == nil then
		self._localTickets[ticketId] = nil
		return
	end

	if ticket.state == "Queued" then
		localState.ticket = ticket
		return
	end

	if ticket.state == "QuickPlayed" then
		return ok({ state = "QuickPlayed", listingId = ticket.listingId })
	end
	if ticket.state == "Cancelled" then
		self._localTickets[ticketId] = nil
		if self.onCancelled then
			self.onCancelled(ticket)
		end
		return
	end

	local matchId = ticket.matchId or (ticket.claim and ticket.claim.matchId)
	if matchId == nil then
		return
	end

	local matchSuccess, record = self._store:get(self._settings.keys.matches, matchId, 3)
	if matchSuccess and record ~= nil and record.state == "Ready" then
		-- A doorbell should have beaten this poll. If it did not, delivery is
		-- unreliable right now and every ticket should tighten its poll cap.
		if self._broadcaster:isHealthy() and record.envelope.committedBy ~= self._serverId then
			self._broadcaster:markUnhealthy()
			self:_log("warn", "match found by poll, not by broadcast", { matchId = matchId })
		end
		self:_deliver(record.envelope, "poll", true)
	end
end

function Engine._heartbeatLocal(self: any, localState: any, now: number, mono: number)
	if mono < localState.nextHeartbeat then
		return
	end
	local settings = self._settings
	localState.nextHeartbeat = mono + settings.heartbeatInterval

	local ticketId = localState.ticket.id
	local renewed = false
	local success, ticket = self._store:update(
		settings.keys.tickets,
		ticketId,
		settings.ticketExpiration,
		function(current: any): any
			renewed = false
			if current == nil or current.state ~= "Queued" then
				return nil
			end
			current.expiresAt = now + settings.ticketExpiration
			renewed = true
			return current
		end,
		3
	)

	if not success or not renewed then
		return
	end

	localState.ticket = ticket
	self._store:sortedSet(
		localState.lane.map,
		ticketId,
		candidateFor(ticket),
		settings.indexExpiration,
		ticket.queuedAt,
		3
	)
	for _, member in ticket.members do
		self._store:update(
			settings.keys.users,
			tostring(member.userId),
			settings.ticketExpiration,
			function(current: any): any
				if current == nil or current.ticketId ~= ticketId then
					return nil
				end
				return { ticketId = ticketId, queue = settings.name, expiresAt = now + settings.ticketExpiration }
			end,
			3
		)
	end
	if ticket.partyId and self._getParties then
		self._getParties():heartbeatQueue(ticket.partyId, ticketId)
	end
end

--------------------------------------------------------------------------------
-- Quick Play
--------------------------------------------------------------------------------

--[=[
	Tries to backfill one ticket into a live match.

	The order here is load-bearing, and it is the same shape as `_commit`:

	1. **Take the seat.** Atomic, so only one server can hold it.
	2. **Take the ticket**, by the compare-and-set in `_release`. A lane worker
	   may have claimed it into a fresh match a moment ago, in which case this
	   fails and the player is already spoken for.
	3. **Give the seat back** if step 2 lost, so a match we are not sending
	   anybody to does not sit there holding capacity until the reservation
	   lapses.

	Doing it the other way round, taking the ticket first, would take a player
	out of the queue before knowing there was anywhere to put them.

	@within Engine
	@private
]=]
function Engine._tryQuickPlay(self: any, ticket: any, now: number): boolean
	local quickplay = self._getQuickPlay()

	local userIds = table.create(#ticket.members)
	for index, member in ticket.members do
		userIds[index] = member.userId
	end

	local found = quickplay:search({
		partition = ticket.partition,
		size = ticket.size,
		userIds = userIds,
		now = now,
	})
	if not found.ok or found.value == nil then
		return false
	end
	local claim = found.value

	local taken = self:_release(ticket.leaderUserId, ticket.id, "QuickPlayed", claim.listingId)
	if taken == nil then
		quickplay:release(claim.listingId, claim.reservationId)
		self:_log("info", "backfill lost the ticket to a match", {
			ticketId = ticket.id,
			listingId = claim.listingId,
		})
		return false
	end

	local assignment = {
		listingId = claim.listingId,
		reservationId = claim.reservationId,
		queue = self._settings.name,
		partition = ticket.partition,
		serverId = claim.listing.serverId,
		members = ticket.members,
		ticketId = ticket.id,
		size = ticket.size,
		data = claim.listing.data,
	}

	self:_metric("muster.quickplay.assigned", ticket.size, { queue = self._settings.name })
	self:_log("info", `backfilled {ticket.size} players`, {
		ticketId = ticket.id,
		listingId = claim.listingId,
		queue = self._settings.name,
	})
	if self.onQuickPlayMatched then
		self.onQuickPlayMatched(assignment)
	end
	return true
end

--[=[
	Runs the backfill search for every local ticket that is due one.

	Tickets are collected before any of them is acted on, because a successful
	backfill removes its entry from `_localTickets` and mutating that while
	iterating it is undefined.

	@within Engine
	@private
]=]
function Engine._advanceQuickPlay(self: any, now: number, mono: number)
	if self._settings.quickPlay == nil or self._getQuickPlay == nil then
		return
	end

	local due = nil
	for ticketId, localState in self._localTickets do
		local ticket = localState.ticket
		if ticket.quickPlay and ticket.state == "Queued" and mono >= (localState.nextQuickPlay or 0) then
			due = due or {}
			table.insert(due, ticketId)
		end
	end
	if due == nil then
		return
	end

	for _, ticketId in due do
		local localState = self._localTickets[ticketId]
		if localState ~= nil then
			-- Charged whether or not a seat was found, so a queue with nothing
			-- joinable costs one read per ticket per interval rather than one per
			-- pass.
			localState.nextQuickPlay = mono + self._settings.quickPlay.searchInterval
			self:_tryQuickPlay(localState.ticket, now)
		end
	end
end

function Engine._advanceTickets(self: any, now: number, mono: number)
	local active: { [string]: boolean } = {}
	for ticketId, localState in self._localTickets do
		self:_pollLocal(ticketId, localState, mono)
		if self._localTickets[ticketId] == nil then
			continue
		end
		self:_heartbeatLocal(localState, now, mono)
		if self._localTickets[ticketId] == nil then
			continue
		end
		local lane = localState.lane
		self._work[lane.key] = self._work[lane.key] or lane
		active[lane.key] = true
	end

	-- Drop work we no longer have a stake in, unless we are still holding its
	-- lease, in which case releasing is `_scan`'s job.
	for key in self._work do
		if not active[key] and self._owned[key] == nil then
			self._work[key] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Lane ownership
--------------------------------------------------------------------------------

function Engine._ownedCount(self: any): number
	local count = 0
	for _ in self._owned do
		count += 1
	end
	return count
end

function Engine._acquireWork(self: any, now: number, mono: number)
	-- Under throttling, stop taking on new lanes before slowing anything else.
	-- Shedding parallelism is cheap; slowing the commit path is not.
	if self._isThrottled() then
		return
	end

	for key, descriptor in self._work do
		if self._owned[key] ~= nil then
			continue
		end
		descriptor.nextAttempt = descriptor.nextAttempt or 0
		if mono < descriptor.nextAttempt then
			continue
		end
		if self:_ownedCount() >= Defaults.MAX_LANES_PER_SERVER then
			continue
		end

		local lease = self._leases:acquire(key)
		if lease then
			self._owned[key] = {
				descriptor = descriptor,
				epoch = lease.epoch,
				renewAt = now + Defaults.LEASE_RENEW_INTERVAL,
				nextScan = mono,
				lastCount = 0,
				-- Candidates from this lane's own map, and the queue time of the
				-- oldest of them. Both start at "nothing seen", which is what
				-- makes a freshly taken lane read wide on its first pass.
				ownCount = 0,
				oldest = 0,
				batchSize = Defaults.MIN_BATCH_SIZE,
				emptyPasses = 0,
			}
			self:_log("info", "took lane", { lane = key, epoch = lease.epoch })
		else
			-- Jittered, so a fleet of servers losing the same race does not all
			-- retry in lockstep.
			descriptor.nextAttempt = mono + 2 + self._random() * 3
		end
	end
end

--[=[
	Whether this lane should read the bands either side of it as well as its own.

	Band boundaries are hard walls, which is the price of splitting by rating,
	and two cases are worth paying to cross:

	- **Too thin to match.** A band holding a handful of players has nothing to
	  gain from privacy and everything to gain from the pool next door. This is
	  also what rescues a lone player at the top of the ladder, whose band can
	  hold nobody else at all, long before a merge would.
	- **Too stale.** Once the anchor's rating window has relaxed past the width
	  of the band, the players it should now reach are by definition outside it.

	Neither is free, so neither is the default: a busy band that is still turning
	players over reads only itself.

	@within Engine
	@private
]=]
function Engine._shouldWiden(self: any, owned: any, now: number): boolean
	if #owned.descriptor.neighbours == 0 then
		return false
	end
	if owned.ownCount < Defaults.LANE_STARVED_DEPTH then
		return true
	end
	local rating = self._settings.rating
	return rating ~= nil and owned.oldest > 0 and now - owned.oldest >= rating.unbounded
end

--[=[
	Reads the lane's candidates, oldest first.

	Returns the count from the lane's own map alongside them, which is what the
	scaler judges this lane's depth by, and the count from everything this lane
	is responsible for, which is what decides whether the lease is worth keeping.
	Candidates borrowed from a neighbour count towards neither: they belong to a
	lane somebody else is holding.

	@within Engine
	@private
]=]
function Engine._readCandidates(self: any, owned: any, now: number): ({ Candidate }, number, number)
	local descriptor = owned.descriptor
	local candidates = {}
	local seen = {}

	-- The lane itself, then any map from a generation still draining. Reading
	-- both means a resize never splits the pool: tickets written before and
	-- after it can still match each other.
	local maps = { descriptor.map }
	for _, legacy in descriptor.legacy do
		table.insert(maps, legacy)
	end
	local core = #maps
	if self:_shouldWiden(owned, now) then
		for _, neighbour in descriptor.neighbours do
			table.insert(maps, neighbour)
		end
	end

	local ownCount = 0
	local coreCount = 0
	local perMap = if #maps > 1 then math.max(1, math.ceil(owned.batchSize / #maps)) else owned.batchSize
	for index, map in maps do
		local success, items = self._store:sortedRange(map, perMap, 5)
		if success then
			for _, item in items do
				local value = item.value
				-- Deduplicated because overlapping maps can surface the same
				-- ticket twice, during a shrink or across a band boundary.
				if value ~= nil and not seen[value.ticketId] then
					seen[value.ticketId] = true
					table.insert(candidates, value)
					if index == 1 then
						ownCount += 1
					end
					if index <= core then
						coreCount += 1
					end
				end
			end
		end
	end

	return candidates, ownCount, coreCount
end

--------------------------------------------------------------------------------
-- Commit
--------------------------------------------------------------------------------

function Engine._abortMatch(self: any, matchId: string, claimed: { any })
	local settings = self._settings
	self._store:update(settings.keys.matches, matchId, settings.matchExpiration, function(current: any): any
		if current == nil or current.state == "Ready" then
			return nil
		end
		current.state = "Aborted"
		return current
	end, 1)

	for _, ticket in claimed do
		self._store:update(settings.keys.tickets, ticket.id, settings.ticketExpiration, function(current: any): any
			if current ~= nil and current.state == "Claimed" and current.claim.matchId == matchId then
				current.state = "Queued"
				current.claim = nil
				return current
			end
			return nil
		end, 1)
	end
end

function Engine._fireAbort(self: any, context: any, reason: string, data: any?, message: string?)
	local abortContext = {
		matchId = context.matchId,
		queue = context.queue,
		partition = context.partition,
		members = context.members,
		reason = reason,
		message = message,
		data = data,
	}
	self:_metric("muster.match.aborted", 1, { queue = context.queue, reason = reason })
	self:_log("warn", "match aborted", { matchId = context.matchId, reason = reason, error = message })
	if self._settings.onAbort then
		local success, failure = pcall(self._settings.onAbort, abortContext)
		if not success then
			self:_log("error", "onAbort handler errored", { matchId = context.matchId, error = tostring(failure) })
		end
	end
	if self.onAborted then
		self.onAborted(abortContext)
	end
end

--[=[
	Moves one ticket from `Queued` to `Claimed`, repairing stale claims on the
	way.

	A claim past its deadline means its owner stopped. What it left behind
	depends on how far it got: if the referenced match reached `Ready`, the
	players are genuinely matched, so the ticket is finalized under that match
	rather than stolen. If the match is still `Claiming` past its own deadline it
	never committed, so it is marked `Aborted` and the ticket is taken.

	Tickets whose origin server has stopped heartbeating are refused, since a
	match containing them could not be delivered.

	@within Engine
	@private
]=]
function Engine._claimTicket(self: any, candidate: Candidate, matchId: string, owned: any): any?
	local settings = self._settings
	local now = self._clock()

	local readSuccess, existing = self._store:get(settings.keys.tickets, candidate.ticketId, 1)
	if not readSuccess or existing == nil then
		return nil
	end

	-- A ticket whose origin server stopped heartbeating is on its way out.
	-- Matching it would produce a match with a player nobody can deliver to.
	local lastHeartbeat = existing.expiresAt - settings.ticketExpiration
	if now - lastHeartbeat > settings.heartbeatInterval * 2 then
		return nil
	end

	if existing.state == "Claimed" and existing.claim.expiresAt <= now then
		local matchSuccess, previous = self._store:get(settings.keys.matches, existing.claim.matchId, 1)
		if matchSuccess and previous ~= nil and previous.state == "Ready" then
			self._store:update(
				settings.keys.tickets,
				existing.id,
				settings.ticketExpiration,
				function(current: any): any
					if current ~= nil and current.state == "Claimed" and current.claim.matchId == previous.id then
						current.state = "Matched"
						current.matchId = previous.id
						return current
					end
					return nil
				end,
				1
			)
			return nil
		elseif matchSuccess and previous ~= nil and previous.state == "Claiming" then
			self._store:update(settings.keys.matches, previous.id, settings.matchExpiration, function(current: any): any
				if current ~= nil and current.state == "Claiming" and current.expiresAt <= now then
					current.state = "Aborted"
					return current
				end
				return nil
			end, 1)
		end
	end

	local claimed = false
	local success, ticket = self._store:update(
		settings.keys.tickets,
		candidate.ticketId,
		settings.ticketExpiration,
		function(current: any): any
			claimed = false
			if current == nil then
				return nil
			elseif current.state == "Queued" or (current.state == "Claimed" and current.claim.expiresAt <= now) then
				current.state = "Claimed"
				current.claim = {
					matchId = matchId,
					leaseKey = owned.descriptor.key,
					epoch = owned.epoch,
					expiresAt = now + settings.claimDuration,
				}
				claimed = true
				return current
			elseif current.state == "Claimed" and current.claim.matchId == matchId then
				claimed = true
				return current
			end
			return nil
		end,
		1
	)

	return if success and claimed then ticket else nil
end

function Engine._cleanupTicket(self: any, ticket: any)
	-- Uses the layout the ticket was written under, so a resize in the meantime
	-- does not leave its index entry behind in an abandoned map.
	local map = Lanes.name(
		self._settings,
		ticket.partition,
		ticket.laneCount or 1,
		ticket.laneGeneration or 0,
		ticket.lane or 0
	)
	self._store:sortedRemove(map, ticket.id, 4)
end

--[=[
	Turns a group of candidates into a committed match, or into nothing.

	The order of these steps is load-bearing:

	1. **Sort the ticket ids.** Two workers contending for overlapping tickets
	   acquire them in the same order and so cannot deadlock.
	2. **Write the `Claiming` record.** A crash after this leaves a record
	   another worker can resolve, rather than claims pointing at nothing.
	3. **Claim every ticket.** Any refusal aborts and returns the rest to
	   `Queued`. No hook has run yet, so nothing needs compensating.
	4. **Validate the lease** before doing anything expensive.
	5. **Run `finalize`.** The only step that yields and the only one with side
	   effects outside Muster. The lease is renewed first so a slow hook cannot
	   outlive it, the return value is validated and size-checked, and the lease
	   is validated **again** afterwards because time passed.
	6. **Compare-and-set `Claiming` to `Ready`.** Guarded on server id, lease
	   epoch and deadline together, so a worker that lost its lease cannot commit
	   even if it reaches this line. This is the linearization point: before it
	   the match does not exist, after it it does.
	7. **Then** mark tickets matched, unlock parties, and announce.

	@within Engine
	@private
]=]
function Engine._commit(self: any, group: { Candidate }, owned: any): boolean
	local settings = self._settings
	local now = self._clock()
	local matchId = self._id()

	local ticketIds = table.create(#group)
	for index, candidate in group do
		ticketIds[index] = candidate.ticketId
	end
	table.sort(ticketIds)

	local created = self._store:set(settings.keys.matches, matchId, {
		v = settings.version,
		id = matchId,
		state = "Claiming",
		ownerServerId = self._serverId,
		leaseKey = owned.descriptor.key,
		leaseEpoch = owned.epoch,
		createdAt = now,
		expiresAt = now + settings.claimDuration,
		ticketIds = ticketIds,
	}, settings.matchExpiration, 1)
	if not created then
		return false
	end

	local byId = {}
	for _, candidate in group do
		byId[candidate.ticketId] = candidate
	end

	local claimed = {}
	for _, ticketId in ticketIds do
		local ticket = self:_claimTicket(byId[ticketId], matchId, owned)
		if ticket == nil then
			self:_abortMatch(matchId, claimed)
			self:_log("info", "match abandoned, ticket unavailable", { matchId = matchId, ticketId = ticketId })
			return false
		end
		table.insert(claimed, ticket)
	end

	local members = {}
	local partyIds = {}
	local seenParties = {}
	local ratingTotal = 0
	local ratingCount = 0
	for _, ticket in claimed do
		for _, member in ticket.members do
			table.insert(members, member)
			if member.rating ~= nil then
				ratingTotal += member.rating
				ratingCount += 1
			end
		end
		if ticket.partyId and not seenParties[ticket.partyId] then
			seenParties[ticket.partyId] = true
			table.insert(partyIds, ticket.partyId)
		end
	end

	local context = {
		matchId = matchId,
		queue = settings.name,
		partition = owned.descriptor.partition,
		members = members,
		ticketIds = ticketIds,
		partyIds = partyIds,
		size = #members,
		averageRating = if ratingCount > 0 then ratingTotal / ratingCount else nil,
		createdAt = now,
		deadline = self._monotonic() + settings.finalizeTimeout,
	}

	-- Fence #1: cheap, and it catches the common case before any real work.
	if not self._leases:validate(owned.descriptor.key, owned.epoch) then
		self:_abortMatch(matchId, claimed)
		self:_fireAbort(context, "LeaseLost")
		return false
	end

	local data: any = {}
	if settings.finalize then
		-- Push the lease out first: a 5s hook must not be able to outlive a 15s
		-- lease that was already 12s old.
		if self._leases:renew(owned.descriptor.key, owned.epoch) == nil then
			self:_abortMatch(matchId, claimed)
			self:_fireAbort(context, "LeaseLost")
			return false
		end

		local outcome = Finalizer.run(settings.finalize, context, settings.finalizeTimeout, {
			monotonic = self._monotonic,
			sleep = settings.sleep,
			spawn = settings.spawn,
		})
		if not outcome.ok then
			self:_abortMatch(matchId, claimed)
			self:_fireAbort(context, outcome.reason :: string, nil, outcome.message)
			return false
		end

		local sane, sanitized, why = Serialize.validate(outcome.value, settings.maxMatchDataBytes)
		if not sane then
			self:_abortMatch(matchId, claimed)
			self:_fireAbort(context, "FinalizerTooLarge", outcome.value, why)
			return false
		end
		data = sanitized

		-- Fence #2: the hook yielded, so this lease may have changed hands while
		-- it ran.
		if not self._leases:validate(owned.descriptor.key, owned.epoch) then
			self:_abortMatch(matchId, claimed)
			self:_fireAbort(context, "LeaseLost", data)
			return false
		end
	end

	local envelope = {
		v = settings.version,
		matchId = matchId,
		queue = settings.name,
		partition = owned.descriptor.partition,
		createdAt = now,
		size = #members,
		members = members,
		ticketIds = ticketIds,
		partyIds = partyIds,
		committedBy = self._serverId,
		data = data,
	}

	local ready = false
	local committed = self._store:update(
		settings.keys.matches,
		matchId,
		settings.matchExpiration,
		function(current: any): any
			ready = false
			if
				current == nil
				or current.state ~= "Claiming"
				or current.ownerServerId ~= self._serverId
				or current.leaseEpoch ~= owned.epoch
				or current.expiresAt <= self._clock()
			then
				return nil
			end
			current.state = "Ready"
			current.envelope = envelope
			ready = true
			return current
		end,
		1
	)

	if not committed or not ready then
		self:_abortMatch(matchId, claimed)
		self:_fireAbort(context, if committed then "TicketStolen" else "StoreUnavailable", data)
		return false
	end

	for _, ticket in claimed do
		self._store:update(settings.keys.tickets, ticket.id, settings.ticketExpiration, function(current: any): any
			if current ~= nil and current.state == "Claimed" and current.claim.matchId == matchId then
				current.state = "Matched"
				current.matchId = matchId
				return current
			end
			return nil
		end, 1)
		if ticket.partyId and self._getParties then
			self._getParties():markMatched(ticket.partyId, ticket.id, matchId)
		end
		self:_cleanupTicket(ticket)
	end

	local longestWait = 0
	for _, ticket in claimed do
		longestWait = math.max(longestWait, now - ticket.queuedAt)
	end
	self:_metric("muster.match.ready", #members, { queue = settings.name, partition = envelope.partition })
	self:_log("info", `match ready: {#members} players`, {
		matchId = matchId,
		queue = settings.name,
		tickets = #claimed,
		parties = #partyIds,
		longestWait = longestWait,
	})

	self._broadcaster:announce(envelope)
	self:_deliver(envelope, "commit", true)
	return true
end

--------------------------------------------------------------------------------
-- Delivery
--------------------------------------------------------------------------------

--[=[
	Delivers a committed match to this server, if it holds any of the players.

	Deduplicated on matchId, so a match arriving by commit, by announcement and
	by poll fires the signal once.

	@within Engine
	@private
]=]
function Engine._deliver(self: any, envelope: any, source: string, dedupe: boolean)
	if dedupe and not self._broadcaster:accept(envelope.matchId) then
		return
	end

	local mine = false
	for _, member in envelope.members do
		if member.serverId == self._serverId then
			mine = true
			break
		end
	end

	for _, ticketId in envelope.ticketIds do
		local localState = self._localTickets[ticketId]
		if localState then
			self._localTickets[ticketId] = nil
			if not self._settings.manualAcknowledge then
				self:_releaseUsers(localState.ticket)
				if localState.ticket.partyId and self._getParties then
					self._getParties():acknowledgeMatch(localState.ticket.partyId, envelope.matchId)
				end
			end
		end
	end

	if not mine then
		return
	end

	self:_metric("muster.match.delivered", envelope.size, { queue = self._settings.name, source = source })
	if self.onMatched then
		self.onMatched(envelope, source)
	end
end

--------------------------------------------------------------------------------
-- Worker loop
--------------------------------------------------------------------------------

function Engine._scan(self: any, key: string, owned: any, now: number, mono: number)
	if now >= owned.renewAt then
		local lease = self._leases:renew(key, owned.epoch)
		if lease == nil then
			self._owned[key] = nil
			self._scaler:forget(key)
			owned.descriptor.nextAttempt = mono + 2 + self._random() * 3
			self:_log("info", "lost lane", { lane = key, epoch = owned.epoch })
			return
		end
		owned.renewAt = now + Defaults.LEASE_RENEW_INTERVAL
	end

	if mono < owned.nextScan then
		return
	end

	local candidates, ownCount, coreCount = self:_readCandidates(owned, now)
	owned.lastCount = #candidates
	owned.ownCount = ownCount
	if #candidates >= owned.batchSize then
		owned.batchSize = math.min(Defaults.MAX_BATCH_SIZE, owned.batchSize * 2)
	elseif #candidates <= owned.batchSize / 4 then
		owned.batchSize = math.max(Defaults.MIN_BATCH_SIZE, math.floor(owned.batchSize / 2))
	end

	-- What this lane holds on its own: how deep it is, how long its oldest player
	-- has been in it, and the ratings a band split would be placed from.
	-- Candidates pulled in from a neighbour or a draining generation are matched
	-- against, but they say nothing about this lane and are left out.
	local ratings = table.create(ownCount)
	local oldest = 0
	for index = 1, ownCount do
		local candidate = candidates[index]
		if candidate.rating ~= nil then
			table.insert(ratings, candidate.rating)
		end
		if oldest == 0 or candidate.queuedAt < oldest then
			oldest = candidate.queuedAt
		end
	end
	owned.oldest = oldest

	-- Judged against the largest batch we would ever ask for, not the one we
	-- happened to ask for. A small early batch filling up says nothing about
	-- how deep the lane really is.
	local resized = self._scaler:observe(owned.descriptor, ownCount, Defaults.MAX_BATCH_SIZE, ratings)
	if resized ~= nil then
		self:_metric("muster.lanes.resized", resized.count, { queue = self._settings.name })
		self:_log("info", `lanes for {owned.descriptor.partition} are now {resized.count}`, {
			partition = owned.descriptor.partition,
			from = owned.descriptor.count,
			to = resized.count,
			generation = resized.generation,
			bounds = table.concat(resized.bounds, ","),
		})
	end

	local groups = Matcher.select(candidates, now, self._matcher)
	for _, group in groups do
		self:_commit(group, owned)
	end

	-- Judged on what this lane is responsible for, not on what it borrowed. A
	-- lane kept alive by its neighbour's queue is a lane this server is holding
	-- for nothing, and holding it counts against `MAX_LANES_PER_SERVER`.
	if coreCount == 0 then
		owned.emptyPasses += 1
	else
		owned.emptyPasses = 0
	end

	if owned.emptyPasses >= Defaults.EMPTY_PASSES_BEFORE_RELEASE then
		self._leases:release(key, owned.epoch)
		self._owned[key] = nil
		self._scaler:forget(key)
		owned.descriptor.nextAttempt = mono + Defaults.MAX_SCAN_DELAY
		self:_log("info", "released idle lane", { lane = key })
		return
	end

	local delay = Defaults.scanDelay(#candidates, self._isThrottled())
	owned.nextScan = mono + delay * (0.85 + self._random() * 0.3)
end

--[=[
	One pass: upkeep on local tickets, lane acquisition, then a scan of each held
	lane.

	@within Engine
]=]
function Engine.step(self: any)
	local now = self._clock()
	local mono = self._monotonic()
	self:_advanceTickets(now, mono)
	-- Before lane work: a ticket that can be backfilled right now should not
	-- wait out a scan it is about to leave the queue anyway.
	self:_advanceQuickPlay(now, mono)
	self:_advanceListings(mono)
	self:_acquireWork(now, mono)
	for key, owned in self._owned do
		self:_scan(key, owned, now, mono)
	end
end

--[=[
	Heartbeats whichever listings this server is hosting. Only reaches for the
	service if it has already been built, so a lobby server that never hosts
	anything pays nothing.

	@within Engine
	@private
]=]
function Engine._advanceListings(self: any, mono: number)
	if self._settings.quickPlay == nil or self._getQuickPlay == nil then
		return
	end
	local quickplay = self._getQuickPlay(true)
	if quickplay ~= nil then
		quickplay:step(mono)
	end
end

--[=[
	@within Engine
]=]
function Engine.start(self: any)
	if self._running then
		return
	end
	self._running = true
	self._broadcaster:start()

	local settings = self._settings
	settings.spawn(function()
		while self._running do
			local success, failure = pcall(function()
				self:step()
			end)
			if not success then
				self:_log("error", "worker pass failed", { error = tostring(failure) })
			end
			settings.sleep(0.1)
		end
	end)
end

--[=[
	Stops the loop and releases every lease this server holds, so another server
	can take the lanes immediately rather than after the 15-second timeout.

	@within Engine
]=]
function Engine.stop(self: any)
	self._running = false
	self._broadcaster:stop()
	for key, owned in self._owned do
		self._leases:release(key, owned.epoch)
		self._scaler:forget(key)
	end
	table.clear(self._owned)
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

function Engine.getTicketForUser(self: any, userId: number): any
	local settings = self._settings
	local success, reservation = self._store:get(settings.keys.users, tostring(userId), 5)
	if not success then
		return err("StoreUnavailable", tostring(reservation), true)
	end
	if reservation == nil or reservation.ticketId == "" or reservation.expiresAt <= self._clock() then
		return ok(nil)
	end

	local ticketSuccess, ticket = self._store:get(settings.keys.tickets, reservation.ticketId, 5)
	if not ticketSuccess then
		return err("StoreUnavailable", tostring(ticket), true)
	end
	if ticket == nil then
		self._store:remove(settings.keys.users, tostring(userId))
		return ok(nil)
	end
	return ok(ticket)
end

--[=[
	Moves a ticket out of `Queued` and tears down everything that referenced it:
	its lane index entry, its members' user reservations, this server's local
	copy, and its party lock.

	The compare-and-set is the interesting part. `_claimTicket` also only
	succeeds on a `Queued` ticket, so this is the single point where cancelling,
	backfilling and matching arbitrate against each other. Whichever writes
	first wins, and the others see a state they cannot act on.

	@param state -- The terminal state to write: `Cancelled` or `QuickPlayed`.
	@return any -- The ticket, or `nil` when it could not be taken.
	@return any -- The failure to hand back, when there is one.
	@within Engine
	@private
]=]
function Engine._release(
	self: any,
	requesterUserId: number,
	ticketId: string,
	state: string,
	matchId: string?
): (any, any)
	local settings = self._settings
	local taken = false
	local success, ticket = self._store:update(
		settings.keys.tickets,
		ticketId,
		settings.ticketExpiration,
		function(current: any): any
			taken = false
			if current == nil or current.leaderUserId ~= requesterUserId or current.state ~= "Queued" then
				return nil
			end
			current.state = state
			if matchId ~= nil then
				current.listingId = matchId
			end
			taken = true
			return current
		end,
		3
	)

	if not success then
		return nil, err("StoreUnavailable", tostring(ticket), true)
	end
	if not taken then
		return nil, err("NotQueued", "That ticket is missing, already matched, or owned by someone else")
	end

	self:_cleanupTicket(ticket)
	self:_releaseUsers(ticket)
	self._localTickets[ticketId] = nil
	if ticket.partyId and self._getParties then
		self._getParties():unlockQueue(ticket.partyId, ticket.id)
	end
	return ticket, nil
end

function Engine.cancel(self: any, requesterUserId: number, ticketId: string): any
	local ticket, failure = self:_release(requesterUserId, ticketId, "Cancelled")
	if failure then
		return failure
	end

	self:_log("info", "ticket cancelled", { ticketId = ticketId, user = requesterUserId })
	if self.onCancelled then
		self.onCancelled(ticket)
	end
	return ok(true)
end

function Engine.getStatus(self: any, ticketId: string): any
	local settings = self._settings
	local success, ticket = self._store:get(settings.keys.tickets, ticketId, 5)
	if not success then
		return err("StoreUnavailable", tostring(ticket), true)
	end
	if ticket == nil then
		return ok({ state = "Expired" })
	end
	if ticket.state == "Queued" then
		return ok({ state = "Queued", queuedAt = ticket.queuedAt })
	end
	if ticket.state == "QuickPlayed" then
		return ok({ state = "QuickPlayed", listingId = ticket.listingId })
	end
	if ticket.state == "Cancelled" then
		return ok({ state = "Cancelled" })
	end

	local matchId = ticket.matchId or (ticket.claim and ticket.claim.matchId)
	if matchId == nil then
		return ok({ state = "Claiming" })
	end

	local matchSuccess, record = self._store:get(settings.keys.matches, matchId, 3)
	if not matchSuccess then
		return err("StoreUnavailable", tostring(record), true)
	end
	if record ~= nil and record.state == "Ready" then
		return ok({ state = "Matched", match = record.envelope })
	end
	return ok({ state = "Claiming" })
end

function Engine.getMatch(self: any, matchId: string): any
	local success, record = self._store:get(self._settings.keys.matches, matchId, 5)
	if not success then
		return err("StoreUnavailable", tostring(record), true)
	end
	if record == nil or record.state ~= "Ready" then
		return ok(nil)
	end
	return ok(record.envelope)
end

function Engine.acknowledge(self: any, requesterUserId: number, ticketId: string): any
	local status = self:getStatus(ticketId)
	if not status.ok then
		return status
	end
	if status.value.state ~= "Matched" then
		return err("NotQueued", "That ticket has no ready match")
	end

	local success, ticket = self._store:get(self._settings.keys.tickets, ticketId, 3)
	if not success then
		return err("StoreUnavailable", tostring(ticket), true)
	end
	if ticket == nil or ticket.leaderUserId ~= requesterUserId then
		return err("NotLeader", "Only the ticket's leader may acknowledge its match")
	end

	self:_releaseUsers(ticket)
	self._localTickets[ticketId] = nil
	if ticket.partyId and self._getParties then
		local acknowledged = self._getParties():acknowledgeMatch(ticket.partyId, status.value.match.matchId)
		if not acknowledged.ok then
			return acknowledged
		end
	end
	return ok(status.value.match)
end

return Engine
