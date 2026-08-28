# Muster

[![CI](https://github.com/shmeatley/muster/actions/workflows/ci.yml/badge.svg)](https://github.com/shmeatley/muster/actions/workflows/ci.yml)
[![Wally](https://img.shields.io/badge/wally-shmeatley%2Fmuster-blue)](https://wally.run/package/shmeatley/muster)
[![Docs](https://img.shields.io/badge/docs-moonwave-blue)](https://shmeatley.github.io/muster)
[![Demo](https://img.shields.io/badge/demo-play%20on%20roblox-e2241a)](https://www.roblox.com/games/100811184569764/Muster-Demo)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Cross-server matchmaking for Roblox

Muster aims to be a drag and drop cross-server matchmaking solution that is extremely customizable, along with scalable architecture that can handle thousands of players in a queue without any extra work on your part. It is designed to be a library, not a service, so you can use it with your own rating system, teleportation system, and server reservation system. That does result in more work on your part, but it also means you can use it with whatever systems you already have in place, and you can change those systems without having to change Muster.

## Installation

```toml
[dependencies]
Muster = "shmeatley/muster@0.3.0"
```

Then run:

```sh
wally install
```

## Quick start

```lua
local Muster = require(ReplicatedStorage.Packages.Muster)
local Players = game:GetService("Players")

local duels = Muster.new({ name = "duels", size = 2 })

duels.matched:connect(function(match)
	for _, member in match.members do
		print(member.userId, "->", match.matchId)
	end
end)

Players.PlayerAdded:Connect(function(player)
	duels:enqueue(player.UserId)
end)
```

That is the whole setup. The worker starts itself, subscribes for cross-server
delivery, cleans up when players leave, and matches on its first scan.

## See it running

There is a demo place, published so you can watch a match form without building
anything:
**[Muster Demo](https://www.roblox.com/games/100811184569764/Muster-Demo)**.
Click the blue pad to queue, the grey one to add a bot, and the board tells you
what the queue is doing. That is a real queue on real MemoryStore, matching
across every server the game is running.

`MusterDemo.rbxl` is committed here too, so you can open it in Studio and read
the source alongside it, or rebuild it with:

```sh
rojo build demo.project.json -o MusterDemo.rbxl
```

The wiring is all in [demo/server/Sandbox](demo/server/Sandbox): one
`Muster.new` call, a handful of signal handlers, and the pads that drive them.
See [demo/README.md](demo/README.md).

## Reserved servers, teams, and the `finalize` hook

Muster never teleports, but it makes teleporting easy. `finalize` runs **once
per match**, on whichever server formed it, and whatever it returns is attached
to the envelope as `match.data` and delivered to everyone. This is where you can reserve a server, pick a map, and assign teams. For example:

To be clear, `finalize` is not a hook that runs on every server, it runs only on the server that formed the match. The data it returns is then sent to all servers that have players in the match.

`matched` fires on every server that has at least one player in the match, so you can teleport them all to the reserved server.

```lua
local ranked = Muster.new({
	name = "ranked",
	size = { min = 4, target = 8, max = 8 },
	rating = { window = 150, relax = 25, default = 1000 },

	finalize = function(match)
		return {
			accessCode = TeleportService:ReserveServerAsync(ARENA_PLACE),
			map = pickMap(match.size),
			killer = match.members[math.random(match.size)].userId,
		}
	end,

	onAbort = function(context)
		Analytics:log("match_abandoned", { reason = context.reason })
	end,
})

ranked.matched:connect(function(match)
	local present = {}
	for _, member in match.members do
		local player = Players:GetPlayerByUserId(member.userId)
		if player then
			table.insert(present, player)
		end
	end
	if #present == 0 then
		return
	end

	TeleportService:TeleportToPrivateServer(ARENA_PLACE, match.data.accessCode, present, nil, {
		matchId = match.matchId,
		map = match.data.map,
		killer = match.data.killer,
	})
end)
```

`match.data` is typed as the finalizer's return type, so `match.data.accessCode`
autocompletes.

### The hook's contract

Read this before writing one. All four points come from the same fact: this is a
distributed system where servers cannot see each other.

- It runs **exactly once per `matchId`**, never concurrently for the same one.
- It may run **more than once for the same set of players**, under different
  matchIds, if a worker stalls and another repairs its work. **Deduplicate on
  `matchId`, never on the player set.**
- Its side effects may **survive a match that never forms**, because the lease
  can be lost while it yields. Write it to be idempotent or cheap to abandon, and use
  `onAbort` to release anything expensive. (A leaked reserved-server access code
  costs nothing and expires on its own, which is why this is usually fine.)
- Because of that, be careful when doing things like writing to a database.
- If it throws, exceeds `finalizeTimeout`, or returns something unstorable, the
  match aborts cleanly and every player goes back in the queue.

## Quick Play (optional)

Everything above forms **new** matches. Quick Play adds the other half: dropping
a player straight into a match that is already running with room to spare. It is
off unless you ask for it, and it **ignores rating entirely**, so it belongs on
casual queues rather than ranked ones.

```lua
local casual = Muster.new({ name = "casual", size = 8, quickPlay = true })
```

On the arena server, advertise yourself once you are ready for players:

```lua
casual.quickplay:host({
	data = { accessCode = code, placeId = ARENA_PLACE },
})
```

That is the whole match-server side. The listing refreshes its player count
every 30 seconds off the back of the worker that is already running, and a
server that crashes is delisted 90 seconds later without anyone cleaning up.

`host` hands back a handle for the two things a round actually needs:

```lua
local listing = Muster.Result.unwrap(casual.quickplay:host({ data = ... }))

listing:setOpen(false)  -- round underway; stop taking players, stay listed
listing:setOpen(true)   -- intermission; take them again
listing:close()         -- delist now rather than waiting to expire
```

Calling `queue:stop()` closes everything this server hosts, so binding it to
`game:BindToClose` is enough to stop a shutting-down arena from being sent
players it will not be around to seat.

In the lobby:

```lua
casual.quickPlayMatched:connect(function(assignment)
	TeleportService:TeleportToPrivateServer(
		assignment.data.placeId, assignment.data.accessCode, { player })
end)

casual:quickPlay(player.UserId)
```

### Queueing a group

Quick Play can backfill a group together using the same userId list accepted by
`enqueueGroup`:

```lua
casual:quickPlayGroup({ leaderId, friendId })
```

The group is one indivisible ticket. It reserves enough seats for every member
in one listed match, or reserves nothing and stays in the normal queue. The
equivalent lower-level form is
`casual:enqueueGroup({ leaderId, friendId }, { quickPlay = true })`.

### If everything is full, nothing special happens

`quickPlay` writes an **ordinary ticket** and then looks for a seat. If every
listed match is full, the player simply stays in the normal queue and forms a
fresh match the usual way, retrying the backfill search every few seconds while
they wait. So a slot opening up mid-wait pulls them in, and a slot never opening
still gets them a game.

The two outcomes race, which is why `quickPlay` returns the ticket rather than
the match: a backfill arrives on `quickPlayMatched`, a fresh match on `matched`,
and exactly one of them fires.

### Two lobbies, one last seat

This is the part that has to be right. When a 7/8 match is visible to fifty
lobby servers, exactly one of them may take the last seat.

Every claim is a single compare-and-set on the listing record. The store re-runs
the loser's transform against the winner's write, the seat is gone the second
time around, and the loser moves on to its next candidate. There is no lock and
no coordination between lobbies.

A claimed seat is held as a **reservation** until the player arrives, because a
player count that refreshes every 30 seconds cannot be trusted on its own. The
reservation retires when the host's next heartbeat reports that player present,
and expires after 45 seconds if they never show.

The index is sorted by seats free, ascending, so backfill completes a 7/8 game
before it grows a 2/8 one, and full matches are dropped from it entirely rather
than read and discarded.

### Options

| Field | Default | Effect |
| --- | --- | --- |
| `capacity` | `size.max` | Players a hosted match holds. |
| `heartbeatInterval` | `30` | Seconds between player-count refreshes. |
| `listingExpiration` | `heartbeatInterval * 3` | Seconds a listing survives without one. |
| `reservationTimeout` | `45` | Seconds a claimed seat is held. |
| `searchInterval` | `3` | Seconds between retries by a queued player. |
| `lanes` | `"auto"` | Listing lane count. Pin it with an integer. |
| `maxListingDataBytes` | `1024` | Budget for the listing's `data`. |

Listings shard into lanes exactly as tickets do, because a MemoryStore range
read returns at most 200 items and a busy game can have more live matches than
that. The count starts at one and doubles only once a lane is consistently too
full to read in one go, so a game with six live matches pays for none of it.

## Queueing a group

If you already have parties, or your parties form in one lobby and live in a
table on that server, just hand Muster the userIds:

```lua
ranked:enqueueGroup({ leaderId, friendId }, { ratings = ratings })
```

That is one indivisible ticket: never split across matches, matched at the
group's aggregate rating. **This is the path most games want**, and it involves
none of the machinery below.

## Parties (optional)

Muster also ships a cross-server party system, built on the same store. It is
constructed on first access to `queue.parties` and writes nothing until you use
it, so ignoring it costs you nothing.

You need it only if parties have to survive players being on _different_
servers. That happens more than you might expect:

- Join-friend drops you in another server when your friend's is full
- You want to invite someone who isn't in your lobby yet
- Players scatter across lobby servers on the trip back from a match

If none of those apply to your game, use `enqueueGroup` and skip this.

```lua
local parties = ranked.parties

local party = Muster.Result.unwrap(parties:create(leaderUserId))
parties:invite(leaderUserId, friendUserId)

-- On the friend's server, wherever that is:
local invites = Muster.Result.unwrap(parties:listInvites(friendUserId))
parties:acceptInvite(friendUserId, invites[1].id)

-- Only the leader may queue, and membership freezes until it resolves.
ranked:enqueueParty(party.id, leaderUserId, { ratings = ratings })
```

Membership is enforced by compare-and-set, so a player is never in two parties
at once even when two servers try at the same moment. That is the whole
difficulty, since those servers cannot see each other.

## Ratings

Muster does skill-based _matching_, not skill _rating_. Bring your own number
from wherever you keep it.

```lua
rating = {
	window = 150,   -- start within +/-150
	relax = 25,     -- widen by 25 per second waited
	unbounded = 60, -- after a minute, take anyone
	default = 1000, -- for players who have no rating yet
}
```

Omit the `rating` table entirely for an unrated queue, where matching is simply
oldest-first. Rated and unrated is a **per-queue** property: a rated queue
requires a rating for every player, and an unrated one refuses them. Mixing the
two in one lane has no defensible behaviour, so it is rejected loudly at your
call site instead of silently producing bad matches.

A party queues at its mean rating pulled halfway toward its strongest member, so
a good player cannot hide behind low-rated friends. This will help combat the "boosting" problem in your game, but it is not a rating system, but it does not
compute or store ratings, and it does not prevent a player from queuing with
someone who is much stronger than them. That is up to your own rating system.

## Error handling

> If it's your bug, it throws. If it's the network's fault, it's a `Result`.

Bad configuration and bad arguments raise an error at your call site. Anything
that depends on MemoryStore being reachable returns a `Result`, because that
genuinely fails in production:

```lua
local result = queue:enqueue(player.UserId, { rating = 1200 })
if not result.ok then
	if result.error.code == "AlreadyQueued" then
		return "You're already in a queue."
	end
	return if result.error.retryable then "Try again in a moment." else "Couldn't queue."
end
```

## Delivery

`matched` fires on **every server holding one of the matched players**, not
just the one that formed the match. If none of them are here, it does not fire
here, so your handler always has someone to act on.

A match is written to MemoryStore _before_ it is announced, so delivery never
depends on MessagingService:

| Situation                         | Time to delivery    |
| --------------------------------- | ------------------- |
| Normal                            | under ~200 ms       |
| A message is dropped              | up to 30 s          |
| MessagingService is down entirely | ~5 s, automatically |

The last row is the point: Muster notices when the doorbell stops working and
tightens its polling until it recovers. A match is never lost, since the ledger
holds it for five minutes regardless.

Polling backs off per **ticket** (2s, 4s, 8s, 16s, then capped), not per player,
so a full minute of waiting costs a handful of reads. A server with nothing
queued costs nothing at all.

## Lanes scale themselves

A queue is split into lanes, and a ticket is matched against the others in its
own lane. **Lanes buy parallelism by splitting the pool**, so how many you want
depends on how deep the queue is, and _where_ you cut depends on what the queue
knows about its players. You don't have to guess either.

By default (`lanes = "auto"`) a queue starts on **one** lane, so two players
match on the first scan. It divides only once a single lane is consistently too
full for one worker to see all of, and folds back down when the queue thins out
again. No sizing table, no tuning.

**A rated queue divides by rating.** Every lane is a contiguous rating range,
and the boundaries come from the ratings actually queueing: a lane that grows
too deep splits at its own median, and one that goes quiet merges back into its
neighbour. Cutting along the axis matchmaking already cares about means a split
only separates players who were never going to be put in the same game, so four
high-rated players queueing at once land in one lane instead of scattering
across four.

Bands never get narrower than the rating window. A lane whose players are all
within one window of each other has no boundary that would not cut through a set
that all match, so it stays whole however deep it gets, which is exactly the
shape the top of a ladder has. And a band that is nearly empty, or one holding
somebody whose window has already relaxed past its width, reads the lanes either
side of it as well, so a boundary is never a wall to a player with nobody left
on their own side of it.

**An unrated queue divides by hash**, `hash(ticketId) % count`, doubling and
halving. With no ratings there is nothing to order players by and every ticket
may match every other, so an even spread is the best split available.

Pin it if you'd rather: `lanes = 4` (any integer, 1 to 64) disables scaling
entirely, writes no lane record, and spreads by hash.

<details>
<summary>How resharding avoids losing tickets</summary>

Moving lanes around naively is a good way to strand players: a ticket written
under 2 lanes lives in `hash % 2`, and a server that has moved to 4 lanes looks
in `hash % 4` and never finds it. It doesn't error, the player just waits until
their ticket expires.

Muster stamps the layout into every key:

```
mu1:ranked:idx:EMEA:n04g7:02
                    ^^^^^ ^^
                   layout lane
```

`n04` is the lane count and `g7` the revision it belongs to, tracked separately
because a rating boundary can move without the count changing. Servers that
disagree read and write _different_ key spaces rather than corrupting one, and
every ticket stays exactly where its writer put it. While the old layout drains,
workers on the new one also read the old lanes theirs draws from: one extra
where a lane was split, two where two were merged, and the same one or two when
a hash count doubles or halves. Changes are spaced a full `ticketExpiration`
apart, which guarantees an abandoned layout has drained before another lands.

</details>

## Partitions

`partitionKey` splits a queue into pools that never mix: regions, mode variants,
platforms.

```lua
partitionKey = function(request)
	return request.metadata.region
end
```

Muster deliberately ships no region system of its own. A partition never merges
with another, so partitioning a thin queue is how matchmaking stops working; the
decision of when it is safe belongs to you.

Skill brackets are the one split worth _not_ doing here. Give the queue a
`rating` instead and its lanes become rating ranges on their own, with the
difference that a lane rejoins its neighbour when it empties out and a partition
never does.

## Testing your own game against it

`Muster.stores.InMemory` and `Muster.messaging.InMemory` are real
implementations with a synthetic clock and fault injection, so your tests can
run the whole system with no MemoryStore, no Studio, and no waiting:

```lua
local now = 0
local clock = function() return now end
local store = Muster.stores.InMemory.new(clock)

local queue = Muster.new({
	name = "test", size = 2,
	store = store, clock = clock, monotonic = clock,
	autoStart = false, broadcast = false,
	spawn = function(fn) fn() end,
	sleep = function() end,
})

queue:enqueue(1)
queue:enqueue(2)
queue:step()        -- matched, deterministically

store:failNext("update", 2)   -- and now with the store falling over
store:conflictNext("update")  -- and now losing a compare-and-set race
```

Muster's own suite is ~265 assertions run this way, including three servers
contending for one lane, a worker crashing mid-commit, and a finalizer that
loses its lease while yielding.

## How it works

Every server is both a producer and an opportunistic worker; there is no
matchmaker server to elect or provision.

1. **Enqueue** reserves each player's id with compare-and-set, writes the ticket,
   and indexes it in a sorted map keyed by queue time.
2. **Acquire** takes a _lease_ on the lane, carrying a monotonically increasing
   **fencing epoch**.
3. **Scan** reads the oldest candidates and runs the grouping algorithm.
4. **Commit** is two-phase: claim every ticket in sorted order, re-check the
   lease, run `finalize`, re-check the lease _again_ because it yielded, then
   flip the record to `Ready` with a compare-and-set guarded on the epoch. A
   server that stalled and lost its lease cannot commit, because the store itself
   rejects the write.
5. **Deliver** publishes to the servers holding the players.

Quick Play runs alongside that rather than inside it: a flagged ticket also tries
to claim a seat in a live match on every pass, and the two paths arbitrate on the
same compare-and-set that moves a ticket out of `Queued`, so a player resolves to
exactly one of them.

Nothing needs cleaning up when a server dies. Leases expire and the epoch fences
out the dead holder; claims expire and the next worker either adopts a match that
did commit or aborts one that did not; tickets stop heartbeating and evict
themselves.

Full API reference: [shmeatley.github.io/muster](https://shmeatley.github.io/muster)

## Development

```sh
rokit install
lune run test/run    # headless suite
selene src
stylua --check src test demo
```

## License

MIT
