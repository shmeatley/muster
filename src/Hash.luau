--!strict

--[=[
	@class Hash

	FNV-1a, 32 bit.

	Muster uses this to assign tickets to lanes and to fold over-long partition
	keys to a fixed length. Results are stable across servers and sessions, which
	is what lets two servers independently agree on a ticket's lane.

	```lua
	local lane = Muster.hash.partition(ticketId, 8) -- 0..7
	```

	:::caution
	Not a cryptographic hash. Do not use it for anything security sensitive.
	:::
]=]

local Hash = {}

local OFFSET = 2166136261
local PRIME_LOW = 0x0193
local PRIME_HIGH = 0x0100
local LIMB = 0x10000

-- The multiply is split into 16-bit limbs because Luau numbers cannot represent
-- hash * 16777619 exactly, and a direct multiply silently loses the low bits.
local function multiplyPrime(value: number): number
	local low = value % LIMB
	local high = math.floor(value / LIMB)
	local lowProduct = low * PRIME_LOW
	local resultLow = lowProduct % LIMB
	local carry = math.floor(lowProduct / LIMB)
	local resultHigh = (high * PRIME_LOW + low * PRIME_HIGH + carry) % LIMB
	return resultHigh * LIMB + resultLow
end

--[=[
	Hashes a string to a 32-bit unsigned integer.

	@within Hash
]=]
function Hash.string(value: string): number
	local hash = OFFSET
	for index = 1, #value do
		hash = bit32.bxor(hash, string.byte(value, index))
		hash = multiplyPrime(hash)
	end
	return hash
end

--[=[
	Maps a string into `[0, count)`.

	@error "Hash.partition count must be a positive integer" -- Invalid count.
	@within Hash
]=]
function Hash.partition(value: string, count: number): number
	if not (count > 0 and count % 1 == 0) then
		error("Hash.partition count must be a positive integer", 2)
	end
	return Hash.string(value) % count
end

return table.freeze(Hash)
