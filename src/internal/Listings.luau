--!strict

--[=[
	@class Listings
	@private

	Store layout and atomic operations for the Quick Play listing index.

	The shape mirrors the ticket index exactly: a hash map holding the record,
	and a lane sorted map holding a small denormalized copy for discovery.
	Everything that changes occupancy goes through the hash map, because that is
	the only structure the [Store] contract can compare-and-set.

	### The sort key is free seats

	Entries are sorted by seats free, ascending, so a range read returns the
	*fullest joinable* match first, which is what backfill wants: a 7/8 game is
	completed before a 2/8 one is grown. A listing with no seats left is removed
	from the index entirely rather than left in it with a zero, so a range read is
	never spent on matches nobody can join.

	### Why claiming needs no lock

	Fifty lobby servers can see the same 7/8 match at once, and exactly one of
	them may take the last seat. `claim` is a single compare-and-set: the store
	re-runs the loser's transform against the winner's write, the seat is gone the
	second time around, and the loser moves on to its next candidate. There is no
	lease and no coordination, because the store is already a serialization point.

	### Reservations

	A host reports its player count on a heartbeat, so between beats the count is
	stale by up to `heartbeatInterval`. A claim writes a *reservation* holding the
	seats until the players actually arrive, which is what stops two lobbies from
	both filling the same slot inside one heartbeat window.

	A reservation retires in one of two ways, and both matter:

	- The host's next heartbeat reports every one of its userIds as present. They
	  arrived, so they are already inside `players` and counting them again would
	  under-fill the match for the rest of the reservation window.
	- It expires. That is the backstop for a player who took a seat and never
	  arrived, because their teleport failed or their server died.
]=]

local Types = require(script.Parent.Parent.Types)

type Listing<T> = Types.Listing<T>
type ListingView = Types.ListingView
type Reservation = Types.Reservation

local Listings = {}

--[=[
	Seats nobody holds: capacity less the last reported count, less every live
	reservation. Prune first, or seats already given up still count against it.

	@within Listings
]=]
function Listings.freeSlots(listing: any): number
	local held = 0
	for _, reservation in listing.reservations do
		held += reservation.size
	end
	return math.max(0, listing.capacity - listing.players - held)
end

local function isFulfilled(reservation: any, present: { [number]: boolean }?): boolean
	if present == nil then
		return false
	end
	for _, userId in reservation.userIds do
		if not present[userId] then
			return false
		end
	end
	return true
end

--[=[
	Drops reservations that have expired or whose players have arrived. Mutates
	`listing` and reports whether anything went.

	@param present -- A set of userIds the host currently holds, or `nil` to only age reservations out.
	@within Listings
]=]
function Listings.prune(listing: any, now: number, present: { [number]: boolean }?): boolean
	local kept = {}
	local dropped = false
	for _, reservation in listing.reservations do
		if reservation.expiresAt <= now or isFulfilled(reservation, present) then
			dropped = true
		else
			table.insert(kept, reservation)
		end
	end
	listing.reservations = kept
	return dropped
end

--[=[
	Whether a ticket of `size` may join. A closed or lapsed listing is refused
	even while its record survives, since the record outlives the host by design.

	@within Listings
]=]
function Listings.isJoinable(listing: any, size: number, now: number): boolean
	return listing ~= nil and listing.open == true and listing.expiresAt > now and Listings.freeSlots(listing) >= size
end

--[=[
	The reduced copy held in the lane index. Kept small because it is read far
	more often than the listing itself.

	@within Listings
]=]
function Listings.viewFor(listing: any, free: number): ListingView
	return {
		listingId = listing.id,
		serverId = listing.serverId,
		capacity = listing.capacity,
		free = free,
		updatedAt = listing.updatedAt,
	}
end

--------------------------------------------------------------------------------
-- Index
--------------------------------------------------------------------------------

--[=[
	Writes the listing's index entry, or removes it once there is nothing left to
	join. Removing rather than writing a zero is what keeps a range read full of
	matches a searcher can actually use.

	@within Listings
]=]
function Listings.index(store: any, qp: any, map: string, listing: any, free: number): boolean
	if free <= 0 or listing.open ~= true then
		local removed = store:sortedRemove(map, listing.id, 5)
		return removed
	end
	local written = store:sortedSet(map, listing.id, Listings.viewFor(listing, free), qp.indexExpiration, free, 4)
	return written
end

