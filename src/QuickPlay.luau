--!strict

--[=[
	@class QuickPlay

	Backfilling players into matches that are already running.

	Muster's ordinary path only ever forms *new* matches. Quick Play adds the
	other one: a live match server advertises itself, and a queued player who
	fits drops straight into it instead of waiting for a fresh lobby to fill.

	It is off unless a queue asks for it, since it is a casual-mode feature:

	```lua
	local casual = Muster.new({ name = "casual", size = 8, quickPlay = true })
	```

	Quick Play **ignores rating entirely**. There is no window, no relaxation and
	no banding; a listing with a free seat takes the next player who wants it. Do
	not turn it on for a ranked queue.

	### On the match server

	```lua
	local listing = Muster.Result.unwrap(casual.quickplay:host({
		data = { accessCode = code, placeId = ARENA_PLACE },
	}))

	listing:setOpen(false)  -- round underway; stop taking players
	listing:close()         -- delist immediately
	```

	The handle is kept up to date by the queue's own worker pass, so a match
	server needs one `Muster.new` and one `host` call. Its player count refreshes
	every `heartbeatInterval` (30 s), and a server that dies is delisted by
	`listingExpiration` (90 s) without anybody cleaning up.

	### In the lobby

	```lua
	casual.quickPlayMatched:connect(function(assignment)
		TeleportService:TeleportToPrivateServer(
			assignment.data.placeId, assignment.data.accessCode, players)
	end)

	casual:quickPlay(player.UserId)
	```

	[Matchmaker:quickPlay] writes an ordinary ticket flagged for backfill and then
	looks for a seat immediately. **If every listed match is full the player just
	stays in the normal queue** and forms a fresh match the usual way, retrying
	the search every `searchInterval` while they wait. There is no separate queue
	and no dead end: the two paths race, and whichever resolves first wins.

	### Taking the last seat

	Every claim is a compare-and-set on the listing record, so when fifty lobby
	servers see the same 7/8 match, exactly one of them gets the seat and the rest
	move on to their next candidate. Claimed seats are held as reservations until
	the players arrive, which is what stops two lobbies from both filling a slot
	inside one heartbeat window. See [Listings].

	### Lanes

	A MemoryStore range read returns at most 200 items, so listings shard into
	lanes exactly as tickets do, by hash, with the layout stamped into every key.
	The count starts at one and doubles once a lane is consistently too full to
	read in one go, so a game with six live matches pays for none of it. Pin it
	with `quickPlay.lanes` if you would rather.
]=]

local Defaults = require(script.Parent.Defaults)
local LaneScaler = require(script.Parent.internal.LaneScaler)
local Lanes = require(script.Parent.internal.Lanes)
local Listings = require(script.Parent.internal.Listings)
local Result = require(script.Parent.Result)
local Runtime = require(script.Parent.internal.Runtime)
local Serialize = require(script.Parent.internal.Serialize)
local Types = require(script.Parent.Types)

type ListingView = Types.ListingView

local ok = Result.ok
local err = Result.err

--------------------------------------------------------------------------------
-- Handle
--------------------------------------------------------------------------------

--[=[
	@class HostedListing

	The handle [QuickPlay:host] returns. Holds this server's view of its own
	listing and is refreshed by the queue's worker pass.
]=]
local HostedListing = {}
HostedListing.__index = HostedListing

--[=[
	@prop id string
	@within HostedListing
]=]

--[=[
	Opens or closes the listing to new players without delisting it.

	Closing is the right call once a round is underway and late joins would spoil
	it. The listing keeps heartbeating, so it reappears the moment you open it
	again.

	@within HostedListing
]=]
function HostedListing.setOpen(self: any, open: boolean)
	self.open = open ~= false
	-- Take effect now rather than on the next beat: a round starting is exactly
	-- when a stale index entry costs you a player teleporting into it.
	self._service:_beat(self, true)
end

