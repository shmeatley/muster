--!strict

--[=[
	@class LaneScaler

	Chooses how many lanes a partition is divided into, and changes it at
	runtime.

	Active when `lanes` is `"auto"`, which is the default. A pinned count skips
	this entirely: no record is written and no resize occurs.

	### The shared record

	One MemoryStore entry per partition holds `{ count, previous, changedAt }`.
	Servers read it to decide where to write tickets, cached for
	`LANE_STATE_REFRESH` (30 s), and any worker may change it by compare-and-set.
	There is no coordinator. A missing or malformed record falls back to the last
	value this server saw, or to one lane.

	### Resize rules

	- **Grow**, doubling, after `LANE_SATURATED_PASSES` (3) consecutive scans that
	  return a full batch. A saturated lane means the worker sees only its oldest
	  slice.
	- **Shrink**, halving, after `LANE_STARVED_PASSES` (5) consecutive scans below
	  `LANE_STARVED_DEPTH` (8) candidates, while the count is above one.
	- Changes are at least `ticketExpiration` apart.

	Each worker judges only the lane it holds. Because lanes are hashed
	uniformly, one lane's depth multiplied by the count approximates the queue.

	Counts are therefore always powers of two, starting from one, which is what
	makes `Lanes.legacyMaps` exact.

	### Why a resize does not lose tickets

	The count is stamped into every lane key, so servers holding different counts
	read and write separate key spaces. A ticket stays in the lane its writer
	chose, and that writer keeps scanning the lane for as long as the ticket
	lives. Workers on the new count additionally read the old maps their lane
	draws from, so tickets written under either count can still match each other.

	The cooldown exists so an abandoned count fully drains before it can be
	chosen again, which means a lane name is never reused while stale entries
	remain in it.
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
	The lane count to use for `partition`, cached for `LANE_STATE_REFRESH`
	seconds.

	A stale value is safe: the ticket is written into the previous count's lane,
	which its writer continues to scan and which workers on the new count read as
	a legacy map.

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
	Records one scan's result and resizes if the thresholds are met.

	@param depth -- Candidates the scan returned.
	@param cap -- Depth at which the lane counts as saturated.
	@return number? -- The new count, if this observation triggered a change.
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
	Moves a partition to `target` if the count still matches `from` and the
	cooldown has elapsed.

	The compare-and-set means several servers proposing at once is safe: one
	wins, and the others observe the result on their next read.

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
	The previous count, while it could still hold live tickets. Returns `nil`
	once it has drained, at which point workers stop reading legacy maps.

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
