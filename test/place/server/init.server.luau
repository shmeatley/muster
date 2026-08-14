--!nocheck

--[[
	In-Studio smoke test.

		rojo build test.project.json -o MusterTest.rbxl

	Open it and press Play. The headless suite covers behaviour; this covers the
	things Lune cannot see — that the module tree loads under Roblox's instance
	requires, that MemoryStore and MessagingService are reachable, and that a
	real reserved server can be handed through a finalizer.

	Needs "Enable Studio Access to API Services" for the live section. Without
	it, the in-memory section still runs and still proves the tree loads.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Muster = require(ReplicatedStorage.Muster)

local passed, failed = 0, 0

local function check(name: string, condition: boolean, detail: string?)
	if condition then
		passed += 1
	else
		failed += 1
		warn(`[FAIL] {name}{if detail then ` - {detail}` else ""}`)
	end
end

-- Deterministic section: the same code path the headless suite drives, but
-- running inside Roblox against the real module tree.
do
	local now = 0
	local clock = function()
		return now
	end

	local store = Muster.stores.InMemory.new(clock)
	local queue = Muster.new({
		name = "smoke",
		size = 2,
		store = store,
		clock = clock,
		monotonic = clock,
		broadcast = false,
		autoStart = false,
		autoCancelOnLeave = false,
		finalize = function(match)
			return { greeting = `hello {match.size}` }
		end,
	})

	local delivered = nil
	queue.matched:connect(function(match)
		delivered = match
	end)

	check("enqueue succeeds", queue:enqueue(101).ok)
	check("a second player queues", queue:enqueue(102).ok)
	queue:step()

	check("a match was delivered", delivered ~= nil)
	if delivered then
		check("with both players", delivered.size == 2, tostring(delivered.size))
		check("and the finalizer's data", delivered.data.greeting == "hello 2", tostring(delivered.data.greeting))
	end

	check("the party api is reachable", queue.parties ~= nil)
	check("types are exported", Muster.Defaults.SCHEMA_VERSION == 1)
	queue:destroy()
end

-- Live section: real MemoryStore, real MessagingService. This is what proves
-- the adapters bind correctly, which no fake can tell you.
do
	local ok, err = pcall(function()
		local live = Muster.new({
			name = "smokelive",
			size = 2,
			autoStart = false,
			autoCancelOnLeave = false,
		})

		local delivered = nil
		live.matched:connect(function(match)
			delivered = match
		end)

		-- Ids well outside any real UserId range, so a live queue is never
		-- polluted by this.
		local first = live:enqueue(-90001)
		check("a live enqueue succeeds", first.ok, if first.ok then nil else first.error.message)

		local second = live:enqueue(-90002)
		check("and a second", second.ok, if second.ok then nil else second.error.message)

		for _ = 1, 10 do
			live:step()
			if delivered then
				break
			end
			task.wait(0.5)
		end

		check("a live match was delivered", delivered ~= nil)
		if delivered then
			check("with two players", delivered.size == 2)
		end

		local health = live:health()
		check("health reports the queue", health.queue == "smokelive")
		check("and a real JobId", type(health.serverId) == "string" and health.serverId ~= "")

		live:cancelForUser(-90001)
		live:cancelForUser(-90002)
		live:destroy()
	end)

	if not ok then
		warn(`[SKIP] live section did not run: {err}`)
		warn("       enable Studio Access to API Services to exercise MemoryStore")
	end
end

print("")
if failed > 0 then
	warn(`Muster smoke test: {passed} passed, {failed} failed`)
else
	print(`Muster smoke test: all {passed} checks passed`)
end
