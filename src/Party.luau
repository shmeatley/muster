--!strict

--[=[
	@class Party

	Cross-server parties: a group of players who queue together and are never
	split across matches.

	Membership is enforced by a **single-slot index per user**, written with
	compare-and-set. A player belongs to at most one party, and two servers
	racing to add the same player will see exactly one of them win — which is
	the whole problem, since the two servers cannot see each other.

	Accepting an invite is a two-phase reservation: a short-lived `Reserved`
	slot is taken first, the party record is updated second, and the slot is
	promoted to `Active` only once the join actually succeeded. A crash between
	the phases leaves a reservation that expires in 20 seconds rather than a
	player wedged in a party that never got them.

	While a party is queued its membership is **frozen** — invites, kicks,
	leaves, leader transfers and disbands all fail with `PartyLocked` — so the
	roster the matchmaker matched cannot change underneath it. An abandoned
	queue lock repairs itself on the next read rather than freezing the party
	forever.

	```lua
	local parties = Muster.Party.new(store)

	local party = Muster.Result.unwrap(parties:create(leaderUserId))
	parties:invite(leaderUserId, friendUserId)

	-- On the friend's server, possibly a different one entirely:
	local invites = Muster.Result.unwrap(parties:listInvites(friendUserId))
	parties:acceptInvite(friendUserId, invites[1].id)
	```
]=]

local Defaults = require(script.Parent.Defaults)
local Result = require(script.Parent.Result)
local Runtime = require(script.Parent.internal.Runtime)
local Types = require(script.Parent.Types)

type PartyView = Types.PartyView

local ok = Result.ok
local err = Result.err

-- Long enough to outlast a slow party write, short enough that a crashed join
-- does not lock the user out for a noticeable time.
local RESERVATION_SECONDS = 20

type PartyProps = {
	_store: any,
	_clock: () -> number,
	_id: () -> string,
	_keys: any,
	_maxMembers: number,
	_partyExpiration: number,
	_inviteExpiration: number,
	_ticketExpiration: number,
	_matchExpiration: number,
}

local Party = {}
Party.__index = Party

export type Party = typeof(setmetatable({} :: PartyProps, Party))

