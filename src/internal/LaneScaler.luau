--!strict

--[=[
	@class LaneScaler

	Chooses how a partition is divided into lanes, and changes it at runtime.

	Active when `lanes` is `"auto"`, which is the default. A pinned count skips
	this entirely: no record is written and no resize occurs.

	### The shared record

	One MemoryStore entry per partition holds `{ layout, previous, changedAt,
	touchedAt }`. Servers read it to decide where to write tickets, cached for
	`LANE_STATE_REFRESH` (30 s), and any worker may change it by compare-and-set.
	There is no coordinator. A missing or malformed record falls back to the last
	value this server saw, or to a single lane.

	Because the record only changes on a resize and a partition can hold steady
	for hours, whichever server notices it aging past half its TTL rewrites it
	unchanged. Losing it would drop the boundaries with it.

	### Resize rules

	Each worker judges only the lane it holds, from the depth of that lane alone.

	- **Grow** after `LANE_SATURATED_PASSES` (3) consecutive scans that return a
	  full batch. A saturated lane means the worker sees only its oldest slice.
	  In band mode the lane splits in two at the median rating the worker
	  observed in it; in hash mode the count doubles.
	- **Shrink** after `LANE_STARVED_PASSES` (5) consecutive scans below
	  `LANE_STARVED_DEPTH` (8) candidates, while the count is above one. In band
	  mode the lane merges into a neighbour; in hash mode the count halves.
	- Changes are at least `ticketExpiration` apart.

	### When a band refuses to split

	A band narrower than the rating window would separate players who are
	supposed to match each other, so a lane whose observed ratings span less than
	`LANE_SPLIT_SPREAD` windows is left alone however deep it gets. That is the
	rule that keeps a thin, tightly-clustered population, which is what the top
	of the ladder looks like, in one lane where it can actually match.

	It also means band boundaries settle at roughly the rating window apart
	rather than subdividing forever, so growth stops where extra parallelism
	would start costing matches.

	Hash counts are always powers of two, starting from one, which is what makes
	`Lanes.legacyLanes` exact for them.

	### Why a resize does not lose tickets

	The layout's generation is stamped into every lane key, so servers holding
	different generations read and write separate key spaces. A ticket stays in
	the lane its writer chose, and that writer keeps scanning the lane for as
	long as the ticket lives. Workers on the new generation additionally read the
	old lanes their own draws from, so tickets written under either layout can
	still match each other.

	The cooldown exists so an abandoned generation fully drains before another
	change lands, which means a lane name is never reused while stale entries
	remain in it.
]=]

local Defaults = require(script.Parent.Parent.Defaults)
local Lanes = require(script.Parent.Lanes)

type Layout = Lanes.Layout

export type LaneState = {
	layout: Layout,
	previous: Layout?,
	changedAt: number,
	touchedAt: number,
}

type Cached = { state: LaneState, fetchedAt: number }
type Samples = { saturated: number, starved: number }

type ScalerProps = {
	_settings: any,
	_store: any,
	_cache: { [string]: Cached },
	_samples: { [string]: Samples },
	_touched: { [string]: number },
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
		_touched = {},
		changes = 0,
	}, LaneScaler)
end

local function defaultState(settings: any): LaneState
	return { layout = Lanes.starting(settings), previous = nil, changedAt = 0, touchedAt = 0 }
end

local function sanitize(settings: any, raw: any): LaneState?
	if type(raw) ~= "table" then
		return nil
	end
	local layout = Lanes.validate(raw.layout, settings.laneSplit, Defaults.LANE_MAX)
	if layout == nil then
		return nil
	end
	local changedAt = if type(raw.changedAt) == "number" then raw.changedAt else 0
	return {
		layout = layout,
		previous = Lanes.validate(raw.previous, settings.laneSplit, Defaults.LANE_MAX),
		changedAt = changedAt,
		touchedAt = if type(raw.touchedAt) == "number" then raw.touchedAt else changedAt,
	}
end

--[=[
	Rewrites an unchanged record to reset its TTL, once it is over halfway to
	expiring.

	A partition that holds one layout for longer than `laneStateExpiration` would
	otherwise lose the record, and with it the boundaries every server is writing
	against, while tickets are still live in those lanes.

	@within LaneScaler
	@private
]=]
function LaneScaler._touch(self: LaneScaler, partition: string, state: LaneState)
	local settings = self._settings
	-- Generation zero is the fallback every server already agrees on, so there
	-- is nothing worth keeping alive.
	if state.layout.generation == 0 then
		return
	end

	local now = settings.clock()
	local last = math.max(state.touchedAt, self._touched[partition] or 0)
	if now - last < settings.laneStateExpiration / 2 then
		return
	end

	local success = self._store:update(
		settings.keys.lanes,
		partition,
		settings.laneStateExpiration,
		function(current: any): any
			local existing = sanitize(settings, current)
			-- Somebody resized in the meantime; their write already reset the TTL.
			if existing == nil or existing.layout.generation ~= state.layout.generation then
				return nil
			end
			existing.touchedAt = now
			return existing
		end,
		1
	)
	if success then
		self._touched[partition] = now
	end
end

