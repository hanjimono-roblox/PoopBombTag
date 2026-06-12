--!strict

-- BombController (Client, Cosmetic Only)
-- Observes server-authoritative bomb state and provides cosmetic
-- feedback (timer UI, transfer/explosion SFX/VFX).
--
-- This controller does NOT:
--   * Clone bombs (server does this via BombAttachmentService)
--   * Weld bombs (server does this via WeldConstraint)
--   * Position bombs (server does PivotTo)
--   * Destroy bombs (server destroys via DetachBomb)
--   * Track bomb model state (server owns the model replication)
--
-- The bomb model itself is replicated to all clients automatically
-- by Roblox's instance replication because it is parented to the
-- character on the server. Every client sees the EXACT SAME bomb
-- instance and weld.
--
-- Responsibilities:
--   * Drive the bomb timer ScreenGui so players can see remaining fuse
--   * Play transfer VFX/SFX when the bomb changes hands
--   * Play explosion VFX/SFX when the bomb detonates
--   * Play a ticking SFX sourced from the replicated bomb model

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)
local Maid = require(ReplicatedStorage.Shared.Utility.Maid)
local TimeUtil = require(ReplicatedStorage.Shared.Utility.TimeUtil)

local BombController = {}
BombController.__index = BombController
setmetatable(BombController, { __index = BaseController })

-- ---------------------------------------------------------------------------
-- Tuning constants for the visual/audio presentation.  Kept local to the
-- controller so designers can tweak the feel without touching game config.
-- ---------------------------------------------------------------------------
local BOMB_MODEL_NAME = "PoopBombModel"        -- name of the server-replicated bomb model
local TRANSFER_VFX_NAME = "BombTransferVFX"    -- a ParticleEmitter parent created in ReplicatedFirst
local EXPLOSION_VFX_NAME = "BombExplosionVFX"  -- a ParticleEmitter parent created in ReplicatedFirst

local TICK_SOUND_NAME = "BombTick"             -- looping tick SFX, parented to the bomb model
local TRANSFER_SOUND_NAME = "BombTransfer"     -- one-shot when the bomb changes holders
local EXPLOSION_SOUND_NAME = "BombExplosion"   -- one-shot when the bomb detonates

local TICK_FAST_THRESHOLD = 5.0                -- seconds remaining where ticks speed up
local TICK_NORMAL_RATE = 1.0                   -- PlaybackRate at full duration
local TICK_FAST_RATE = 2.4                     -- PlaybackRate in the final stretch

local COUNTDOWN_RED_THRESHOLD = 5.0            -- seconds remaining before the timer turns red

function BombController.new()
	local self: any = BaseController.new("BombController")
	-- _maid owns every RBX object / connection the controller creates so we
	-- can clean up between rounds and on teardown without leaking instances.
	self._maid = Maid.new()
	-- _currentHolder tracks the player we *believe* currently has the bomb.
	-- The server is the source of truth; we just mirror the latest event.
	self._currentHolder = nil :: Player?
	-- _tickSound is the looping tick audio found on the replicated bomb model.
	-- Retrieved each render step from the character's bomb (server-replicated).
	-- NOT owned by this controller; we reference it, not create it.
	self._tickSound = nil :: Sound?
	-- _timerEndTime mirrors the server's _timerEndTime so the client can
	-- render a smooth countdown even between server events.
	self._timerEndTime = 0
	-- _renderConnection is the per-frame RenderStepped binding used to
	-- update the timer UI / tick PlaybackRate.
	self._renderConnection = nil :: RBXScriptConnection?
	-- _ui references the ScreenGui we look up in StarterGui (created in
	-- Studio, see README for the hierarchy).  Cached after first lookup.
	self._ui = nil :: ScreenGui?
	-- _timerText is the TextLabel inside the ScreenGui that displays the
	-- remaining seconds.  Cached so we can avoid FindFirstChild every frame.
	self._timerText = nil :: TextLabel?
	return setmetatable(self, BombController)
end

function BombController:Init()
	BaseController.Init(self)
	-- Pre-resolve the UI so the first frame of a round does not pay the
	-- FindFirstChild cost.  Safe to do at Init because StarterGui has
	-- already replicated by the time the client script runs.
	self:_ResolveUI()
end

