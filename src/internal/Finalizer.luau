--!strict

--[=[
	@class Finalizer

	Runs the consumer's `finalize` hook under a deadline.

	The hook is expected to yield — reserving a server is a web call — so it runs
	on its own thread while the caller waits for either completion or the
	deadline. Both the thread spawner and the clock are injected, which lets the
	suite drive the timeout path without any real time passing.

	:::caution What a timeout can and cannot do
	Luau cannot cancel a thread blocked in a Roblox web call. A `finalize` that
	times out mid-`ReserveServerAsync` still completes later and still allocates
	a server; Muster simply stops waiting for it and aborts the match. That is
	why `onAbort` exists, and why the hook contract asks for side effects that
	are idempotent or cheap to abandon.
	:::
]=]

local Finalizer = {}

export type Outcome = {
	ok: boolean,
	value: any?,
	reason: string?,
	message: string?,
}

--[=[
	Invokes `callback(context)`, waiting at most `timeout` seconds.

	@return Outcome -- `ok` with the return value, or a `FinalizerError` / `FinalizerTimeout` reason.
	@within Finalizer
]=]
function Finalizer.run(callback: (any) -> any, context: any, timeout: number, services: any): Outcome
	local monotonic = services.monotonic
	local sleep = services.sleep
	local spawn = services.spawn

	local finished = false
	local succeeded = false
	local result: any = nil

	spawn(function()
		succeeded, result = pcall(callback, context)
		finished = true
	end)

	-- A synchronous spawn (as the tests use) will already have finished here,
	-- and this loop is skipped entirely.
	local deadline = monotonic() + timeout
	while not finished and monotonic() < deadline do
		sleep(0.05)
	end

	if not finished then
		return { ok = false, reason = "FinalizerTimeout" }
	end
	if not succeeded then
		return { ok = false, reason = "FinalizerError", message = tostring(result) }
	end
	return { ok = true, value = result }
end

return table.freeze(Finalizer)
