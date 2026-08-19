--!strict

--[[
	Muster demo place.

	A lobby with two pads and a status board, running one real queue against
	real MemoryStore and real MessagingService.

		click the blue pad    join the queue, or leave it if you are in it
		click the grey pad    add a bot, so one person can fill a match

	Matches are 4 players, settling for 2 after eight seconds.

	The place is published at:

		https://www.roblox.com/games/100811184569764/Muster-Demo

	To build it yourself:

		rojo build demo.project.json -o MusterDemo.rbxl

	Everything worth reading is next door in `Sandbox`. It is roughly the amount
	of code a real game needs to wire Muster up.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Muster = require(ReplicatedStorage.Muster)
local Sandbox = require(script.Sandbox)

Sandbox.start(Muster)
