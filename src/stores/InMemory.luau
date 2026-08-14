--!strict

--[=[
	@class InMemoryStore

	A complete [Store] in a table, with a synthetic clock, working TTL expiry,
	call counting, and fault injection. Muster's own suite runs entirely against
	it, and it ships publicly so your tests can too — no MemoryStore, no Studio,
	no waiting.

	```lua
	local now = 0
	local store = Muster.stores.InMemory.new(function() return now end)

	local queue = Muster.new({
		name = "test", size = 2,
		store = store, clock = function() return now end,
		autoStart = false, broadcast = false,
	})

	queue:enqueue(1)
	queue:enqueue(2)
	queue:step()          -- matched, deterministically, with no yielding

	now += 200            -- everything expires exactly like it would live
	```

	Two hooks exist purely for tests: [InMemoryStore:failNext] makes the next
	calls fail, and [InMemoryStore:conflictNext] makes an update lose a
	compare-and-set race.
]=]

local Types = require(script.Parent.Parent.Types)

type SortedItem = Types.SortedItem

export type Clock = () -> number

type Entry = { value: any, expiresAt: number }
type SortedEntry = { value: any, expiresAt: number, sortKey: number }
type Conflict = { count: number, mutator: ((any) -> any)? }

type StoreProps = {
	_clock: Clock,
	_hashes: { [string]: { [string]: Entry } },
	_sorted: { [string]: { [string]: SortedEntry } },
	_conflicts: { [string]: Conflict },
	calls: { [string]: number },
	failures: { [string]: number },
}

local InMemoryStore = {}
InMemoryStore.__index = InMemoryStore

export type InMemoryStore = typeof(setmetatable({} :: StoreProps, InMemoryStore))

--[=[
	@param clock -- Defaults to `os.time`. Pass a closure over a local for full control.
	@within InMemoryStore
]=]
function InMemoryStore.new(clock: Clock?): InMemoryStore
	return setmetatable({
		_clock = clock or os.time,
		_hashes = {},
		_sorted = {},
		_conflicts = {},
		calls = {},
		failures = {},
	}, InMemoryStore)
end

--[=[
	Makes the next `count` calls to `operation` fail, as a store outage would.
	Operation names are the method names: `get`, `set`, `update`, `remove`,
	`sortedSet`, `sortedRemove`, `sortedRange`.

	@within InMemoryStore
]=]
function InMemoryStore.failNext(self: InMemoryStore, operation: string, count: number?)
	self.failures[operation] = (self.failures[operation] or 0) + (count or 1)
end

--[=[
	Makes the next `count` updates lose a compare-and-set race: the transform
	runs once against the value it read, that result is thrown away, `mutator`
	installs a competing write, and the transform runs again against the new
	value — which is what MemoryStore's `UpdateAsync` does under contention.

	This is the only way to catch a transform that forgets to reset its own
	bookkeeping on re-entry, which every conditional write in Muster depends on.

	@param mutator -- Receives the current value, returns the competing writer's value. Omit to re-run against unchanged state.
	@within InMemoryStore
]=]
function InMemoryStore.conflictNext(self: InMemoryStore, operation: string, count: number?, mutator: ((any) -> any)?)
	local existing = self._conflicts[operation]
	self._conflicts[operation] = {
		count = (if existing then existing.count else 0) + (count or 1),
		mutator = mutator or (if existing then existing.mutator else nil),
	}
end

function InMemoryStore._record(self: InMemoryStore, operation: string): boolean
	self.calls[operation] = (self.calls[operation] or 0) + 1
	local remaining = self.failures[operation] or 0
	if remaining > 0 then
		self.failures[operation] = remaining - 1
		return false
	end
	return true
end

function InMemoryStore._takeConflict(self: InMemoryStore, operation: string): Conflict?
	local conflict = self._conflicts[operation]
	if conflict == nil or conflict.count <= 0 then
		return nil
	end
	conflict.count -= 1
	return conflict
end

function InMemoryStore._hash(self: InMemoryStore, name: string): { [string]: Entry }
	local map = self._hashes[name]
	if map == nil then
		map = {}
		self._hashes[name] = map
	end
	return map
end