--[=[
	The layout to use for `partition`, cached for `LANE_STATE_REFRESH` seconds.

	A stale value is safe: the ticket is written into the previous generation's
	lane, which its writer continues to scan and which workers on the new one
	read as a legacy map.

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
	else
		self:_touch(partition, state :: LaneState)
	end

	self._cache[partition] = { state = state :: LaneState, fetchedAt = now }
	return state :: LaneState
end

--[[
	Where to cut a saturated band in two.

	The median of what the worker saw, nudged up to the first value above the
	smallest so both halves keep something, and refused outright when the whole
	lane fits inside `LANE_SPLIT_SPREAD` rating windows. See the note on this
	class for why that refusal matters more than the extra parallelism.
]]
local function splitPoint(settings: any, ratings: { number }?): number?
	local rating = settings.rating
	if rating == nil or ratings == nil or #ratings < 2 then
		return nil
	end

	local sorted = table.clone(ratings)
	table.sort(sorted)
	local smallest = sorted[1]
	if sorted[#sorted] - smallest < rating.window * Defaults.LANE_SPLIT_SPREAD then
		return nil
	end

	for index = #sorted // 2 + 1, #sorted do
		if sorted[index] > smallest then
			return sorted[index]
		end
	end
	return nil
end

--[[ The layout one lane too deep for its worker implies. ]]
local function grow(settings: any, descriptor: any, ratings: { number }?): Layout?
	local layout: Layout = descriptor.layout
	if layout.mode ~= "band" then
		return Lanes.hashed(layout.count * 2, layout.generation + 1)
	end
	local value = splitPoint(settings, ratings)
	if value == nil then
		return nil
	end
	return Lanes.split(layout, descriptor.lane, value)
end

--[[ The layout one lane too shallow to be worth holding implies. ]]
local function shrink(descriptor: any): Layout?
	local layout: Layout = descriptor.layout
	if layout.mode ~= "band" then
		return Lanes.hashed(layout.count // 2, layout.generation + 1)
	end
	return Lanes.merge(layout, descriptor.lane)
end

--[=[
	Records one scan's result for the lane `descriptor` addresses, and resizes if
	the thresholds are met.

	@param depth -- Candidates the scan returned from the lane's own map.
	@param cap -- Depth at which the lane counts as saturated.
	@param ratings -- Ratings of those candidates, used to place a band split.
	@return Layout? -- The new layout, if this observation triggered a change.
	@within LaneScaler
]=]
function LaneScaler.observe(
	self: LaneScaler,
	descriptor: any,
	depth: number,
	cap: number,
	ratings: { number }?
): Layout?
	local settings = self._settings
	if settings.laneMode ~= "auto" then
		return nil
	end

	-- Keyed by the lease key, which carries the generation, so a layout change
	-- starts every lane's tally over rather than carrying a verdict about a lane
	-- that no longer exists.
	local samples = self._samples[descriptor.key]
	if samples == nil then
		samples = { saturated = 0, starved = 0 }
		self._samples[descriptor.key] = samples
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

	local layout: Layout = descriptor.layout
	local target: Layout? = nil
	local decided = false
	if samples.saturated >= Defaults.LANE_SATURATED_PASSES and layout.count < Defaults.LANE_MAX then
		decided = true
		target = grow(settings, descriptor, ratings)
	elseif samples.starved >= Defaults.LANE_STARVED_PASSES and layout.count > Defaults.LANE_MIN then
		decided = true
		target = shrink(descriptor)
	end

	if decided then
		-- Reset even when nothing came of it, so a band that refuses to split
		-- reconsiders every few scans rather than on every one.
		samples.saturated = 0
		samples.starved = 0
	end
	if target == nil then
		return nil
	end
	return self:_apply(descriptor.partition, layout, target)
end

--[=[
	Drops the tally for a lane this server no longer holds.

	@within LaneScaler
]=]
function LaneScaler.forget(self: LaneScaler, key: string)
	self._samples[key] = nil
end

--[=[
	Moves a partition to `target` if it is still on `from` and the cooldown has
	elapsed.

	The compare-and-set means several servers proposing at once is safe: one
	wins, and the others observe the result on their next read. Proposals are
	guarded on the generation rather than the count, since two band layouts of
	the same size are not interchangeable.

	@within LaneScaler
	@private
]=]
function LaneScaler._apply(self: LaneScaler, partition: string, from: Layout, target: Layout): Layout?
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
			if state.layout.generation ~= from.generation or now - state.changedAt < settings.ticketExpiration then
				return nil
			end

			result = { layout = target, previous = state.layout, changedAt = now, touchedAt = now }
			applied = true
			return result
		end,
		3
	)

	if not success or not applied or result == nil then
		return nil
	end

	local state = result :: LaneState
	self._cache[partition] = { state = state, fetchedAt = settings.monotonic() }
	self._touched[partition] = now
	self.changes += 1
	return state.layout
end

--[=[
	The previous layout, while it could still hold live tickets. Returns `nil`
	once it has drained, at which point workers stop reading its lanes.

	@within LaneScaler
]=]
function LaneScaler.draining(self: LaneScaler, state: LaneState): Layout?
	if state.previous == nil then
		return nil
	end
	if self._settings.clock() - state.changedAt >= self._settings.ticketExpiration then
		return nil
	end
	return state.previous
end

return LaneScaler