function BombController:Start()
	BaseController.Start(self)

	print("BombController started")

	-- The client NEVER listens to EventManager for bomb state --
	-- it only listens to the dedicated BombReplication RemoteEvent
	-- that is driven by the server-side ReplicationService bridge.
	-- This guarantees the UI works even if EventManager is
	-- disabled client-side.
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local bombReplication = remotes:WaitForChild("BombReplication")

	self._maid:GiveTask(
		bombReplication.OnClientEvent:Connect(function(action: string, ...)
			if action == "Assigned" then
				local holder, durationSeconds = ...
				self:OnBombAssigned(holder, durationSeconds)

			elseif action == "Transferred" then
				local fromPlayer, toPlayer, durationSeconds = ...
				self:OnBombTransferred(fromPlayer, toPlayer, durationSeconds)

			elseif action == "Exploded" then
				local holder = ...
				self:OnBombExploded(holder)

			elseif action == "Cleared" then
				self:ClearBombVisuals()
			end
		end)
	)
end

-- ---------------------------------------------------------------------------
-- Event handlers
-- ---------------------------------------------------------------------------

function BombController:OnBombAssigned(holder: Player, durationSeconds: number)
	-- The bomb model is already being replicated server-side by
	-- BombAttachmentService. We do NOT create or weld anything here.
	-- This handler only manages the timer UI and tick sound.

	self._currentHolder = holder

	-- Use the duration passed by the server so the on-screen timer
	-- matches the authoritative countdown even if we joined late.
	self._timerEndTime = TimeUtil.Now() + durationSeconds

	self:RefreshTickSound()
	self:StartRenderLoop()
	self:_UpdateTimerLabel(durationSeconds)
end

function BombController:OnBombTransferred(fromPlayer: Player, toPlayer: Player, durationSeconds: number)
	-- Always play the transfer feedback so spectators also see/hear it.
	self:_PlayTransferEffect(fromPlayer, toPlayer)

	-- Update holder and timer state so the countdown UI activates
	-- for the new holder (matching the pattern in OnBombAssigned).
	self._currentHolder = toPlayer
	self._timerEndTime = TimeUtil.Now() + durationSeconds

	-- Re-find the tick sound on the new holder's replicated bomb model.
	self:RefreshTickSound()
	self:StartRenderLoop()
	self:_UpdateTimerLabel(durationSeconds)
end

function BombController:OnBombExploded(holder: Player)
	self:_PlayExplosionEffect(holder)
	-- Clear immediately so the bomb does not keep ticking after detonation.
	self:ClearBombVisuals()
end

-- ---------------------------------------------------------------------------
-- Tick sound management (sourced from server-replicated bomb model)
-- ---------------------------------------------------------------------------

-- RefreshTickSound() looks up the server-replicated bomb model on the
-- current holder's character and retrieves (or creates) the ticking sound.
-- The bomb model itself is replicated by Roblox; we only interact with
-- its Sound child for audio feedback.
function BombController:RefreshTickSound()
	local selfAny = self :: any

	-- Stop any previous tick sound reference
	selfAny._tickSound = nil

	local holder = self._currentHolder
	if not holder or not holder.Parent then
		return
	end

	local character = holder.Character
	if not character then
		return
	end

	-- Find the server-replicated bomb model on the character
	local bomb = character:FindFirstChild(BOMB_MODEL_NAME)
	if not bomb or not bomb:IsA("Model") then
		-- Bomb model has not replicated yet; it's fine, we'll
		-- try again on the next render step.
		return
	end

	-- Locate or create the tick sound on the replicated bomb
	local tickSound = bomb:FindFirstChild(TICK_SOUND_NAME)
	if not tickSound or not tickSound:IsA("Sound") then
		tickSound = Instance.new("Sound")
		tickSound.Name = TICK_SOUND_NAME
		tickSound.Looped = true
		tickSound.Volume = 0.6
		tickSound.PlaybackSpeed = TICK_NORMAL_RATE
		tickSound.Parent = bomb
	end

	tickSound:Play()
	selfAny._tickSound = tickSound
end

-- ---------------------------------------------------------------------------
-- Visual state management
-- ---------------------------------------------------------------------------

