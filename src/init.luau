--!strict

--[=[
	@class Muster

	Package entry point.

	Muster forms matches across servers: it shards a queue into lanes, elects a
	worker per lane, groups tickets by size and rating, and delivers the result
	to every server holding a matched player. It does not teleport players,
	reserve servers, or compute ratings. Those attach through the `finalize` hook
	and the rating you supply.

	```lua
	local Muster = require(ReplicatedStorage.Packages.Muster)

	local duels = Muster.new({ name = "duels", size = 2 })

	duels.matched:connect(function(match)
		print(`{match.size} players matched as {match.matchId}`)
	end)

	duels:enqueue(player.UserId)
	```

	Start at [Matchmaker]. [Party] covers cross-server parties, [Result] the
	error convention, and [Types] every exported type.
]=]

local Config = require(script.Config)
local Defaults = require(script.Defaults)
local Hash = require(script.Hash)
local Matchmaker = require(script.Matchmaker)
local Party = require(script.Party)
local QuickPlay = require(script.QuickPlay)
local Result = require(script.Result)
local Signal = require(script.Signal)
local Types = require(script.Types)

local Broadcaster = require(script.internal.Broadcaster)
local Engine = require(script.internal.Engine)
local Finalizer = require(script.internal.Finalizer)
local LaneScaler = require(script.internal.LaneScaler)
local Lanes = require(script.internal.Lanes)
local LeaseManager = require(script.internal.LeaseManager)
local Listings = require(script.internal.Listings)
local Matcher = require(script.internal.Matcher)
local RequestExecutor = require(script.internal.RequestExecutor)
local Serialize = require(script.internal.Serialize)

local InMemoryStore = require(script.stores.InMemory)
local InMemoryMessaging = require(script.messaging.InMemory)
local MemoryStore = require(script.stores.MemoryStore)
local RobloxMessaging = require(script.messaging.Roblox)

export type Metadata = Types.Metadata
export type Member = Types.Member
export type Ticket = Types.Ticket
export type MatchEnvelope<T> = Types.MatchEnvelope<T>
export type MatchContext = Types.MatchContext
export type AbortReason = Types.AbortReason
export type AbortContext = Types.AbortContext
export type Finalizer<T> = Types.Finalizer<T>
export type AbortHandler = Types.AbortHandler
export type QueueStatus<T> = Types.QueueStatus<T>
export type ErrorCode = Types.ErrorCode
export type ServiceError = Types.ServiceError
export type Result<T> = Types.Result<T>
export type Store = Types.Store
export type Messaging = Types.Messaging
export type Subscription = Types.Subscription
export type SortedItem = Types.SortedItem
export type Candidate = Types.Candidate
export type MatcherPolicy = Types.MatcherPolicy
export type RatingConfig = Types.RatingConfig
export type SizeConfig = Types.SizeConfig
export type EnqueueOptions = Types.EnqueueOptions
export type GroupOptions = Types.GroupOptions
export type PartyMember = Types.PartyMember
export type PartyQueue = Types.PartyQueue
export type PartyView = Types.PartyView
export type PartyInvite = Types.PartyInvite
export type QuickPlayConfig = Types.QuickPlayConfig
export type Reservation = Types.Reservation
export type Listing<T> = Types.Listing<T>
export type ListingView = Types.ListingView
export type HostOptions<T> = Types.HostOptions<T>
export type QuickPlayAssignment<T> = Types.QuickPlayAssignment<T>
export type Logger = Types.Logger
export type Metrics = Types.Metrics
export type Party = Party.Party
export type Signal<T> = Signal.Signal<T>
export type Connection = Signal.Connection

local Muster = {
	--[=[
		@prop Party Party
		@within Muster
		@readonly

		Cross-server party state. A [Matchmaker] exposes its own instance as
		`queue.parties`; this export is for using parties without a queue.
	]=]
	Party = Party,

	--[=[
		@prop QuickPlay QuickPlay
		@within Muster
		@readonly

		Backfilling players into live matches. A [Matchmaker] with a `quickPlay`
		config exposes its own instance as `queue.quickplay`.
	]=]
	QuickPlay = QuickPlay,

	--[=[
		@prop Result Result
		@within Muster
		@readonly
	]=]
	Result = Result,

	--[=[
		@prop Signal Signal
		@within Muster
		@readonly
	]=]
	Signal = Signal,

	--[=[
		@prop Defaults Defaults
		@within Muster
		@readonly

		Protocol constants and tuning values.
	]=]
	Defaults = Defaults,

	--[=[
		@prop Config Config
		@within Muster
		@readonly
	]=]
	Config = Config,

	--[=[
		@prop hash Hash
		@within Muster
		@readonly

		FNV-1a string hashing, used for lane assignment.
	]=]
	hash = Hash,

	--[=[
		@prop stores { MemoryStore: MemoryStore, InMemory: InMemoryStore }
		@within Muster
		@readonly

		Storage backends. `MemoryStore` is the production one; `InMemory` is a
		complete implementation backed by tables, for tests.
	]=]
	stores = table.freeze({
		MemoryStore = MemoryStore,
		InMemory = InMemoryStore,
	}),

	--[=[
		@prop messaging { Roblox: RobloxMessaging, InMemory: InMemoryMessaging }
		@within Muster
		@readonly
	]=]
	messaging = table.freeze({
		Roblox = RobloxMessaging,
		InMemory = InMemoryMessaging,
	}),

	--[=[
		@prop internal table
		@within Muster
		@readonly

		The components a [Matchmaker] is assembled from. Useful for building on
		individual pieces. Not covered by semantic versioning, so treat
		[Matchmaker] as the stable surface.
	]=]
	internal = table.freeze({
		Broadcaster = Broadcaster,
		Engine = Engine,
		Finalizer = Finalizer,
		LaneScaler = LaneScaler,
		Lanes = Lanes,
		LeaseManager = LeaseManager,
		Listings = Listings,
		Matcher = Matcher,
		RequestExecutor = RequestExecutor,
		Serialize = Serialize,
	}),
}

--[=[
	Builds a queue. Alias of [Matchmaker.new], where the configuration is
	documented.

	@function new
	@param config MatchmakerConfig
	@return Matchmaker
	@within Muster
]=]
Muster.new = Matchmaker.new

return table.freeze(Muster)