--[=[
	Removes the listing and its index entry.

	Optional. A host that simply stops is delisted by `listingExpiration`; this
	just makes it immediate.

	@within HostedListing
]=]
function HostedListing.close(self: any)
	self._service:_close(self)
end

--[=[
	This server's last known copy of the listing record, or `nil` before the
	first heartbeat has landed.

	@within HostedListing
]=]
function HostedListing.record(self: any): any
	return self._record
end

--[=[
	Seats free as of the last write. A hint: another server may take the last one
	between reading this and acting on it.

	@within HostedListing
]=]
function HostedListing.free(self: any): number
	if self._record == nil then
		return 0
	end
	return Listings.freeSlots(self._record)
end

--------------------------------------------------------------------------------
-- Service
--------------------------------------------------------------------------------

local QuickPlay = {}
QuickPlay.__index = QuickPlay

--[=[
	Builds the service. A [Matchmaker] constructs one as `queue.quickplay` on
	first access and writes nothing until a method is called.

	@within QuickPlay
	@private
]=]
function QuickPlay.new(store: any, settings: any, deps: any?): any
	local extras = deps or {}
	local qp = settings.quickPlay

	-- A derived settings table, so listings get the whole of `Lanes` and
	-- `LaneScaler` without a line of it being duplicated. Only the fields those
	-- two modules read are present, and each one that differs from the queue's
	-- own is deliberate:
	--
	--   indexInfix   a separate key space, so a listing lane never collides
	--                with a ticket lane
	--   laneSplit    always hash: Quick Play has no rating to band by
	--   keys.lanes   its own layout record, so listings scale on their own depth
	--   ticketExpir. LaneScaler reads this as its resize cooldown. Listings
	--                migrate between lanes on a heartbeat rather than draining,
	--                so the cooldown has to outlast a full migration.
	local laneSettings = table.freeze({
		namespace = settings.namespace,
		version = settings.version,
		name = settings.name,
		indexInfix = "qpidx",
		laneSplit = "hash",
		laneMode = qp.laneMode,
		lanes = qp.lanes,
		keys = table.freeze({ lanes = settings.keys.quickplayLanes }),
		ticketExpiration = qp.laneCooldown,
		laneStateExpiration = qp.laneCooldown * 4,
		rating = nil,
		clock = settings.clock,
		monotonic = settings.monotonic,
	})

	return setmetatable({
		_store = store,
		_settings = settings,
		_qp = qp,
		_keys = settings.keys,
		_laneSettings = laneSettings,
		_scaler = LaneScaler.new(laneSettings, store),
		_clock = settings.clock,
		_monotonic = settings.monotonic,
		_random = settings.random,
		_id = settings.id,
		_players = settings.players or Runtime.service("Players"),
		_log = extras.log or function() end,
		_metric = extras.metric or function() end,
		_hosted = {},
		claims = 0,
		misses = 0,
	}, QuickPlay)
end

function QuickPlay._descriptor(self: any, partition: string, lane: number): any
	local state = self._scaler:current(partition)
	return Lanes.descriptor(self._laneSettings, partition, state.layout, lane, self._scaler:draining(state))
end

function QuickPlay._laneFor(self: any, partition: string, listingId: string): any
	local state = self._scaler:current(partition)
	return Lanes.forTicket(self._laneSettings, partition, state.layout, listingId, nil, self._scaler:draining(state))
end

--------------------------------------------------------------------------------
-- Hosting
--------------------------------------------------------------------------------