function BombController:ClearBombVisuals()
	self._currentHolder = nil
	self._timerEndTime = 0
	self._tickSound = nil
	self:_StopRenderLoop()
	self:_SetTimerLabelVisible(false)
end

-- ---------------------------------------------------------------------------
-- Render-step loop (timer UI + tick rate)
-- ---------------------------------------------------------------------------

function BombController:StartRenderLoop()
	if self._renderConnection then
		return
	end

	-- We use RenderStepped so the timer label updates every frame for
	-- a smooth countdown.  The actual expiry is still server-driven
	-- (BombExploded event); this loop is purely cosmetic.
	self._renderConnection = RunService.RenderStepped:Connect(function(_deltaTime: number)
		self:OnRenderStep()
	end)
	self:_SetTimerLabelVisible(true)
end

function BombController:_StopRenderLoop()
	local connection = self._renderConnection
	if connection then
		connection:Disconnect()
		self._renderConnection = nil
	end
end

function BombController:OnRenderStep()
	-- Look up the tick sound on the replicated bomb. The bomb model
	-- is replicated by the server; we just find it and play the tick.
	-- If the bomb model hasn't replicated yet, RefreshTickSound is a no-op.
	self:RefreshTickSound()

	local remaining = self._timerEndTime > 0 and TimeUtil.SecondsRemaining(self._timerEndTime) or 0
	self:_UpdateTimerLabel(remaining)
	self:_UpdateTickRate(remaining)

	-- Local "expired" guard: if the server hasn't fired BombExploded
	-- yet but the local countdown hit zero, stop the tick so it does
	-- not loop forever waiting for the network event.
	if remaining <= 0 and self._tickSound and self._tickSound.Playing then
		self._tickSound:Stop()
	end
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------

-- Resolves the ScreenGui + TextLabel from StarterGui.  See the README for
-- the expected hierarchy (ScreenGui named "BombHUD" with a TextLabel named
-- "TimerLabel").  Safe to call multiple times -- caches the result.
function BombController:_ResolveUI()
	-- If we have cached references, verify they are still valid.
	-- ResetOnSpawn can destroy the old GUI and create a new one,
	-- leaving us with stale references to destroyed instances.
	if self._ui and self._timerText then
		if self._ui.Parent and self._timerText.Parent then
			return
		end
		-- References are stale (GUI was reset on respawn), re-resolve.
		self._ui = nil
		self._timerText = nil
	end

	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	local gui = playerGui:FindFirstChild("BombHUD")
	if not gui or not gui:IsA("ScreenGui") then
		-- Designer has not created the GUI yet.  We silently no-op;
		-- the rest of the controller (visuals + sounds) still works.
		return
	end

	local label = gui:FindFirstChild("TimerLabel", true)
	if not label or not label:IsA("TextLabel") then
		return
	end

	self._ui = gui
	self._timerText = label
end

function BombController:_SetTimerLabelVisible(visible: boolean)
	print("Timer visible:", visible)
	self:_ResolveUI()
	print("Label:", self._timerText)
	local label = self._timerText
	if not label then
		return
	end

	label.Visible = visible
	if not visible then
		label.Text = ""
	end
end

function BombController:_UpdateTimerLabel(remainingSeconds: number)
	self:_ResolveUI()
	local label = self._timerText
	if not label then
		return
	end

	-- Whole-number display matches the "X seconds left" feel of a bomb
	-- timer.  Clamp negatives so the label does not flash -0 or -1
	-- between the local timer hitting 0 and the server firing the event.
	-- local seconds = math.max(0, math.ceil(remainingSeconds))
	label.Text = string.format("%.2f", math.max(0, remainingSeconds))

	-- Visually escalate as time runs out: turn the text red in the
	-- final stretch so players can tell at a glance the fuse is short.
	local uiController = self.Controllers and self.Controllers:Get("UIController")
	-- UIController may not exist yet; treat its absence as "no theme".
	local _ = uiController -- reserved for future shared theme lookups

	local seconds = math.max(0, remainingSeconds)

	if seconds <= COUNTDOWN_RED_THRESHOLD then
		label.TextColor3 = Color3.fromRGB(255, 80, 80)
	else
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
	end
end

-- ---------------------------------------------------------------------------
-- Audio
-- ---------------------------------------------------------------------------

