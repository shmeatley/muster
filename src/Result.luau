--!strict

--[=[
	@class Result

	The return type of every method that touches the network.

	Muster splits failures by cause. Invalid configuration and invalid arguments
	throw at level 2, so the traceback points at the call site. Anything that
	depends on MemoryStore being reachable returns a `Result` instead, since
	those failures occur in normal operation and callers must branch on them.

	```lua
	local result = queue:enqueue(player.UserId, { rating = 1200 })
	if not result.ok then
		if result.error.code == "AlreadyQueued" then
			return "You're already in a queue."
		end
		return if result.error.retryable then "Try again in a moment." else "Couldn't queue."
	end
	print("queued as", result.value.id)
	```

	`result.error` carries an [ErrorCode], a message, and `retryable`. It also
	defines `__tostring` as `"<code>: <message>"`.
]=]

local Types = require(script.Parent.Types)

type ServiceError = Types.ServiceError
type ErrorCode = Types.ErrorCode
type Result<T> = Types.Result<T>

local Result = {}

local errorMetatable = {
	__tostring = function(self: ServiceError): string
		return `{self.code}: {self.message}`
	end,
}

--[=[
	Wraps a value as a success.

	@within Result
]=]
function Result.ok<T>(value: T): Result<T>
	return { ok = true, value = value }
end

--[=[
	Builds a failure.

	`retryable` marks errors where the same call may succeed on a later attempt,
	such as a store outage, as opposed to ones that will not, such as
	`AlreadyQueued`.

	@within Result
]=]
function Result.err<T>(code: ErrorCode, message: string, retryable: boolean?): Result<T>
	return {
		ok = false,
		error = setmetatable({
			code = code,
			message = message,
			retryable = retryable or false,
		}, errorMetatable) :: any,
	}
end

--[=[
	@within Result
]=]
function Result.isOk<T>(result: Result<T>): boolean
	return result.ok
end

--[=[
	Returns the value, or throws with the error's code and message.

	For call sites where a failure is unrecoverable, such as startup code or a
	test.

	@error "<code>: <message>" -- The wrapped ServiceError.
	@within Result
]=]
function Result.unwrap<T>(result: Result<T>): T
	if result.ok then
		return result.value
	end
	error(`{result.error.code}: {result.error.message}`, 2)
end

--[=[
	Returns the value, or `fallback` if the result is a failure.

	@within Result
]=]
function Result.unwrapOr<T>(result: Result<T>, fallback: T): T
	return if result.ok then result.value else fallback
end

return table.freeze(Result)
