--!strict

--[=[
	@class Signal

	A minimal event, used for [Matchmaker]'s `matched`, `aborted`, `queued` and
	`cancelled`. Muster ships its own so the package has no runtime dependencies.

	Handlers fire synchronously, in connection order, on the thread that raised
	the event. A handler that throws is reported and skipped; the remaining
	handlers still run. Disconnecting from inside a handler is safe, because each
	fire iterates a snapshot of the handler list.

	```lua
	local connection = queue.matched:connect(function(match)
		print(match.matchId)
	end)

	connection:disconnect()
	```
]=]

export type Connection = {
	connected: boolean,
	disconnect: (self: Connection) -> (),
}

type SignalProps<T> = {
	_handlers: { (T) -> () },
	_onError: ((string) -> ())?,
}

local Signal = {}
Signal.__index = Signal

export type Signal<T> = typeof(setmetatable({} :: SignalProps<T>, Signal))

--[=[
	Creates a signal.

	@param onError -- Called with the error text when a handler throws. Defaults to `warn`.
	@within Signal
]=]
function Signal.new<T>(onError: ((string) -> ())?): Signal<T>
	return setmetatable({
		_handlers = {},
		_onError = onError,
	}, Signal)
end

--[=[
	Registers a handler and returns a connection to remove it with.

	@error "Signal:connect expects a function" -- The handler was not callable.
	@within Signal
]=]
function Signal.connect<T>(self: Signal<T>, handler: (T) -> ()): Connection
	if type(handler) ~= "function" then
		error("Signal:connect expects a function", 2)
	end
	table.insert(self._handlers, handler)

	local connection: Connection
	connection = {
		connected = true,
		disconnect = function(_self: Connection)
			if not connection.connected then
				return
			end
			connection.connected = false
			local index = table.find(self._handlers, handler)
			if index then
				table.remove(self._handlers, index)
			end
		end,
	}
	return connection
end

--[=[
	Calls every connected handler with `value`.

	@within Signal
]=]
function Signal.fire<T>(self: Signal<T>, value: T)
	-- Snapshot, so a handler may disconnect itself (or others) mid-fire.
	for _, handler in table.clone(self._handlers) do
		-- Wrapped in a function with a declared return so `pcall` is typed as
		-- yielding the error value; handlers themselves return nothing.
		local ok, err = pcall(function(): any
			handler(value)
			return nil
		end)
		if not ok then
			if self._onError then
				self._onError(tostring(err))
			else
				warn(`[Muster] signal handler errored: {err}`)
			end
		end
	end
end

--[=[
	Removes every handler.

	@within Signal
]=]
function Signal.disconnectAll<T>(self: Signal<T>)
	table.clear(self._handlers)
end

return Signal
