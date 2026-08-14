--!strict

--[=[
	@class LeaseManager

	A distributed lock with a fencing token, built on compare-and-set.

	Only the server holding a lane's lease scans it, which stops two servers
	forming overlapping matches from the same tickets.

	A lease alone is not sufficient. A server can stall on a long yield, a GC
	pause or a slow web call, lose its lease to the timeout, and resume still
	believing it holds one. So every lease carries a monotonically increasing
	`epoch`, and the commit checks that epoch inside its own transform — a
	stalled server's write is rejected by the store rather than by a check it
	could skip.

	Three properties keep the epoch meaningful:

	- Taking over an expired lease increments it, so the previous holder's token
	  is permanently stale.
	- Re-acquiring a lease you already hold keeps it, so renewal is not treated
	  as a takeover.
	- Releasing writes a tombstone instead of deleting the key, so the counter
	  survives a clean handoff rather than restarting at 1.

	Leases last `LEASE_DURATION` (15 s) and are renewed every
	`LEASE_RENEW_INTERVAL` (5 s), giving three attempts before expiry. The stored
	record lives three times as long as the lease so an idle gap cannot lose the
	epoch to expiry.
]=]

local Defaults = require(script.Parent.Parent.Defaults)

export type Lease = { ownerServerId: string, expiresAt: number, epoch: number }

type LeaseProps = {
	_store: any,
	_name: string,
	_ownerServerId: string,
	_clock: () -> number,
	_duration: number,
}

local LeaseManager = {}
LeaseManager.__index = LeaseManager

export type LeaseManager = typeof(setmetatable({} :: LeaseProps, LeaseManager))

--[=[
	Creates a lease manager over a store structure.

	@param ownerServerId -- Identifies this holder; leases are only renewable and releasable by their owner.
	@param options -- `clock` and `duration`.
	@within LeaseManager
]=]
function LeaseManager.new(store: any, name: string, ownerServerId: string, options: any?): LeaseManager
	local settings = options or {}
	return setmetatable({
		_store = store,
		_name = name,
		_ownerServerId = ownerServerId,
		_clock = settings.clock or os.time,
		_duration = settings.duration or Defaults.LEASE_DURATION,
	}, LeaseManager)
end

--[=[
	Takes the lease if it is free or expired, or refreshes it if this owner
	already holds it.

	@return Lease? -- The lease and its epoch, or `nil` if another owner holds it.

	@within LeaseManager
]=]
function LeaseManager.acquire(self: LeaseManager, key: string): Lease?
	local now = self._clock()
	local acquired = false
	local result: Lease? = nil

	-- The record outlives the lease by 3x so an idle gap cannot lose the epoch
	-- counter to TTL expiry and reset the fence.
	local success = self._store:update(self._name, key, self._duration * 3, function(current: any): any
		-- Reset on every invocation: the transform may be re-run after a
		-- compare-and-set conflict, and a flag left set from the losing attempt
		-- would report an acquisition that never happened.
		acquired = false
		result = nil

		if current == nil or current.expiresAt <= now then
			local epoch = if current then current.epoch + 1 else 1
			result = { ownerServerId = self._ownerServerId, expiresAt = now + self._duration, epoch = epoch }
			acquired = true
			return result
		elseif current.ownerServerId == self._ownerServerId then
			result = {
				ownerServerId = self._ownerServerId,
				expiresAt = now + self._duration,
				epoch = current.epoch,
			}
			acquired = true
			return result
		end
		return nil
	end, 2)

	return if success and acquired then result else nil
end

--[=[
	Extends a lease held at a known epoch.

	Fails if another owner took it, or if it was taken and returned, since the
	epoch will have moved on.

	@within LeaseManager
]=]
function LeaseManager.renew(self: LeaseManager, key: string, epoch: number): Lease?
	local now = self._clock()
	local renewed = false
	local result: Lease? = nil

	local success = self._store:update(self._name, key, self._duration * 3, function(current: any): any
		renewed = false
		result = nil
		if current == nil or current.ownerServerId ~= self._ownerServerId or current.epoch ~= epoch then
			return nil
		end
		result = { ownerServerId = self._ownerServerId, expiresAt = now + self._duration, epoch = epoch }
		renewed = true
		return result
	end, 2)

	return if success and renewed then result else nil
end

--[=[
	Whether this owner still holds `key` at `epoch`. A read, not a write; called
	before and after anything that yields.

	@within LeaseManager
]=]
function LeaseManager.validate(self: LeaseManager, key: string, epoch: number): boolean
	local success, lease = self._store:get(self._name, key, 2)
	return success
		and lease ~= nil
		and lease.ownerServerId == self._ownerServerId
		and lease.epoch == epoch
		and lease.expiresAt > self._clock()
end

--[=[
	Releases the lane immediately rather than letting it time out.

	Writes a tombstone instead of removing the key, so the next acquirer reads
	the stored epoch and increments it and fencing tokens stay monotonic across a
	clean handoff.

	@within LeaseManager
]=]
function LeaseManager.release(self: LeaseManager, key: string, epoch: number): boolean
	local released = false
	local success = self._store:update(self._name, key, self._duration, function(current: any): any
		released = false
		if current == nil or current.ownerServerId ~= self._ownerServerId or current.epoch ~= epoch then
			return nil
		end
		released = true
		return { ownerServerId = "", expiresAt = 0, epoch = epoch }
	end, 2)
	return success and released
end

return LeaseManager
