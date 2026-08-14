--!nocheck

--[[
	Assertions and fixtures shared by every test file.

	`world` is the important one: it builds a set of Muster instances that share
	one store and one message bus, which is what "several servers" means here.
	Time is a plain local that tests advance by hand, so every wait, TTL, lease
	expiry and poll interval is exact and nothing sleeps.
]]

local Loader = require("./load")

local Harness = {}

local passed = 0
local failed = 0
local failures: { string } = {}
local currentSuite = "?"

function Harness.suite(name: string)
	currentSuite = name
end

function Harness.check(name: string, condition: boolean, detail: string?)
	if condition then
		passed += 1
	else
		failed += 1
		table.insert(failures, `{currentSuite} :: {name}{if detail then ` - {detail}` else ""}`)
	end
end

function Harness.equal(name: string, actual: any, expected: any)
	Harness.check(name, actual == expected, `expected {tostring(expected)}, got {tostring(actual)}`)
end

function Harness.near(name: string, actual: number, expected: number, tolerance: number?)
	local slack = tolerance or 1e-6
	Harness.check(name, math.abs(actual - expected) <= slack, `expected {expected} +/- {slack}, got {tostring(actual)}`)
end

function Harness.throws(name: string, callback: () -> (), expectedSubstring: string?)
	local ok, err = pcall(callback)
	if ok then
		Harness.check(name, false, "expected an error, none was raised")
		return
	end
	if expectedSubstring ~= nil and string.find(tostring(err), expectedSubstring, 1, true) == nil then
		Harness.check(name, false, `error did not mention "{expectedSubstring}": {tostring(err)}`)
		return
	end
	Harness.check(name, true)
end

function Harness.results()
	return passed, failed, failures
end

--[[
	Loads the package once per process.
]]
local muster: any = nil
function Harness.muster(): any
	if muster == nil then
		muster = Loader.new(".").muster()
	end
	return muster
end

--[[
	A shared clock, store and bus, plus a factory for servers on them.

	Every instance built by `world.server` is configured for determinism:
	no autostart, no real sleeping, a synchronous spawn so `finalize` resolves
	inline, and a fixed random so jitter is reproducible.
]]
function Harness.world(options: any?)
	local settings = options or {}
	local Muster = Harness.muster()

	local now = settings.startAt or 1000
	local clock = function()
		return now
	end

	local store = Muster.stores.InMemory.new(clock)
	local bus = Muster.messaging.InMemory.new()

	local world
	world = {
		store = store,
		bus = bus,
		clock = clock,
		servers = {},

		now = function(): number
			return now
		end,

		advance = function(seconds: number)
			now += seconds
		end,

		server = function(serverId: string, config: any?): any
			local base = {
				name = settings.name or "test",
				size = settings.size or 2,
				store = store,
				messaging = bus,
				serverId = serverId,
				clock = clock,
				monotonic = clock,
				random = function()
					return 0.5
				end,
				sleep = function() end,
				spawn = function(callback)
					callback()
				end,
				id = world.nextId,
				autoStart = false,
				autoCancelOnLeave = false,
			}
			for key, value in settings.config or {} do
				base[key] = value
			end
			for key, value in config or {} do
				base[key] = value
			end

			local instance = Muster.new(base)
			-- `start` also subscribes the doorbell. The worker loop itself never
			-- runs, because `spawn` is synchronous and `sleep` returns instantly:
			-- the loop body would spin forever, so tests drive `step` by hand.
			instance._engine._broadcaster:start()
			table.insert(world.servers, instance)
			return instance
		end,

		--[[
			Runs `step` on every server, in order, `passes` times.

			`secondsPerPass` advances the clock between passes, which is needed
			whenever a pass has to wait out a scan delay or a poll interval.
		]]
		tick = function(passes: number?, secondsPerPass: number?)
			for pass = 1, passes or 1 do
				if secondsPerPass and pass > 1 then
					now += secondsPerPass
				end
				for _, instance in world.servers do
					instance:step()
				end
			end
		end,

		--[[ Collects every match delivered to any server. ]]
		collect = function(): { any }
			local seen = {}
			for _, instance in world.servers do
				instance.matched:connect(function(match)
					table.insert(seen, match)
				end)
			end
			return seen
		end,
	}

	local counter = 0
	world.nextId = function(): string
		counter += 1
		-- Padded so ids sort lexicographically in creation order, which keeps
		-- lane assignment and tie-breaks reproducible across runs.
		return string.format("id-%06d", counter)
	end

	return world
end

return Harness
