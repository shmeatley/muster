# Muster

[![CI](https://github.com/shmeatley/muster/actions/workflows/ci.yml/badge.svg)](https://github.com/shmeatley/muster/actions/workflows/ci.yml)
[![Wally](https://img.shields.io/badge/wally-shmeatley%2Fmuster-blue)](https://wally.run/package/shmeatley/muster)
[![Docs](https://img.shields.io/badge/docs-moonwave-blue)](https://shmeatley.github.io/muster)
[![Demo](https://img.shields.io/badge/demo-play%20on%20roblox-e2241a)](https://www.roblox.com/games/100811184569764/Muster-Demo)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Cross-server matchmaking for Roblox

For regional matching, use **attributes rather than partitions**. Attributes let
you prefer nearby regions and widen that choice over time. A partition is only
appropriate when those players must never share a match.

Muster forms matches across Roblox servers using your game's ratings, attributes,
server reservation and teleportation systems. It is a library you run in your own
servers. Standard queues can scale through lanes; attribute-rule queues currently
use one lane per partition with bounded candidate discovery. Capacity depends on
match size, rules, party composition and backend latency; the benchmarks below
are measurements of the local implementation, not a guaranteed player limit.

Version 0.4.0 adds attribute rules and forward-page discovery for rule queues.

## Installation

```toml
[dependencies]
Muster = "shmeatley/muster@0.4.0"
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

Omit the `rating` table entirely for an unrated queue. Without attribute rules,
matching is oldest-first; `rules` adds its own constraints and preferences. Rated and unrated is a **per-queue** property: a rated queue
requires a rating for every player, and an unrated one refuses them. Mixing the
two in one lane has no defensible behaviour, so it is rejected loudly at your
call site instead of silently producing bad matches.

A party queues at its mean rating pulled halfway toward its strongest member, so
a good player cannot hide behind low-rated friends. This will help combat the "boosting" problem in your game, but it is not a rating system, but it does not
compute or store ratings, and it does not prevent a player from queuing with
someone who is much stronger than them. That is up to your own rating system.

## Error handling

Invalid queue configuration throws when you construct the queue. Some call-site
errors, such as a missing required rating, also throw. Enqueue validation uses
`Result` errors such as `InvalidAttributes`; check those before using the ticket.
Network operations return a `Result` too, so the game can handle failures:

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
| Notification after commit         | backend-dependent   |
| A message is dropped              | up to 30 s          |
| MessagingService is down entirely | ~5 s, automatically |

The last row is the point: Muster notices when the doorbell stops working and
tightens its polling until it recovers. A match is never lost, since the ledger
holds it for five minutes regardless.

Polling backs off per **ticket** (2s, 4s, 8s, 16s, then capped), not per player,
so a full minute of waiting costs a handful of reads. A server with nothing
queued costs nothing at all.

## Lanes scale themselves

This section describes queues without `rules`. Attribute-rule queues currently
resolve `lanes = "auto"` to one fixed lane per partition and reject explicit
counts above one, including when `rating` is also configured. Their optimized
search does not add cross-lane discovery; see [attribute performance](#attribute-matching-performance).

A standard queue is split into lanes. Workers search their own lane, relevant
draining generations and, when warranted, adjacent rating bands. **Lanes buy parallelism by splitting the pool**, so how many you want
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
reduces unnecessary comparisons, but can separate compatible players near a
boundary or after their windows relax. Nearby high-rated players tend to stay
together rather than being scattered by ticket hash.

A band refuses to split unless its observed ratings span at least two initial
rating windows. This protects tight clusters, but does not guarantee that every
compatible pair shares a lane. A worker also reads the immediate adjacent bands
when its own depth is below eight tickets or its oldest ticket has reached
`rating.unbounded`. It does not search every band covered by a relaxed window.

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

`partitionKey` splits a queue into pools that never mix, such as separate mode
variants. **Use attributes for regions** so nearby regions can match as their
limits widen. Only partition by region when cross-region matching must remain
impossible, including for Quick Play backfill.

```lua
partitionKey = function(request)
	return request.metadata.modeVariant
end
```

Muster does not measure latency for you. Use numeric region coordinates when
their gaps reflect proximity, or a string-region cost matrix in `rules`. A
partition never merges with another; splitting a thin pool can leave it with
nobody to match. See [attribute rules](#multiple-matching-attributes) for region
examples. Quick Play backfill bypasses attribute rules.

Skill brackets are the one split worth _not_ doing here. Give the queue a
`rating` instead and its lanes become rating ranges on their own, with the
difference that a lane rejoins its neighbour when it empties out and a partition
never does.

## Multiple matching attributes

Use `rules` to compare independent numeric, string and boolean attributes when
forming **new matches**. Keep permanently separate pools in `partition`; put a
region in attributes if it may become eligible later.

```lua
local queue = Muster.new({
	name = "social",
	size = 8,
	rules = {
		Age = {
			type = "number", compare = "distance", prefer = "closer",
			limit = {
				{ after = 0, value = 2 },
				{ after = 30, value = 5 },
				{ after = 90, value = 10 },
			},
		},
		Region = { type = "string", compare = "equal", relaxAfter = 45 },
		IsVerified = { type = "boolean", compare = "equal" },
		IsFlaggedCheater = { type = "boolean", compare = "required", value = false },
	},
})

queue:enqueue(player.UserId, {
	attributes = {
		Age = 21, Region = "US_EAST",
		IsVerified = true, IsFlaggedCheater = false,
	},
})
```

Each rule declares `type` and `compare`:

| Comparison | Behavior |
| --- | --- |
| `distance` | Numeric absolute difference, or a string-category cost matrix. `limit` is a fixed nonnegative number or a schedule starting at `{ after = 0, value = ... }`. The default is zero. |
| `equal` | Values must match. Optional `relaxAfter` allows unequal values once **both** tickets have waited that long. Omit it for permanent equality. |
| `required` | Every member must have `value`. It is checked at enqueue for ordinary tickets and cannot relax. For example, `value = false` excludes flagged players; equality instead separates flagged and unflagged players. |

Distance schedules have increasing times and nondecreasing finite limits, with
at most 32 steps. The final limit stays enforced indefinitely. Age and region
schedules are evaluated independently from the original queue timestamp, without
requeueing. Acceptance is always mutual: a distance must fit the **smaller** of
the two current limits. An older ticket cannot override a new ticket's limit.

Checks cover every member pair, including within a party; age is not averaged.
A currently incompatible party waits until its own restrictions relax. A party
with conflicting permanent equality values cannot form a new match; validate
that party composition in your game before queueing. Parties are never split.
Both `enqueueGroup` and `enqueueParty` take `attributes` keyed by userId:

```lua
queue:enqueueGroup({ aliceId, bobId }, {
	attributes = {
		[aliceId] = { Age = 21, Region = "US_EAST", IsVerified = true, IsFlaggedCheater = false },
		[bobId] = { Age = 23, Region = "US_EAST", IsVerified = true, IsFlaggedCheater = false },
	},
})
```

For string distance, supply a symmetric matrix. Identical categories cost zero;
missing edges remain forbidden. Every category must have a row, including empty
rows for categories that can only match themselves. These are game-defined
costs, not measured ping:

```lua
Region = {
	type = "string", compare = "distance", prefer = "closer",
	distances = {
		US_EAST = { US_WEST = 60, EU = 90 },
		US_WEST = { US_EAST = 60, EU = 150 },
		EU = { US_EAST = 90, US_WEST = 150 },
	},
	limit = { { after = 0, value = 0 }, { after = 30, value = 80 }, { after = 60, value = 150 } },
}
```

Numeric region coordinates also work with `type = "number"` and numeric distance,
if numeric gaps represent useful proximity. Arbitrary IDs do not imply latency.

Constraints reject candidates; preferences rank eligible groups. Add
`prefer = "closer"` to distance rules or `prefer = "equal"` to equality rules to
rank groups while retaining the constraint. Set `mode = "preference"` on distance
or equality rules to rank without rejecting. Optional nonnegative `weight`
(default 1) scales the penalty. Each preference contributes its worst
member-pair distance (or 0/1 equality penalty); their weighted sum is minimized,
then the sum of ticket queue timestamps. Weights must account for differing
units. Missing matrix edges have infinite preference cost. Required rules are
always constraints.

If `rating` is also configured, its existing anchor-based window remains an
additional eligibility check; rule preferences supply the group score. Without
`rules`, the existing rating matching and scoring behavior is unchanged.

**Current bounds:** rule queues resolve `lanes = "auto"` to one fixed lane;
explicit lane counts above one and custom `matcher`/`layout` overrides are
rejected. A scan requests at most 100 candidates. Most scans start with the
oldest tickets; forward pages also give newer tickets a chance when a head is
stalled or stays busy. Selection visits visible anchors oldest first and keeps
eight alternatives per reachable group size. This is still bounded search:
compatible tickets spread across separate windows may never be compared. It is
not exhaustive matching or a distributed attribute index.

Configure 1-16 named attributes (names up to 32 bytes). Every member must supply
all configured fields, with no unknown fields, finite numbers and strings up to
128 bytes. Invalid input returns `InvalidAttributes`. Values are copied at
enqueue and included in `match.members[i].attributes`. The estimated serialized
attribute budget per ticket is the smaller of 4096 bytes and
`floor(8192 * ticketSize / size.max)`, reserving attribute space across a full
match. Keep unrelated data in `metadata`. Rules configuration is copied, frozen
and limited to an estimated 16 KiB.

Rule fingerprints separate new-match lane indexes, leases and layouts from
legacy queues and other rule configurations. All workers for a pool must use the
same configuration. Changing rules starts a separate new-match pool; old tickets
need old workers to finish or must expire/cancel. User reservations and Quick
Play listings remain shared for the same namespace and queue name.

**Quick Play backfill deliberately bypasses matching rules**, as it bypasses
ratings. A Quick Play ticket still needs valid attributes for the new-match path,
but its live-match destination is selected by the existing partition and seat
rules. Quick Play tickets may also bypass required-value eligibility at enqueue;
that requirement still prevents them from forming a new match. Hard attribute
constraints are guarantees about new-match formation only.

## Attribute matching performance

The matcher now reuses compatibility and score calculations and skips search
work that cannot improve a match. It keeps the same eight beam alternatives
and matching rules.

Here are the original results alongside two runs after optimization, measured
on October 16, 2026 with Lune 0.10.5 on a Ryzen 5 7600X running Windows:

| Fixture | Original median | New medians, two runs |
| --- | ---: | ---: |
| 25 solo tickets, 8-player match | 9.32 ms | 1.33-2.54 ms |
| 50 solo tickets, 8-player match | 41.23 ms | 3.98-6.24 ms |
| 100 solo tickets, 8-player match | 171.97 ms | 12.44-13.72 ms |
| 100 solo tickets, hard constraints only | 132.20 ms | 9.89-11.28 ms |
| 100 solo tickets, 32-player match | 884.29 ms | 27.19-35.64 ms |
| 100 solo tickets, 16 rules | 798.27 ms | 61.53-62.00 ms |
| 100 four-player parties, 8-player match | 80.66 ms | 5.40-5.82 ms |

The usual fixture has four rules: age proximity, region, verification and a
required unflagged value. Each run takes 3-9 timed samples after warmup. These
are local timings, not Roblox server limits. Results vary: the mixed
verified/unverified fixture measured 12.58 and 28.27 ms at 100 tickets.

The standard 100-ticket scan is about 13 times faster, so the earlier warning
about CPU cost at 50 tickets no longer applies to that fixture. Larger matches
and more rules still cost more. Profile your game on Roblox before choosing a
capacity limit or adding lanes.

An earlier discovery test found a real problem: 100 incompatible old tickets
hid eight compatible players behind them. The worker now pages beyond that head.
Rule queues still use one lane per partition, and a party counts as one ticket.

After a full scan makes no matches, the next scan reads an oldest prefix and a
forward page. A busy head also gets a forward scan after four normal scans,
so some ongoing matching cannot keep newer players hidden forever. Each forward
scan is followed by a normal oldest-first scan. Pages overlap by up to
`size.target - 1` tickets and wrap when they reach the tail. Cursors belong to the
worker lease; they reset if another worker takes over. Queue timestamps and rule
relaxation schedules do not change.

Each scan requests at most 100 entries across at most two range reads. Small
queues still use a single read. Large targets can leave less room for the oldest
prefix and require more overlap. Custom store adapters must support the optional
fifth `sortedRange` argument, an exclusive `{ sortKey, key }` cursor; the bundled
adapters implement it. Quick Play discovery is unchanged.

The hidden group now matches after 3.25 simulated seconds in that test, instead
of staying stuck for the full 100-second run. This does not guarantee every
compatible combination will share a window, particularly with scattered groups,
ongoing arrivals or frequent worker changes. There is no cross-lane rule search.

A compatible 5,000-player burst drained in 15.5 simulated seconds. That clock
excludes CPU time and network latency, and the in-memory store does not enforce
real quotas or throttling. It is a useful comparison fixture, not a promise
about how many players a live queue can handle.

Run the benchmarks from the repository root:

```sh
lune run bench/attributes
lune run bench/optimization/verify
```

The first command overwrites [the latest results](bench/attributes-results.json).
The second checks optimized matching against the saved original implementation.
See the [benchmark notes](bench/optimization/README.md) for methods, validation,
[the two-run comparison](bench/optimization/recheck-20261016-170742/comparison.json)
and the earlier runs. Those two optimized-matcher reruns kept the same outcomes. The later discovery
change matches the hidden group after 3.25 simulated seconds. The latest run
keeps all 44 pure matcher counts and the normal burst/arrival outcomes unchanged;
`bench/discovery-before.json` preserves the pre-fix results.

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

The latest recorded full suite passed 590 checks with zero failures or crashes
(October 16, 2026); run it again for your checkout. It covers three servers
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
lune run bench/optimization/verify  # compare optimized selection with preserved source
lune run bench/attributes           # overwrite latest benchmark JSON
```

## License

MIT
