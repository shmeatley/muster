--!strict

--[=[
	@class Finalizer

	Runs the `finalize` hook under a deadline.

	The hook is expected to yield, so it runs on its own thread while the caller
	waits for completion or the deadline, whichever comes first. The spawner and
	clock are injected, which lets tests drive the timeout path without real time
	passing.

	:::caution
	A timed-out hook is abandoned, not cancelled. Luau cannot interrupt a thread
	blocked in a web call, so a `finalize` that times out during
	`ReserveServerAsync` still completes later and still allocates a server —
	Muster has simply stopped waiting and aborted the match. Write hooks whose
	side effects are idempotent or cheap to abandon, and release expensive ones
	in `onAbort`.
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

	@param services -- `monotonic`, `sleep` and `spawn`.
	@return Outcome -- `ok` with the return value, or a reason of `FinalizerError` or `FinalizerTimeout`.
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
