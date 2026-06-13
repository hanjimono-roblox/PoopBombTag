--!strict

-- MapVoteController (Client)
-- Listens for map voting events from the server and manages the UI.
-- Players click on map options in the MapVoteUI to cast their vote.
--
-- This controller follows the same pattern as UIController / BombController:
-- it resolves UI elements in PlayerGui and reacts to server events.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local MapVoteController = {}
MapVoteController.__index = MapVoteController
setmetatable(MapVoteController, { __index = BaseController })

-- Duration for the result reveal animation
local RESULT_FADE_DURATION = 0.5

function MapVoteController.new()
	local self: any = BaseController.new("MapVoteController")
	-- Whether voting UI is currently visible
	self._votingActive = false
	-- The map options displayed
	self._options = {} :: { string }
	-- Vote tallies: mapName -> count
	self._votes = {} :: { [string]: number }
	-- The map name the local player voted for (nil if not voted)
	self._myVote = nil :: string?
	-- Root UI references
	self._voteGui = nil :: ScreenGui?
	self._frame = nil :: Frame?
	self._timerLabel = nil :: TextLabel?
	self._titleLabel = nil :: TextLabel?
	-- References to option buttons
	self._optionButtons = {} :: { TextButton }
	self._optionLabels = {} :: { TextLabel }
	self._voteCountLabels = {} :: { TextLabel }
	-- Timer thread for countdown display
	self._timerThread = nil :: thread?
	return setmetatable(self, MapVoteController)
end

function MapVoteController:Init()
	BaseController.Init(self)
	self:_ResolveUI()
end

function MapVoteController:Start()
	BaseController.Start(self)

	print("MapVoteController started")

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local mapVoteRemote = remotes:WaitForChild("MapVote")

	mapVoteRemote.OnClientEvent:Connect(function(action: string, ...)
		self:_OnMapVoteAction(action, ...)
	end)
end

-- ---------------------------------------------------------------------------
-- UI Resolution
-- ---------------------------------------------------------------------------

function MapVoteController:_ResolveUI()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	local gui = playerGui:FindFirstChild("MapVoteUI")
	if gui and gui:IsA("ScreenGui") then
		self._voteGui = gui

		local frame = gui:FindFirstChild("VoteFrame")
		if frame and frame:IsA("Frame") then
			self._frame = frame

			-- Resolve timer label
			local timer = frame:FindFirstChild("TimerLabel", true)
			if timer and timer:IsA("TextLabel") then
				self._timerLabel = timer
			end

			-- Resolve title label
			local title = frame:FindFirstChild("TitleLabel", true)
			if title and title:IsA("TextLabel") then
				self._titleLabel = title
			end

			-- Resolve option buttons (MapOption_1, MapOption_2, MapOption_3)
			self._optionButtons = {}
			self._optionLabels = {}
			self._voteCountLabels = {}

			for i = 1, 3 do
				local buttonName = `MapOption_{i}`
				local button = frame:FindFirstChild(buttonName, true)
				if button and button:IsA("TextButton") then
					table.insert(self._optionButtons, button)

					-- The button text itself shows the map name
					local nameLabel = button:FindFirstChild("MapName")
					if nameLabel and nameLabel:IsA("TextLabel") then
						table.insert(self._optionLabels, nameLabel)
					else
						-- Fallback: use the button itself for display
						table.insert(self._optionLabels, button)
					end

					-- Vote count label inside each option
					local countLabel = button:FindFirstChild("VoteCount")
					if countLabel and countLabel:IsA("TextLabel") then
						table.insert(self._voteCountLabels, countLabel)
					else
						table.insert(self._voteCountLabels, nil)
					end
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Event Dispatch
-- ---------------------------------------------------------------------------

function MapVoteController:_OnMapVoteAction(action: string, ...)
	if action == "MapVoteStarted" then
		local options, durationSeconds = ... :: { string }, ... :: number
		self:_OnVoteStarted(options, durationSeconds)

	elseif action == "MapVoteUpdated" then
		local votes = ... :: { [string]: number }
		self:_OnVoteUpdated(votes)

	elseif action == "MapVoteEnded" then
		local winner, votes = ... :: string, ... :: { [string]: number }
		self:_OnVoteEnded(winner, votes)
	end
end

-- ---------------------------------------------------------------------------
-- Vote Lifecycle Handlers
-- ---------------------------------------------------------------------------

function MapVoteController:_OnVoteStarted(options: { string }, durationSeconds: number)
	self._votingActive = true
	self._options = options
	self._votes = {}
	self._myVote = nil

	-- Initialize vote counts to zero
	for _, mapName in ipairs(options) do
		self._votes[mapName] = 0
	end

	-- Show and configure the UI
	self:_ShowUI(options)

	-- Start countdown
	if self._timerThread then
		task.cancel(self._timerThread)
	end
	self._timerThread = task.spawn(function()
		local remaining = durationSeconds
		while remaining > 0 do
			if self._timerLabel then
				self._timerLabel.Text = `Voting ends in {remaining}s`
			end
			task.wait(1)
			remaining = remaining - 1
		end
		if self._timerLabel then
			self._timerLabel.Text = "Vote ending..."
		end
	end)