--[=[
	Advertises this server as joinable.

	Call it once the match server is ready to take players, with whatever a
	joining server needs to reach you:

	```lua
	queue.quickplay:host({ data = { accessCode = code, placeId = ARENA_PLACE } })
	```

	`data` is delivered verbatim as `assignment.data` and must survive a JSON
	round trip, within `quickPlay.maxListingDataBytes` (1024).

	`capacity` defaults to `quickPlay.capacity`, which defaults to `size.max`.
	The player count is read from `playerCount` on every heartbeat, defaulting to
	the `Players` service.

	@param options HostOptions
	@return Result<HostedListing>
	@within QuickPlay
]=]
function QuickPlay.host(self: any, options: any): any
	local opts = options or {}
	local qp = self._qp

	local sane, data, why = Serialize.validate(opts.data or {}, qp.maxListingDataBytes)
	if not sane then
		return err("InvalidListingData", `quickPlay data {why}`)
	end

	local capacity = opts.capacity or qp.capacity
	if type(capacity) ~= "number" or capacity < 1 or capacity % 1 ~= 0 then
		error("Muster: `capacity` must be a positive integer", 3)
	end

	local partition = opts.partition or "all"
	local listingId = opts.listingId or self._id()
	local now = self._clock()

	local counter = opts.playerCount
		or function(): number
			if self._players == nil then
				return 0
			end
			return #self._players:GetPlayers()
		end
	local present = opts.presentUserIds
		or function(): { number }
			local ids = {}
			if self._players == nil then
				return ids
			end
			for _, player in self._players:GetPlayers() do
				table.insert(ids, player.UserId)
			end
			return ids
		end

	local lane = self:_laneFor(partition, listingId)
	local listing = {
		v = self._settings.version,
		id = listingId,
		queue = self._settings.name,
		partition = partition,
		serverId = self._settings.serverId,
		capacity = capacity,
		players = opts.players or counter(),
		open = true,
		reservations = {},
		data = data,
		lane = lane.lane,
		laneCount = lane.count,
		laneGeneration = lane.generation,
		updatedAt = now,
		expiresAt = now + qp.listingExpiration,
	}

	local published, failure = Listings.publish(self._store, self._keys, qp, listing)
	if not published then
		return err("StoreUnavailable", tostring(failure), true)
	end

	local handle = setmetatable({
		id = listingId,
		partition = partition,
		open = true,
		_service = self,
		_record = listing,
		_map = lane.map,
		_lane = lane,
		_playerCount = counter,
		_presentUserIds = present,
		_nextBeat = self._monotonic() + qp.heartbeatInterval,
	}, HostedListing)

	Listings.index(self._store, qp, lane.map, listing, Listings.freeSlots(listing))
	self._hosted[listingId] = handle

	self._metric("muster.quickplay.hosted", 1, { queue = self._settings.name, partition = partition })
	self._log("info", "listing published", {
		listingId = listingId,
		queue = self._settings.name,
		partition = partition,
		capacity = capacity,
		lane = lane.lane,
	})
	return ok(handle)
end

--[=[
	One heartbeat for one hosted listing: refresh the count, retire fulfilled
	reservations, migrate to a new lane if the layout moved, and rewrite the
	index entry.

	@within QuickPlay
	@private
]=]
function QuickPlay._beat(self: any, handle: any, force: boolean?)
	local qp = self._qp
	local now = self._clock()

	local presentIds = handle._presentUserIds()
	local present = {}
	for _, userId in presentIds do
		present[userId] = true
	end

	-- A listing outlives a resize, unlike a ticket, so it moves itself rather
	-- than waiting to drain. Writing the new entry before removing the old one
	-- means the listing is briefly in both lanes and never in neither; `read`
	-- deduplicates the overlap.
	local lane = self:_laneFor(handle.partition, handle.id)
	local moved = lane.map ~= handle._map

	local beat, listing = Listings.heartbeat(self._store, self._keys, qp, handle.id, {
		players = handle._playerCount(),
		present = present,
		open = handle.open,
		lane = if moved then lane.lane else nil,
		laneCount = if moved then lane.count else nil,
		laneGeneration = if moved then lane.generation else nil,
	}, now)

	handle._nextBeat = self._monotonic() + qp.heartbeatInterval

	if not beat then
		-- The record is gone: expired while this server was unhealthy, or removed
		-- elsewhere. Stop pretending to host it.
		self._hosted[handle.id] = nil
		self._log("warn", "listing lost", { listingId = handle.id })
		return
	end

	handle._record = listing
	Listings.index(self._store, qp, lane.map, listing, Listings.freeSlots(listing))
	if moved then
		self._store:sortedRemove(handle._map, handle.id, 5)
		self._log("info", "listing migrated lane", {
			listingId = handle.id,
			from = handle._map,
			to = lane.map,
		})
	end
	handle._map = lane.map
	handle._lane = lane

	if force then
		-- A forced beat is a state change, not a scheduled one, so it does not
		-- get to postpone the next scheduled one indefinitely.
		handle._nextBeat = math.min(handle._nextBeat, self._monotonic() + qp.heartbeatInterval)
	end
