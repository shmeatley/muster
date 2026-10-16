--!nocheck
-- Instrument a sandbox-loaded copy, leaving production source untouched.
-- Arguments: output JSON path, optional Matcher source snapshot.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local process = require("@lune/process")
local M = require("../../test/lib/harness").muster()
local source = fs.readFile(process.args[2] or "src/internal/Matcher.luau")
source = source:gsub("local Defaults = require%(script.Parent.Parent.Defaults%)", "local Defaults, Rules, Types = ...")
source = source
	:gsub("local Rules = require%(script.Parent.Rules%)", "")
	:gsub("local Types = require%(script.Parent.Parent.Types%)", "")
source = source:gsub(
	"local Matcher = {}",
	"local Matcher = {}\nlocal profile = {states=0, accepts=0, scores=0, scoreSeconds=0, comparisons=0, lexSteps=0, copies=0, pairProbes=0, pairMisses=0}\nMatcher.profile=profile"
)
source = source:gsub(
	"local function better%(a: State, b: State%): boolean",
	"local function better(a: State, b: State): boolean\nprofile.comparisons += 1"
)
source = source:gsub(
	"for i = 1, math.min%(#a.indexes, #b.indexes%) do",
	"for i = 1, math.min(#a.indexes, #b.indexes) do\nprofile.lexSteps += 1"
)
source = source:gsub("for _, state in bucket do", "for _, state in bucket do\nprofile.states += 1")
source = source:gsub("if accepts then", "if accepts then\nprofile.accepts += 1")
source = source:gsub("proposed = extend%(state, index%)", "proposed = extend(state, index)\nprofile.copies += 1")
source = source:gsub(
	"spread = plan.extend%(state.summary, index, scratch%)",
	"local timer = os.clock()\nspread = plan.extend(state.summary, index, scratch)\nprofile.scores += 1\nprofile.scoreSeconds += os.clock()-timer"
)
source = source:gsub(
	"local spread, queued = policy.score%(candidates, proposed%)",
	"local timer = os.clock()\nlocal spread, queued = policy.score(candidates, proposed)\nprofile.scores += 1\nprofile.scoreSeconds += os.clock()-timer"
)
source = source:gsub(
	"local function pair%(a: number, b: number%): boolean",
	"local function pair(a: number, b: number): boolean\nprofile.pairProbes += 1"
)
source = source:gsub("if row%[high%] == nil then", "if row[high] == nil then\nprofile.pairMisses += 1")
local Matcher =
	luau.load(source)(M.Defaults, require("../../test/lib/load").new(".").resolve({ "src", "internal", "Rules" }), {})
local settings = assert(M.Config.resolve({
	name = "profile",
	size = 8,
	rules = {
		Age = { type = "number", compare = "distance", limit = 2, prefer = "closer" },
		Region = { type = "string", compare = "equal", relaxAfter = 45 },
		IsVerified = { type = "boolean", compare = "equal" },
		IsFlaggedCheater = { type = "boolean", compare = "required", value = false },
	},
}))
local candidates = {}
for i = 1, 100 do
	candidates[i] = {
		ticketId = string.format("%06d", i),
		size = 1,
		queuedAt = 1000,
		ratings = {},
		ruleKey = settings.ruleKey,
		attributes = { { Age = 20 + i % 3, Region = "NA", IsVerified = true, IsFlaggedCheater = false } },
	}
end
local started = os.clock()
local groups = Matcher.select(candidates, 1000, Matcher.policy(settings))
Matcher.profile.elapsedSeconds = os.clock() - started
Matcher.profile.groups = #groups
print(serde.encode("json", Matcher.profile, true))
if process.args[1] then
	fs.writeFile(process.args[1], serde.encode("json", Matcher.profile, true))
end
