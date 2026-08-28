--!strict

--[=[
	@class Types

	Every type Muster exposes. Has no runtime dependencies.

	These are re-exported from the package root, so write `Muster.MatchEnvelope`
	rather than requiring this module directly.
]=]

local Types = {}

--[=[
	@type Metadata { [string]: any }
	@within Types

	Caller-supplied data carried on a ticket.

	Must survive a JSON round trip through MemoryStore: strings, numbers,
	booleans, and tables of those. Functions, Instances, cycles, and tables
	mixing array and dictionary keys are rejected at enqueue with
	`InvalidMetadata`. Limited to `maxMetadataBytes` (1024).
]=]
export type Metadata = { [string]: any }

--[=[
	@interface Member
	@within Types
	.userId number
	.serverId string -- JobId of the server that enqueued them; where their match is delivered.
	.rating number? -- Present if and only if the queue is rated.
	.provisional boolean? -- True when `rating.default` was substituted for a missing rating.
	.metadata Metadata?

	One player within a ticket or a match.

	`serverId` is per-member rather than per-ticket because a party's members can
	be on different servers, and each is notified on their own.
]=]
export type Member = {
	userId: number,
	serverId: string,
	rating: number?,
	provisional: boolean?,
	metadata: Metadata?,
}

--[=[
	@interface Ticket
	@within Types
	.id string
	.queue string
	.partition string
	.partyId string?
	.leaderUserId number
	.members { Member }
	.size number
	.rating number? -- Party-aggregated rating, absent on unrated queues.
	.metadata Metadata?
	.queuedAt number
	.expiresAt number
	.state "Queued" | "Claimed" | "Matched" | "Cancelled" | "QuickPlayed"
	.matchId string?
	.lane number -- Index within the partition.
	.laneCount number -- Lane count in force when the ticket was written; lanes scale at runtime.
	.laneGeneration number -- Which revision of the partition's lane layout that count belonged to.
	.quickPlay boolean? -- True when this ticket may also backfill into a live match. See [QuickPlay].
	.listingId string? -- The listing a `QuickPlayed` ticket was backfilled into.

	A queue entry covering one player or one group. A ticket is never split
	across matches.
]=]
export type Ticket = {
	id: string,
	queue: string,
	partition: string,
	partyId: string?,
	leaderUserId: number,
	members: { Member },
	size: number,
	rating: number?,
	metadata: Metadata?,
	queuedAt: number,
	expiresAt: number,
	state: "Queued" | "Claimed" | "Matched" | "Cancelled" | "QuickPlayed",
	matchId: string?,
	lane: number,
	laneCount: number,
	laneGeneration: number,
	quickPlay: boolean?,
	listingId: string?,
}

--[=[
	@interface MatchEnvelope
	@within Types
	.v number -- Schema version.
	.matchId string
	.queue string
	.partition string
	.createdAt number
	.size number -- Total players across all members.
	.members { Member }
	.ticketIds { string }
	.partyIds { string }
	.data T -- The `finalize` hook's return value, or an empty table if there is no hook.

	A committed match, delivered to every server holding one of its members.

	Generic over the finalizer's return type, so `match.data.accessCode` is typed
	and autocompletes.

	Deduplicate on `matchId`. The same set of players may appear under a second
	matchId if a worker stalled and its work was repaired.
]=]
export type MatchEnvelope<T> = {
	v: number,
	matchId: string,
	queue: string,
	partition: string,
	createdAt: number,
	size: number,
	members: { Member },
	ticketIds: { string },
	partyIds: { string },
	data: T,
}

--[=[
	@interface MatchContext
	@within Types
	.matchId string
	.queue string
	.partition string
	.members { Member }
	.ticketIds { string }
	.partyIds { string }
	.size number
	.averageRating number? -- Mean member rating, absent on unrated queues.
	.createdAt number
	.deadline number -- Monotonic time the hook must return by.

	The argument to a `finalize` hook: everything known about the match before the
	hook's own return value is attached.
]=]
export type MatchContext = {
	matchId: string,
	queue: string,
	partition: string,
	members: { Member },
	ticketIds: { string },
	partyIds: { string },
	size: number,
	averageRating: number?,
	createdAt: number,
	deadline: number,
}