--[=[
	Reads the joinable listings in one lane, oldest generation included.

	The lane's own map is read first so its entries are the leading run of the
	result, which is what lets [LaneScaler] judge this lane's depth from them
	alone. Maps from a generation still draining follow, so a resize never hides a
	listing that has not migrated yet.

	@return { ListingView } -- Fullest first.
	@return number -- How many came from the lane's own map.
	@within Listings
]=]
function Listings.read(store: any, descriptor: any, count: number): ({ ListingView }, number)
	local maps = { descriptor.map }
	for _, legacy in descriptor.legacy do
		table.insert(maps, legacy)
	end

	local views = {}
	local seen = {}
	local ownCount = 0
	local perMap = if #maps > 1 then math.max(1, math.ceil(count / #maps)) else count

	for index, map in maps do
		local success, items = store:sortedRange(map, perMap, 5)
		if success then
			for _, item in items do
				local value = item.value
				-- Deduplicated because a listing mid-migration is briefly in both
				-- its old lane and its new one.
				if value ~= nil and not seen[value.listingId] then
					seen[value.listingId] = true
					table.insert(views, value)
					if index == 1 then
						ownCount += 1
					end
				end
			end
		end
	end

	return views, ownCount
end

--------------------------------------------------------------------------------
-- Record
--------------------------------------------------------------------------------

--[=[
	Writes a new listing record.

	@within Listings
]=]
function Listings.publish(store: any, keys: any, qp: any, listing: any): (boolean, any)
	return store:set(keys.quickplay, listing.id, listing, qp.listingExpiration, 3)
end

--[=[
	Reads one listing record.

	@within Listings
]=]
function Listings.get(store: any, keys: any, listingId: string): (boolean, any)
	return store:get(keys.quickplay, listingId, 5)
end

--[=[
	Takes `reservation.size` seats, or nothing at all.

	The whole contention story lives in this transform. See the note on this
	class for why one compare-and-set is sufficient.

	@return boolean -- True when the seats are ours.
	@return any -- The listing as it stands after the write, for refreshing the index.
	@within Listings
]=]
function Listings.claim(
	store: any,
	keys: any,
	qp: any,
	listingId: string,
	reservation: any,
	now: number
): (boolean, any)
	local claimed = false
	local result: any = nil

	local success = store:update(keys.quickplay, listingId, qp.listingExpiration, function(current: any): any
		-- Reset on every invocation: the transform may be re-run after a
		-- compare-and-set conflict, and a flag left set from the losing attempt
		-- would report a seat that was never taken.
		claimed = false
		result = nil

		if current == nil or current.open ~= true or current.expiresAt <= now then
			return nil
		end
		-- Seats given up since the last heartbeat are ours to take.
		Listings.prune(current, now, nil)
		if Listings.freeSlots(current) < reservation.size then
			return nil
		end

		table.insert(current.reservations, reservation)
		claimed = true
		result = current
		return current
	end, 1)

	return success and claimed, result
end

--[=[
	Gives a reservation's seats back, for a teleport that failed or a ticket that
	turned out to be spoken for.

	@within Listings
]=]
function Listings.release(store: any, keys: any, qp: any, listingId: string, reservationId: string): (boolean, any)
	local released = false
	local result: any = nil

	local success = store:update(keys.quickplay, listingId, qp.listingExpiration, function(current: any): any
		released = false
		result = nil

		if current == nil then
			return nil
		end
		local kept = {}
		for _, reservation in current.reservations do
			if reservation.id == reservationId then
				released = true
			else
				table.insert(kept, reservation)
			end
		end
		-- Already gone, most likely retired by a heartbeat that saw the players
		-- arrive. Writing again would only reset the TTL.
		if not released then
			return nil
		end

		current.reservations = kept
		result = current
		return current
	end, 2)

	return success and released, result
end

--[=[
	Refreshes a listing: its player count, its lease on life, and whichever
	reservations have now been fulfilled.

	@param update -- `players`, `present`, `open`, and the lane stamp when migrating.
	@within Listings
]=]
function Listings.heartbeat(store: any, keys: any, qp: any, listingId: string, update: any, now: number): (boolean, any)
	local beat = false
	local result: any = nil

	local success = store:update(keys.quickplay, listingId, qp.listingExpiration, function(current: any): any
		beat = false
		result = nil

		if current == nil then
			return nil
		end

		current.players = update.players
		current.open = update.open
		current.updatedAt = now
		current.expiresAt = now + qp.listingExpiration
		if update.lane ~= nil then
			current.lane = update.lane
			current.laneCount = update.laneCount
			current.laneGeneration = update.laneGeneration
		end
		Listings.prune(current, now, update.present)

		beat = true
		result = current
		return current
	end, 3)

	return success and beat, result
end

--[=[
	Removes a listing and its index entry outright, for a host shutting down
	cleanly. A host that dies instead is evicted by `listingExpiration`.

	@within Listings
]=]
function Listings.remove(store: any, keys: any, map: string, listingId: string)
	store:sortedRemove(map, listingId, 4)
	store:remove(keys.quickplay, listingId, 3)
end

return table.freeze(Listings)
