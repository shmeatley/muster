--!strict

--[=[
	@class Lanes

	Key layout for the queue index.

	A queue is divided into partitions, whatever `partitionKey` returns or `"all"`
	by default, and each partition into lanes. A ticket is hashed into exactly one
	lane and matched only against the other tickets in it.

	Lanes trade pool size for parallelism. One lane means a single worker sees
	every queued ticket. Four lanes means four servers can match at once, each
	seeing a quarter of them. More lanes only help once one lane is deep enough
	to fill matches on its own.

	[LaneScaler] adjusts the count at runtime, so the count is stamped into every
	key:

	```
	mu1:ranked:idx:EMEA:n04:02
	                     ^^^ ^^
	                   count lane
	```

	The stamp is what makes changing the count safe: servers that disagree about
	it read and write separate key spaces rather than one shared space, and a
	ticket always stays in the lane its writer chose. `legacyMaps` covers the
	window where both counts hold live tickets.

	Sort keys are queue timestamps, so an ascending range read returns the oldest
	tickets first.
]=]

local Hash = require(script.Parent.Parent.Hash)

export type Descriptor = {
	key: string,
	partition: string,
	lane: number,
	count: number,
	map: string,
	-- Maps from the previous count that could still hold tickets belonging to
	-- this lane. Empty once the old generation has drained.
	legacy: { string },
}

local Lanes = {}

--[=[
	@within Lanes
]=]
function Lanes.name(settings: any, partition: string, count: number, lane: number): string
	local stamp = string.format("n%02d", count)
	return `{settings.namespace}{settings.version}:{settings.name}:idx:{partition}:{stamp}:{string.format("%02d", lane)}`
end

--[=[
	Which lane a ticket belongs to at a given count. Deterministic, so two
	servers using the same count agree without coordinating.

	@within Lanes
]=]
function Lanes.laneFor(count: number, ticketId: string): number
	if count <= 1 then
		return 0
	end
	return Hash.partition(ticketId, count)
end

--[=[
	The maps from `previous` that may hold tickets belonging to `lane` at
	`count`. A worker reads these alongside its own lane while the old count
	drains.

	Both counts are powers of two, since [LaneScaler] only doubles or halves from
	one, which makes this exact. A ticket hashes to `h % count`:

	- **Growing** (`count > previous`): a ticket in old map `o` satisfies
	  `h % previous == o`, so its new lane is one of `o`, `o + previous`,
	  `o + 2*previous`, and so on. Reading old map `lane % previous` covers it.
	- **Shrinking** (`count < previous`): `h % count == (h % previous) % count`,
	  so every old map `o` with `o % count == lane` contributes.

	Either way the result holds at most `previous / count` entries: one when
	growing, two on a single halving.

	@within Lanes
]=]
function Lanes.legacyMaps(settings: any, partition: string, count: number, lane: number, previous: number?): { string }
	if previous == nil or previous == count then
		return {}
	end

	local maps = {}
	if count > previous then
		table.insert(maps, Lanes.name(settings, partition, previous, lane % previous))
	else
		for old = lane, previous - 1, count do
			table.insert(maps, Lanes.name(settings, partition, previous, old))
		end
	end
	return maps
end

--[=[
	@param previous -- The count being drained, if one still is.
	@within Lanes
]=]
function Lanes.descriptor(settings: any, partition: string, count: number, lane: number, previous: number?): Descriptor
	return {
		-- The lease key carries the count too, so a worker holding lane 0 of a
		-- 2-lane space does not block lane 0 of a 4-lane one.
		key = `{partition}:{string.format("n%02d", count)}:{string.format("%02d", lane)}`,
		partition = partition,
		lane = lane,
		count = count,
		map = Lanes.name(settings, partition, count, lane),
		legacy = Lanes.legacyMaps(settings, partition, count, lane, previous),
	}
end

--[=[
	The lane descriptor a given ticket lands in at `count`.

	@within Lanes
]=]
function Lanes.forTicket(
	settings: any,
	partition: string,
	count: number,
	ticketId: string,
	previous: number?
): Descriptor
	return Lanes.descriptor(settings, partition, count, Lanes.laneFor(count, ticketId), previous)
end

--[=[
	Every lane in a partition at `count`.

	@within Lanes
]=]
function Lanes.allFor(settings: any, partition: string, count: number, previous: number?): { Descriptor }
	local result = table.create(count)
	for lane = 0, count - 1 do
		table.insert(result, Lanes.descriptor(settings, partition, count, lane, previous))
	end
	return result
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
