--!strict

-- UIController (Client)
-- Manages all client-side UI state and bridges server round/announcement
-- events to the physically-authored ScreenGuis in StarterGui.
--
-- Panel lifecycle:
--   * LobbyUI  — shown during intermission / lobby state (default visible)
--   * RoundHUD — shown during active rounds
--   * AnnouncementGui — shown temporarily for admin broadcasts

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local UIController = {}
UIController.__index = UIController
setmetatable(UIController, { __index = BaseController })

-- How long the announcement label stays visible after a broadcast.
local ANNOUNCEMENT_DURATION = 5.0

function UIController.new()
	local self: any = BaseController.new("UIController")
	-- LobbyUI references
	self._lobbyGui = nil :: ScreenGui?
	self._intermissionTimer = nil :: TextLabel?
	self._returnToLobbyButton = nil :: TextButton?
	-- RoundHUD references
	self._roundGui = nil :: ScreenGui?
	self._roundStateLabel = nil :: TextLabel?
	self._aliveCountLabel = nil :: TextLabel?
	self._winnerLabel = nil :: TextLabel?
	-- AnnouncementGui references
	self._announcementGui = nil :: ScreenGui?
	self._announcementLabel = nil :: TextLabel?
	-- Announcement cleanup
	self._announcementThread = nil :: thread?
	return setmetatable(self, UIController)
end

function UIController:Init()
	BaseController.Init(self)
	self:_ResolveAllUI()
end

function UIController:Start()
	BaseController.Start(self)

	print("UIController started")

	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	-- Listen for round replication
	local roundRemote = remotes:WaitForChild("RoundReplication")
	roundRemote.OnClientEvent:Connect(function(action: string, ...)
		self:_OnRoundAction(action, ...)
	end)

	-- Listen for announcements
	local announcementRemote = remotes:WaitForChild("AnnouncementEvent")
	announcementRemote.OnClientEvent:Connect(function(message: string)
		self:_ShowAnnouncement(message)
	end)
end

-- ---------------------------------------------------------------------------
-- UI resolution (mirrors BombController:_ResolveUI pattern)
-- ---------------------------------------------------------------------------

function UIController:_ResolveAllUI()
	self:_ResolveLobbyUI()
	self:_ResolveRoundHUD()
	self:_ResolveAnnouncementGui()
end

function UIController:_ResolveLobbyUI()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	local gui = playerGui:FindFirstChild("LobbyUI")
	if gui and gui:IsA("ScreenGui") then
		self._lobbyGui = gui

		local timer = gui:FindFirstChild("IntermissionTimer", true)
		if timer and timer:IsA("TextLabel") then
			self._intermissionTimer = timer
		end

		local button = gui:FindFirstChild("ReturnToLobbyButton", true)
		if button and button:IsA("TextButton") then
			self._returnToLobbyButton = button
			button.MouseButton1Click:Connect(function()
				self:_OnReturnToLobbyClicked()
			end)
		end
	end
end

function UIController:_ResolveRoundHUD()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	local gui = playerGui:FindFirstChild("RoundHUD")
	if gui and gui:IsA("ScreenGui") then
		self._roundGui = gui

		local stateLabel = gui:FindFirstChild("RoundStateLabel", true)
		if stateLabel and stateLabel:IsA("TextLabel") then
			self._roundStateLabel = stateLabel
		end

		local countLabel = gui:FindFirstChild("AliveCountLabel", true)
		if countLabel and countLabel:IsA("TextLabel") then
			self._aliveCountLabel = countLabel
		end

		local winLabel = gui:FindFirstChild("WinnerLabel", true)
		if winLabel and winLabel:IsA("TextLabel") then
			self._winnerLabel = winLabel
		end
	end
end

function UIController:_ResolveAnnouncementGui()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	local gui = playerGui:FindFirstChild("AnnouncementGui")
	if gui and gui:IsA("ScreenGui") then
		self._announcementGui = gui

		local label = gui:FindFirstChild("AnnouncementLabel", true)
		if label and label:IsA("TextLabel") then
			self._announcementLabel = label
		end
	end
end

-- ---------------------------------------------------------------------------
-- Round action handler
-- ---------------------------------------------------------------------------

function UIController:_OnRoundAction(action: string, ...)
	if action == "RoundStarted" then
		local mode = ... :: string
		self:OnRoundStarted(mode)

	elseif action == "RoundEnded" then
		local reason, winners = ... :: string, ...
		self:OnRoundEnded(reason, winners)

	elseif action == "PlayerWon" then
		local player = ... :: Player
		self:OnPlayerWon(player)

	elseif action == "PlayersWon" then
		local winners = ... :: { Player }
		self:OnPlayersWon(winners)

	elseif action == "PlayerReturnedToLobby" then
		local player = ... :: Player
		self:OnPlayerReturnedToLobby(player)

	elseif action == "RoundPlayerLeft" then
		local player = ... :: Player
		self:OnRoundPlayerLeft(player)
	end