--[=[
	@type AbortReason "FinalizerError" | "FinalizerTimeout" | "FinalizerTooLarge" | "LeaseLost" | "StoreUnavailable" | "TicketStolen"
	@within Types

	Why a match that had already claimed its tickets failed to commit. Its
	players return to the queue in every case.

	| Reason | Cause |
	| --- | --- |
	| `FinalizerError` | The hook threw. |
	| `FinalizerTimeout` | The hook did not return within `finalizeTimeout`. |
	| `FinalizerTooLarge` | The hook's return value failed validation or exceeded `maxMatchDataBytes`. |
	| `LeaseLost` | Another server took the lane while the hook was yielding. |
	| `StoreUnavailable` | MemoryStore rejected the commit. |
	| `TicketStolen` | A ticket was claimed by another match between selection and commit. |
]=]
export type AbortReason =
	"FinalizerError"
	| "FinalizerTimeout"
	| "FinalizerTooLarge"
	| "LeaseLost"
	| "StoreUnavailable"
	| "TicketStolen"

--[=[
	@interface AbortContext
	@within Types
	.matchId string
	.queue string
	.partition string
	.members { Member }
	.reason AbortReason
	.message string? -- The hook's error text, when `reason` is `FinalizerError`.
	.data any? -- The hook's return value, if it produced one before the abort.

	The argument to `onAbort`.

	When `data` is present, the hook ran to completion and its side effects
	outlived a match that never formed.
]=]
export type AbortContext = {
	matchId: string,
	queue: string,
	partition: string,
	members: { Member },
	reason: AbortReason,
	message: string?,
	data: any?,
}

--[=[
	@type Finalizer (context: MatchContext) -> T
	@within Types

	Runs once per `matchId`, on the server that formed the match, after its
	tickets are claimed and before it commits. Expected to yield.

	The same set of players may be finalized again under a different matchId if
	this match aborts, so deduplicate on `matchId`.
]=]
export type Finalizer<T> = (context: MatchContext) -> T

--[=[
	@type AbortHandler (context: AbortContext) -> ()
	@within Types
]=]
export type AbortHandler = (context: AbortContext) -> ()

--[=[
	@type QueueStatus { state: "Queued", queuedAt: number } | { state: "Claiming" } | { state: "Matched", match: MatchEnvelope<T> } | { state: "QuickPlayed", listingId: string? } | { state: "Cancelled" } | { state: "Expired" }
	@within Types
]=]
export type QueueStatus<T> =
	{ state: "Queued", queuedAt: number }
	| { state: "Claiming" }
	| { state: "Matched", match: MatchEnvelope<T> }
	-- Backfilled into a live match by [QuickPlay] rather than matched into a new one.
	| { state: "QuickPlayed", listingId: string? }
	| { state: "Cancelled" }
	| { state: "Expired" }

--[=[
	@type ErrorCode string
	@within Types

	The codes a [ServiceError] can carry. Switch on this rather than on the
	message text, which is not stable.
]=]
export type ErrorCode =
	-- Transport
	"StoreUnavailable"
	| "MessagingUnavailable"
	-- Queue
	| "AlreadyQueued"
	| "NotQueued"
	| "InvalidPartySize"
	| "DuplicateMember"
	| "MissingRating"
	| "InvalidMetadata"
	-- Party
	| "PartyNotFound"
	| "PartyUnavailable"
	| "PartyChanged"
	| "PartyLocked"
	| "PartyFull"
	| "AlreadyInParty"
	| "NotLeader"
	| "NotMember"
	| "InvalidTarget"
	| "InviteNotFound"
	| "MatchMismatch"
	-- Quick Play
	| "QuickPlayDisabled"
	| "ListingNotFound"
	| "ListingFull"
	| "InvalidListingData"

--[=[
	@interface ServiceError
	@within Types
	.code ErrorCode
	.message string
	.retryable boolean -- True when the same call may succeed on a later attempt.
]=]
export type ServiceError = {
	code: ErrorCode,
	message: string,
	retryable: boolean,
}

--[=[
	@type Result { ok: true, value: T } | { ok: false, error: ServiceError }
	@within Types

	Returned by every method that touches the network. Invalid configuration and
	invalid arguments throw instead. See [Result].
]=]
export type Result<T> = { ok: true, value: T } | { ok: false, error: ServiceError }

