--!strict

--[=[
	@class Runtime
	@private

	The only module in Muster that touches a Roblox global. Everything else
	receives what it needs through configuration, which is what lets the whole
	engine run headlessly under Lune against fakes.

	Each global is read through an `any`-typed local so the same source
	typechecks under Roblox (where `game` exists) and runs under Lune (where it
	resolves to `nil`).
]=]

local gameRef: any = game
local taskRef: any = task

local Runtime = {}

Runtime.isRoblox = typeof(gameRef) == "Instance"

--[=[
	@within Runtime
	@private
]=]
function Runtime.service(name: string): any?
	if not Runtime.isRoblox then
		return nil
	end
	local ok, result = pcall(function()
		return gameRef:GetService(name)
	end)
	return if ok then result else nil
end

--[=[
	@within Runtime
	@private
]=]
function Runtime.spawn(callback: () -> ())
	if taskRef ~= nil then
		taskRef.spawn(callback)
		return
	end
	local thread = coroutine.create(callback)
	local ok, err = coroutine.resume(thread)
	if not ok then
		warn(`[Muster] spawned thread errored: {err}`)
	end
end

--[=[
	@within Runtime
	@private
	@error "Muster needs a `sleep` function outside Roblox" -- Inject one through the config.
]=]
function Runtime.sleep(seconds: number)
	if taskRef == nil then
		error("Muster needs a `sleep` function outside Roblox; pass one in the config", 2)
	end
	taskRef.wait(seconds)
end

local HEX = "0123456789abcdef"

-- Pure-Luau UUIDv4, for when HttpService is unavailable (Lune, or a place with
-- the service disabled). Only ever used for ids that are compared, never for
-- anything that needs cryptographic unpredictability.
local function fallbackGuid(): string
	local out = table.create(36)
	for index = 1, 36 do
		if index == 9 or index == 14 or index == 19 or index == 24 then
			out[index] = "-"
		elseif index == 15 then
			out[index] = "4"
		else
			local nibble = math.random(1, 16)
			if index == 20 then
				nibble = math.random(9, 12)
			end
			out[index] = string.sub(HEX, nibble, nibble)
		end
	end
	return table.concat(out)
end

--[=[
	@within Runtime
	@private
]=]
function Runtime.guid(): string
	local http = Runtime.service("HttpService")
	if http ~= nil then
		local ok, result = pcall(function()
			return http:GenerateGUID(false)
		end)
		if ok then
			return result
		end
	end
	return fallbackGuid()
end

--[=[
	Returns this server's JobId, or `nil` when there isn't a meaningful one.

	Studio hands out an empty JobId, and two Studio sessions sharing `""` would
	each believe they owned the other's leases. Reporting `nil` lets the caller
	substitute a unique id instead.

	@within Runtime
	@private
]=]
function Runtime.jobId(): string?
	if not Runtime.isRoblox then
		return nil
	end
	local ok, id = pcall(function()
		return gameRef.JobId
	end)
	if not ok or type(id) ~= "string" or id == "" then
		return nil
	end
	return id
end

return table.freeze(Runtime)