end

function QuickPlay._close(self: any, handle: any)
	self._hosted[handle.id] = nil
	Listings.remove(self._store, self._keys, handle._map, handle.id)
	self._log("info", "listing closed", { listingId = handle.id })
end

--------------------------------------------------------------------------------
-- Searching
--------------------------------------------------------------------------------

--[=[
	The lanes to walk this pass, starting somewhere random.

	Spreading searchers over lanes rather than starting everyone at lane 0 is
	what keeps a resize from turning into a stampede on one map. With one lane,
	which is where a small game sits, this is a single read.

	@within QuickPlay
	@private
]=]
function QuickPlay._searchOrder(self: any, count: number): { number }
	local walk = math.min(count, Defaults.LISTING_SEARCH_LANES)
	local start = math.floor(self._random() * count) % count
	local order = table.create(walk)
	for offset = 0, walk - 1 do
		table.insert(order, (start + offset) % count)
	end
	return order
end

--[=[
	Looks for a seat and takes it.

	Returns `ok(nil)` when nothing joinable was found, which is the ordinary
	"everything is full" outcome and not an error: the caller stays queued.

	@param request -- `partition`, `size`, `userIds`.
	@return Result<{ listingId: string, reservationId: string, listing: Listing }?>
	@within QuickPlay
]=]
function QuickPlay.search(self: any, request: any): any
	local partition = request.partition or "all"
	local size = request.size or 1
	local now = request.now or self._clock()

	local state = self._scaler:current(partition)
	for _, lane in self:_searchOrder(state.layout.count) do
		local descriptor = self:_descriptor(partition, lane)
		local views, ownCount = Listings.read(self._store, descriptor, Defaults.MAX_LISTING_BATCH)

		-- Lanes grow when one is consistently too full to read in a single range
		-- read, which is the same signal the ticket lanes scale on.
		local resized = self._scaler:observe(descriptor, ownCount, Defaults.MAX_LISTING_BATCH, nil)
		if resized ~= nil then
			self._log("info", `listing lanes for {partition} are now {resized.count}`, {
				partition = partition,
				to = resized.count,
				generation = resized.generation,
			})
		end

		local viable = {}
		for _, view in views do
			if view.free >= size then
				table.insert(viable, view)
			end
		end
		if #viable > 0 then
			local claim = self:_claimAny(viable, partition, size, request.userIds or {}, now)
			if claim ~= nil then
				return ok(claim)
			end
		end
	end

	self.misses += 1
	return ok(nil)
end