--[=[
	@interface SortedItem
	@within Types
	.key string
	.value any
	.sortKey number
]=]
export type SortedItem = { key: string, value: any, sortKey: number }

--[=[
	@interface Store
	@within Types

	The storage contract, implemented by `Muster.stores.MemoryStore` against
	Roblox MemoryStore and by `Muster.stores.InMemory` against tables.

	Every method returns `(success, value)` and must not throw.

	`update` must be a compare-and-set: the transform may be invoked more than
	once for a single call, and returning `nil` from it must abort the write.
]=]
export type Store = {
	get: (self: any, name: string, key: string, priority: number?) -> (boolean, any),
	set: (self: any, name: string, key: string, value: any, expiration: number, priority: number?) -> (boolean, any),
	update: (
		self: any,
		name: string,
		key: string,
		expiration: number,
		transform: (any) -> any,
		priority: number?
	) -> (boolean, any),
	remove: (self: any, name: string, key: string, priority: number?) -> (boolean, any),
	sortedSet: (
		self: any,
		name: string,
		key: string,
		value: any,
		expiration: number,
		sortKey: number,
		priority: number?
	) -> (boolean, any),
	sortedRemove: (self: any, name: string, key: string, priority: number?) -> (boolean, any),
	sortedRange: (self: any, name: string, count: number, priority: number?) -> (boolean, any),
}

--[=[
	@interface Subscription
	@within Types
	.disconnect (self: any) -> ()
]=]
export type Subscription = { disconnect: (self: any) -> () }

--[=[
	@interface Messaging
	@within Types

	The notification contract. Delivery is assumed to be best-effort and
	unordered; Muster never depends on a message arriving.
]=]
export type Messaging = {
	publish: (self: any, topic: string, payload: any) -> (boolean, any),
	subscribe: (self: any, topic: string, handler: (any) -> ()) -> Subscription,
}

--[=[
	@interface Candidate
	@within Types
	.ticketId string
	.partyId string?
	.size number
	.rating number?
	.ratings { number }
	.queuedAt number

	The reduced view of a ticket held in the lane index and passed to [Matcher].
	Kept small because it is read far more often than the ticket record itself.
]=]
export type Candidate = {
	ticketId: string,
	partyId: string?,
	size: number,
	rating: number?,
	ratings: { number },
	queuedAt: number,
}

--[=[
	@interface MatcherPolicy
	@within Types
	.minSize number
	.targetSize number
	.maxSize number
	.fallbackAfter number -- Seconds before a below-target group is accepted.
	.compatible (anchor: Candidate, candidate: Candidate, waitSeconds: number) -> boolean
	.score (candidates: { Candidate }, indexes: { number }) -> (number, number)

	Everything [Matcher] knows about how to group candidates. Supply one through
	the `matcher` config field to replace the rating window with role
	composition, region affinity, or any other rule.

	`compatible` decides whether a candidate may join an anchor's group.

	`score` returns `(primary, secondary)`, both minimized and compared in that
	order. The built-in policy uses rating spread, then total queue time.
]=]
export type MatcherPolicy = {
	minSize: number,
	targetSize: number,
	maxSize: number,
	fallbackAfter: number,
	compatible: (anchor: Candidate, candidate: Candidate, waitSeconds: number) -> boolean,
	score: (candidates: { Candidate }, indexes: { number }) -> (number, number),
}

--[=[
	@interface RatingConfig
	@within Types
	.window number? -- Starting rating tolerance. Default 200.
	.relax number? -- Extra tolerance per second waited. Default 40.
	.maxWindow number? -- Ceiling on the widened window. Default infinite.
	.unbounded number? -- Seconds after which any rating matches. Default 60.
	.default number? -- Substituted when a caller omits a rating. Default nil, which makes omission an error.
	.aggregate (({ number }) -> number)? -- Party rating from member ratings. Default is a max-biased mean.

	Supplying this table makes a queue rated. Omit it for an unrated queue, where
	tickets carry no rating and matching is oldest-first.

	Rated and unrated is a per-queue property: a rated queue requires a rating
	for every player, and an unrated one rejects them.
]=]
export type RatingConfig = {
	window: number?,
	relax: number?,
	maxWindow: number?,
	unbounded: number?,
	default: number?,
	aggregate: (({ number }) -> number)?,
}

