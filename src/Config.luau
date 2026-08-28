--!strict

--[=[
	@class Config

	Validates a queue configuration and normalizes it into the frozen settings
	table every other module reads.

	`resolve` returns `(settings, problem)` rather than throwing, so validation
	is directly testable and so [Matchmaker] can raise the error at the caller's
	own `Muster.new` line rather than from inside this module.
]=]

local Defaults = require(script.Parent.Defaults)
local Hash = require(script.Parent.Hash)
local Runtime = require(script.Parent.internal.Runtime)
local Types = require(script.Parent.Types)

type Metadata = Types.Metadata

local Config = {}

local NAME_PATTERN = "^[%w_%-]+$"

local function isCallable(value: any): boolean
	return type(value) == "function"
end

local function isPositiveInteger(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value == value
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function checkName(label: string, value: any, limit: number): string?
	if type(value) ~= "string" or value == "" then
		return `Muster: \`{label}\` must be a non-empty string`
	end
	if #value > limit then
		return `Muster: \`{label}\` must be at most {limit} characters (got {#value})`
	end
	if not string.match(value, NAME_PATTERN) then
		return `Muster: \`{label}\` may only contain letters, digits, underscores and hyphens (got "{value}")`
	end
	return nil
end

local function resolveSize(raw: any): (any, string?)
	if raw == nil then
		return nil, "Muster: `size` is required"
	end
	if type(raw) == "number" then
		if not isPositiveInteger(raw) then
			return nil, `Muster: \`size\` must be a positive integer (got {raw})`
		end
		return { min = raw, target = raw, max = raw }, nil
	end
	if type(raw) ~= "table" then
		return nil, "Muster: `size` must be a number or a table of { min, target, max }"
	end

	local min = raw.min
	if not isPositiveInteger(min) then
		return nil, "Muster: `size.min` must be a positive integer"
	end
	local max = raw.max or raw.target or min
	local target = raw.target or max
	if not isPositiveInteger(target) or not isPositiveInteger(max) then
		return nil, "Muster: `size.target` and `size.max` must be positive integers"
	end
	if not (min <= target and target <= max) then
		return nil, `Muster: \`size\` must satisfy min <= target <= max (got {min}, {target}, {max})`
	end
	return { min = min, target = target, max = max }, nil
end

local function resolveRating(raw: any): (any, string?)
	if raw == nil then
		return nil, nil
	end
	if type(raw) ~= "table" then
		return nil, "Muster: `rating` must be a table, or nil for an unrated queue"
	end

	local window = raw.window or Defaults.RATING_WINDOW
	local relax = raw.relax or Defaults.RATING_RELAX
	local maxWindow = raw.maxWindow or math.huge
	local unbounded = raw.unbounded or Defaults.RATING_UNBOUNDED

	if not (type(window) == "number" and window > 0) then
		return nil, "Muster: `rating.window` must be a positive number"
	end
	if not (type(relax) == "number" and relax >= 0) then
		return nil, "Muster: `rating.relax` must be a non-negative number"
	end
	if not (type(maxWindow) == "number" and maxWindow >= window) then
		return nil, "Muster: `rating.maxWindow` must be a number no smaller than `rating.window`"
	end
	if not (type(unbounded) == "number" and unbounded > 0) then
		return nil, "Muster: `rating.unbounded` must be a positive number of seconds"
	end
	if raw.default ~= nil and not isFiniteNumber(raw.default) then
		return nil, "Muster: `rating.default` must be a finite number"
	end
	if raw.aggregate ~= nil and not isCallable(raw.aggregate) then
		return nil, "Muster: `rating.aggregate` must be a function"
	end

	return {
		window = window,
		relax = relax,
		maxWindow = maxWindow,
		unbounded = unbounded,
		default = raw.default,
		aggregate = raw.aggregate or Defaults.aggregate,
	},
		nil
end

--[=[
	Validates the `quickPlay` table, or `nil` when the feature is off.

	`quickPlay = true` is shorthand for every default. The lane count is
	validated the same way the ticket lane count is, and for the same reason:
	listings shard by hash, and only the scaler's own resize path depends on the
	count being a power of two.

	@within Config
	@private
]=]
local function resolveQuickPlay(raw: any, size: any): (any, string?)
	if raw == nil or raw == false then
		return nil, nil
	end
	local given = if raw == true then {} else raw
	if type(given) ~= "table" then
		return nil, "Muster: `quickPlay` must be a table, `true`, or nil to leave Quick Play off"
	end

	local capacity = given.capacity or size.max
	if not isPositiveInteger(capacity) then
		return nil, "Muster: `quickPlay.capacity` must be a positive integer"
	end

	local heartbeatInterval = given.heartbeatInterval or Defaults.LISTING_HEARTBEAT_INTERVAL
	if not (type(heartbeatInterval) == "number" and heartbeatInterval > 0) then
		return nil, "Muster: `quickPlay.heartbeatInterval` must be a positive number of seconds"
	end

	-- Three missed beats by default. A listing has to outlive more than one
	-- dropped heartbeat, or a single slow request evicts a healthy match.
	local listingExpiration = given.listingExpiration or heartbeatInterval * 3
	if not (type(listingExpiration) == "number" and listingExpiration > heartbeatInterval) then
		return nil, "Muster: `quickPlay.listingExpiration` must be a number larger than `quickPlay.heartbeatInterval`"
	end

	local reservationTimeout = given.reservationTimeout or Defaults.RESERVATION_TIMEOUT
	if not (type(reservationTimeout) == "number" and reservationTimeout > 0) then
		return nil, "Muster: `quickPlay.reservationTimeout` must be a positive number of seconds"
	end

	local searchInterval = given.searchInterval or Defaults.QUICKPLAY_SEARCH_INTERVAL
	if not (type(searchInterval) == "number" and searchInterval > 0) then
		return nil, "Muster: `quickPlay.searchInterval` must be a positive number of seconds"
	end

	local laneMode = "auto"
	local lanes = Defaults.LANES
	if given.lanes ~= nil and given.lanes ~= "auto" then
		laneMode = "fixed"
		lanes = given.lanes
		if not isPositiveInteger(lanes) or lanes > Defaults.LANE_MAX then
			return nil,
				`Muster: \`quickPlay.lanes\` must be "auto" or an integer from 1 to {Defaults.LANE_MAX} (got {tostring(
					given.lanes
				)})`
		end
	end

	local maxListingDataBytes = given.maxListingDataBytes or Defaults.MAX_LISTING_DATA_BYTES
	if not isPositiveInteger(maxListingDataBytes) then
		return nil, "Muster: `quickPlay.maxListingDataBytes` must be a positive integer"
	end

	return {
		capacity = capacity,
		heartbeatInterval = heartbeatInterval,
		listingExpiration = listingExpiration,
		-- Index entries outlive their listing slightly, for the same reason
		-- ticket index entries do: a search must never see an entry vanish out
		-- from under a listing that is still live.
		indexExpiration = listingExpiration + 10,
		reservationTimeout = reservationTimeout,
		searchInterval = searchInterval,
		lanes = lanes,
		laneMode = laneMode,
		-- A listing outlives a resize, unlike a ticket, so it migrates to its new
		-- lane on its next heartbeat rather than draining. The resize cooldown has
		-- to comfortably exceed that, or a second resize could land while the
		-- fleet is still moving.
		laneCooldown = math.max(heartbeatInterval * 3, listingExpiration),
		maxListingDataBytes = maxListingDataBytes,
	},
		nil
end

local FUNCTION_FIELDS = {
	"partitionKey",
	"finalize",
	"onAbort",
	"clock",
	"monotonic",
	"random",
	"sleep",
	"spawn",
	"id",
	"logger",
	"metrics",
}

--[=[
	Folds a partition key to something a MemoryStore name can hold.

	Keys of 32 characters or fewer made up of letters, digits, underscores and
	hyphens pass through unchanged, which keeps lane names readable in logs.
	Anything else is replaced by a hash.

	@within Config
]=]
function Config.normalizePartition(value: string): string
	if #value <= Defaults.MAX_PARTITION_LENGTH and string.match(value, NAME_PATTERN) then
		return value
	end
	return `h{Hash.string(value)}`
end

--[=[
	Validates a raw config and fills in every default.

	@return any -- The frozen settings table, or `nil` when `problem` is set.
	@return string? -- The validation failure, naming the offending field.
	@within Config
]=]
function Config.resolve(raw: any): (any, string?)
	if type(raw) ~= "table" then
		return nil, "Muster.new expects a config table"
	end

	local problem = checkName("name", raw.name, Defaults.MAX_NAME_LENGTH)
	if problem then
		return nil, problem
	end

	local namespace = raw.namespace or Defaults.NAMESPACE
	problem = checkName("namespace", namespace, Defaults.MAX_NAME_LENGTH)
	if problem then
		return nil, problem
	end

	local size, sizeProblem = resolveSize(raw.size)
	if sizeProblem then
		return nil, sizeProblem
	end

	local rating, ratingProblem = resolveRating(raw.rating)
	if ratingProblem then
		return nil, ratingProblem
	end

	local quickPlay, quickPlayProblem = resolveQuickPlay(raw.quickPlay, size)
	if quickPlayProblem then
		return nil, quickPlayProblem
	end

	for _, field in FUNCTION_FIELDS do
		if raw[field] ~= nil and not isCallable(raw[field]) then
			return nil, `Muster: \`{field}\` must be a function`
		end
	end

	local finalizeTimeout = raw.finalizeTimeout or Defaults.FINALIZE_TIMEOUT
	if not (type(finalizeTimeout) == "number" and finalizeTimeout > 0) then
		return nil, "Muster: `finalizeTimeout` must be a positive number of seconds"
	end
	if finalizeTimeout > Defaults.MAX_FINALIZE_TIMEOUT then
		return nil,
			`Muster: \`finalizeTimeout\` must be at most {Defaults.MAX_FINALIZE_TIMEOUT} seconds; a slower hook `
				.. "would hold its tickets past the point where crash recovery stays responsive"
	end
	if raw.onAbort ~= nil and raw.finalize == nil then
		return nil, "Muster: `onAbort` only fires for matches that ran a `finalize` hook; set `finalize` too"
	end

	-- `lanes` is "auto" (the default) or a pinned count.
	--
	-- A pinned count may be any integer in range. The power-of-two rule exists
	-- only so the scaler can map old lanes onto new ones exactly when it
	-- resizes, and a pinned count never resizes. With no previous layout,
	-- `Lanes.legacyLanes` is never reached. The invariant stays enforced where it
	-- is actually load-bearing, inside LaneScaler.
	local laneMode = "auto"
	local lanes = Defaults.LANES
	if raw.lanes ~= nil and raw.lanes ~= "auto" then
		laneMode = "fixed"
		lanes = raw.lanes
		if not isPositiveInteger(lanes) or lanes > Defaults.LANE_MAX then
			return nil,
				`Muster: \`lanes\` must be "auto" or an integer from 1 to {Defaults.LANE_MAX} (got {tostring(raw.lanes)})`
		end
	end

	-- How a partition's pool is divided. A scaling rated queue splits by rating
	-- band, which separates players who would not have matched anyway; anything
	-- else has no ordering to split on and spreads tickets by hash. A pinned
	-- count is deliberately included in "anything else": bands are placed from
	-- what the scaler observes, and a pinned queue never runs it.
	local laneSplit = if laneMode == "auto" and rating ~= nil then "band" else "hash"

	local fallbackAfter = raw.fallbackAfter or Defaults.FALLBACK_AFTER
	if not (type(fallbackAfter) == "number" and fallbackAfter >= 0) then
		return nil, "Muster: `fallbackAfter` must be a non-negative number of seconds"
	end

	local pollInterval = raw.pollInterval or Defaults.POLL_INTERVAL
	local pollIntervalMax = raw.pollIntervalMax or Defaults.POLL_INTERVAL_MAX
	if not (type(pollInterval) == "number" and pollInterval > 0) then
		return nil, "Muster: `pollInterval` must be a positive number of seconds"
	end
	if not (type(pollIntervalMax) == "number" and pollIntervalMax >= pollInterval) then
		return nil, "Muster: `pollIntervalMax` must be a number no smaller than `pollInterval`"
	end

	local ticketExpiration = raw.ticketExpiration or Defaults.TICKET_EXPIRATION
	if not (type(ticketExpiration) == "number" and ticketExpiration >= 30) then
		return nil, "Muster: `ticketExpiration` must be at least 30 seconds"
	end

	for _, field in { "maxMetadataBytes", "maxMatchDataBytes", "inlineBroadcastBytes" } do
		if raw[field] ~= nil and not isPositiveInteger(raw[field]) then
			return nil, `Muster: \`{field}\` must be a positive integer`
		end
	end

	local serverId = raw.serverId or Runtime.jobId()
	if serverId ~= nil and type(serverId) ~= "string" then
		return nil, "Muster: `serverId` must be a string"
	end
	if serverId == nil then
		-- Studio hands out an empty JobId, and Lune has none at all. A per-process
		-- random id keeps lease ownership and broadcast addressing distinct
		-- between sessions, which is what a real JobId would have done.
		serverId = `local-{Runtime.guid()}`
	end

	local settings = {
		name = raw.name,
		namespace = namespace,
		version = Defaults.SCHEMA_VERSION,

		size = table.freeze(size),
		rating = if rating then table.freeze(rating) else nil,
		rated = rating ~= nil,
		fallbackAfter = fallbackAfter,
		lanes = lanes,
		laneMode = laneMode,
		laneSplit = laneSplit,
		-- The shared layout outlives any ticket written against it, so a partition
		-- that goes quiet does not silently reset to one lane mid-drain. A
		-- partition that stays busy without resizing has its record refreshed
		-- before it gets here; see `LaneScaler._touch`.
		laneStateExpiration = ticketExpiration * 4,
		partitionKey = raw.partitionKey,

		finalize = raw.finalize,
		finalizeTimeout = finalizeTimeout,
		onAbort = raw.onAbort,
		-- Widened once here rather than extending N claims mid-commit, which
		-- would cost an extra write per ticket per match.
		claimDuration = Defaults.CLAIM_DURATION + (if raw.finalize then finalizeTimeout else 0),

		ticketExpiration = ticketExpiration,
		indexExpiration = ticketExpiration + 10,
		matchExpiration = raw.matchExpiration or Defaults.MATCH_EXPIRATION,
		heartbeatInterval = raw.heartbeatInterval or Defaults.TICKET_HEARTBEAT_INTERVAL,

		broadcast = raw.broadcast ~= false,
		topicShards = raw.topicShards or 0,
		pollInterval = pollInterval,
		pollIntervalMax = pollIntervalMax,
		pollIntervalUnhealthy = raw.pollIntervalUnhealthy or Defaults.POLL_INTERVAL_UNHEALTHY,

		maxMetadataBytes = raw.maxMetadataBytes or Defaults.MAX_METADATA_BYTES,
		maxMatchDataBytes = raw.maxMatchDataBytes or Defaults.MAX_MATCH_DATA_BYTES,
		inlineBroadcastBytes = raw.inlineBroadcastBytes or Defaults.INLINE_BROADCAST_BYTES,

		autoStart = raw.autoStart ~= false,
		autoCancelOnLeave = raw.autoCancelOnLeave ~= false,
		manualAcknowledge = raw.manualAcknowledge == true,

		quickPlay = if quickPlay then table.freeze(quickPlay) else nil,

		store = raw.store,
		messaging = raw.messaging,
		players = raw.players,
		matcher = raw.matcher,
		layout = raw.layout,
		logger = raw.logger,
		metrics = raw.metrics,

		-- Two clocks on purpose. `clock` is wall time and must agree across
		-- servers, because it is written into leases, claims and TTLs. `monotonic`
		-- is local and only paces this server's own loops, so it wants resolution
		-- rather than agreement. os.time() is whole seconds, which would quantize
		-- every scan delay and poll interval to 1s.
		clock = raw.clock or os.time,
		monotonic = raw.monotonic or os.clock,
		random = raw.random or math.random,
		sleep = raw.sleep or Runtime.sleep,
		spawn = raw.spawn or Runtime.spawn,
		id = raw.id or Runtime.guid,
		serverId = serverId,
	}

	local prefix = `{namespace}{Defaults.SCHEMA_VERSION}`
	settings.keys = table.freeze({
		tickets = `{prefix}:{raw.name}:tickets`,
		matches = `{prefix}:{raw.name}:matches`,
		leases = `{prefix}:{raw.name}:leases`,
		-- Keyed by partition: each one scales on its own depth.
		lanes = `{prefix}:{raw.name}:lanes`,
		-- Quick Play keeps its own ledger and its own lane layout, so a listing
		-- never shares a key space with a ticket.
		quickplay = `{prefix}:{raw.name}:qp`,
		quickplayLanes = `{prefix}:{raw.name}:qplanes`,
		-- Shared across every queue in the namespace, so a player cannot hold
		-- tickets in two queues at once. Use a distinct `namespace` for queues
		-- that should be independent.
		users = `{prefix}:users`,
		parties = `{prefix}:parties`,
		memberships = `{prefix}:members`,
		invites = `{prefix}:invites`,
	})

	return table.freeze(settings), nil
end

return table.freeze(Config)
