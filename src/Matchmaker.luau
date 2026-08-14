--!strict

--[=[
	@class Matchmaker

	A single queue. Construct one per game mode.

	```lua
	local duels = Muster.new({ name = "duels", size = 2 })

	duels.matched:connect(function(match)
		for _, member in match.members do
			print(member.userId, "->", match.matchId)
		end
	end)

	duels:enqueue(player.UserId)
	```

	Constructing a queue starts its worker thread, subscribes it for cross-server
	delivery, and connects `Players.PlayerRemoving` to cancel tickets. Each of
	those can be disabled with `autoStart`, `broadcast`, and `autoCancelOnLeave`.

	### Configuration

	`name` and `size` are required; everything else has a default.

	| Field | Type | Default | Effect |
	| --- | --- | --- | --- |
	| `name` | `string` | — | Namespaces this queue's keys. Max 16 characters, alphanumeric plus `_` and `-`. |
	| `size` | `number \| SizeConfig` | — | `6` is shorthand for `{ min = 6, target = 6, max = 6 }`. |
	| `rating` | `RatingConfig?` | `nil` | Present makes the queue rated. See [RatingConfig]. |
	| `fallbackAfter` | `number` | `10` | Seconds before a below-`target` group is accepted. |
	| `finalize` | `Finalizer<T>?` | `nil` | Runs once per match; its return value becomes `match.data`. |
	| `finalizeTimeout` | `number` | `5` | Seconds. Must not exceed 15. |
	| `onAbort` | `AbortHandler?` | `nil` | Called when a match fails after its hook ran. Requires `finalize`. |
	| `partitionKey` | `function?` | `nil` | Returns a partition name per ticket. Partitions never match each other. |
	| `lanes` | `"auto" \| number` | `"auto"` | Pinning a number disables runtime scaling. See [LaneScaler]. |
	| `broadcast` | `boolean` | `true` | Publish match notifications over MessagingService. |
	| `autoStart` | `boolean` | `true` | Start the worker thread on construction. |
	| `autoCancelOnLeave` | `boolean` | `true` | Cancel a player's ticket when they leave. |
	| `manualAcknowledge` | `boolean` | `false` | Require [Matchmaker:acknowledge] to release matched players. |
	| `ticketExpiration` | `number` | `180` | Seconds a ticket survives without a heartbeat. Minimum 30. |
	| `maxMetadataBytes` | `number` | `1024` | Per-ticket metadata budget. |
	| `maxMatchDataBytes` | `number` | `4096` | Budget for the finalizer's return value. |
	| `namespace` | `string` | `"mu"` | Change to run independent deployments in one universe. |

	These accept injected implementations, primarily for tests: `store`,
	`messaging`, `players`, `matcher`, `layout`, `logger`, `metrics`, `clock`,
	`monotonic`, `random`, `sleep`, `spawn`, `id`, `serverId`.

	### Delivery

	`matched` fires on every server holding at least one of the matched players.
	A server holding none of them does not receive the event, so a handler can
	assume it has someone to act on.

	Matches are written to MemoryStore before being announced, so delivery does
	not depend on MessagingService. Typical latency is under 200 ms; if a message
	is dropped, a poll finds the match within `pollIntervalMax` (30 s), and if
	MessagingService is unavailable the poll cap tightens to 5 s automatically.
]=]

local Config = require(script.Parent.Config)
local Engine = require(script.Parent.internal.Engine)
local Party = require(script.Parent.Party)
local RequestExecutor = require(script.Parent.internal.RequestExecutor)
local Result = require(script.Parent.Result)
local Runtime = require(script.Parent.internal.Runtime)
local Signal = require(script.Parent.Signal)
local Types = require(script.Parent.Types)

type MatchEnvelope<T> = Types.MatchEnvelope<T>
type Ticket = Types.Ticket
type Result<T> = Types.Result<T>

local Matchmaker = {}