--[=[
	Tries the head of the viable candidates until one of them yields a seat.

	The head is sampled rather than taken in order. The index is sorted fullest
	first, which is the right *policy* but the wrong thing for every lobby in the
	fleet to act on at the same instant, so each searcher starts somewhere
	slightly different within the few fullest matches.

	@within QuickPlay
	@private
]=]
function QuickPlay._claimAny(
	self: any,
	viable: { ListingView },
	partition: string,
	size: number,
	userIds: { number },
	now: number
): any?
	local attempts = math.min(#viable, Defaults.LISTING_CLAIM_ATTEMPTS)
	local offset = if #viable > 1 then math.floor(self._random() * attempts) % attempts else 0

	for step = 0, attempts - 1 do
		local view = viable[((offset + step) % #viable) + 1]
		local reservationId = self._id()
		local reservation = {
			id = reservationId,
			size = size,
			userIds = userIds,
			expiresAt = now + self._qp.reservationTimeout,
		}

		local claimed, listing = Listings.claim(self._store, self._keys, self._qp, view.listingId, reservation, now)
		if claimed then
			-- Refresh the index with what we just left behind, so the next
			-- searcher is not sent at a match this claim has already filled.
			local descriptor = self:_laneFor(partition, view.listingId)
			Listings.index(self._store, self._qp, descriptor.map, listing, Listings.freeSlots(listing))

			self.claims += 1
			self._metric("muster.quickplay.claimed", size, { queue = self._settings.name, partition = partition })
			return { listingId = view.listingId, reservationId = reservationId, listing = listing }
		end
	end
	return nil
end

--[=[
	Hands a claimed seat back. Call it when the teleport you were holding it for
	did not happen.

	@return Result<boolean> -- False when the reservation was already gone.
	@within QuickPlay
]=]
function QuickPlay.release(self: any, listingId: string, reservationId: string): any
	local released, listing = Listings.release(self._store, self._keys, self._qp, listingId, reservationId)
	if not released then
		return ok(false)
	end

	local descriptor = self:_laneFor(listing.partition, listingId)
	Listings.index(self._store, self._qp, descriptor.map, listing, Listings.freeSlots(listing))
	self._metric("muster.quickplay.released", 1, { queue = self._settings.name })
	return ok(true)
end

--------------------------------------------------------------------------------
-- Queries and upkeep
--------------------------------------------------------------------------------

--[=[
	The joinable listings in a partition, fullest first, for a server browser or
	a debug command.

	Reads every lane, so prefer [QuickPlay:search] for anything on a hot path.

	@return Result<{ ListingView }>
	@within QuickPlay
]=]
function QuickPlay.listings(self: any, partition: string?): any
	local key = partition or "all"
	local state = self._scaler:current(key)
	local all = {}
	for lane = 0, state.layout.count - 1 do
		local views = Listings.read(self._store, self:_descriptor(key, lane), Defaults.MAX_LISTING_BATCH)
		for _, view in views do
			table.insert(all, view)
		end
	end
	table.sort(all, function(left, right)
		if left.free == right.free then
			return left.listingId < right.listingId
		end
		return left.free < right.free
	end)
	return ok(all)
end

--[=[
	Reads one listing record by id.

	@return Result<Listing?>
	@within QuickPlay
]=]
function QuickPlay.get(self: any, listingId: string): any
	local success, listing = Listings.get(self._store, self._keys, listingId)
	if not success then
		return err("StoreUnavailable", tostring(listing), true)
	end
	if listing == nil or listing.expiresAt <= self._clock() then
		return ok(nil)
	end
	return ok(listing)
end

--[=[
	Heartbeats whichever hosted listings are due. Driven by the queue's worker
	pass, so `queue:step()` covers it.

	@within QuickPlay
]=]
function QuickPlay.step(self: any, mono: number)
	if next(self._hosted) == nil then
		return
	end
	local due = nil
	for _, handle in self._hosted do
		if mono >= handle._nextBeat then
			due = due or {}
			table.insert(due, handle)
		end
	end
	if due == nil then
		return
	end
	for _, handle in due do
		self:_beat(handle)
	end
end

--[=[
	Hosted listings on this server, for [Matchmaker:health].

	@within QuickPlay
]=]
function QuickPlay.hostedCount(self: any): number
	local count = 0
	for _ in self._hosted do
		count += 1
	end
	return count
end

--[=[
	Delists everything this server is hosting.

	Called from [Matchmaker:stop], so a match server bound to `game:BindToClose`
	stops taking players the moment it starts shutting down rather than after
	`listingExpiration`. A server that dies without this is cleaned up by expiry
	anyway; this only makes it immediate.

	@within QuickPlay
]=]
function QuickPlay.closeAll(self: any)
	for _, handle in self._hosted do
		Listings.remove(self._store, self._keys, handle._map, handle.id)
	end
	table.clear(self._hosted)
end

return QuickPlay
