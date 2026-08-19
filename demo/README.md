# The demo place

A lobby with two pads and a status board, running one real queue against real
MemoryStore and real MessagingService. It is here so you can see Muster work
before deciding whether to install it, and so there is a small worked example of
wiring it up.

It is live at
**[Muster Demo](https://www.roblox.com/games/100811184569764/Muster-Demo)**.

`MusterDemo.rbxl` is committed at the root of the repository, so you can also
open it in Studio and press Play without installing anything. To rebuild it
after changing the source:

```sh
rojo build demo.project.json -o MusterDemo.rbxl
```

## What to do in it

- Click the blue pad to join the queue, or to leave it if you are already in.
- Click the grey pad to add a bot, so one person can fill a match.

Matches are four players, or two once someone has waited eight seconds. Click
blue, click grey once, wait: you are in a match. Click grey three times instead
and it forms immediately.

The board shows what this server has queued, which lanes it is working, and
whether message delivery looks healthy. The Output window carries the same story
in more detail, including Muster's own worker log: taking a lane, forming
matches, handing the lane back when the queue goes quiet.

In Studio this needs **Enable Studio Access to API Services** (Game Settings,
Security). Without it every store call fails, and the board says so, which is
exactly what a MemoryStore outage looks like in production.

Nothing teleports. The two places a real game would (`finalize` to reserve a
server, `matched` to send everyone there) are marked in the source.

## Files

```
MusterDemo.rbxl            the built place, committed so it can be opened directly
demo.project.json          builds it
demo/server/
  init.server.luau         the entry point
  Sandbox/
    init.luau              the queue, its signals, and the pads that drive it
    Arena.luau             the parts and the GUI, which are not the interesting part
```

`Sandbox/init.luau` is the file to read: one `Muster.new` call, a handful of
signal handlers, and two click handlers. That is about what a real game needs.
Everything else is scaffolding so the queue has something to be driven by.