--[[
	`parties` is built on first access rather than in `new`.

	Most games never touch it: `enqueueGroup` covers queueing a set of players
	as one ticket, and a game whose parties form in a single lobby has no reason
	to keep party state anywhere shared. Building it lazily means those games
	carry none of it, and the ones that do want it pay nothing until they ask.
]]
function Matchmaker.__index(self: any, key: string): any
	if key == "parties" then
		-- `_getParties` is a real field on the instance, so reading it does not
		-- re-enter this metamethod.
		return self._getParties()
	end
	return Matchmaker[key]
end

local function buildStore(settings: any, executor: any): any
	if settings.store then
		return settings.store
	end
	local MemoryStore = require(script.Parent.stores.MemoryStore)
	return MemoryStore.new(executor)
end

local function buildMessaging(settings: any, executor: any): any?
	if not settings.broadcast then
		return nil
	end
	if settings.messaging then
		return settings.messaging
	end
	if not Runtime.isRoblox then
		return nil
	end
	local RobloxMessaging = require(script.Parent.messaging.Roblox)
	return RobloxMessaging.new(executor)
end

--[=[
	@prop matched Signal<MatchEnvelope<T>>
	@within Matchmaker

	Fires on every server holding at least one of the matched players. Does not
	fire on a server holding none of them.
]=]

--[=[
	@prop aborted Signal<AbortContext>
	@within Matchmaker

	Fires when a match that had already claimed its tickets failed to commit. Its
	players return to the queue. See [AbortReason].
]=]

--[=[
	@prop queued Signal<Ticket>
	@within Matchmaker

	Fires on this server when a ticket is successfully enqueued here.
]=]

--[=[
	@prop cancelled Signal<Ticket>
	@within Matchmaker

	Fires on this server when a ticket it was tracking is cancelled.
]=]

--[=[
	@prop parties Party
	@within Matchmaker

	Cross-server parties sharing this queue's store. Built on first access and
	writes nothing until used; see [Party].
]=]

--[=[
	Builds a queue. `name` and `size` are required; see the configuration table
	on [Matchmaker] for the rest.

	Configuration problems throw rather than returning a `Result`, since they
	cannot be recovered from at runtime.

	@param config MatchmakerConfig
	@error "Muster: ..." -- Reported at the call site, naming the offending field.
	@within Matchmaker
]=]
function Matchmaker.new(config: any): any
	local settings, problem = Config.resolve(config)
	if problem then
		error(problem, 2)
	end

	local executor = RequestExecutor.new(settings)
	local store = buildStore(settings, executor)
	local messaging = buildMessaging(settings, executor)

	local partyService: any = nil
	local function getParties(): any
		if partyService == nil then
			partyService = Party.new(store, {
				clock = settings.clock,
				id = settings.id,
				keys = settings.keys,
				ticketExpiration = settings.ticketExpiration,
				matchExpiration = settings.matchExpiration,
				maxMembers = math.max(settings.size.max, 2),
			})
		end
		return partyService
	end

	local self = setmetatable({
		_settings = settings,
		_executor = executor,
		_store = store,
		_messaging = messaging,
		_connections = {},
		_getParties = getParties,

		matched = Signal.new(),
		aborted = Signal.new(),
		queued = Signal.new(),
		cancelled = Signal.new(),
	}, Matchmaker)

	self._engine = Engine.new(settings, {
		store = store,
		messaging = messaging,
		-- Passed as an accessor, not an instance. The engine only reaches for it
		-- when a ticket actually carries a partyId.
		parties = getParties,
		isThrottled = function()
			return executor:isThrottled()
		end,
	})

	self._engine.onMatched = function(envelope)
		self.matched:fire(envelope)
	end
	self._engine.onAborted = function(context)
		self.aborted:fire(context)
	end
	self._engine.onQueued = function(ticket)
		self.queued:fire(ticket)
	end
	self._engine.onCancelled = function(ticket)
		self.cancelled:fire(ticket)
	end

	if settings.autoCancelOnLeave then
		local players = settings.players or Runtime.service("Players")
		if players ~= nil then
			table.insert(
				self._connections,
				players.PlayerRemoving:Connect(function(player)
					self:cancelForUser(player.UserId)
				end)
			)
		end
	end

	if settings.autoStart then
		self:start()
	end

	return self