end

function MapVoteController:_OnVoteUpdated(votes: { [string]: number })
	self._votes = votes
	self:_UpdateVoteCounts()
end

function MapVoteController:_OnVoteEnded(winner: string, _votes: { [string]: number })
	self._votingActive = false
	self._votes = _votes

	-- Cancel countdown timer
	if self._timerThread then
		task.cancel(self._timerThread)
		self._timerThread = nil
	end

	-- Show winner highlight
	self:_ShowWinner(winner)

	-- Disable all buttons
	for _, button in ipairs(self._optionButtons) do
		button.Active = false
		button.AutoButtonColor = false
	end

	-- Auto-hide after a delay
	task.delay(3, function()
		self:HideUI()
	end)
end

-- ---------------------------------------------------------------------------
-- UI Display Methods
-- ---------------------------------------------------------------------------

function MapVoteController:_ShowUI(options: { string })
	self:_ResolveUI()
	if not self._voteGui then
		return
	end

	self._voteGui.Enabled = true
	self._voteGui.DisplayOrder = 10

	if self._titleLabel then
		self._titleLabel.Text = "Vote for the next map!"
	end

	-- Configure option buttons
	for i, mapName in ipairs(options) do
		if self._optionLabels[i] then
			self._optionLabels[i].Text = mapName
		end
		if self._optionButtons[i] then
			self._optionButtons[i].Visible = true
			self._optionButtons[i].Active = true
			self._optionButtons[i].AutoButtonColor = true
			self._optionButtons[i].BackgroundColor3 = Color3.fromRGB(60, 60, 60)

			-- Clone the closure to capture the map name
			local capturedMapName = mapName
			self._optionButtons[i].MouseButton1Click:Connect(function()
				self:_CastVote(capturedMapName)
			end)
		end
		if self._voteCountLabels[i] then
			self._voteCountLabels[i].Text = "0"
			self._voteCountLabels[i].Visible = true
		end
	end

	-- Hide any unused option slots
	for i = #options + 1, #self._optionButtons do
		self._optionButtons[i].Visible = false
	end

	-- Animate the frame in
	if self._frame then
		local tween = TweenService:Create(
			self._frame,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 0.2 }
		)
		tween:Play()
	end
end

function MapVoteController:HideUI()
	self:_ResolveUI()
	if not self._voteGui then
		return
	end

	self._voteGui.Enabled = false
	self._votingActive = false

	-- Clean up button connections by re-resolving on next show
	self._optionButtons = {}
end

-- ---------------------------------------------------------------------------
-- Voting Action
-- ---------------------------------------------------------------------------

function MapVoteController:_CastVote(mapName: string)
	if not self._votingActive then
		return
	end

	-- Prevent double-voting client-side
	if self._myVote then
		return
	end

	self._myVote = mapName

	-- Highlight the selected option
	for i, button in ipairs(self._optionButtons) do
		if self._optionLabels[i] and self._optionLabels[i].Text == mapName then
			button.BackgroundColor3 = Color3.fromRGB(80, 180, 80) -- Green highlight
		else
			button.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
		end
	end

	-- Fire the vote to the server
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		return
	end
	local mapVoteRemote = remotes:FindFirstChild("MapVote")
	if mapVoteRemote and mapVoteRemote:IsA("RemoteEvent") then
		mapVoteRemote:FireServer("CastVote", mapName)
	end
end

-- ---------------------------------------------------------------------------
-- UI Update Methods
-- ---------------------------------------------------------------------------

function MapVoteController:_UpdateVoteCounts()
	for i, mapName in ipairs(self._options) do
		if self._voteCountLabels[i] then
			local count = self._votes[mapName] or 0
			self._voteCountLabels[i].Text = tostring(count)
		end
	end
end

function MapVoteController:_ShowWinner(winner: string)
	for i, button in ipairs(self._optionButtons) do
		if self._optionLabels[i] and self._optionLabels[i].Text == winner then
			-- Highlight the winner in gold
			button.BackgroundColor3 = Color3.fromRGB(255, 200, 50)

			-- Animate the winner label
			if self._optionLabels[i] then
				local tween = TweenService:Create(
					self._optionLabels[i],
					TweenInfo.new(RESULT_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ TextSize = 28 }
				)
				tween:Play()
			end
		else
			button.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
		end
	end

	if self._titleLabel then
		self._titleLabel.Text = `Next map: {winner}!`
	end
end

-- ---------------------------------------------------------------------------
-- State Query API
-- ---------------------------------------------------------------------------

-- Returns true if a map vote is currently active.
function MapVoteController:IsVotingActive(): boolean
	return self._votingActive
end

-- Returns the current vote options.
function MapVoteController:GetOptions(): { string }
	return self._options
end

-- Returns the map name the local player voted for, or nil.
function MapVoteController:GetMyVote(): string?
	return self._myVote
end

return MapVoteController