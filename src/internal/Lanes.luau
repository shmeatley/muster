--!strict

--[=[
	@class Lanes

	Key layout for the queue index.

	A queue is divided into partitions, whatever `partitionKey` returns or `"all"`
	by default, and each partition into lanes. A ticket lands in exactly one lane
	and is matched only against the other tickets in it.

	### What shares a lane

	Lanes buy parallelism by splitting the pool, so *which* tickets share one
	decides whether the split costs anything. There are two schemes, and the
	queue's own configuration picks between them:

	- **Bands**, on a rated queue left on `lanes = "auto"`. A lane is a
	  contiguous rating range: lane 0 holds everyone below the first boundary,
	  the last lane everyone above the last. Splitting a rated queue by rating
	  separates players who would not have matched anyway, so four high-rated
	  players queueing at once always land together.
	- **Hashes**, on an unrated queue or a pinned count. A ticket's lane is
	  `hash(ticketId) % count`. With no rating there is nothing to order players
	  by and every ticket may match every other, so an even spread is the best
	  split available.

	Both are deterministic: two servers holding the same layout agree on a
	ticket's lane without coordinating.

	### Generations

	[LaneScaler] changes the layout at runtime. A band layout can change without
	the count changing, so a monotonic generation number, alongside the count, is
	stamped into every key:

	```
	mu1:ranked:idx:EMEA:n04g7:02
	                    ^^^^^ ^^
	                   layout lane
	```

	The stamp is what makes changing the layout safe: servers that disagree about
	it read and write separate key spaces rather than one shared space, and a
	ticket always stays in the lane its writer chose. A descriptor's `legacy`
	covers the window where both generations hold live tickets.

	Sort keys are queue timestamps, so an ascending range read returns the oldest
	tickets first.
]=]

local Hash = require(script.Parent.Parent.Hash)

--[=[
	@interface Layout
	@within Lanes
	.generation number -- Monotonic per partition. Stamped into every key.
	.count number
	.mode "band" | "hash"
	.bounds { number } -- Band mode: `count - 1` ascending interior boundaries. Empty in hash mode.

	One partition's division into lanes, at one point in time.
]=]
export type Layout = {
	generation: number,
	count: number,
	mode: "band" | "hash",
	bounds: { number },
}

export type Descriptor = {
	key: string,
	partition: string,
	lane: number,
	layout: Layout,
	count: number,
	generation: number,
	-- The rating range this lane covers, infinite on the open ends. Both are
	-- infinite in hash mode, where a lane covers no particular range.
	low: number,
	high: number,
	map: string,
	-- Maps from the previous generation that could still hold tickets belonging
	-- to this lane. Empty once the old generation has drained.
	legacy: { string },
	-- The lanes either side of this one. Read only when this lane is too thin or
	-- too stale to match on its own; see `Engine._shouldWiden`.
	neighbours: { string },
}

local Lanes = {}

--[=[
	A hash layout of `count` lanes.

	@within Lanes
]=]
function Lanes.hashed(count: number, generation: number): Layout
	return { generation = generation, count = count, mode = "hash", bounds = {} }
end