end

function Matchmaker._resolveRating(self: any, userId: number, supplied: number?): number?
	local settings = self._settings
	if not settings.rated then
		if supplied ~= nil then
			error(
				`Muster: queue "{settings.name}" is unrated, so \`rating\` cannot be supplied. `
					.. "Add a `rating` table to the config to make it rated.",
				3
			)
		end
		return nil
	end
	if supplied ~= nil then
		return supplied
	end
	if settings.rating.default ~= nil then
		return settings.rating.default
	end
	error(
		`Muster: queue "{settings.name}" is rated but no rating was given for user {userId}. `
			.. "Pass one, or set `rating.default` for players who do not have one yet.",
		3
	)
end

--[=[
	Queues one player as a one-member ticket.

	On a rated queue, `options.rating` is required unless `rating.default` is
	configured; on an unrated queue, supplying one throws.

	@param options EnqueueOptions?
	@return Result<Ticket>
	@error "Muster: queue \"<name>\" is rated but no rating was given" -- No rating and no default.
	@error "Muster: queue \"<name>\" is unrated, so `rating` cannot be supplied" -- Rating passed to an unrated queue.
	@within Matchmaker
]=]
function Matchmaker.enqueue(self: any, userId: number, options: any?): any
	local settings = self._settings
	local opts = options or {}
	local rating = self:_resolveRating(userId, opts.rating)

	local member = {
		userId = userId,
		serverId = opts.serverId or settings.serverId,
		rating = rating,
		provisional = if settings.rated and opts.rating == nil then true else nil,
	}

	return self._engine:enqueue({
		members = { member },
		leaderUserId = userId,
		partition = self:_partitionFor(opts, { userId }),
		metadata = opts.metadata,
	})
end