function BombController:_UpdateTickRate(remainingSeconds: number)
	local tick = self._tickSound
	if not tick then
		return
	end

	-- Speed up the tick as the fuse gets shorter to build tension.  The
	-- server's _timerThread ticks at 0.03s, so we have plenty of room
	-- to lerp the client-side PlaybackRate smoothly.
	local targetRate = if remainingSeconds <= TICK_FAST_THRESHOLD
		then TICK_FAST_RATE
		else TICK_NORMAL_RATE

	if math.abs(tick.PlaybackSpeed  - targetRate) > 0.01 then
		-- Tween so the change is smooth rather than a hard step.  Short
		-- duration is fine -- we are only smoothing jitter, not chasing
		-- a moving target.
		TweenService:Create(tick, TweenInfo.new(0.2), { PlaybackSpeed  = targetRate }):Play()
	end
end

-- ---------------------------------------------------------------------------
-- Transfer + explosion feedback
-- ---------------------------------------------------------------------------

function BombController:_PlayTransferEffect(_fromPlayer: Player, toPlayer: Player)
	-- One-shot SFX at the new holder's position so the audio is
	-- positional (you can tell roughly where they are when the
	-- handoff happens).
	self:_PlayOneShotAtPlayer(TRANSFER_SOUND_NAME, toPlayer)

	-- Spawn a short-lived particle burst on the new holder.  We
	-- reuse the explosion VFX template if available, even though
	-- the visual is more of a "poof" than a fireball -- cheaper
	-- than maintaining a separate transfer-only asset.
	self:_SpawnBurstAtPlayer(TRANSFER_VFX_NAME, toPlayer)
end

function BombController:_PlayExplosionEffect(holder: Player)
	self:_PlayOneShotAtPlayer(EXPLOSION_SOUND_NAME, holder)
	self:_SpawnBurstAtPlayer(EXPLOSION_VFX_NAME, holder)
end

function BombController:_PlayOneShotAtPlayer(soundName: string, player: Player)
	local character = player and player.Character
	if not character then
		return
	end

	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end

	-- Look up the Sound asset in SoundService by convention.  If the
	-- sound does not exist we silently no-op so the game still runs
	-- even if the audio asset is missing.
	local template = SoundService:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then
		return
	end

	local oneShot = template:Clone()
	oneShot.Parent = head
	oneShot.Looped = false
	oneShot:Play()
	-- Clean up after the sound finishes so we do not leak instances
	-- in the character's head (which gets destroyed on respawn anyway,
	-- but explicit cleanup is good hygiene).
	oneShot.Ended:Once(function()
		oneShot:Destroy()
	end)
end

function BombController:_SpawnBurstAtPlayer(vfxName: string, player: Player)
	local character = player and player.Character
	if not character then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	-- Look up the VFX template in ReplicatedFirst.  Designers should drop
	-- a Model (or any Instance with ParticleEmitters in it) into
	-- ReplicatedFirst with a known name; we clone it, parent it briefly
	-- to the holder's character, then destroy it after the burst.
	local template = ReplicatedFirst:FindFirstChild(vfxName)
	if not template then
		return
	end

	local burst = template:Clone()
	burst.Parent = character

	-- Enable all ParticleEmitters under the cloned template.  Designers
	-- usually author these with EmissionEnabled = false on the template
	-- so they do not fire in the editor; flip them on for the burst.
	for _, descendant in ipairs(burst:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Fire") or descendant:IsA("Smoke") then
			(descendant :: any).Enabled = true
		end
	end

	-- Let the burst play for a short window, then clean up.  Two seconds
	-- is enough for any reasonable "transfer poof" or "explosion pop";
	-- tune by adjusting the cleanup delay rather than editing every
	-- emitter's Lifetime.
	task.delay(2, function()
		if burst and burst.Parent then
			burst:Destroy()
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

-- The BaseController does not define a Stop hook, but the registry does
-- not call one either.  We expose Destroy() so the controller can be
-- manually torn down if it is ever created outside the registry (e.g.
-- in tests).  The Maid handles releasing every RBX object + connection.
function BombController:Destroy()
	self._tickSound = nil
	self:_StopRenderLoop()

	local maid = self._maid :: any
	if maid and type(maid.DoCleaning) == "function" then
		maid:DoCleaning()
	end
end

return BombController