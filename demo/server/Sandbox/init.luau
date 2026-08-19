--!strict

--[[
	The demo: one real queue, on real MemoryStore, with real players.

	This is also the worked example. Strip out the pads, the board and the bots
	and what is left is the whole integration: build a queue, handle `matched`,
	call `enqueue` when a player asks to play.

	What you do here:

		click the blue pad    join the queue, or leave it if you are in it
		click the grey pad    add a bot, so one person can fill a match

	Matches are 4 players, settling for 2 after eight seconds. So: click blue,
	click grey once, wait eight seconds, and you are in a match. Click grey
	three times instead and it forms immediately.

	Needs "Enable Studio Access to API Services" (Game Settings, Security).
	Without it every store call fails, which the board will tell you about,
	because that is exactly what a MemoryStore outage looks like in production.

	Nothing teleports. A real game reserves a server in `finalize` and teleports
	in `matched`; both places are marked below.
]]

local Players = game:GetService("Players")

local Arena = require(script.Arena)

-- Ids far outside the real UserId range, so a bot can never be confused with a
-- person and never pollutes a real player's queue state.
local BOT_ID_BASE = -90000

local MAPS = { "Canyon", "Foundry", "Harbour", "Tundra" }

-- Match sizing, kept here because the board quotes it back at you.
local MIN_PLAYERS = 2
local TARGET_PLAYERS = 4
local FALLBACK_AFTER = 8

-- Muster logs what its worker is doing if you give it a logger. Worth watching
-- once: you will see it take a lane, form matches, and hand the lane back when
-- the queue goes quiet.
local SHOW_ENGINE_LOG = true

local Sandbox = {}

local function shortId(id: string): string
	return string.sub(id, 1, 8)
end

--[[ Turns a ServiceError into something worth showing a player. ]]
local function describe(failure: any): string
	if failure.code == "StoreUnavailable" then
		return "MemoryStore is unreachable. Enable Studio Access to API Services."
	elseif failure.code == "AlreadyQueued" then
		return "You are already in a queue."
	end
	return `{failure.code}: {failure.message}`
end