end

-- ---------------------------------------------------------------------------
-- Round lifecycle UI
-- ---------------------------------------------------------------------------

function UIController:OnRoundStarted(mode: string)
	self:_SetPanelVisible("LobbyUI", false)
	self:_SetPanelVisible("RoundHUD", true)

	local stateLabel = self._roundStateLabel
	if stateLabel then
		local modeText = if mode == "FirstElimination" then "First Tag Wins!" else "Last Man Standing!"
		stateLabel.Text = modeText
		stateLabel.Visible = true
	end

	self:_UpdateAliveCount()
	self:_HideWinnerLabel()
end

function UIController:OnRoundEnded(reason: string, winners: { Player })
	local stateLabel = self._roundStateLabel
	if stateLabel then
		stateLabel.Text = "Round Over!"
	end
end

function UIController:OnPlayerWon(player: Player)
	self:_ShowWinnerLabel(player.Name .. " wins!")
end

function UIController:OnPlayersWon(winners: { Player })
	if #winners == 1 then
		self:_ShowWinnerLabel(winners[1].Name .. " wins!")
	else
		self:_ShowWinnerLabel("It's a tie!")
	end
end

function UIController:OnPlayerReturnedToLobby(player: Player)
	-- The local player returned to lobby: switch panels
	if player == Players.LocalPlayer then
		self:_SetPanelVisible("RoundHUD", false)
		self:_SetPanelVisible("LobbyUI", true)

		local timerLabel = self._intermissionTimer
		if timerLabel then
			timerLabel.Text = "Returned to lobby"
		end
	end
end

function UIController:OnRoundPlayerLeft(player: Player)
	self:_UpdateAliveCount()
end

-- ---------------------------------------------------------------------------
-- Announcement display
-- ---------------------------------------------------------------------------

function UIController:_ShowAnnouncement(message: string)
	-- Cancel any previous announcement fade timer
	if self._announcementThread then
		task.cancel(self._announcementThread)
		self._announcementThread = nil
	end

	self:_ResolveAnnouncementGui()
	local label = self._announcementLabel
	if not label then
		return
	end

	label.Text = message
	label.Visible = true
	label.TextTransparency = 0
	label.Position = UDim2.fromScale(0.5, 0.25)

	-- Fade out after duration
	self._announcementThread = task.spawn(function()
		task.wait(ANNOUNCEMENT_DURATION)

		-- Tween fade out
		local tween = TweenService:Create(label, TweenInfo.new(0.5), { TextTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()

		label.Visible = false
		label.Text = ""
		self._announcementThread = nil
	end)
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------

-- Toggles visibility of an entire ScreenGui panel and its contained labels.
-- "LobbyUI" — shown during intermission
-- "RoundHUD" — shown during active rounds
function UIController:_SetPanelVisible(panelName: string, visible: bool)
	if panelName == "LobbyUI" then
		self:_ResolveLobbyUI()
		if self._lobbyGui then
			self._lobbyGui.Enabled = visible
		end
		-- The return-to-lobby button should only show during a round, not in lobby
		if self._returnToLobbyButton then
			self._returnToLobbyButton.Visible = not visible
		end

	elseif panelName == "RoundHUD" then
		self:_ResolveRoundHUD()
		if self._roundGui then
			self._roundGui.Enabled = visible
		end
		if not visible then
			self:_HideWinnerLabel()
			if self._roundStateLabel then
				self._roundStateLabel.Visible = false
			end
			if self._aliveCountLabel then
				self._aliveCountLabel.Visible = false
			end
		end
	end
end

function UIController:_UpdateAliveCount()
	self:_ResolveRoundHUD()
	local label = self._aliveCountLabel
	if not label then
		return
	end

	-- The client doesn't track alive count directly; this updates when
	-- RoundPlayerLeft events fire. For a full count, the server would
	-- need to fire an AliveCount payload.
	label.Visible = true
end

-- Sets the winner label text and shows it with a brief entrance animation
function UIController:_ShowWinnerLabel(text: string)
	self:_ResolveRoundHUD()
	local label = self._winnerLabel
	if not label then
		return
	end

	label.Text = text
	label.Visible = true
	label.TextTransparency = 0
end

function UIController:_HideWinnerLabel()
	local label = self._winnerLabel
	if label then
		label.Visible = false
		label.Text = ""
	end
end

-- ---------------------------------------------------------------------------
-- Return to Lobby action
-- ---------------------------------------------------------------------------

function UIController:_OnReturnToLobbyClicked()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		return
	end

	local playerAction = remotes:FindFirstChild("PlayerAction")
	if not playerAction or not playerAction:IsA("RemoteEvent") then
		return
	end

	playerAction:FireServer("ReturnToLobby")
end

return UIController