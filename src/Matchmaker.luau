--!strict

--[=[
	@class Matchmaker

	A queue. Construct one per game mode, enqueue players, and listen for
	matches.

	```lua
	local Muster = require(ReplicatedStorage.Packages.Muster)

	local duels = Muster.new({ name = "duels", size = 2 })

	duels.matched:connect(function(match)
		for _, member in match.members do
			print(member.userId, "->", match.matchId)
		end
	end)

	duels:enqueue(player.UserId)
	```

	That is the whole setup. The worker starts itself, subscribes for
	cross-server delivery, cleans up when players leave, and matches on its
	first scan.

	### The finalize hook

	Muster stops at the match envelope: it never teleports and never reserves
	servers, because every game wants that done differently. Instead, `finalize`
	runs once per match on whichever server formed it, and whatever it returns
	is attached to the envelope as `match.data` and delivered to everyone.

	```lua
	local ranked = Muster.new({
		name = "ranked",
		size = { min = 4, target = 8, max = 8 },
		rating = { window = 150, relax = 25, default = 1000 },

		finalize = function(match)
			return {
				accessCode = TeleportService:ReserveServerAsync(ARENA_PLACE),
				map = pickMap(match.size),
			}
		end,
	})

	ranked.matched:connect(function(match)
		local present = {}
		for _, member in match.members do
			local player = Players:GetPlayerByUserId(member.userId)
			if player then table.insert(present, player) end
		end
		if #present == 0 then return end
		TeleportService:TeleportToPrivateServer(ARENA_PLACE, match.data.accessCode, present)
	end)
	```

	The contract for that hook, which is worth reading before you write one:

	- It runs **exactly once per matchId**, never concurrently for the same one.
	- It may run **more than once for the same set of players** under different
	  matchIds, if a worker stalls and another repairs its work. **Deduplicate on
	  `matchId`, never on the player set.**
	- Its side effects may **survive a match that never forms** — the lease can
	  be lost during the yield. Write it to be idempotent or cheap to abandon,
	  and use `onAbort` to release anything expensive.
	- If it throws, times out, or returns something unstorable, the match aborts
	  cleanly and every player goes back in the queue.

	### Delivery

	`matched` fires on **every server holding one of the matched players**, not
	just the one that formed the match. If none of the players are on this
	server, it does not fire here at all — so the handler can assume it has
	someone to act on.

	A match is written to MemoryStore before it is announced, so delivery does
	not depend on MessagingService: typically it arrives in under 200 ms, and
	if messaging is down entirely a poll finds it within a few seconds.
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
Matchmaker.__index = Matchmaker

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
	Builds a queue. Every field except `name` and `size` has a default.

	@param config MatchmakerConfig
	@error "Muster: ..." -- Any configuration problem, reported at your call site.
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

	local parties = Party.new(store, {
		clock = settings.clock,
		id = settings.id,
		keys = settings.keys,
		ticketExpiration = settings.ticketExpiration,
		matchExpiration = settings.matchExpiration,
		maxMembers = math.max(settings.size.max, 2),
	})

	local self = setmetatable({
		_settings = settings,
		_executor = executor,
		_store = store,
		_messaging = messaging,
		_connections = {},

		parties = parties,
		matched = Signal.new(),
		aborted = Signal.new(),
		queued = Signal.new(),
		cancelled = Signal.new(),
	}, Matchmaker)

	self._engine = Engine.new(settings, {
		store = store,
		messaging = messaging,
		parties = parties,
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
	Queues one player.

	@param options EnqueueOptions?
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
	Queues an arbitrary set of players as one indivisible ticket, without using
	Muster's own party system. Use this when you already have parties or squads
	of your own.

	@param options GroupOptions?
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
	Queues a Muster party. Only its leader may do this, and the party's
	membership is frozen until the ticket resolves.

	@param options GroupOptions?
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
	Cancels a ticket. Only its leader may do so, and only while it is still
	queued — a ticket already claimed for a match cannot be pulled back.

	@within Matchmaker
]=]
function Matchmaker.cancel(self: any, requesterUserId: number, ticketId: string): any
	return self._engine:cancel(requesterUserId, ticketId)
end

--[=[
	Cancels whatever ticket a user holds, if any. Wired to `PlayerRemoving`
	automatically unless `autoCancelOnLeave` is off.

	@return Result<boolean> -- Whether a ticket was actually cancelled.
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
	@within Matchmaker
]=]
function Matchmaker.getTicket(self: any, userId: number): any
	return self._engine:getTicketForUser(userId)
end

--[=[
	@within Matchmaker
]=]
function Matchmaker.getStatus(self: any, ticketId: string): any
	return self._engine:getStatus(ticketId)
end

--[=[
	Reads a finalized match by id — useful for a player who rejoined on a new
	server and needs the envelope again.

	@within Matchmaker
]=]
function Matchmaker.getMatch(self: any, matchId: string): any
	return self._engine:getMatch(matchId)
end

--[=[
	Releases a ticket's players so they can queue again, and unlocks its party.
	Done for you unless `manualAcknowledge` is set, which is what you want if
	teleporting can fail and you need the option to re-queue.

	@within Matchmaker
]=]
function Matchmaker.acknowledge(self: any, requesterUserId: number, ticketId: string): any
	return self._engine:acknowledge(requesterUserId, ticketId)
end

--[=[
	Runs one worker pass. The loop calls this for you; call it directly in tests
	to advance the system a step at a time.

	@within Matchmaker
]=]
function Matchmaker.step(self: any)
	self._engine:step()
end

--[=[
	@within Matchmaker
]=]
function Matchmaker.start(self: any)
	self._engine:start()
end

--[=[
	Stops the worker and hands back every lease, so another server picks the
	work up at once rather than waiting for a timeout. Call it from
	`BindToClose`.

	@within Matchmaker
]=]
function Matchmaker.stop(self: any)
	self._engine:stop()
end

--[=[
	Stops everything and drops all signal handlers.

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
	A snapshot for logging or a debug command: how many tickets this server has
	queued, how many lanes it is working, whether broadcasts look healthy, and
	per-structure request health.

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
		throttled = self._executor:isThrottled(),
		broadcastHealthy = self._engine._broadcaster:isHealthy(),
		broadcastsSent = self._engine._broadcaster.published,
		broadcastsReceived = self._engine._broadcaster.received,
		requests = self._executor:snapshot(),
	}
end

return Matchmaker