--[=[
	@interface SizeConfig
	@within Types
	.min number
	.target number?
	.max number?

	Match sizing. `size = 6` is shorthand for all three being 6, and `target`
	defaults to `max`.

	A group reaching `target` commits immediately. A smaller one waits
	`fallbackAfter` seconds, after which the largest group down to `min` is
	accepted.
]=]
export type SizeConfig = { min: number, target: number?, max: number? }

--[=[
	@interface EnqueueOptions
	@within Types
	.rating number? -- Required on a rated queue unless `rating.default` is set. Throws on an unrated queue.
	.metadata Metadata?
	.partition string? -- Overrides `partitionKey` for this ticket. Partitions never match each other.
	.serverId string? -- Overrides where this member's match is delivered. Defaults to this server.
	.quickPlay boolean? -- Also let this ticket backfill into a live match. Requires the `quickPlay` config.
]=]
export type EnqueueOptions = {
	rating: number?,
	metadata: Metadata?,
	partition: string?,
	serverId: string?,
	quickPlay: boolean?,
}

--[=[
	@interface GroupOptions
	@within Types
	.ratings { [number]: number }? -- Per-userId ratings, required on a rated queue without a default.
	.metadata Metadata?
	.partition string? -- Overrides `partitionKey` for this ticket.
	.serverIds { [number]: string }? -- Per-userId delivery addresses, for members on other servers.
	.quickPlay boolean? -- Also let this ticket backfill into a live match. Requires the `quickPlay` config.
]=]
export type GroupOptions = {
	ratings: { [number]: number }?,
	metadata: Metadata?,
	partition: string?,
	serverIds: { [number]: string }?,
	quickPlay: boolean?,
}

--[=[
	@interface PartyMember
	@within Types
	.userId number
	.joinedAt number
	.serverId string?
]=]
export type PartyMember = {
	userId: number,
	joinedAt: number,
	serverId: string?,
	quickPlay: boolean?,
}

--[=[
	@interface PartyQueue
	@within Types
	.ticketId string
	.state "Queued" | "Matched"
	.matchId string?
	.expiresAt number
]=]
export type PartyQueue = {
	ticketId: string,
	state: "Queued" | "Matched",
	matchId: string?,
	expiresAt: number,
}

--[=[
	@interface PartyView
	@within Types
	.id string
	.leaderUserId number
	.members { PartyMember }
	.createdAt number
	.version number -- Incremented on every mutation; compare it to detect a stale read.
	.queue PartyQueue? -- Non-nil while queued, during which membership is frozen.
]=]
export type PartyView = {
	v: number,
	id: string,
	leaderUserId: number,
	members: { PartyMember },
	createdAt: number,
	version: number,
	queue: PartyQueue?,
}

--[=[
	@interface PartyInvite
	@within Types
	.id string
	.partyId string
	.leaderUserId number
	.targetUserId number
	.createdAt number
	.expiresAt number
]=]
export type PartyInvite = {
	id: string,
	partyId: string,
	leaderUserId: number,
	targetUserId: number,
	createdAt: number,
	expiresAt: number,
}

--[=[
	@interface QuickPlayConfig
	@within Types
	.capacity number? -- Players a hosted match holds. Defaults to `size.max`.
	.heartbeatInterval number? -- Seconds between player-count refreshes. Default 30.
	.listingExpiration number? -- Seconds a listing survives without a heartbeat. Default 90.
	.reservationTimeout number? -- Seconds a claimed seat is held. Default 45.
	.searchInterval number? -- Seconds between search attempts by a queued ticket. Default 3.
	.lanes ("auto" | number)? -- Listing lane count. Default `"auto"`.
	.maxListingDataBytes number? -- Budget for a listing's `data`. Default 1024.

	Supplying this table, or `true` for all of its defaults, turns Quick Play on
	for a queue. Omit it and the feature is off: [Matchmaker:quickPlay] and
	`queue.quickplay` both throw.

	See [QuickPlay].
]=]
export type QuickPlayConfig = {
	capacity: number?,
	heartbeatInterval: number?,
	listingExpiration: number?,
	reservationTimeout: number?,
	searchInterval: number?,
	lanes: (string | number)?,
	maxListingDataBytes: number?,
}