local function copyParty(party: PartyView): PartyView
	local members = table.create(#party.members)
	for index, member in party.members do
		members[index] = {
			userId = member.userId,
			joinedAt = member.joinedAt,
			serverId = member.serverId,
		}
	end
	return {
		v = party.v,
		id = party.id,
		leaderUserId = party.leaderUserId,
		members = members,
		createdAt = party.createdAt,
		version = party.version,
		queue = if party.queue
			then {
				ticketId = party.queue.ticketId,
				state = party.queue.state,
				matchId = party.queue.matchId,
				expiresAt = party.queue.expiresAt,
			}
			else nil,
	}
end

local function memberIndex(party: PartyView, userId: number): number?
	for index, member in party.members do
		if member.userId == userId then
			return index
		end
	end
	return nil
end

--[=[
	@param options -- `clock`, `id`, `namespace`, `maxMembers`. A [Matchmaker] passes its own.
	@within Party
]=]
function Party.new(store: any, options: any?): Party
	local settings = options or {}
	local namespace = settings.namespace or Defaults.NAMESPACE
	local prefix = `{namespace}{Defaults.SCHEMA_VERSION}`

	return setmetatable({
		_store = store,
		_clock = settings.clock or os.time,
		_id = settings.id or Runtime.guid,
		_keys = settings.keys or {
			parties = `{prefix}:parties`,
			memberships = `{prefix}:members`,
			invites = `{prefix}:invites`,
		},
		_maxMembers = settings.maxMembers or Defaults.MAX_PARTY_MEMBERS,
		_partyExpiration = settings.partyExpiration or Defaults.PARTY_EXPIRATION,
		_inviteExpiration = settings.inviteExpiration or Defaults.INVITE_EXPIRATION,
		_ticketExpiration = settings.ticketExpiration or Defaults.TICKET_EXPIRATION,
		_matchExpiration = settings.matchExpiration or Defaults.MATCH_EXPIRATION,
	}, Party)
end

--[=[
	Reads a party, repairing an abandoned queue lock on the way out.

	The repair matters: a server that queued a party and then died would
	otherwise leave it locked until the record itself expired, two hours later.

	@within Party
]=]
function Party.get(self: Party, partyId: string): any
	local success, party = self._store:get(self._keys.parties, partyId, 5)
	if not success then
		return err("StoreUnavailable", tostring(party), true)
	end
	if party == nil then
		return err("PartyNotFound", "That party no longer exists")
	end

	if party.queue ~= nil and party.queue.expiresAt <= self._clock() then
		local repaired = false
		local updated, nextParty = self._store:update(
			self._keys.parties,
			partyId,
			self._partyExpiration,
			function(current: any): any
				repaired = false
				if current == nil or current.queue == nil or current.queue.expiresAt > self._clock() then
					return nil
				end
				local copy = copyParty(current)
				copy.queue = nil
				copy.version += 1
				repaired = true
				return copy
			end,
			3
		)
		if updated and repaired then
			party = nextParty
		end
	end
	return ok(party)
end

--[=[
	The party a user belongs to, or `nil`. Clears a membership pointing at a
	party that no longer contains them.

	@within Party
]=]
function Party.getForUser(self: Party, userId: number): any
	local success, membership = self._store:get(self._keys.memberships, tostring(userId), 5)
	if not success then
		return err("StoreUnavailable", tostring(membership), true)
	end
	if membership == nil then
		return ok(nil)
	end

	local result = self:get(membership.partyId)
	if not result.ok then
		if result.error.code == "PartyNotFound" then
			self._store:remove(self._keys.memberships, tostring(userId))
			return ok(nil)
		end
		return result
	end
	if memberIndex(result.value, userId) == nil then
		self._store:remove(self._keys.memberships, tostring(userId))
		return ok(nil)
	end
	return result
end

--[=[
	@within Party
]=]
function Party.create(self: Party, leaderUserId: number, serverId: string?): any
	local now = self._clock()
	local partyId = self._id()

	local reserved = false
	local success, failure = self._store:update(
		self._keys.memberships,
		tostring(leaderUserId),
		self._partyExpiration,
		function(current: any): any
			reserved = false
			if current ~= nil and (current.state ~= "Reserved" or current.expiresAt > now) then
				return nil
			end
			reserved = true
			return { partyId = partyId, state = "Active", expiresAt = now + self._partyExpiration }
		end,
		3
	)

	if not success then
		return err("StoreUnavailable", tostring(failure), true)
	end
	if not reserved then
		return err("AlreadyInParty", "That user already belongs to a party")
	end

	local party: PartyView = {
		v = Defaults.SCHEMA_VERSION,
		id = partyId,
		leaderUserId = leaderUserId,
		members = { { userId = leaderUserId, joinedAt = now, serverId = serverId } },
		createdAt = now,
		version = 1,
		queue = nil,
	}

	local stored, storeError = self._store:set(self._keys.parties, partyId, party, self._partyExpiration, 3)
	if not stored then
		self._store:remove(self._keys.memberships, tostring(leaderUserId))
		return err("StoreUnavailable", tostring(storeError), true)
	end
	return ok(party)
end

--[=[
	Invites are an inbox keyed by the **target**, so a player sees their invites
	on whatever server they happen to be on. Capped at
	`Defaults.MAX_PARTY_INVITES` per user, oldest evicted first.

	@within Party
]=]
function Party.invite(self: Party, leaderUserId: number, targetUserId: number): any
	if leaderUserId == targetUserId then
		return err("InvalidTarget", "A user cannot invite themselves")
	end

	local owned = self:getForUser(leaderUserId)
	if not owned.ok then
		return owned
	end
	local party = owned.value
	if party == nil or party.leaderUserId ~= leaderUserId then
		return err("NotLeader", "Only the party leader may invite")
	end
	if party.queue ~= nil then
		return err("PartyLocked", "A queued party cannot change membership")
	end
	if #party.members >= self._maxMembers then
		return err("PartyFull", `That party already has {self._maxMembers} members`)
	end

	local now = self._clock()
	local invite = {
		id = self._id(),
		partyId = party.id,
		leaderUserId = leaderUserId,
		targetUserId = targetUserId,
		createdAt = now,
		expiresAt = now + self._inviteExpiration,
	}

	local success, failure = self._store:update(
		self._keys.invites,
		tostring(targetUserId),
		self._inviteExpiration,
		function(current: any): any
			local inbox = {}
			for _, existing in current or {} do
				if existing.expiresAt > now and existing.partyId ~= party.id then
					table.insert(inbox, existing)
				end
			end
			table.insert(inbox, invite)
			while #inbox > Defaults.MAX_PARTY_INVITES do
				table.remove(inbox, 1)
			end
			return inbox
		end,
		3
	)

	if not success then
		return err("StoreUnavailable", tostring(failure), true)
	end
	return ok(invite)
end

--[=[
	@within Party
]=]
function Party.listInvites(self: Party, userId: number): any
	local success, inbox = self._store:get(self._keys.invites, tostring(userId), 5)
	if not success then
		return err("StoreUnavailable", tostring(inbox), true)
	end

	local active = {}
	local now = self._clock()
	for _, invite in inbox or {} do
		if invite.expiresAt > now then
			table.insert(active, invite)
		end
	end
	return ok(active)
end

function Party._removeInvite(self: Party, userId: number, inviteId: string)
	local now = self._clock()
	self._store:update(self._keys.invites, tostring(userId), self._inviteExpiration, function(current: any): any
		local inbox = {}
		for _, invite in current or {} do
			if invite.id ~= inviteId and invite.expiresAt > now then
				table.insert(inbox, invite)
			end
		end
		return inbox
	end, 4)
end

--[=[
	@within Party
]=]
function Party.declineInvite(self: Party, userId: number, inviteId: string): any
	self:_removeInvite(userId, inviteId)
	return ok(true)
end

--[=[
	Joins the inviting party, reserving the user's membership slot before
	touching the party so two competing invites cannot both succeed.

	@within Party
]=]
function Party.acceptInvite(self: Party, userId: number, inviteId: string, serverId: string?): any
	local listed = self:listInvites(userId)
	if not listed.ok then
		return listed
	end

	local selected = nil
	for _, invite in listed.value do
		if invite.id == inviteId then
			selected = invite
			break
		end
	end
	if selected == nil then
		return err("InviteNotFound", "That invitation is missing or has expired")
	end

	local now = self._clock()
	local reservationId = self._id()
	local reserved = false
	local success, failure = self._store:update(
		self._keys.memberships,
		tostring(userId),
		self._partyExpiration,
		function(current: any): any
			reserved = false
			if current ~= nil and (current.state ~= "Reserved" or current.expiresAt > now) then
				return nil
			end
			reserved = true
			return {
				partyId = selected.partyId,
				state = "Reserved",
				reservationId = reservationId,
				expiresAt = now + RESERVATION_SECONDS,
			}
		end,
		3
	)

	if not success then
		return err("StoreUnavailable", tostring(failure), true)
	end
	if not reserved then
		return err("AlreadyInParty", "That user already belongs to a party")
	end

	local joined = false
	local updated, partyOrError = self._store:update(
		self._keys.parties,
		selected.partyId,
		self._partyExpiration,
		function(current: any): any
			joined = false
			if current == nil or current.queue ~= nil or #current.members >= self._maxMembers then
				return nil
			end
			local party = copyParty(current)
			if memberIndex(party, userId) then
				joined = true
				return party
			end
			table.insert(party.members, { userId = userId, joinedAt = now, serverId = serverId })
			party.version += 1
			joined = true
			return party
		end,
		3
	)

	if not updated or not joined then
		self._store:remove(self._keys.memberships, tostring(userId))
		return err(
			if updated then "PartyUnavailable" else "StoreUnavailable",
			if updated then "That party is full, queued, or gone" else tostring(partyOrError),
			not updated
		)
	end

	self._store:set(self._keys.memberships, tostring(userId), {
		partyId = selected.partyId,
		state = "Active",
		expiresAt = now + self._partyExpiration,
	}, self._partyExpiration, 3)
	self:_removeInvite(userId, inviteId)
	return ok(partyOrError)
end

function Party._removeMember(self: Party, actorUserId: number, targetUserId: number, kicked: boolean): any
	local membership = self:getForUser(actorUserId)
	if not membership.ok then
		return membership
	end
	local currentParty = membership.value
	if currentParty == nil then
		return err("PartyNotFound", "That user does not belong to a party")
	end
	if currentParty.queue ~= nil then
		return err("PartyLocked", "A queued party cannot change membership")
	end
	if kicked and currentParty.leaderUserId ~= actorUserId then
		return err("NotLeader", "Only the leader may remove another member")
	end
	if not kicked and actorUserId ~= targetUserId then
		return err("InvalidTarget", "A member may only remove themselves")
	end

	local removed = false
	local disbanded = false
	local success, partyOrError = self._store:update(
		self._keys.parties,
		currentParty.id,
		self._partyExpiration,
		function(current: any): any
			removed = false
			disbanded = false
			if current == nil or current.queue ~= nil then
				return nil
			end
			local index = memberIndex(current, targetUserId)
			if index == nil then
				return nil
			end

			local party = copyParty(current)
			table.remove(party.members, index)
			removed = true
			if #party.members == 0 then
				disbanded = true
				return party
			end
			-- The longest-standing member inherits, which is both predictable
			-- and stable across servers computing it independently.
			if party.leaderUserId == targetUserId then
				table.sort(party.members, function(left, right)
					return left.joinedAt < right.joinedAt
				end)
				party.leaderUserId = party.members[1].userId
			end
			party.version += 1
			return party
		end,
		3
	)

	if not success then
		return err("StoreUnavailable", tostring(partyOrError), true)
	end
	if not removed then
		return err("PartyChanged", "The party changed while removing that member", true)
	end

	self._store:remove(self._keys.memberships, tostring(targetUserId))
	if disbanded then
		self._store:remove(self._keys.parties, currentParty.id)
		return ok(nil)
	end
	return ok(partyOrError)
end

--[=[
	@within Party
]=]
function Party.leave(self: Party, userId: number): any
	return self:_removeMember(userId, userId, false)
end

--[=[
	@within Party
]=]
function Party.kick(self: Party, leaderUserId: number, targetUserId: number): any
	if leaderUserId == targetUserId then
		return err("InvalidTarget", "Use `leave` to remove the leader")
	end
	return self:_removeMember(leaderUserId, targetUserId, true)
end

--[=[
	@within Party
]=]
function Party.transferLeader(self: Party, leaderUserId: number, targetUserId: number): any
	local owned = self:getForUser(leaderUserId)
	if not owned.ok then
		return owned
	end
	local currentParty = owned.value
	if currentParty == nil or currentParty.leaderUserId ~= leaderUserId then
		return err("NotLeader", "Only the leader may transfer leadership")
	end
	if currentParty.queue ~= nil then
		return err("PartyLocked", "A queued party cannot change leadership")
	end
	if memberIndex(currentParty, targetUserId) == nil then
		return err("NotMember", "That user is not in the party")
	end

	local changed = false
	local success, party = self._store:update(
		self._keys.parties,
		currentParty.id,
		self._partyExpiration,
		function(current: any): any
			changed = false
			if current == nil or current.leaderUserId ~= leaderUserId or current.queue ~= nil then
				return nil
			end
			local nextParty = copyParty(current)
			nextParty.leaderUserId = targetUserId
			nextParty.version += 1
			changed = true
			return nextParty
		end,
		3
	)

	if not success then
		return err("StoreUnavailable", tostring(party), true)
	end
	if not changed then
		return err("PartyChanged", "The party changed while transferring leadership", true)
	end
	return ok(party)
end

--[=[
	Refreshes a member's TTL and records which server they are currently on, so
	a match involving them is delivered to the right place.

	@within Party
]=]
function Party.heartbeat(self: Party, userId: number, serverId: string?): any
	local owned = self:getForUser(userId)
	if not owned.ok or owned.value == nil then
		return owned
	end

	local partyId = owned.value.id
	local success, party = self._store:update(
		self._keys.parties,
		partyId,
		self._partyExpiration,
		function(current: any): any
			if current == nil then
				return nil
			end
			local nextParty = copyParty(current)
			local index = memberIndex(nextParty, userId)
			if index then
				nextParty.members[index].serverId = serverId
			end
			return nextParty
		end,
		4
	)

	if not success then
		return err("StoreUnavailable", tostring(party), true)
	end
	self._store:set(self._keys.memberships, tostring(userId), {
		partyId = partyId,
		state = "Active",
		expiresAt = self._clock() + self._partyExpiration,
	}, self._partyExpiration, 4)
	return ok(party)
end

--[=[
	Freezes membership against a queue ticket. Called by [Matchmaker] — you do
	not normally call this yourself.

	@within Party
	@private
]=]
function Party.lockQueue(self: Party, partyId: string, leaderUserId: number, ticketId: string): any
	local locked = false
	local success, party = self._store:update(
		self._keys.parties,
		partyId,
		self._partyExpiration,
		function(current: any): any
			locked = false
			if current == nil or current.leaderUserId ~= leaderUserId or current.queue ~= nil then
				return nil
			end
			local nextParty = copyParty(current)
			nextParty.queue = {
				ticketId = ticketId,
				state = "Queued",
				expiresAt = self._clock() + self._ticketExpiration,
			}
			nextParty.version += 1
			locked = true
			return nextParty
		end,
		3
	)

	if not success then
		return err("StoreUnavailable", tostring(party), true)
	end
	if not locked then
		return err("PartyLocked", "That party is already queued, or you are not its leader")
	end
	return ok(party)
end

--[=[
	@within Party
	@private
]=]
function Party.unlockQueue(self: Party, partyId: string, ticketId: string): any
	local unlocked = false
	local success, party = self._store:update(
		self._keys.parties,
		partyId,
		self._partyExpiration,
		function(current: any): any
			unlocked = false
			if current == nil or current.queue == nil or current.queue.ticketId ~= ticketId then
				return nil
			end
			local nextParty = copyParty(current)
			nextParty.queue = nil
			nextParty.version += 1
			unlocked = true
			return nextParty
		end,
		3
	)

	if not success then
		return err("StoreUnavailable", tostring(party), true)
	end
	if not unlocked then
		return err("PartyChanged", "That party is not queued against this ticket")
	end
	return ok(party)
end

--[=[
	@within Party
	@private
]=]
function Party.heartbeatQueue(self: Party, partyId: string, ticketId: string): any
	local renewed = false
	local success, party = self._store:update(
		self._keys.parties,
		partyId,
		self._partyExpiration,
		function(current: any): any
			renewed = false
			if current == nil or current.queue == nil or current.queue.ticketId ~= ticketId then
				return nil
			end
			local nextParty = copyParty(current)
			local queue = nextParty.queue
			if queue == nil then
				return nil
			end
			queue.expiresAt = self._clock() + self._ticketExpiration
			renewed = true
			return nextParty
		end,
		4
	)

	if not success then
		return err("StoreUnavailable", tostring(party), true)
	end
	if not renewed then
		return err("PartyChanged", "That party is not queued against this ticket")
	end
	return ok(party)
end

--[=[
	@within Party
	@private
]=]
function Party.markMatched(self: Party, partyId: string, ticketId: string, matchId: string): any
	local changed = false
	local success, party = self._store:update(
		self._keys.parties,
		partyId,
		self._partyExpiration,
		function(current: any): any
			changed = false
			if current == nil or current.queue == nil or current.queue.ticketId ~= ticketId then
				return nil
			end
			local nextParty = copyParty(current)
			nextParty.queue = {
				ticketId = ticketId,
				state = "Matched",
				matchId = matchId,
				expiresAt = self._clock() + self._matchExpiration,
			}
			nextParty.version += 1
			changed = true
			return nextParty
		end,
		3
	)

	if not success then
		return err("StoreUnavailable", tostring(party), true)
	end
	if not changed then
		return err("PartyChanged", "That party is not queued against this ticket")
	end
	return ok(party)
end

--[=[
	@within Party
	@private
]=]
function Party.acknowledgeMatch(self: Party, partyId: string, matchId: string): any
	local result = self:get(partyId)
	if not result.ok then
		return result
	end
	local party = result.value
	if party.queue == nil or party.queue.state ~= "Matched" or party.queue.matchId ~= matchId then
		return err("MatchMismatch", "That party is not locked to this match")
	end
	return self:unlockQueue(partyId, party.queue.ticketId)
end

--[=[
	@within Party
]=]
function Party.disband(self: Party, leaderUserId: number): any
	local owned = self:getForUser(leaderUserId)
	if not owned.ok then
		return owned
	end
	local party = owned.value
	if party == nil or party.leaderUserId ~= leaderUserId then
		return err("NotLeader", "Only the leader may disband the party")
	end
	if party.queue ~= nil then
		return err("PartyLocked", "A queued party cannot be disbanded")
	end

	for _, member in party.members do
		self._store:remove(self._keys.memberships, tostring(member.userId))
	end
	local success, failure = self._store:remove(self._keys.parties, party.id)
	if not success then
		return err("StoreUnavailable", tostring(failure), true)
	end
	return ok(true)
end

return Party
