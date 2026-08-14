--!strict

--[=[
	@class Broadcaster

	Cross-server delivery of committed matches.

	MemoryStore is the source of truth; MessagingService only shortens the wait.
	A match is written and flipped to `Ready` before anything is published, so
	losing every message costs latency and nothing else.

	### Addressing

	One topic per server, named `<namespace><version>:<serverId>`, with each
	instance subscribed to exactly one. A match is published only to the distinct
	servers holding its members, typically two to six.

	A single shared topic would instead deliver every match to every server. With
	Roblox's per-universe receive budget of `400 + 200 x servers` per minute,
	that caps the experience at roughly 200 matches per minute regardless of
	size, so per-server topics are used instead.

	`topicShards` folds servers into a fixed number of topics if topic
	cardinality ever needs limiting; `0`, the default, means one per server.

	### Payload

	Envelopes under `inlineBroadcastBytes` (600) are sent inside the message,
	saving the receiver a read. Larger ones send only the matchId and the
	receiver reads the ledger. An inline envelope is safe to trust because it
	exists only after the commit succeeded.

	### Health

	A failed publish, or a match found by polling that should have arrived as a
	message, marks delivery unhealthy for `BROADCAST_UNHEALTHY_DURATION` (300 s).
	While unhealthy, tickets poll on a much tighter cap.
]=]

local Defaults = require(script.Parent.Parent.Defaults)
local Serialize = require(script.Parent.Serialize)

type BroadcasterProps = {
	_settings: any,
	_messaging: any,
	_topic: string,
	_subscription: any,
	_onEnvelope: (any, string) -> (),
	_fetch: (string) -> any,
	_seen: { [string]: number },
	_seenOrder: { string },
	_unhealthyUntil: number,
	published: number,
	received: number,
}

local Broadcaster = {}
Broadcaster.__index = Broadcaster

export type Broadcaster = typeof(setmetatable({} :: BroadcasterProps, Broadcaster))

--[=[
	@param onEnvelope -- Called with `(envelope, source)` for each newly seen match.
	@param fetch -- Reads an envelope from the ledger by matchId, for non-inline messages.
	@within Broadcaster
]=]
function Broadcaster.new(settings: any, messaging: any, onEnvelope: (any, string) -> (), fetch: (string) -> any)
	return setmetatable({
		_settings = settings,
		_messaging = messaging,
		_topic = Broadcaster.topicFor(settings, settings.serverId),
		_subscription = nil,
		_onEnvelope = onEnvelope,
		_fetch = fetch,
		_seen = {},
		_seenOrder = {},
		_unhealthyUntil = 0,
		published = 0,
		received = 0,
	}, Broadcaster)
end

--[=[
	The topic a given server listens on.

	@within Broadcaster
]=]
function Broadcaster.topicFor(settings: any, serverId: string): string
	local prefix = `{settings.namespace}{settings.version}`
	if settings.topicShards > 0 then
		local Hash = require(script.Parent.Parent.Hash)
		return `{prefix}:s{Hash.partition(serverId, settings.topicShards)}`
	end
	return `{prefix}:{serverId}`
end

--[=[
	Records a matchId and reports whether it had not been seen before.

	Bounded to `Defaults.SEEN_CAPACITY` (256) entries, evicted oldest first, so a
	long-lived server does not accumulate them.

	@within Broadcaster
]=]
function Broadcaster.accept(self: Broadcaster, matchId: string): boolean
	if self._seen[matchId] then
		return false
	end
	self._seen[matchId] = 1
	table.insert(self._seenOrder, matchId)
	if #self._seenOrder > Defaults.SEEN_CAPACITY then
		local oldest = table.remove(self._seenOrder, 1)
		if oldest then
			self._seen[oldest] = nil
		end
	end
	return true
end

--[=[
	@within Broadcaster
]=]
function Broadcaster.isHealthy(self: Broadcaster): boolean
	if not self._settings.broadcast then
		return false
	end
	return self._settings.monotonic() >= self._unhealthyUntil
end

--[=[
	Marks delivery unreliable for `BROADCAST_UNHEALTHY_DURATION` seconds.

	@within Broadcaster
]=]
function Broadcaster.markUnhealthy(self: Broadcaster)
	self._unhealthyUntil = self._settings.monotonic() + Defaults.BROADCAST_UNHEALTHY_DURATION
end

--[=[
	Subscribes to this server's topic. Calling it twice does nothing.

	@within Broadcaster
]=]
function Broadcaster.start(self: Broadcaster)
	if self._subscription ~= nil or not self._settings.broadcast or self._messaging == nil then
		return
	end
	self._subscription = self._messaging:subscribe(self._topic, function(payload)
		self:_receive(payload)
	end)
end

--[=[
	@within Broadcaster
]=]
function Broadcaster.stop(self: Broadcaster)
	if self._subscription == nil then
		return
	end
	self._subscription:disconnect()
	self._subscription = nil
end

function Broadcaster._receive(self: Broadcaster, payload: any)
	if type(payload) ~= "table" or type(payload.matchId) ~= "string" then
		return
	end
	self.received += 1

	if not self:accept(payload.matchId) then
		return
	end

	local envelope = payload.envelope
	if envelope == nil then
		envelope = self._fetch(payload.matchId)
		if envelope == nil then
			-- The ledger entry is gone or unreadable. The ticket's own poll is
			-- the backstop, so let it be found there; releasing the dedupe entry
			-- would risk delivering twice instead.
			return
		end
	end
	self._onEnvelope(envelope, "broadcast")
end

--[=[
	Publishes a committed match to every other server holding one of its members.
	Called only after the match has reached `Ready`.

	@within Broadcaster
]=]
function Broadcaster.announce(self: Broadcaster, envelope: any)
	if not self._settings.broadcast or self._messaging == nil then
		return
	end

	local targets: { [string]: boolean } = {}
	for _, member in envelope.members do
		if member.serverId ~= nil and member.serverId ~= self._settings.serverId then
			targets[member.serverId] = true
		end
	end
	if next(targets) == nil then
		return
	end

	-- Inline when it fits. The budget is well under MessagingService's 1 kB cap
	-- because that cap counts Roblox's framing too, and a rejected publish is
	-- worse than an extra read.
	local payload: any = { matchId = envelope.matchId }
	if Serialize.size(envelope) <= self._settings.inlineBroadcastBytes then
		payload.envelope = envelope
	end

	local failed = false
	for serverId in targets do
		local ok = self._messaging:publish(Broadcaster.topicFor(self._settings, serverId), payload)
		self.published += 1
		if not ok then
			failed = true
		end
	end
	if failed then
		self:markUnhealthy()
	end
end

--[=[
	How long a ticket waits before its next poll, given how many it has already
	made.

	Doubles from `pollInterval` (2 s), capped at `pollIntervalMax` (30 s) while
	delivery is healthy and at `pollIntervalUnhealthy` (5 s) while it is not.

	@within Broadcaster
]=]
function Broadcaster.pollInterval(self: Broadcaster, attempt: number): number
	local settings = self._settings
	local cap = if self:isHealthy() then settings.pollIntervalMax else settings.pollIntervalUnhealthy
	local interval = settings.pollInterval * (2 ^ math.max(0, attempt))
	return math.min(cap, interval)
end

return Broadcaster