function Sandbox.start(Muster: any): any
	local arena = Arena.new()

	-- Everything the board shows is kept here and updated from the queue's own
	-- signals. A demo that polled the store once a second to draw a sign would
	-- be a poor advertisement for a library that counts its requests.
	local waiting: { [number]: { name: string, since: number } } = {}
	local botsAdded = 0
	local lastMatch: any = nil
	local lastFailure: string? = nil

	local queue = Muster.new({
		name = "sandbox",
		-- Four players, but two will do once someone has waited eight seconds.
		-- That setting is what decides whether a small game feels alive.
		size = { min = MIN_PLAYERS, target = TARGET_PLAYERS, max = TARGET_PLAYERS },
		fallbackAfter = FALLBACK_AFTER,

		--[[
			Runs once per match, on whichever server formed it. In a real game:

				accessCode = TeleportService:ReserveServerAsync(ARENA_PLACE)

			Whatever it returns is attached to the envelope and delivered to
			every server holding a player, so nobody has to ask anyone anything
			before teleporting.
		]]
		finalize = function(match)
			return {
				map = MAPS[math.random(#MAPS)],
				formedBy = match.matchId,
			}
		end,

		-- Fires when a match that had already claimed its players failed to
		-- commit. In a real game this is where you release the reserved server.
		onAbort = function(context)
			warn(`[sandbox] match {shortId(context.matchId)} aborted: {context.reason}`)
		end,

		logger = if SHOW_ENGINE_LOG
			then function(level: string, message: string, fields: any)
				local detail = {}
				for key, value in fields do
					table.insert(detail, `{key}={value}`)
				end
				table.sort(detail)
				print(`[muster/{level}] {message} {table.concat(detail, " ")}`)
			end
			else nil,
	})

	----------------------------------------------------------------------------
	-- Signals. These four are the whole integration surface for a game.
	----------------------------------------------------------------------------

	-- Fires on this server for every ticket enqueued here.
	queue.queued:connect(function(ticket)
		for _, member in ticket.members do
			waiting[member.userId] = {
				name = (ticket.metadata and ticket.metadata.name) or tostring(member.userId),
				since = os.time(),
			}
		end
	end)

	-- Fires for a ticket this server was tracking that has been cancelled,
	-- including the automatic cancel when a player leaves the game.
	queue.cancelled:connect(function(ticket)
		for _, member in ticket.members do
			waiting[member.userId] = nil
		end
	end)

	--[[
		Fires on every server holding at least one matched player, which here is
		always this one. Deduplicate on `match.matchId`: the same players can be
		matched again under a new id if a worker stalls and another repairs it.
	]]
	queue.matched:connect(function(match)
		lastMatch = match
		arena:flash()

		local names = {}
		for _, member in match.members do
			local entry = waiting[member.userId]
			table.insert(names, if entry then entry.name else tostring(member.userId))
			waiting[member.userId] = nil
		end

		print(`[sandbox] match {shortId(match.matchId)}: {table.concat(names, ", ")} on {match.data.map}`)

		for _, member in match.members do
			local player = Players:GetPlayerByUserId(member.userId)
			if player then
				arena:setHud(player, `Matched on {match.data.map}, {match.size} players`)
			end
		end

		-- A real game teleports here, using the reserved server the finalizer
		-- produced:
		--
		--   TeleportService:TeleportToPrivateServer(
		--     ARENA_PLACE, match.data.accessCode, present, nil,
		--     { matchId = match.matchId, map = match.data.map }
		--   )
	end)

	----------------------------------------------------------------------------
	-- The pads.
	----------------------------------------------------------------------------

	arena:onQueueClick(function(player)
		-- Already queued here? Then this is a leave, not a join. `waiting` is
		-- local state, so answering that question costs no request at all.
		if waiting[player.UserId] then
			local cancelled = queue:cancelForUser(player.UserId)
			if cancelled.ok then
				waiting[player.UserId] = nil
				arena:setHud(player, "Left the queue.")
			else
				arena:setHud(player, describe(cancelled.error))
			end
			return
		end

		-- Metadata rides along on the ticket and comes back on the envelope.
		-- Keep it small: the budget is 1 kB per ticket.
		local result = queue:enqueue(player.UserId, { metadata = { name = player.Name } })
		if not result.ok then
			local message = describe(result.error)
			lastFailure = message
			arena:setHud(player, message)
			warn(`[sandbox] enqueue failed: {result.error}`)
			return
		end

		lastFailure = nil
		arena:setHud(player, `Queued as ticket {shortId(result.value.id)}`)
	end)

	arena:onBotClick(function(player)
		botsAdded += 1
		local userId = BOT_ID_BASE - botsAdded

		local result = queue:enqueue(userId, { metadata = { name = `Bot {botsAdded}` } })
		if not result.ok then
			local message = describe(result.error)
			lastFailure = message
			arena:setHud(player, message)
			return
		end

		lastFailure = nil
		arena:setHud(player, `Added Bot {botsAdded} to the queue`)
	end)

	-- A bot has no PlayerRemoving to clean it up, so one that never matches sits
	-- in the queue until its ticket stops being heartbeaten and expires, three
	-- minutes later. That is the same mechanism that clears a crashed server's
	-- players, watched from the outside.
	Players.PlayerRemoving:Connect(function(player)
		waiting[player.UserId] = nil
		arena:clearHud(player)
	end)

	----------------------------------------------------------------------------
	-- The board.
	----------------------------------------------------------------------------

	local function render()
		-- `health` is this server's own view: what it has queued locally, which
		-- lanes it is working, and whether message delivery looks reliable.
		local health = queue:health()

		local lines = {
			"MUSTER SANDBOX",
			"",
			`queue     {health.queue}`,
			`size      {TARGET_PLAYERS} players, or {MIN_PLAYERS} after {FALLBACK_AFTER}s`,
			`server    {shortId(health.serverId)}`,
			`lanes     {health.ownedLanes} held of {health.laneCount} ({health.laneMode})`,
			`doorbell  {if health.broadcastHealthy then "healthy" else "degraded, polling harder"}`,
			"",
			"in the queue on this server:",
		}

		local queued = 0
		for _, entry in waiting do
			queued += 1
			table.insert(lines, `  {entry.name} waiting {os.time() - entry.since}s`)
		end
		if queued == 0 then
			table.insert(lines, "  nobody yet. click the blue pad.")
		end

		table.insert(lines, "")
		if lastMatch then
			table.insert(lines, `last match {lastMatch.size} players on {lastMatch.data.map}`)
			table.insert(lines, `           {shortId(lastMatch.matchId)}`)
		else
			table.insert(lines, "last match none yet")
		end
		if lastFailure then
			table.insert(lines, "")
			table.insert(lines, lastFailure)
		end

		arena:setBoard(lines)
	end

	local rendering = true
	task.spawn(function()
		while rendering do
			render()
			task.wait(1)
		end
	end)

	-- Releasing this server's lane leases on shutdown lets another server pick
	-- them up immediately instead of waiting out the fifteen second timeout.
	game:BindToClose(function()
		rendering = false
		queue:stop()
	end)

	print("")
	print("Muster sandbox is live. Click the blue pad to queue, the grey pad to add a bot.")
	print(`Matches are {TARGET_PLAYERS} players, or {MIN_PLAYERS} after {FALLBACK_AFTER} seconds of waiting.`)
	print("")

	return queue
end

return Sandbox
