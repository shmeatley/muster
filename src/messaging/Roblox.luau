--!strict

--[=[
	@class RobloxMessaging

	The production [Messaging] adapter: MessagingService behind a
	[RequestExecutor].

	Delivery is treated as best-effort. A committed match is written to
	MemoryStore before anything is published, so a dropped, delayed or duplicated
	message costs latency only.

	The platform limits that shape the per-server topic scheme:

	| Limit | Value |
	| --- | --- |
	| Payload size | 1 kB, including framing |
	| Subscriptions per server | 20 + 8 x players |
	| Messages sent per server | 600 + 240 x players / min |
	| Messages received per topic | 40 + 80 x servers / min |
	| Messages received per universe | 400 + 200 x servers / min |
]=]

local Runtime = require(script.Parent.Parent.internal.Runtime)

local MessagingService: any = Runtime.service("MessagingService")

type MessagingProps = {
	_executor: any,
}

local RobloxMessaging = {}
RobloxMessaging.__index = RobloxMessaging

export type RobloxMessaging = typeof(setmetatable({} :: MessagingProps, RobloxMessaging))

--[=[
	@within RobloxMessaging
	@error "MessagingService is unavailable" -- Raised outside Roblox; inject a bus, or set `broadcast = false`.
]=]
function RobloxMessaging.new(executor: any): RobloxMessaging
	if MessagingService == nil then
		error("Muster: MessagingService is unavailable here; pass a `messaging` adapter in the config instead", 2)
	end
	return setmetatable({ _executor = executor }, RobloxMessaging)
end

--[=[
	Publishes at priority 4, so sustained failure trips the circuit breaker
	rather than retrying indefinitely. The receiver's poll finds the match
	regardless.

	@within RobloxMessaging
]=]
function RobloxMessaging.publish(self: RobloxMessaging, topic: string, payload: any): (boolean, any)
	return self._executor:execute(4, "messaging", function()
		return MessagingService:PublishAsync(topic, payload)
	end)
end

--[=[
	@within RobloxMessaging
]=]
function RobloxMessaging.subscribe(self: RobloxMessaging, topic: string, handler: (any) -> ()): any
	local ok, connection = self._executor:execute(3, "messaging", function()
		return MessagingService:SubscribeAsync(topic, function(message)
			handler(message.Data)
		end)
	end)

	if not ok then
		return {
			disconnect = function() end,
		}
	end

	return {
		disconnect = function()
			pcall(function()
				connection:Disconnect()
			end)
		end,
	}
end

return RobloxMessaging