--[=[
	A band layout with the given interior boundaries, which must be ascending.
	`{}` is the single lane covering every rating.

	@within Lanes
]=]
function Lanes.banded(bounds: { number }, generation: number): Layout
	return { generation = generation, count = #bounds + 1, mode = "band", bounds = bounds }
end

--[=[
	The layout a partition starts on, before anything has been observed: one
	lane, generation zero, in whichever mode this queue uses.

	@within Lanes
]=]
function Lanes.starting(settings: any): Layout
	if settings.laneSplit == "band" then
		return Lanes.banded({}, 0)
	end
	return Lanes.hashed(settings.lanes, 0)
end

--[=[
	The map name for one lane.

	`settings.indexInfix` picks the key space, defaulting to `"idx"` for the
	ticket index. [QuickPlay] passes `"qpidx"` through a derived settings table,
	which is what lets listings reuse this whole module without their keys ever
	colliding with a ticket lane's.

	@within Lanes
]=]
function Lanes.name(settings: any, partition: string, count: number, generation: number, lane: number): string
	local stamp = string.format("n%02dg%d", count, generation)
	local index = string.format("%02d", lane)
	local infix = settings.indexInfix or "idx"
	return `{settings.namespace}{settings.version}:{settings.name}:{infix}:{partition}:{stamp}:{index}`
end

--[=[
	The rating range `lane` covers, as a half-open `[low, high)`. Infinite on the
	open ends, and infinite on both in hash mode.

	@within Lanes
]=]
function Lanes.band(layout: Layout, lane: number): (number, number)
	if layout.mode ~= "band" then
		return -math.huge, math.huge
	end
	local low = if lane <= 0 then -math.huge else layout.bounds[lane]
	local high = if lane >= layout.count - 1 then math.huge else layout.bounds[lane + 1]
	return low, high
end

--[=[
	Which lane a ticket belongs to under `layout`. Deterministic, so two servers
	using the same layout agree without coordinating.

	`rating` is the ticket's party-aggregated rating and is only read in band
	mode, where it is what decides the lane. It is never absent there in
	practice, since a rated queue rejects a ticket without one; a missing rating
	falls into the lowest band.

	@within Lanes
]=]
function Lanes.laneFor(layout: Layout, ticketId: string, rating: number?): number
	if layout.count <= 1 then
		return 0
	end
	if layout.mode ~= "band" then
		return Hash.partition(ticketId, layout.count)
	end
	if rating == nil then
		return 0
	end

	-- The number of boundaries at or below the rating, found by bisection.
	local bounds = layout.bounds
	local lane = 0
	local low, high = 1, #bounds
	while low <= high do
		local middle = (low + high) // 2
		if rating >= bounds[middle] then
			lane = middle
			low = middle + 1
		else
			high = middle - 1
		end
	end
	return lane
end

--[=[
	The lanes of `previous` that may hold tickets belonging to `lane` under
	`layout`. A worker reads their maps alongside its own while the old
	generation drains.

	- **Bands**: a ticket's band follows from its rating, so the old lanes that
	  can hold one of this lane's tickets are exactly those whose range overlaps
	  this lane's. Layouts change by one boundary at a time, which makes that one
	  old lane after a split and two after a merge.
	- **Hashes**: both counts are powers of two, since the scaler only doubles or
	  halves, which makes this exact. A ticket hashes to `h % count`: growing, a
	  ticket in old lane `o` satisfies `h % previous == o`, so reading old lane
	  `lane % previous` covers it; shrinking, `h % count` equals
	  `(h % previous) % count`, so every old lane `o` with `o % count == lane`
	  contributes.

	Either way the result holds at most `previous.count / count` entries.

	@within Lanes
]=]
function Lanes.legacyLanes(layout: Layout, lane: number, previous: Layout?): { number }
	local lanes = {}
	if previous == nil or previous.generation == layout.generation or previous.mode ~= layout.mode then
		return lanes
	end

	if layout.mode == "band" then
		local low, high = Lanes.band(layout, lane)
		for old = 0, previous.count - 1 do
			local oldLow, oldHigh = Lanes.band(previous, old)
			if oldLow < high and low < oldHigh then
				table.insert(lanes, old)
			end
		end
		return lanes
	end

	if layout.count > previous.count then
		table.insert(lanes, lane % previous.count)
	elseif layout.count < previous.count then
		for old = lane, previous.count - 1, layout.count do
			table.insert(lanes, old)
		end
	else
		table.insert(lanes, lane)
	end
	return lanes
end

--[=[
	`legacyLanes` as map names.

	@within Lanes
]=]
function Lanes.legacyMaps(settings: any, partition: string, layout: Layout, lane: number, previous: Layout?): { string }
	local maps = {}
	if previous == nil then
		return maps
	end
	for _, old in Lanes.legacyLanes(layout, lane, previous) do
		table.insert(maps, Lanes.name(settings, partition, previous.count, previous.generation, old))
	end
	return maps
end

--[=[
	The maps of the lanes immediately either side of `lane`, which in band mode
	are the two holding the ratings closest to it. Empty in hash mode, where a
	neighbouring lane holds nothing more relevant than any other lane does.

	@within Lanes
]=]
function Lanes.neighbours(settings: any, partition: string, layout: Layout, lane: number): { string }
	local maps = {}
	if layout.mode ~= "band" then
		return maps
	end
	if lane > 0 then
		table.insert(maps, Lanes.name(settings, partition, layout.count, layout.generation, lane - 1))
	end
	if lane < layout.count - 1 then
		table.insert(maps, Lanes.name(settings, partition, layout.count, layout.generation, lane + 1))
	end
	return maps
end

--[=[
	@param previous -- The generation being drained, if one still is.
	@within Lanes
]=]
function Lanes.descriptor(settings: any, partition: string, layout: Layout, lane: number, previous: Layout?): Descriptor
	local low, high = Lanes.band(layout, lane)
	local stamp = string.format("n%02dg%d", layout.count, layout.generation)
	return {
		-- The lease key carries the layout too, so a worker holding lane 0 of one
		-- generation does not block lane 0 of the next.
		key = `{partition}:{stamp}:{string.format("%02d", lane)}`,
		partition = partition,
		lane = lane,
		layout = layout,
		count = layout.count,
		generation = layout.generation,
		low = low,
		high = high,
		map = Lanes.name(settings, partition, layout.count, layout.generation, lane),
		legacy = Lanes.legacyMaps(settings, partition, layout, lane, previous),
		neighbours = Lanes.neighbours(settings, partition, layout, lane),
	}
end

--[=[
	The lane descriptor a given ticket lands in under `layout`.

	@within Lanes
]=]
function Lanes.forTicket(
	settings: any,
	partition: string,
	layout: Layout,
	ticketId: string,
	rating: number?,
	previous: Layout?
): Descriptor
	return Lanes.descriptor(settings, partition, layout, Lanes.laneFor(layout, ticketId, rating), previous)
end

--[=[
	Every lane in a partition under `layout`.

	@within Lanes
]=]
function Lanes.allFor(settings: any, partition: string, layout: Layout, previous: Layout?): { Descriptor }
	local result = table.create(layout.count)
	for lane = 0, layout.count - 1 do
		table.insert(result, Lanes.descriptor(settings, partition, layout, lane, previous))
	end
	return result
end

--[=[
	Splits `lane` in two at `value`, which becomes the lower bound of the upper
	half. Returns `nil` when the cut falls outside the lane, which would leave an
	empty band, or when the layout is not banded.

	@within Lanes
]=]
function Lanes.split(layout: Layout, lane: number, value: number): Layout?
	if layout.mode ~= "band" then
		return nil
	end
	local low, high = Lanes.band(layout, lane)
	if not (value > low and value < high) then
		return nil
	end
	local bounds = table.clone(layout.bounds)
	table.insert(bounds, lane + 1, value)
	return Lanes.banded(bounds, layout.generation + 1)
end

--[=[
	Merges `lane` into a neighbour by dropping the boundary between them: the one
	below it where there is one, so a merge folds a lane into the pool of
	slightly weaker players rather than jumping upward.

	@within Lanes
]=]
function Lanes.merge(layout: Layout, lane: number): Layout?
	if layout.mode ~= "band" or layout.count <= 1 then
		return nil
	end
	local bounds = table.clone(layout.bounds)
	table.remove(bounds, if lane > 0 then lane else 1)
	return Lanes.banded(bounds, layout.generation + 1)
end

--[=[
	Reads a stored layout back, or `nil` if it is absent, malformed, or not the
	mode this queue uses. Takes `any` on purpose: it is the validator for values
	read out of MemoryStore.

	@within Lanes
]=]
function Lanes.validate(raw: any, mode: string, maxCount: number): Layout?
	if type(raw) ~= "table" or raw.mode ~= mode then
		return nil
	end

	local generation = raw.generation
	if type(generation) ~= "number" or generation ~= generation or generation < 0 or generation % 1 ~= 0 then
		return nil
	end

	if mode ~= "band" then
		if not Lanes.isPowerOfTwo(raw.count) or raw.count > maxCount then
			return nil
		end
		return Lanes.hashed(raw.count, generation)
	end

	if type(raw.bounds) ~= "table" then
		return nil
	end
	local bounds = {}
	local last = -math.huge
	for index = 1, #raw.bounds do
		local bound = raw.bounds[index]
		if type(bound) ~= "number" or bound ~= bound or bound <= last or bound == math.huge then
			return nil
		end
		last = bound
		bounds[index] = bound
	end
	if #bounds + 1 > maxCount then
		return nil
	end
	return Lanes.banded(bounds, generation)
end

--[=[
	Rounds `count` down to a power of two, clamped to `[min, max]`.

	@within Lanes
]=]
function Lanes.clamp(count: number, min: number, max: number): number
	local result = 1
	while result * 2 <= count and result * 2 <= max do
		result *= 2
	end
	return math.max(min, math.min(max, result))
end

--[=[
	Whether `count` is a power of two. Accepts any type, since it validates
	values read back from the store.

	@within Lanes
]=]
function Lanes.isPowerOfTwo(count: any): boolean
	-- Takes `any` on purpose: it is the validator for values read back out of
	-- MemoryStore, which may be absent or garbage.
	if type(count) ~= "number" or count ~= count or count < 1 or count % 1 ~= 0 then
		return false
	end
	return bit32.band(count, count - 1) == 0
end

return table.freeze(Lanes)
