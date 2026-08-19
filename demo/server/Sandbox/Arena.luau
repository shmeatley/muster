--!strict

--[[
	The physical half of the sandbox: two pads you can click and two screens to
	read.

	None of this is Muster. It is here so the live queue has something to be
	driven by and something to report to, and it is kept in its own module so
	the interesting file next door stays about matchmaking. Skim it once and
	then ignore it.

	Everything is built in code rather than shipped as instances in the place
	file, so you can read what the world is made of without opening Studio's
	explorer.
]]

local PAD_SIZE = Vector3.new(10, 1, 10)
local QUEUE_COLOR = Color3.fromRGB(64, 132, 214)
local BOT_COLOR = Color3.fromRGB(102, 102, 112)
local MATCH_COLOR = Color3.fromRGB(88, 196, 122)

local Arena = {}
Arena.__index = Arena

--[[ A floating caption, used for the pad labels. ]]
local function caption(parent: Instance, text: string, offset: number, size: number): TextLabel
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(280, 64)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, offset, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = size
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = billboard

	return label
end

--[[ An anchored pad with a click detector and a caption above it. ]]
local function pad(name: string, position: Vector3, color: Color3, text: string): (Part, ClickDetector)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = PAD_SIZE
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = workspace

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 48
	click.Parent = part

	caption(part, text, 4, 22)
	return part, click
end

--[[
	Builds the world and returns a handle to it.

	The pads are clickable rather than touch-triggered on purpose: a Touched
	event fires many times a second while you stand on a part, and debouncing
	that is noise nobody came here to read.
]]
function Arena.new()
	local self = setmetatable({
		_hud = {},
	}, Arena)

	self.queuePad, self._queueClick = pad("QueuePad", Vector3.new(-8, 0.5, -18), QUEUE_COLOR, "CLICK TO QUEUE")
	self.botPad, self._botClick = pad("BotPad", Vector3.new(8, 0.5, -18), BOT_COLOR, "CLICK TO ADD A BOT")

	-- The status board. An invisible anchor part with one big billboard on it,
	-- so it always faces whoever is reading.
	local anchor = Instance.new("Part")
	anchor.Name = "StatusBoard"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(0, 8, -30)
	anchor.Parent = workspace

	local board = Instance.new("BillboardGui")
	board.Size = UDim2.fromOffset(520, 300)
	board.AlwaysOnTop = false
	board.Parent = anchor

	local backing = Instance.new("Frame")
	backing.Size = UDim2.fromScale(1, 1)
	backing.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	backing.BackgroundTransparency = 0.15
	backing.BorderSizePixel = 0
	backing.Parent = board

	self._board = Instance.new("TextLabel")
	self._board.Size = UDim2.new(1, -24, 1, -24)
	self._board.Position = UDim2.fromOffset(12, 12)
	self._board.BackgroundTransparency = 1
	self._board.Font = Enum.Font.Code
	self._board.TextSize = 18
	self._board.TextColor3 = Color3.fromRGB(226, 232, 240)
	self._board.TextXAlignment = Enum.TextXAlignment.Left
	self._board.TextYAlignment = Enum.TextYAlignment.Top
	self._board.Text = ""
	self._board.Parent = backing

	return self
end

--[[ Called with the player who clicked the queue pad. ]]
function Arena.onQueueClick(self, callback: (Player) -> ())
	self._queueClick.MouseClick:Connect(callback)
end

--[[ Called with the player who clicked the bot pad. ]]
function Arena.onBotClick(self, callback: (Player) -> ())
	self._botClick.MouseClick:Connect(callback)
end

--[[ Replaces the status board's contents. Takes a list of lines. ]]
function Arena.setBoard(self, lines: { string })
	self._board.Text = table.concat(lines, "\n")
end

--[[
	Per-player text in the corner of the screen.

	Created on the server, which is allowed to write into PlayerGui, so the
	sandbox needs no client script at all.
]]
function Arena.setHud(self, player: Player, text: string)
	local label = self._hud[player]
	if label == nil or label.Parent == nil then
		local screen = Instance.new("ScreenGui")
		screen.Name = "MusterSandbox"
		screen.ResetOnSpawn = false

		label = Instance.new("TextLabel")
		label.AnchorPoint = Vector2.new(0.5, 1)
		label.Position = UDim2.new(0.5, 0, 1, -24)
		label.Size = UDim2.fromOffset(520, 32)
		label.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
		label.BackgroundTransparency = 0.25
		label.BorderSizePixel = 0
		label.Font = Enum.Font.Code
		label.TextSize = 18
		label.TextColor3 = Color3.fromRGB(226, 232, 240)
		label.Parent = screen

		screen.Parent = player:WaitForChild("PlayerGui")
		self._hud[player] = label
	end
	label.Text = text
end

function Arena.clearHud(self, player: Player)
	self._hud[player] = nil
end

--[[ Turns the queue pad green for a moment, so a match is visible from across the map. ]]
function Arena.flash(self)
	self.queuePad.Color = MATCH_COLOR
	task.delay(1.5, function()
		self.queuePad.Color = QUEUE_COLOR
	end)
end

return Arena
