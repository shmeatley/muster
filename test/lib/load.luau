--!nocheck

--[[
	Loads the package's own source under Lune.

	The point is that the suite runs against the code Muster actually ships,
	instance requires and all, rather than a headless transcription that could
	drift from it. `script` becomes a proxy that records a path as it is walked,
	and `require` resolves that path back to a file.

	The Roblox globals are deliberately *absent* from the environment rather
	than faked. `Runtime` reads them through `any`-typed locals and falls back
	when they are nil, so leaving them out exercises exactly the path a
	non-Roblox host takes.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Loader = {}

local function pathProxy(segments: { string }): any
	return setmetatable({ __segments = segments }, {
		__index = function(_self, key: string): any
			if key == "Parent" then
				local up = table.clone(segments)
				table.remove(up)
				return pathProxy(up)
			end
			if key == "Name" then
				return segments[#segments]
			end
			local down = table.clone(segments)
			table.insert(down, key)
			return pathProxy(down)
		end,
		__tostring = function()
			return table.concat(segments, ".")
		end,
	})
end

--[[
	Builds a loader rooted at `root` (the repository directory).
]]
function Loader.new(root: string)
	local cache: { [string]: any } = {}

	local function resolve(segments: { string }): any
		local key = table.concat(segments, "/")
		if cache[key] ~= nil then
			return cache[key]
		end

		local candidates = { `{root}/{key}.luau`, `{root}/{key}/init.luau` }
		local source: string? = nil
		for _, candidate in candidates do
			if fs.isFile(candidate) then
				source = fs.readFile(candidate)
				break
			end
		end
		if source == nil then
			error(`cannot resolve module "{key}" (looked for {candidates[1]} and {candidates[2]})`)
		end

		local environment: { [string]: any } = {
			math = math,
			table = table,
			string = string,
			buffer = buffer,
			bit32 = bit32,
			os = os,
			utf8 = utf8,
			coroutine = coroutine,
			assert = assert,
			error = error,
			pcall = pcall,
			xpcall = xpcall,
			select = select,
			next = next,
			type = type,
			typeof = typeof,
			tostring = tostring,
			tonumber = tonumber,
			ipairs = ipairs,
			pairs = pairs,
			unpack = table.unpack,
			setmetatable = setmetatable,
			getmetatable = getmetatable,
			rawget = rawget,
			rawset = rawset,
			rawequal = rawequal,
			rawlen = rawlen,
			print = print,
			warn = print,
			script = pathProxy(segments),
			require = function(target: any): any
				local targetSegments = rawget(target, "__segments")
				if targetSegments == nil then
					error(`require() expected a script path, got {tostring(target)}`)
				end
				return resolve(targetSegments)
			end,
		}

		-- Cache before evaluating so a cycle surfaces as a nil field rather than
		-- an infinite descent.
		local chunk = luau.load(source, { environment = environment, debugName = key })
		local result = chunk()
		cache[key] = result
		return result
	end

	return {
		resolve = resolve,
		--[[ Loads the package entry point. ]]
		muster = function()
			return resolve({ "src" })
		end,
	}
end

return Loader