--[=[
	Queues a set of players as one ticket. The group is never split across
	matches and is matched at its aggregate rating.

	Takes userIds directly and does not involve [Party]. The first userId becomes
	the ticket's leader, which is who may cancel or acknowledge it.

	```lua
	queue:enqueueGroup({ leaderId, friendId }, { ratings = ratings })
	```

	Groups larger than `size.max` are rejected with `InvalidPartySize`, and a
	repeated userId with `DuplicateMember`.

	@param options GroupOptions?
	@return Result<Ticket>
	@within Matchmaker
]=]
function Matchmaker.enqueueGroup(self: any, userIds: { number }, options: any?): any
	local settings = self._settings
	local opts = options or {}
	local ratings = opts.ratings or {}
	local serverIds = opts.serverIds or {}

	local members = table.create(#userIds)
	for index, userId in userIds do
		members[index] = {
			userId = userId,
			serverId = serverIds[userId] or opts.serverId or settings.serverId,
			rating = self:_resolveRating(userId, ratings[userId]),
			provisional = if settings.rated and ratings[userId] == nil then true else nil,
		}
	end

	return self._engine:enqueue({
		members = members,
		leaderUserId = userIds[1],
		partition = self:_partitionFor(opts, userIds),
		metadata = opts.metadata,
	})
end

--[=[
	Queues a [Party] by id. Only the party's leader may call this.

	The party's membership is locked for the lifetime of the ticket: invites,
	kicks, leaves, leadership transfers and disbanding all return `PartyLocked`
	until the ticket matches, is cancelled, or expires.

	@param options GroupOptions? -- `ratings` is keyed by userId.
	@return Result<Ticket>
	@within Matchmaker
]=]
function Matchmaker.enqueueParty(self: any, partyId: string, requesterUserId: number, options: any?): any
	local settings = self._settings
	local opts = options or {}
	local ratings = opts.ratings or {}

	local partyResult = self.parties:get(partyId)
	if not partyResult.ok then
		return partyResult
	end
	local party = partyResult.value
	if party.leaderUserId ~= requesterUserId then
		return Result.err("NotLeader", "Only the party leader may queue the party")
	end

	local userIds = table.create(#party.members)
	local members = table.create(#party.members)
	for index, partyMember in party.members do
		userIds[index] = partyMember.userId
		members[index] = {
			userId = partyMember.userId,
			serverId = partyMember.serverId or settings.serverId,
			rating = self:_resolveRating(partyMember.userId, ratings[partyMember.userId]),
			provisional = if settings.rated and ratings[partyMember.userId] == nil then true else nil,
		}
	end

	-- Lock before enqueueing so nobody can join or leave between the roster we
	-- just read and the ticket we are about to write.
	local ticketId = settings.id()
	local locked = self.parties:lockQueue(party.id, requesterUserId, ticketId)
	if not locked.ok then
		return locked
	end

	local result = self._engine:enqueue({
		members = members,
		leaderUserId = requesterUserId,
		partyId = party.id,
		partition = self:_partitionFor(opts, userIds),
		metadata = opts.metadata,
		ticketId = ticketId,
	})
	if not result.ok then
		self.parties:unlockQueue(party.id, ticketId)
	end
	return result
end

function Matchmaker._partitionFor(self: any, options: any, userIds: { number }): string
	if options.partition ~= nil then
		return Config.normalizePartition(options.partition)
	end
	if self._settings.partitionKey == nil then
		return "all"
	end

	local success, value = pcall(self._settings.partitionKey, {
		userIds = userIds,
		metadata = options.metadata,
		ratings = options.ratings,
		rating = options.rating,
	})
	if not success or type(value) ~= "string" or value == "" then
		return "all"
	end
	return Config.normalizePartition(value)
end

--[=[
	Cancels a ticket.

	Only the ticket's leader may cancel it, and only while its state is
	`Queued`. A ticket already claimed for a match returns `NotQueued`.

	@return Result<true>
	@within Matchmaker
]=]
function Matchmaker.cancel(self: any, requesterUserId: number, ticketId: string): any
	return self._engine:cancel(requesterUserId, ticketId)
end

--[=[
	Cancels whatever ticket a user currently holds, if any.

	Unlike [Matchmaker:cancel], this looks the ticket up and cancels it as its
	leader, so it works for any member of a group. Connected to
	`Players.PlayerRemoving` unless `autoCancelOnLeave` is disabled.

	@return Result<boolean> -- True if a ticket was cancelled, false if the user had none queued.
	@within Matchmaker
]=]
function Matchmaker.cancelForUser(self: any, userId: number): any
	local existing = self._engine:getTicketForUser(userId)
	if not existing.ok then
		return existing
	end
	local ticket = existing.value
	if ticket == nil or ticket.state ~= "Queued" then
		return Result.ok(false)
	end

	local cancelled = self._engine:cancel(ticket.leaderUserId, ticket.id)
	if not cancelled.ok then
		return cancelled
	end
	return Result.ok(true)
end

--[=[
	The ticket a user currently holds, or `nil`.

	Tickets are exclusive across every queue sharing a namespace, so this returns
	a ticket even if the user queued somewhere else.

	@return Result<Ticket?>
	@within Matchmaker
]=]
function Matchmaker.getTicket(self: any, userId: number): any
	return self._engine:getTicketForUser(userId)
end

--[=[
	The state of a ticket: `Queued`, `Claiming`, `Matched`, `Cancelled`, or
	`Expired`. A `Matched` status carries the envelope.

	@return Result<QueueStatus<T>>
	@within Matchmaker
]=]
function Matchmaker.getStatus(self: any, ticketId: string): any
	return self._engine:getStatus(ticketId)
end

--[=[
	Reads a committed match by id, or `nil` if there is no ready match under that
	id. Matches remain readable for `matchExpiration` (300 s), which covers a
	player who rejoined on another server and needs the envelope again.

	@return Result<MatchEnvelope<T>?>
	@within Matchmaker
]=]
function Matchmaker.getMatch(self: any, matchId: string): any
	return self._engine:getMatch(matchId)
end

--[=[
	Releases a matched ticket's players so they may queue again, and unlocks its
	party.

	This happens automatically on delivery unless `manualAcknowledge` is set.
	Enable that setting to hold the reservation until you have confirmed whatever
	follows the match — a teleport, for instance — so a failure leaves the
	players free to re-queue rather than locked out until their reservation
	expires.

	@return Result<MatchEnvelope<T>>
	@within Matchmaker
]=]
function Matchmaker.acknowledge(self: any, requesterUserId: number, ticketId: string): any
	return self._engine:acknowledge(requesterUserId, ticketId)
end

--[=[
	Runs one worker pass: ticket upkeep, lane acquisition, then a scan of each
	held lane.

	The worker thread calls this on a loop. Calling it directly advances the
	system one step, which is how the test suite drives it without yielding.

	@within Matchmaker
]=]
function Matchmaker.step(self: any)
	self._engine:step()
end

--[=[
	Starts the worker thread and subscribes for cross-server delivery. Called by
	the constructor unless `autoStart` is disabled. Calling it twice does
	nothing.

	@within Matchmaker
]=]
function Matchmaker.start(self: any)
	self._engine:start()
end

--[=[
	Stops the worker and releases every lane lease this server holds, so another
	server can take them immediately instead of waiting out the 15-second
	timeout. Suitable for `game:BindToClose`.

	@within Matchmaker
]=]
function Matchmaker.stop(self: any)
	self._engine:stop()
end

--[=[
	Calls [Matchmaker:stop], disconnects the `PlayerRemoving` connection, and
	drops every signal handler.

	@within Matchmaker
]=]
function Matchmaker.destroy(self: any)
	self:stop()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.matched:disconnectAll()
	self.aborted:disconnectAll()
	self.queued:disconnectAll()
	self.cancelled:disconnectAll()
end

--[=[
	A snapshot of this server's view of the queue, for logging or a debug
	command.

	| Field | Meaning |
	| --- | --- |
	| `localTickets` | Tickets this server enqueued and is still tracking. |
	| `ownedLanes` | Lane leases this server currently holds. |
	| `laneMode` | `"auto"` or `"fixed"`. |
	| `laneCount` | Lanes the default partition is sharded into. |
	| `laneChanges` | Resizes this server has applied. |
	| `throttled` | True once 1% of requests have come back throttled. |
	| `broadcastHealthy` | False while message delivery looks unreliable. |
	| `broadcastsSent` / `broadcastsReceived` | Message counts since start. |
	| `requests` | Per-structure successes, failures, throttles and mean latency. |

	Values are local to this server, not fleet-wide.

	@within Matchmaker
]=]
function Matchmaker.health(self: any): any
	local queued = 0
	for _ in self._engine._localTickets do
		queued += 1
	end
	local lanes = 0
	for _ in self._engine._owned do
		lanes += 1
	end

	return {
		queue = self._settings.name,
		serverId = self._settings.serverId,
		localTickets = queued,
		ownedLanes = lanes,
		laneMode = self._settings.laneMode,
		-- What this server currently believes the default partition is sharded
		-- to, and how many resizes it has applied.
		laneCount = self._engine._scaler:current("all").count,
		laneChanges = self._engine._scaler.changes,
		throttled = self._executor:isThrottled(),
		broadcastHealthy = self._engine._broadcaster:isHealthy(),
		broadcastsSent = self._engine._broadcaster.published,
		broadcastsReceived = self._engine._broadcaster.received,
		requests = self._executor:snapshot(),
	}
end

return Matchmaker
