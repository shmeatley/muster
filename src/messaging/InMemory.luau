--!strict

--[=[
	@class InMemoryMessaging

	An in-process [Messaging] bus reproducing the real one's failure modes:
	messages can be dropped, delayed, or delivered twice.

	Several [Matchmaker] instances sharing one bus stand in for several servers,
	which is how the suite exercises cross-server delivery with no Roblox API
	calls.

	```lua
	local bus = Muster.messaging.InMemory.new()

	local a = Muster.new({ name = "q", size = 2, store = store, messaging = bus, serverId = "A" })
	local b = Muster.new({ name = "q", size = 2, store = store, messaging = bus, serverId = "B" })

	bus:dropNext(1)   -- B never hears the doorbell, and must find the match by polling
	```
]=]

type Handler = (any) -> ()

type BusProps = {
	_handlers: { [string]: { Handler } },
	_drop: number,
	_duplicate: number,
	_held: { { topic: string, payload: any } },
	_holding: boolean,
	published: { { topic: string, payload: any } },
}

local InMemoryMessaging = {}
InMemoryMessaging.__index = InMemoryMessaging

export type InMemoryMessaging = typeof(setmetatable({} :: BusProps, InMemoryMessaging))

--[=[
	@within InMemoryMessaging
]=]
function InMemoryMessaging.new(): InMemoryMessaging
	return setmetatable({
		_handlers = {},
		_drop = 0,
		_duplicate = 0,
		_held = {},
		_holding = false,
		published = {},
	}, InMemoryMessaging)
end

--[=[
	Silently discards the next `count` published messages.

	@within InMemoryMessaging
]=]
function InMemoryMessaging.dropNext(self: InMemoryMessaging, count: number?)
	self._drop += (count or 1)
end

--[=[
	Delivers the next `count` published messages twice, so handlers must be
	idempotent.

	@within InMemoryMessaging
]=]
function InMemoryMessaging.duplicateNext(self: InMemoryMessaging, count: number?)
	self._duplicate += (count or 1)
end

--[=[
	Holds every subsequent message until [InMemoryMessaging:release], modelling
	delivery arriving after the receiver has already begun polling.

	@within InMemoryMessaging
]=]
function InMemoryMessaging.hold(self: InMemoryMessaging)
	self._holding = true
end

--[=[
	Delivers everything held since [InMemoryMessaging:hold].

	@within InMemoryMessaging
]=]
function InMemoryMessaging.release(self: InMemoryMessaging)
	self._holding = false
	local held = self._held
	self._held = {}
	for _, message in held do
		self:_deliver(message.topic, message.payload)
	end
end

function InMemoryMessaging._deliver(self: InMemoryMessaging, topic: string, payload: any)
	local handlers = self._handlers[topic]
	if handlers == nil then
		return
	end
	for _, handler in table.clone(handlers) do
		handler(payload)
	end
end

function InMemoryMessaging.publish(self: InMemoryMessaging, topic: string, payload: any): (boolean, any)
	table.insert(self.published, { topic = topic, payload = payload })

	if self._drop > 0 then
		self._drop -= 1
		return true, nil
	end

	local times = 1
	if self._duplicate > 0 then
		self._duplicate -= 1
		times = 2
	end

	for _ = 1, times do
		if self._holding then
			table.insert(self._held, { topic = topic, payload = payload })
		else
			self:_deliver(topic, payload)
		end
	end
	return true, nil
end

function InMemoryMessaging.subscribe(self: InMemoryMessaging, topic: string, handler: Handler): any
	local handlers = self._handlers[topic]
	if handlers == nil then
		handlers = {}
		self._handlers[topic] = handlers
	end
	table.insert(handlers, handler)

	return {
		disconnect = function()
			local index = table.find(handlers, handler)
			if index then
				table.remove(handlers, index)
			end
		end,
	}
end

--[=[
	Messages published to `topic`, including dropped ones.

	@within InMemoryMessaging
]=]
function InMemoryMessaging.countFor(self: InMemoryMessaging, topic: string): number
	local count = 0
	for _, message in self.published do
		if message.topic == topic then
			count += 1
		end
	end
	return count
end

return InMemoryMessaging
