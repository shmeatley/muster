--!strict

--[=[
	@class LaneScaler

	Decides how many lanes a partition should have, and moves it there safely.

	### The shared record

	One MemoryStore entry per partition holds `{ count, previous, changedAt }`.
	Every server reads it (cached for `LANE_STATE_REFRESH` seconds) to know where
	to write tickets, and any worker may propose a change through a
	compare-and-set. There is no coordinator.

	### Why resizing is safe

	The count is stamped into every lane key, so servers that disagree about it
	write to *different* key spaces rather than corrupting one. A ticket is
	always readable in the lane its writer put it in — the writer keeps scanning
	that lane for as long as the ticket lives, and workers on the new count also
	read the old maps through `Lanes.legacyMaps`. Nothing is stranded, and the
	two pools see each other throughout.

	The cooldown between changes is a full `ticketExpiration`. That is deliberate:
	it guarantees every ticket written under an abandoned count has expired or
	matched before that count can come back into use, so a lane name is never
	reused while stale entries sit in it.

	### When it changes

	Each worker judges only the lane it holds. Lanes are hashed uniformly, so one
	lane's depth times the count estimates the whole queue.

	- **Grow** (double) after `LANE_SATURATED_PASSES` consecutive scans that come
	  back at the batch cap. A saturated lane means the worker is only seeing the
	  oldest slice of it, which biases matching.
	- **Shrink** (halve) after `LANE_STARVED_PASSES` consecutive scans below
	  `LANE_STARVED_DEPTH`, when the count is above 1. Over-sharding is the worse
	  failure: it scatters a thin queue so nobody matches at all.

	Both directions are gated on consecutive observations, so a single burst or
	lull does not move anything.
]=]

local Defaults = require(script.Parent.Parent.Defaults)
local Lanes = require(script.Parent.Lanes)

export type LaneState = {
	count: number,
	previous: number?,
	changedAt: number,
}

type Cached = { state: LaneState, fetchedAt: number }
type Samples = { saturated: number, starved: number }

type ScalerProps = {
	_settings: any,
	_store: any,
	_cache: { [string]: Cached },
	_samples: { [string]: Samples },
	changes: number,
}

local LaneScaler = {}
LaneScaler.__index = LaneScaler

export type LaneScaler = typeof(setmetatable({} :: ScalerProps, LaneScaler))

--[=[
	@within LaneScaler
]=]
function LaneScaler.new(settings: any, store: any): LaneScaler
	return setmetatable({
		_settings = settings,
		_store = store,
		_cache = {},
		_samples = {},
		changes = 0,
	}, LaneScaler)
end

local function defaultState(settings: any): LaneState
	return { count = settings.lanes, previous = nil, changedAt = 0 }
end

local function sanitize(settings: any, raw: any): LaneState?
	if type(raw) ~= "table" or not Lanes.isPowerOfTwo(raw.count) then
		return nil
	end
	if raw.count > Defaults.LANE_MAX then
		return nil
	end
	return {
		count = raw.count,
		previous = if Lanes.isPowerOfTwo(raw.previous) then raw.previous else nil,
		changedAt = if type(raw.changedAt) == "number" then raw.changedAt else 0,
	}
end

--[=[
	The lane count to use for `partition` right now.

	Cached, because this is read on the enqueue path. A stale read is harmless:
	the ticket goes into the previous count's lane, which its writer keeps
	scanning and which the new count's workers read as a legacy map.

	@within LaneScaler
]=]
function LaneScaler.current(self: LaneScaler, partition: string): LaneState
	local settings = self._settings
	if settings.laneMode ~= "auto" then
		return defaultState(settings)
	end

	local now = settings.monotonic()
	local cached = self._cache[partition]
	if cached ~= nil and now - cached.fetchedAt < Defaults.LANE_STATE_REFRESH then
		return cached.state
	end

	local success, raw = self._store:get(settings.keys.lanes, partition, 5)
	local state = if success then sanitize(settings, raw) else nil
	if state == nil then
		-- Either the store is unhappy or nothing has been written yet. Falling
		-- back to what we last saw (or the configured start) keeps enqueueing
		-- working through an outage.
		state = if cached then cached.state else defaultState(settings)
	end

	self._cache[partition] = { state = state :: LaneState, fetchedAt = now }
	return state :: LaneState
end

--[=[
	Feeds one scan's result in. Returns the new count if this observation caused
	a change, otherwise `nil`.

	@param depth -- Candidates the scan returned.
	@param cap -- The batch size it asked for; reaching it means the lane is saturated.
	@within LaneScaler
]=]
function LaneScaler.observe(self: LaneScaler, partition: string, count: number, depth: number, cap: number): number?
	local settings = self._settings
	if settings.laneMode ~= "auto" then
		return nil
	end

	local samples = self._samples[partition]
	if samples == nil then
		samples = { saturated = 0, starved = 0 }
		self._samples[partition] = samples
	end

	if depth >= cap then
		samples.saturated += 1
		samples.starved = 0
	elseif depth < Defaults.LANE_STARVED_DEPTH then
		samples.starved += 1
		samples.saturated = 0
	else
		samples.saturated = 0
		samples.starved = 0
	end

	local target: number? = nil
	if samples.saturated >= Defaults.LANE_SATURATED_PASSES and count < Defaults.LANE_MAX then
		target = count * 2
	elseif samples.starved >= Defaults.LANE_STARVED_PASSES and count > Defaults.LANE_MIN then
		target = count // 2
	end

	if target == nil then
		return nil
	end

	samples.saturated = 0
	samples.starved = 0
	return self:_apply(partition, count, target)
end

--[=[
	Moves a partition to `target`, if nobody beat us to it and the cooldown has
	elapsed. The compare-and-set is what makes several servers proposing at once
	safe: exactly one wins and the rest see the result on their next read.

	@within LaneScaler
	@private
]=]
function LaneScaler._apply(self: LaneScaler, partition: string, from: number, target: number): number?
	local settings = self._settings
	local now = settings.clock()
	local applied = false
	local result: LaneState? = nil

	local success = self._store:update(
		settings.keys.lanes,
		partition,
		settings.laneStateExpiration,
		function(current: any): any
			applied = false
			result = nil

			local state = sanitize(settings, current) or defaultState(settings)
			-- Somebody already moved it, or moved it recently. Either way this
			-- observation is stale and must not be applied on top.
			if state.count ~= from or now - state.changedAt < settings.ticketExpiration then
				return nil
			end

			result = { count = target, previous = from, changedAt = now }
			applied = true
			return result
		end,
		3
	)

	if not success or not applied or result == nil then
		return nil
	end

	self._cache[partition] = { state = result :: LaneState, fetchedAt = settings.monotonic() }
	self.changes += 1
	return (result :: LaneState).count
end

--[=[
	Whether the count that `state` replaced could still hold live tickets. Once
	false, workers stop reading legacy maps.

	@within LaneScaler
]=]
function LaneScaler.draining(self: LaneScaler, state: LaneState): number?
	if state.previous == nil then
		return nil
	end
	if self._settings.clock() - state.changedAt >= self._settings.ticketExpiration then
		return nil
	end
	return state.previous
end

return LaneScaler
