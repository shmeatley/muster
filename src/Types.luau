--!strict

--[=[
	@class Types

	Every type Muster exposes, in one place with no runtime dependencies. The
	aggregator re-exports all of these, so consumers should write
	`Muster.MatchEnvelope` rather than reaching in here.
]=]

local Types = {}

--[=[
	@type Metadata { [string]: any }
	@within Types

	Arbitrary consumer data carried on a ticket. Must survive a JSON round trip
	through MemoryStore: strings, numbers, booleans, and tables of those. No
	functions, no Instances, no cycles.
]=]
export type Metadata = { [string]: any }

--[=[
	@interface Member
	@within Types
	.userId number
	.serverId string -- JobId of the server that enqueued them. The broadcast address.
	.rating number? -- Present if and only if the queue is rated.
	.provisional boolean? -- True when `rating.default` was substituted for a missing rating.
	.metadata Metadata?

	One player inside a ticket or a finalized match. `serverId` is per-member
	rather than per-ticket because a party can span several servers, and each
	member's own server is the one that needs to hear about the match.
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
	.state "Queued" | "Claimed" | "Matched" | "Cancelled"
	.matchId string?

	A queue entry. One ticket covers one solo player or one whole party — parties
	are never split across matches.
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
	state: "Queued" | "Claimed" | "Matched" | "Cancelled",
	matchId: string?,
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
	.data T -- Whatever your `finalize` hook returned.

	A finalized match, delivered to every server holding one of its members.
	Generic over the finalizer's return type, so `match.data.accessCode` is
	typed and autocompletes.

	Deduplicate on `matchId`, never on the set of players — see the `finalize`
	contract on [Matchmaker].
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

	What a `finalize` hook receives. Everything about the match except the
	decoration the hook itself is about to produce.
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

	Why a match that had already claimed its tickets failed to commit.

	- `FinalizerError` — the hook threw.
	- `FinalizerTimeout` — the hook did not return within `finalizeTimeout`.
	- `FinalizerTooLarge` — the hook's return value failed validation or exceeded `maxMatchDataBytes`.
	- `LeaseLost` — another server took over this lane while the hook was yielding.
	- `StoreUnavailable` — MemoryStore rejected the final commit.
	- `TicketStolen` — a ticket was claimed by another match between selection and commit.
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

	Passed to `onAbort`. When `data` is present the hook ran to completion and
	its side effects survived a match that never formed — that is what this
	callback is for.
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

	Runs exactly once per `matchId`, on whichever server formed the match, after
	its tickets are claimed and before it commits. Yielding is expected — this is
	where `TeleportService:ReserveServerAsync` goes.
]=]
export type Finalizer<T> = (context: MatchContext) -> T

--[=[
	@type AbortHandler (context: AbortContext) -> ()
	@within Types
]=]
export type AbortHandler = (context: AbortContext) -> ()

--[=[
	@type QueueStatus { state: "Queued", queuedAt: number } | { state: "Claiming" } | { state: "Matched", match: MatchEnvelope<T> } | { state: "Cancelled" } | { state: "Expired" }
	@within Types
]=]
export type QueueStatus<T> =
	{ state: "Queued", queuedAt: number }
	| { state: "Claiming" }
	| { state: "Matched", match: MatchEnvelope<T> }
	| { state: "Cancelled" }
	| { state: "Expired" }

--[=[
	@type ErrorCode string
	@within Types

	The closed set of codes on a [ServiceError]. Switch on this rather than on
	the message text.
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

	Returned by every method that touches the network. Programming mistakes throw
	instead — see the error-handling section of the README.
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

	The storage contract. `Muster.stores.MemoryStore` implements it against
	Roblox MemoryStore; `Muster.stores.InMemory` implements it in a table for
	tests. Every method returns `(success, value)` and never throws.

	`update` must be a compare-and-set: the transform may be invoked more than
	once, and returning `nil` from it must abort the write.
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

	The notification contract. Delivery is assumed best-effort and unordered —
	Muster never depends on a message arriving.
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

	The denormalized view of a ticket that the matcher sees. Deliberately small:
	it is what gets written into the lane index, and it is read far more often
	than the ticket itself.
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

	Everything the grouping algorithm knows. Supply your own to replace the
	rating window with role composition, region affinity, or anything else.

	`score` returns `(primary, secondary)`, both minimized, compared in order.
	The built-in policies use rating spread then total queue time.
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

	Presence of this table is what makes a queue rated. Omit it entirely for an
	unrated queue, where tickets carry no rating and matching is oldest-first.
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

	Match sizing. `Muster.new{ size = 6 }` is shorthand for all three being 6.
	A group at `target` commits immediately; a smaller one waits `fallbackAfter`
	seconds before it will settle for anything down to `min`.
]=]
export type SizeConfig = { min: number, target: number?, max: number? }

--[=[
	@interface EnqueueOptions
	@within Types
	.rating number? -- Required on a rated queue unless `rating.default` is set. Throws on an unrated queue.
	.metadata Metadata?
	.partition string? -- Overrides `partitionKey` for this ticket.
	.serverId string? -- Overrides the broadcast address. You almost never want this.
]=]
export type EnqueueOptions = {
	rating: number?,
	metadata: Metadata?,
	partition: string?,
	serverId: string?,
}

--[=[
	@interface GroupOptions
	@within Types
	.ratings { [number]: number }? -- Per-userId ratings, required on a rated queue without a default.
	.metadata Metadata?
	.partition string?
	.serverIds { [number]: string }? -- Per-userId broadcast addresses, for members on other servers.
]=]
export type GroupOptions = {
	ratings: { [number]: number }?,
	metadata: Metadata?,
	partition: string?,
	serverIds: { [number]: string }?,
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
	.version number -- Bumped on every mutation; use it to detect staleness.
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
