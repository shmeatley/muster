--!strict

--[=[
	@class Muster

	Cross-server matchmaking for Roblox.

	Players and parties go into a queue; Muster handles the distributed part —
	sharded queue lanes, worker election, skill-windowed grouping, and delivery
	of the result to every server holding a matched player. It stops at the
	match envelope: it does not teleport, does not reserve servers, and does not
	compute or store ratings. Those are yours, and `finalize` is where they
	attach.

	```lua
	local Muster = require(ReplicatedStorage.Packages.Muster)

	local duels = Muster.new({ name = "duels", size = 2 })

	duels.matched:connect(function(match)
		print(`{match.size} players matched as {match.matchId}`)
	end)

	duels:enqueue(player.UserId)
	```

	See [Matchmaker] for the queue itself, [Party] for cross-server parties, and
	[Result] for the error convention.
]=]

local Config = require(script.Config)
local Defaults = require(script.Defaults)
local Hash = require(script.Hash)
local Matchmaker = require(script.Matchmaker)
local Party = require(script.Party)
local Result = require(script.Result)
local Signal = require(script.Signal)
local Types = require(script.Types)

local Broadcaster = require(script.internal.Broadcaster)
local Engine = require(script.internal.Engine)
local Finalizer = require(script.internal.Finalizer)
local LaneScaler = require(script.internal.LaneScaler)
local Lanes = require(script.internal.Lanes)
local LeaseManager = require(script.internal.LeaseManager)
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

		Cross-server parties, usable on their own. A [Matchmaker] exposes its own
		instance as `queue.parties`.
	]=]
	Party = Party,

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

		Every tunable and its reasoning.
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

		The deterministic string hash used for lane assignment.
	]=]
	hash = Hash,

	--[=[
		@prop stores { MemoryStore: MemoryStore, InMemory: InMemoryStore }
		@within Muster
		@readonly

		Storage backends. `InMemory` ships so your own tests can run against a
		real implementation with a synthetic clock and fault injection.
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

		The pieces a [Matchmaker] is assembled from, for building something
		Muster does not do. Not covered by semver — treat the facade as the API.
	]=]
	internal = table.freeze({
		Broadcaster = Broadcaster,
		Engine = Engine,
		Finalizer = Finalizer,
		LaneScaler = LaneScaler,
		Lanes = Lanes,
		LeaseManager = LeaseManager,
		Matcher = Matcher,
		RequestExecutor = RequestExecutor,
		Serialize = Serialize,
	}),
}

--[=[
	Builds a queue. See [Matchmaker] for the full configuration surface.

	@function new
	@param config MatchmakerConfig
	@return Matchmaker
	@within Muster
]=]
Muster.new = Matchmaker.new

return table.freeze(Muster)