function InMemoryStore._sortedMap(self: InMemoryStore, name: string): { [string]: SortedEntry }
	local map = self._sorted[name]
	if map == nil then
		map = {}
		self._sorted[name] = map
	end
	return map
end

function InMemoryStore._live(self: InMemoryStore, map: { [string]: Entry }, key: string): any
	local entry = map[key]
	if entry == nil then
		return nil
	end
	if entry.expiresAt <= self._clock() then
		map[key] = nil
		return nil
	end
	return entry.value
end

function InMemoryStore.get(self: InMemoryStore, name: string, key: string, _priority: number?): (boolean, any)
	if not self:_record("get") then
		return false, "injected failure"
	end
	return true, self:_live(self:_hash(name), key)
end

function InMemoryStore.set(
	self: InMemoryStore,
	name: string,
	key: string,
	value: any,
	expiration: number,
	_priority: number?
): (boolean, any)
	if not self:_record("set") then
		return false, "injected failure"
	end
	self:_hash(name)[key] = { value = value, expiresAt = self._clock() + expiration }
	return true, value
end

function InMemoryStore.update(
	self: InMemoryStore,
	name: string,
	key: string,
	expiration: number,
	transform: (any) -> any,
	_priority: number?
): (boolean, any)
	if not self:_record("update") then
		return false, "injected failure"
	end
	local map = self:_hash(name)
	local current = self:_live(map, key)

	local conflict = self:_takeConflict("update")
	if conflict then
		-- The losing attempt. Its result is discarded, exactly as MemoryStore
		-- discards a transform whose compare-and-set failed.
		transform(current)
		if conflict.mutator then
			local competing = conflict.mutator(current)
			if competing ~= nil then
				map[key] = { value = competing, expiresAt = self._clock() + expiration }
			else
				map[key] = nil
			end
			current = self:_live(map, key)
		end
	end

	local nextValue = transform(current)
	if nextValue ~= nil then
		map[key] = { value = nextValue, expiresAt = self._clock() + expiration }
	end
	return true, if nextValue ~= nil then nextValue else current
end

function InMemoryStore.remove(self: InMemoryStore, name: string, key: string, _priority: number?): (boolean, any)
	if not self:_record("remove") then
		return false, "injected failure"
	end
	self:_hash(name)[key] = nil
	return true, nil
end

function InMemoryStore.sortedSet(
	self: InMemoryStore,
	name: string,
	key: string,
	value: any,
	expiration: number,
	sortKey: number,
	_priority: number?
): (boolean, any)
	if not self:_record("sortedSet") then
		return false, "injected failure"
	end
	self:_sortedMap(name)[key] = {
		value = value,
		expiresAt = self._clock() + expiration,
		sortKey = sortKey,
	}
	return true, value
end

function InMemoryStore.sortedRemove(self: InMemoryStore, name: string, key: string, _priority: number?): (boolean, any)
	if not self:_record("sortedRemove") then
		return false, "injected failure"
	end
	self:_sortedMap(name)[key] = nil
	return true, nil
end

function InMemoryStore.sortedRange(
	self: InMemoryStore,
	name: string,
	count: number,
	_priority: number?
): (boolean, { SortedItem } | string)
	if not self:_record("sortedRange") then
		return false, "injected failure"
	end
	local now = self._clock()
	local map = self:_sortedMap(name)
	local items = {}
	for key, entry in map do
		if entry.expiresAt <= now then
			map[key] = nil
		else
			table.insert(items, { key = key, value = entry.value, sortKey = entry.sortKey })
		end
	end
	table.sort(items, function(left, right)
		if left.sortKey == right.sortKey then
			return left.key < right.key
		end
		return left.sortKey < right.sortKey
	end)
	while #items > count do
		table.remove(items)
	end
	return true, items
end

--[=[
	Total calls made, by operation. Muster's suite asserts against this to keep
	the request budget from regressing.

	@within InMemoryStore
]=]
function InMemoryStore.callCount(self: InMemoryStore, operation: string?): number
	if operation then
		return self.calls[operation] or 0
	end
	local total = 0
	for _, count in self.calls do
		total += count
	end
	return total
end

return InMemoryStore