--[=[
	@interface Reservation
	@within Types
	.id string
	.size number -- Seats held.
	.userIds { number } -- Who the seats are for. Used to retire the reservation once they arrive.
	.expiresAt number

	A seat held in a listing between a claim and the player arriving. Counted
	against capacity for as long as it lives, so two lobbies cannot fill the same
	slot.
]=]
export type Reservation = {
	id: string,
	size: number,
	userIds: { number },
	expiresAt: number,
}

--[=[
	@interface Listing
	@within Types
	.v number -- Schema version.
	.id string
	.queue string
	.partition string
	.serverId string -- JobId of the match server hosting it.
	.capacity number
	.players number -- Count at the last heartbeat, so up to `heartbeatInterval` stale.
	.open boolean -- False once the host has stopped taking players.
	.reservations { Reservation }
	.data T -- Whatever the host published: an access code, a place id, a map name.
	.lane number
	.laneCount number
	.laneGeneration number
	.updatedAt number
	.expiresAt number

	One live match, advertised for backfill. Generic over the host's `data`, so
	`listing.data.accessCode` is typed.
]=]
export type Listing<T> = {
	v: number,
	id: string,
	queue: string,
	partition: string,
	serverId: string,
	capacity: number,
	players: number,
	open: boolean,
	reservations: { Reservation },
	data: T,
	lane: number,
	laneCount: number,
	laneGeneration: number,
	updatedAt: number,
	expiresAt: number,
}

--[=[
	@interface ListingView
	@within Types
	.listingId string
	.serverId string
	.capacity number
	.free number -- Seats free as of the last write. A hint, not a guarantee.
	.updatedAt number

	The reduced copy of a listing held in the lane index, kept small because it
	is read far more often than the listing itself. `free` is what the index is
	sorted by, ascending, so the fullest joinable match is returned first.
]=]
export type ListingView = {
	listingId: string,
	serverId: string,
	capacity: number,
	free: number,
	updatedAt: number,
}

--[=[
	@interface HostOptions
	@within Types
	.data T -- Published to whoever joins. Put the access code and place id here.
	.capacity number? -- Overrides `quickPlay.capacity` for this match.
	.partition string? -- Only searchers on the same partition find it. Defaults to `"all"`.
	.players number? -- Starting player count. Defaults to `playerCount()`.
	.playerCount (() -> number)? -- Read on every heartbeat. Defaults to the `Players` service.
	.presentUserIds (() -> { number })? -- Who is in the match now, used to retire fulfilled reservations.
	.listingId string? -- Reuse a known id, so a restarted host adopts its own listing.

	The argument to [QuickPlay:host].
]=]
export type HostOptions<T> = {
	data: T,
	capacity: number?,
	partition: string?,
	players: number?,
	playerCount: (() -> number)?,
	presentUserIds: (() -> { number })?,
	listingId: string?,
}

--[=[
	@interface QuickPlayAssignment
	@within Types
	.listingId string
	.reservationId string -- Pass to [QuickPlay:release] if the teleport fails.
	.queue string
	.partition string
	.serverId string -- The match server hosting the listing.
	.members { Member }
	.ticketId string -- The ticket this assignment consumed.
	.size number
	.data T -- The listing's published data.

	Delivered on `queue.quickPlayMatched` when a queued player is backfilled into
	a live match. Unlike a [MatchEnvelope] this fires only on the server that
	claimed the seat, since that is the server holding the players.
]=]
export type QuickPlayAssignment<T> = {
	listingId: string,
	reservationId: string,
	queue: string,
	partition: string,
	serverId: string,
	members: { Member },
	ticketId: string,
	size: number,
	data: T,
}

--[=[
	@type Logger (level: "info" | "warn" | "error", message: string, fields: { [string]: any }) -> ()
	@within Types
]=]
export type Logger = (level: string, message: string, fields: { [string]: any }) -> ()

--[=[
	@type Metrics (name: string, value: number, tags: { [string]: any }) -> ()
	@within Types
]=]
export type Metrics = (name: string, value: number, tags: { [string]: any }) -> ()

return Types
