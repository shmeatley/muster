--!strict

--[=[
	@class Defaults

	Protocol constants and tuning values.

	Values worth varying per game are exposed on [Matchmaker]'s configuration.
	The rest are protocol constants that every server must agree on: changing one
	requires draining the queue first, since servers running different values
	will disagree about expiry and ownership.

	```lua
	print(Muster.Defaults.LEASE_DURATION) -- 15
	```
]=]

local Defaults = {}

-- Bumped only on a breaking change to a stored record's shape. It is part of
-- every MemoryStore key, so a bump isolates old records rather than corrupting
-- readers mid-deploy.
Defaults.SCHEMA_VERSION = 1
-- The version is appended to this, so keys read `mu1:<queue>:tickets`. Set a
-- different `namespace` to run two fully independent deployments in one
-- universe.
Defaults.NAMESPACE = "mu"

-- How long a worker owns a lane before another server may take it. Renewed
-- every LEASE_RENEW_INTERVAL, giving three chances to renew before expiry.
-- The stored record lives 3x longer than the lease so the fencing epoch
-- survives an idle gap and stays monotonic.
Defaults.LEASE_DURATION = 15
Defaults.LEASE_RENEW_INTERVAL = 5

-- A claimed ticket is unavailable to other workers for this long. The window
-- has to outlast the whole commit path including a finalizer, so the resolved
-- value is this plus `finalizeTimeout`.
Defaults.CLAIM_DURATION = 20

-- A ticket self-evicts this long after its last heartbeat, which is how a
-- crashed server's tickets leave the queue without anyone cleaning up.
Defaults.TICKET_EXPIRATION = 180
Defaults.TICKET_HEARTBEAT_INTERVAL = 30
-- Index entries outlive their ticket slightly, so a scan never sees a lane
-- entry vanish out from under a ticket that is still live.
Defaults.INDEX_EXPIRATION = 190
Defaults.MATCH_EXPIRATION = 300

Defaults.PARTY_EXPIRATION = 2 * 60 * 60
Defaults.INVITE_EXPIRATION = 60
Defaults.MAX_PARTY_MEMBERS = 8
Defaults.MAX_PARTY_INVITES = 20

-- Queues start on a single lane and grow only once one lane cannot keep up.
-- Starting high is the classic way to break a small queue: with 64 lanes, two
-- players almost never land in the same one and nobody ever matches.
Defaults.LANES = 1
Defaults.LANE_MIN = 1
-- Counts are powers of two so a resize maps old lanes onto new ones exactly.
Defaults.LANE_MAX = 64
Defaults.MAX_LANES_PER_SERVER = 8
Defaults.EMPTY_PASSES_BEFORE_RELEASE = 3

-- Consecutive scans that come back full before the count doubles. A saturated
-- lane means the worker is only seeing its oldest slice.
Defaults.LANE_SATURATED_PASSES = 3
-- Consecutive shallow scans before it halves, and the depth that counts as
-- shallow. Shrinking is deliberately slower to trigger than growing: a brief
-- lull is common, and over-sharding a thin queue is the worse failure.
Defaults.LANE_STARVED_PASSES = 5
Defaults.LANE_STARVED_DEPTH = 8
-- How long a server may go before re-reading the shared lane count. A stale
-- read only means writing into the previous count's lane, which is still read.
Defaults.LANE_STATE_REFRESH = 30

Defaults.MIN_SCAN_DELAY = 0.25
Defaults.MAX_SCAN_DELAY = 5
Defaults.MIN_BATCH_SIZE = 10
-- MemoryStore caps GetRangeAsync at 200; staying under it keeps one scan to one
-- request.
Defaults.MAX_BATCH_SIZE = 100

Defaults.RATING_WINDOW = 200
Defaults.RATING_RELAX = 40
Defaults.RATING_UNBOUNDED = 60
-- A party queues at its mean rating pulled halfway toward its best player, so a
-- strong player cannot hide behind low-rated friends.
Defaults.PARTY_RATING_MAX_BIAS = 0.5

Defaults.FALLBACK_AFTER = 10

Defaults.FINALIZE_TIMEOUT = 5
-- Hard ceiling. A finalizer slower than this would push the claim window past
-- the point where crash recovery stays responsive.
Defaults.MAX_FINALIZE_TIMEOUT = 15

-- Poll backoff for the doorbell fallback: doubles from POLL_INTERVAL up to the
-- cap. The cap tightens when broadcasts look unhealthy.
Defaults.POLL_INTERVAL = 2
Defaults.POLL_INTERVAL_MAX = 30
Defaults.POLL_INTERVAL_UNHEALTHY = 5
Defaults.BROADCAST_UNHEALTHY_DURATION = 300

-- MessagingService caps a payload at 1 KB including its own framing, so the
-- inline envelope budget is deliberately well under that. Exceeding it is not
-- an error: the doorbell degrades to carrying just the matchId.
Defaults.INLINE_BROADCAST_BYTES = 600
Defaults.MAX_METADATA_BYTES = 1024
-- MemoryStore allows 32 KB per item; 4 KB of consumer decoration leaves ample
-- room for the rest of the envelope.
Defaults.MAX_MATCH_DATA_BYTES = 4096
Defaults.MAX_DATA_DEPTH = 8
Defaults.SEEN_CAPACITY = 256

Defaults.MAX_NAME_LENGTH = 16
Defaults.MAX_PARTITION_LENGTH = 32

--[=[
	The default party rating: the mean of its members pulled
	`PARTY_RATING_MAX_BIAS` of the way toward the highest.

	@within Defaults
]=]
function Defaults.aggregate(ratings: { number }): number
	if #ratings == 0 then
		return 0
	end
	local total = 0
	local maximum = -math.huge
	for _, rating in ratings do
		total += rating
		maximum = math.max(maximum, rating)
	end
	local mean = total / #ratings
	return mean + Defaults.PARTY_RATING_MAX_BIAS * (maximum - mean)
end

--[=[
	The rating window after waiting `waitSeconds`: linear growth from `window` at
	`relax` per second, becoming unbounded at `unbounded`.

	@within Defaults
]=]
function Defaults.ratingWindow(rating: any, waitSeconds: number): number
	if waitSeconds >= rating.unbounded then
		return math.huge
	end
	return math.min(rating.maxWindow, rating.window + waitSeconds * rating.relax)
end

--[=[
	Delay before the next scan of a lane. Busy lanes are scanned more often,
	empty ones back off, and every delay doubles while the store reports
	throttling.

	@within Defaults
]=]
function Defaults.scanDelay(candidateCount: number, throttled: boolean): number
	local delay = if candidateCount >= 100
		then Defaults.MIN_SCAN_DELAY
		elseif candidateCount >= 25 then 0.5
		elseif candidateCount >= 5 then 1
		elseif candidateCount > 0 then 2
		else Defaults.MAX_SCAN_DELAY
	return math.min(Defaults.MAX_SCAN_DELAY, if throttled then delay * 2 else delay)
end

--[=[
	Candidates to read on the next scan, sized from the previous one so a quiet
	queue does not pay for a large range read.

	@within Defaults
]=]
function Defaults.batchSize(previousCount: number): number
	if previousCount >= 500 then
		return Defaults.MAX_BATCH_SIZE
	elseif previousCount >= 100 then
		return 50
	elseif previousCount >= 20 then
		return 25
	end
	return Defaults.MIN_BATCH_SIZE
end

return table.freeze(Defaults)
