# Muster

[![CI](https://github.com/shmeatley/muster/actions/workflows/ci.yml/badge.svg)](https://github.com/shmeatley/muster/actions/workflows/ci.yml)
[![Wally](https://img.shields.io/badge/wally-shmeatley%2Fmuster-blue)](https://wally.run/package/shmeatley/muster)
[![Docs](https://img.shields.io/badge/docs-moonwave-blue)](https://shmeatley.github.io/muster)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Cross-server matchmaking for Roblox, in fully-typed Luau.

Players and parties go into a queue. Muster does the distributed part — sharded
queue lanes, worker election, skill-windowed grouping, and delivery of the
finished match to every server holding one of its players.

**It stops at the match envelope.** Muster does not teleport, does not reserve
servers, and does not compute or store ratings, because every game wants those
done differently. It hands you a validated roster with your own data attached,
and gets out of the way.

## Installation

```toml
[dependencies]
Muster = "shmeatley/muster@0.1.0"
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

## Reserved servers, teams, maps — the `finalize` hook

Muster never teleports, but it makes teleporting easy. `finalize` runs **once
per match**, on whichever server formed it, and whatever it returns is attached
to the envelope as `match.data` and delivered to everyone.

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
- Its side effects may **survive a match that never forms** — the lease can be
  lost while it yields. Write it to be idempotent or cheap to abandon, and use
  `onAbort` to release anything expensive. (A leaked reserved-server access code
  costs nothing and expires on its own, which is why this is usually fine.)
- If it throws, exceeds `finalizeTimeout`, or returns something unstorable, the
  match aborts cleanly and every player goes back in the queue.

## Queueing a group

If you already have parties — or your parties form in one lobby and live in a
table on that server — just hand Muster the userIds:

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

You need it only if parties have to survive players being on *different*
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
at once even when two servers try at the same moment — which is the whole
difficulty, since those servers cannot see each other.

## Ratings

Muster does skill-based *matching*, not skill *rating*. Bring your own number
from wherever you keep it — Elo, Glicko, OpenSkill, or a stat you made up.

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
a good player cannot hide behind low-rated friends.

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

`matched` fires on **every server holding one of the matched players** — not
just the one that formed the match. If none of them are here, it does not fire
here, so your handler always has someone to act on.

A match is written to MemoryStore *before* it is announced, so delivery never
depends on MessagingService:

| Situation | Time to delivery |
| --- | --- |
| Normal | under ~200 ms |
| A message is dropped | up to 30 s |
| MessagingService is down entirely | ~5 s, automatically |

The last row is the point: Muster notices when the doorbell stops working and
tightens its polling until it recovers. A match is never lost — the ledger holds
it for five minutes regardless.

Polling backs off per **ticket** (2s, 4s, 8s, 16s, then capped), not per player,
so a full minute of waiting costs a handful of reads. A server with nothing
queued costs nothing at all.

## Lanes scale themselves

A queue is split into lanes, and a ticket is matched against the others in its
own lane. **Lanes buy parallelism by splitting the pool**, so the right number
depends on how deep the queue actually is — and you don't have to guess.

By default (`lanes = "auto"`) a queue starts on **one** lane, so two players
match on the first scan, and it doubles only once a single lane is consistently
too full for one worker to see all of. When the queue thins out again, it halves
back down. No sizing table, no tuning.

Pin it if you'd rather: `lanes = 4` (any integer, 1–64) disables scaling
entirely and writes no lane record.

<details>
<summary>How resizing avoids losing tickets</summary>

Changing a lane count naively is a good way to strand players: a ticket written
under 2 lanes lives in `hash % 2`, and a server that has moved to 4 lanes looks
in `hash % 4` and never finds it. It doesn't error — the player just waits until
their ticket expires.

Muster stamps the count into every key:

```
mu1:ranked:idx:EMEA:n04:02
                    ^^^ ^^
                  count lane
```

So servers that disagree read and write *different* key spaces rather than
corrupting one, and every ticket stays exactly where its writer put it. During a
resize, workers on the new count also read the old maps the new lane could draw
from — one extra map when growing, two when halving — so the old and new pools
still match against each other. Changes are spaced a full `ticketExpiration`
apart, which guarantees an abandoned count has drained before it can be reused.

</details>

## Partitions

`partitionKey` splits a queue into pools that never mix — regions, skill
brackets, mode variants, platforms:

```lua
partitionKey = function(request)
	return request.metadata.region
end
```

Muster deliberately ships no region system of its own. A partition never merges
with another, so partitioning a thin queue is how matchmaking stops working; the
decision of when it is safe belongs to you.

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
2. **Acquire** takes a *lease* on the lane, carrying a monotonically increasing
   **fencing epoch**.
3. **Scan** reads the oldest candidates and runs the grouping algorithm.
4. **Commit** is two-phase: claim every ticket in sorted order, re-check the
   lease, run `finalize`, re-check the lease *again* because it yielded, then
   flip the record to `Ready` with a compare-and-set guarded on the epoch. A
   server that stalled and lost its lease cannot commit, because the store itself
   rejects the write.
5. **Deliver** publishes to the servers holding the players.

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
stylua --check src test
```

## License

MIT
