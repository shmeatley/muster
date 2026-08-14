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
	-- Read the partition's current lane count (cached) so this ticket lands
	-- where the rest of the fleet is looking.
	local laneState = self._scaler:current(partition)
	local lane =
		self._layout.forTicket(settings, partition, laneState.count, ticketId, self._scaler:draining(laneState))

	local rating: number? = nil
	if settings.rated then
		local ratings = table.create(#members)
		for index, member in members do
			ratings[index] = member.rating
		end
		rating = settings.rating.aggregate(ratings)
	end

	local ticket = {
		v = settings.version,
		id = ticketId,
		queue = settings.name,
		partition = partition,
		lane = lane.lane,
		-- Recorded, not recomputed later: the count can change while this ticket
		-- is queued, and its index entry stays in the map it was written to.
		laneCount = lane.count,
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

function Engine._readCandidates(self: any, owned: any): { Candidate }
	local descriptor = owned.descriptor
	local candidates = {}
	local seen = {}

	-- The lane itself, then any map from a count still draining. Reading both
	-- means a resize never splits the pool: tickets written before and after it
	-- can still match each other.
	local maps = { descriptor.map }
	for _, legacy in descriptor.legacy do
		table.insert(maps, legacy)
	end

	local perMap = if #maps > 1 then math.max(1, math.ceil(owned.batchSize / #maps)) else owned.batchSize
	for _, map in maps do
		local success, items = self._store:sortedRange(map, perMap, 5)
		if success then
			for _, item in items do
				local value = item.value
				-- Deduplicated because overlapping legacy maps can surface the
				-- same ticket to two lanes during a shrink.
				if value ~= nil and not seen[value.ticketId] then
					seen[value.ticketId] = true
					table.insert(candidates, value)
				end
			end
		end
	end

	return candidates
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
	-- Uses the count the ticket was written under, so a resize in the meantime
	-- does not leave its index entry behind in an abandoned map.
	local map = Lanes.name(self._settings, ticket.partition, ticket.laneCount or 1, ticket.lane or 0)
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
			owned.descriptor.nextAttempt = mono + 2 + self._random() * 3
			self:_log("info", "lost lane", { lane = key, epoch = owned.epoch })
			return
		end
		owned.renewAt = now + Defaults.LEASE_RENEW_INTERVAL
	end

	if mono < owned.nextScan then
		return
	end

	local candidates = self:_readCandidates(owned)
	owned.lastCount = #candidates
	if #candidates >= owned.batchSize then
		owned.batchSize = math.min(Defaults.MAX_BATCH_SIZE, owned.batchSize * 2)
	elseif #candidates <= owned.batchSize / 4 then
		owned.batchSize = math.max(Defaults.MIN_BATCH_SIZE, math.floor(owned.batchSize / 2))
	end

	-- Judged against the largest batch we would ever ask for, not the one we
	-- happened to ask for. A small early batch filling up says nothing about
	-- how deep the lane really is.
	local resized =
		self._scaler:observe(owned.descriptor.partition, owned.descriptor.count, #candidates, Defaults.MAX_BATCH_SIZE)
	if resized ~= nil then
		self:_metric("muster.lanes.resized", resized, { queue = self._settings.name })
		self:_log("info", `lane count for {owned.descriptor.partition} is now {resized}`, {
			partition = owned.descriptor.partition,
			from = owned.descriptor.count,
			to = resized,
		})
	end

	local groups = Matcher.select(candidates, now, self._matcher)
	for _, group in groups do
		self:_commit(group, owned)
	end

	if #candidates == 0 then
		owned.emptyPasses += 1
	else
		owned.emptyPasses = 0
	end

	if owned.emptyPasses >= Defaults.EMPTY_PASSES_BEFORE_RELEASE then
		self._leases:release(key, owned.epoch)
		self._owned[key] = nil
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
	self:_acquireWork(now, mono)
	for key, owned in self._owned do
		self:_scan(key, owned, now, mono)
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

function Engine.cancel(self: any, requesterUserId: number, ticketId: string): any
	local settings = self._settings
	local cancelled = false
	local success, ticket = self._store:update(
		settings.keys.tickets,
		ticketId,
		settings.ticketExpiration,
		function(current: any): any
			cancelled = false
			if current == nil or current.leaderUserId ~= requesterUserId or current.state ~= "Queued" then
				return nil
			end
			current.state = "Cancelled"
			cancelled = true
			return current
		end,
		3
	)

	if not success then
		return err("StoreUnavailable", tostring(ticket), true)
	end
	if not cancelled then
		return err("NotQueued", "That ticket is missing, already matched, or owned by someone else")
	end

	self:_cleanupTicket(ticket)
	self:_releaseUsers(ticket)
	self._localTickets[ticketId] = nil
	if ticket.partyId and self._getParties then
		self._getParties():unlockQueue(ticket.partyId, ticket.id)
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
