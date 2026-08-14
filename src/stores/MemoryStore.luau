--!strict

--[=[
	@class MemoryStore

	The production [Store]: Roblox MemoryStore hash maps and sorted maps behind
	a [RequestExecutor].

	Muster builds one of these for you. Construct it yourself only when you want
	several queues to share one executor, so their health tracking and circuit
	breakers are pooled:

	```lua
	local executor = Muster.internal.RequestExecutor.new({ logger = log })
	local store = Muster.stores.MemoryStore.new(executor)

	local ranked = Muster.new({ name = "ranked", size = 8, store = store })
	local casual = Muster.new({ name = "casual", size = 8, store = store })
	```
]=]

local Runtime = require(script.Parent.Parent.internal.Runtime)

local MemoryStoreService: any = Runtime.service("MemoryStoreService")

type StoreProps = {
	_executor: any,
}

local MemoryStore = {}
MemoryStore.__index = MemoryStore

export type MemoryStore = typeof(setmetatable({} :: StoreProps, MemoryStore))

--[=[
	@param executor RequestExecutor -- Supplies the retry, backoff and circuit-breaker policy.
	@within MemoryStore
	@error "MemoryStore is unavailable" -- Raised outside Roblox; inject a store instead.
]=]
function MemoryStore.new(executor: any): MemoryStore
	if MemoryStoreService == nil then
		error("Muster: MemoryStoreService is unavailable here; pass a `store` in the config instead", 2)
	end
	return setmetatable({ _executor = executor }, MemoryStore)
end

function MemoryStore.get(self: MemoryStore, name: string, key: string, priority: number?): (boolean, any)
	local map = MemoryStoreService:GetHashMap(name)
	return self._executor:execute(priority or 6, name, function()
		return map:GetAsync(key)
	end)
end

function MemoryStore.set(
	self: MemoryStore,
	name: string,
	key: string,
	value: any,
	expiration: number,
	priority: number?
): (boolean, any)
	local map = MemoryStoreService:GetHashMap(name)
	return self._executor:execute(priority or 3, name, function()
		return map:SetAsync(key, value, expiration)
	end)
end

function MemoryStore.update(
	self: MemoryStore,
	name: string,
	key: string,
	expiration: number,
	transform: (any) -> any,
	priority: number?
): (boolean, any)
	local map = MemoryStoreService:GetHashMap(name)
	return self._executor:execute(priority or 3, name, function()
		return map:UpdateAsync(key, transform, expiration)
	end)
end

function MemoryStore.remove(self: MemoryStore, name: string, key: string, priority: number?): (boolean, any)
	local map = MemoryStoreService:GetHashMap(name)
	return self._executor:execute(priority or 3, name, function()
		return map:RemoveAsync(key)
	end)
end

function MemoryStore.sortedSet(
	self: MemoryStore,
	name: string,
	key: string,
	value: any,
	expiration: number,
	sortKey: number,
	priority: number?
): (boolean, any)
	local map = MemoryStoreService:GetSortedMap(name)
	return self._executor:execute(priority or 4, name, function()
		return map:SetAsync(key, value, expiration, sortKey)
	end)
end

function MemoryStore.sortedRemove(self: MemoryStore, name: string, key: string, priority: number?): (boolean, any)
	local map = MemoryStoreService:GetSortedMap(name)
	return self._executor:execute(priority or 5, name, function()
		return map:RemoveAsync(key)
	end)
end

--[=[
	Reads the oldest `count` entries. Sort keys are queue timestamps, so
	ascending order is first-come-first-served.

	:::note
	MemoryStore caps a range read at 200 items. A lane holding more than that is
	only ever matched from its oldest 200 — correct, but it biases the rating
	window, and it is the point at which raising `lanes` starts to pay off.
	:::

	@within MemoryStore
]=]
function MemoryStore.sortedRange(self: MemoryStore, name: string, count: number, priority: number?): (boolean, any)
	local map = MemoryStoreService:GetSortedMap(name)
	return self._executor:execute(priority or 5, name, function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, count, nil, nil)
	end)
end

return MemoryStore
