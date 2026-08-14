--!strict

--[=[
	@class RequestExecutor

	Wraps every store and messaging call in a retry policy, tracks per-structure
	health, and trips a circuit breaker on structures that keep failing.

	Requests carry a priority. Lower is more important:

	| Priority | Used by | Attempts | Circuit-broken? |
	| --- | --- | --- | --- |
	| 1 | The commit path: claims and the Ready CAS | 5 | Never |
	| 2 | Leases | 5 | Never |
	| 3 | Ticket writes, party mutations | 5 | Never |
	| 4-6 | Lane index writes, range scans, reads | 3 | Yes |

	The split matters because shedding a lane scan under load self-corrects on
	the next pass, while abandoning a half-committed match leaves tickets stuck
	until their claims expire.

	Retries use exponential backoff from 0.25 s, doubling to a 4 s ceiling, with
	20% jitter. Throttling is detected by matching the error text, which is the
	only signal Roblox exposes.
]=]

local Types = require(script.Parent.Parent.Types)

type Logger = Types.Logger
type Metrics = Types.Metrics

local BACKOFF_START = 0.25
local BACKOFF_CEILING = 4
local CIRCUIT_FAILURES = 3
local CIRCUIT_DURATION = 5
local CRITICAL_PRIORITY = 3
local THROTTLE_RATIO = 0.01

type Health = {
	successes: number,
	failures: number,
	throttles: number,
	averageLatency: number,
	openUntil: number,
}

type ExecutorProps = {
	_clock: () -> number,
	_sleep: (number) -> (),
	_random: () -> number,
	_logger: Logger?,
	_metrics: Metrics?,
	health: { [string]: Health },
}

local RequestExecutor = {}
RequestExecutor.__index = RequestExecutor

export type RequestExecutor = typeof(setmetatable({} :: ExecutorProps, RequestExecutor))

--[=[
	@within RequestExecutor
]=]
function RequestExecutor.new(options: any?): RequestExecutor
	local settings = options or {}
	return setmetatable({
		_clock = settings.monotonic or settings.clock or os.clock,
		_sleep = settings.sleep,
		_random = settings.random or math.random,
		_logger = settings.logger,
		_metrics = settings.metrics,
		health = {},
	}, RequestExecutor)
end

local function isThrottle(message: string): boolean
	local lowered = string.lower(message)
	return string.find(lowered, "thrott", 1, true) ~= nil
		or string.find(lowered, "overlimit", 1, true) ~= nil
		or string.find(lowered, "request limit", 1, true) ~= nil
end

function RequestExecutor.healthFor(self: RequestExecutor, structure: string): Health
	local health = self.health[structure]
	if health == nil then
		health = { successes = 0, failures = 0, throttles = 0, averageLatency = 0, openUntil = 0 }
		self.health[structure] = health
	end
	return health
end

--[=[
	Runs `callback`, retrying with jittered exponential backoff.

	@return boolean -- Whether the call eventually succeeded.
	@return any -- The result, or the final error message. Never throws.

	@within RequestExecutor
]=]
function RequestExecutor.execute(
	self: RequestExecutor,
	priority: number,
	structure: string,
	callback: () -> any
): (boolean, any)
	local health = self:healthFor(structure)
	if priority > CRITICAL_PRIORITY and health.openUntil > self._clock() then
		return false, "circuit open"
	end

	local attempts = if priority <= CRITICAL_PRIORITY then 5 else 3
	local delay = BACKOFF_START
	for attempt = 1, attempts do
		local startedAt = self._clock()
		local success, result = pcall(callback)
		local latency = self._clock() - startedAt
		if success then
			health.successes += 1
			health.averageLatency += (latency - health.averageLatency) / health.successes
			if self._metrics then
				self._metrics("muster.request.success", 1, { structure = structure, priority = priority })
			end
			return true, result
		end

		local message = tostring(result)
		health.failures += 1
		if isThrottle(message) then
			health.throttles += 1
		end
		if self._metrics then
			self._metrics("muster.request.failure", 1, { structure = structure, priority = priority })
		end

		if attempt < attempts then
			if self._sleep then
				local jitter = 0.8 + self._random() * 0.4
				self._sleep(delay * jitter)
			end
			delay = math.min(delay * 2, BACKOFF_CEILING)
		else
			if priority > CRITICAL_PRIORITY and health.failures >= CIRCUIT_FAILURES then
				health.openUntil = self._clock() + CIRCUIT_DURATION
			end
			if self._logger then
				self._logger("warn", "request failed", {
					structure = structure,
					priority = priority,
					error = message,
				})
			end
			return false, message
		end
	end
	return false, "request failed"
end

--[=[
	True once at least 1% of observed requests have come back throttled.

	The engine responds by declining to lease new lanes and doubling its scan
	delay, shedding parallelism before slowing the commit path.

	@within RequestExecutor
]=]
function RequestExecutor.isThrottled(self: RequestExecutor): boolean
	local successes = 0
	local throttles = 0
	for _, health in self.health do
		successes += health.successes
		throttles += health.throttles
	end
	return throttles > 0 and throttles / math.max(1, successes + throttles) >= THROTTLE_RATIO
end

--[=[
	A copy of per-structure health: successes, failures, throttles, mean latency,
	and the circuit-breaker deadline.

	@within RequestExecutor
]=]
function RequestExecutor.snapshot(self: RequestExecutor): { [string]: Health }
	local out = {}
	for structure, health in self.health do
		out[structure] = table.clone(health)
	end
	return out
end

return RequestExecutor
