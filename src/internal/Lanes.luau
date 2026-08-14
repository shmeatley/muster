--!strict

--[=[
	@class Lanes

	Key layout for the queue index.

	A queue is split into `partition` values (whatever `partitionKey` returns,
	or `"all"`), and each partition into `lanes` sorted maps. A ticket is hashed
	into exactly one lane and is only ever matched against the other tickets in
	it.

	**Lanes buy parallelism by splitting the pool.** One lane means one worker
	sees every queued ticket and matches on its first scan; four lanes means
	four servers can match simultaneously, each seeing a quarter of the queue.
	That trade only pays once a single lane is deep enough to fill matches on
	its own, which is why the default is 1 — a two-player queue with 64 lanes
	would leave its two players in different lanes, never matching, which is
	exactly the failure this default exists to prevent.

	Sort keys are queue timestamps, so an ascending range read is oldest-first
	and matching is fair by default.
]=]

local Hash = require(script.Parent.Parent.Hash)

export type Descriptor = {
	key: string,
	partition: string,
	lane: number,
	map: string,
}

local Lanes = {}

--[=[
	@within Lanes
]=]
function Lanes.name(settings: any, partition: string, lane: number): string
	return `{settings.namespace}{settings.version}:{settings.name}:idx:{partition}:{string.format("%02d", lane)}`
end

--[=[
	Which lane a ticket belongs to. Deterministic across servers, which is what
	lets a worker holding one lane know that no other lane contains its ticket.

	@within Lanes
]=]
function Lanes.laneFor(settings: any, ticketId: string): number
	if settings.lanes <= 1 then
		return 0
	end
	return Hash.partition(ticketId, settings.lanes)
end

--[=[
	@within Lanes
]=]
function Lanes.descriptor(settings: any, partition: string, lane: number): Descriptor
	return {
		key = `{partition}:{string.format("%02d", lane)}`,
		partition = partition,
		lane = lane,
		map = Lanes.name(settings, partition, lane),
	}
end

--[=[
	The lane descriptor a given ticket landed in.

	@within Lanes
]=]
function Lanes.forTicket(settings: any, partition: string, ticketId: string): Descriptor
	return Lanes.descriptor(settings, partition, Lanes.laneFor(settings, ticketId))
end

--[=[
	Every lane in a partition, for a worker deciding what else it could take on.

	@within Lanes
]=]
function Lanes.allFor(settings: any, partition: string): { Descriptor }
	local result = table.create(settings.lanes)
	for lane = 0, settings.lanes - 1 do
		table.insert(result, Lanes.descriptor(settings, partition, lane))
	end
	return result
end

return table.freeze(Lanes)
