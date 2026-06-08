--!strict

-- BombController (Client)
-- Renders the bomb on the local screen in response to server-side
-- authoritative events from BombManager.  Nothing here is authoritative --
-- it is purely cosmetic / feedback.  The actual game state, including
-- who holds the bomb and when it explodes, is owned by the server.
--
-- The controller is responsible for:
--   * Spawning a 3D "bomb" attachment on the current holder's character
--     (or clearing it when the round resets).
--   * Playing a ticking SFX that speeds up as the timer runs out.
--   * Driving the bomb timer ScreenGui so players can see how much time
--     is left on the fuse.
--   * Playing a quick "transfer" VFX/SFX when the bomb changes hands.
--   * Playing an explosion VFX/SFX when the bomb detonates.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local Maid = require(ReplicatedStorage.Shared.Utility.Maid)
local TimeUtil = require(ReplicatedStorage.Shared.Utility.TimeUtil)

local BombController = {}
BombController.__index = BombController
setmetatable(BombController, { __index = BaseController })

-- ---------------------------------------------------------------------------
-- Tuning constants for the visual/audio presentation.  Kept local to the
-- controller so designers can tweak the feel without touching game config.
-- ---------------------------------------------------------------------------
local BOMB_MODEL_NAME = "PoopBombModel"        -- cloned onto the holder's character
local BOMB_ATTACH_OFFSET = CFrame.new(0, 2.5, -1.2) * CFrame.Angles(math.rad(-15), 0, 0)
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
	-- _bombAttachment is the model welded to the current holder's character.
	self._bombAttachment = nil :: Model?
	-- _tickSound is the looping tick audio so we can tweak PlaybackRate
	-- dynamically as the fuse burns down.
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

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local bombEvent = remotes:WaitForChild("BombEvent")

	self._maid:GiveTask(
		bombEvent.OnClientEvent:Connect(function(action: string, ...)
			print("BombEvent received:", action)

			if action == "Assigned" then
				local holder, durationSeconds = ...

				if holder then
					print("BombAssigned received", holder.Name, durationSeconds)
				end

				self:OnBombAssigned(holder, durationSeconds)

			elseif action == "Transferred" then
				local fromPlayer, toPlayer = ...

				if fromPlayer and toPlayer then
					print("BombTransferred received", fromPlayer.Name, toPlayer.Name)
				end

				self:OnBombTransferred(fromPlayer, toPlayer)

			elseif action == "Exploded" then
				local holder = ...

				if holder then
					print("BombExploded received", holder.Name)
				end

				self:OnBombExploded(holder)

			elseif action == "RoundEnded" then
				print("RoundEnded received")
				self:ClearBombVisuals()
			end
		end)
	)
end

-- ---------------------------------------------------------------------------
-- Event handlers
-- ---------------------------------------------------------------------------

function BombController:OnBombAssigned(holder: Player, durationSeconds: number)
	-- If for some reason we are still rendering on the previous holder
	-- (e.g. the assignment was a forced re-roll from EliminatePlayer),
	-- clear those visuals before attaching to the new holder.
	if self._currentHolder and self._currentHolder ~= holder then
		self:_DestroyBombAttachment()
	end

	self._currentHolder = holder

	-- Use the duration passed by the server so the on-screen timer
	-- matches the authoritative countdown even if we joined late.
	self._timerEndTime = TimeUtil.Now() + durationSeconds

	self:EnsureBombVisuals()
	self:StartRenderLoop()
	self:_UpdateTimerLabel(durationSeconds)
end

function BombController:OnBombTransferred(fromPlayer: Player, toPlayer: Player)
	-- Always play the transfer feedback so spectators also see/hear it.
	self:_PlayTransferEffect(fromPlayer, toPlayer)

	-- Re-attach the bomb to the new holder.  The server re-fires
	-- BombAssigned for the new holder as part of the same logical
	-- "hand-off" -- we listen to both and the latest one wins.
	self._currentHolder = toPlayer
	self:EnsureBombVisuals()
end

function BombController:OnBombExploded(holder: Player)
	self:_PlayExplosionEffect(holder)
	-- Clear immediately so the bomb does not keep ticking after detonation.
	self:ClearBombVisuals()
end

-- ---------------------------------------------------------------------------
-- 3D bomb attachment (model welded to the holder's character)
-- ---------------------------------------------------------------------------

function BombController:EnsureBombVisuals()
	local holder = self._currentHolder
	if not holder or not holder.Parent then
		-- Holder has left or is invalid -- tear down any stale visuals.
		self:_DestroyBombAttachment()
		return
	end

	-- Find a place to source the bomb model from.  ReplicatedStorage is
	-- the right home for cosmetic assets shared with the client.  If the
	-- asset isn't there yet, just skip -- the rest of the UI/feedback
	-- (timer, sounds) will still work without the visual model.
	local sourceTemplate = ReplicatedStorage:FindFirstChild(BOMB_MODEL_NAME)
	if not sourceTemplate or not sourceTemplate:IsA("Model") then
		return
	end

	-- Idempotent: if the attachment is already parented to a valid
	-- character, leave it alone.
	if self._bombAttachment and self._bombAttachment.Parent then
		return
	end

	local character = holder.Character
	if not character then
		-- Character may not be loaded yet (just respawned).  Try again
		-- the next render frame; harmless because the loop polls
		-- EnsureBombVisuals whenever the holder changes.
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	-- Clone the template so each holder can have their own weld without
	-- fighting the original.
	local bomb = sourceTemplate:Clone()

	-- Weld to the head/root so the bomb follows the holder.  A Weld
	-- constraint keeps the relationship declarative and replication-safe.
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = rootPart
	weld.Part1 = bomb.PrimaryPart or bomb:FindFirstChildWhichIsA("BasePart")
	weld.Parent = bomb
	bomb:PivotTo(rootPart.CFrame * BOMB_ATTACH_OFFSET)
	bomb.Parent = character

	self._bombAttachment = bomb

	-- Find / create a tick Sound inside the model so it is positional.
	local tickSound = bomb:FindFirstChild(TICK_SOUND_NAME)
	if not tickSound or not tickSound:IsA("Sound") then
		tickSound = Instance.new("Sound")
		tickSound.Name = TICK_SOUND_NAME
		tickSound.Looped = true
		tickSound.Volume = 0.6
		tickSound.PlaybackRate = TICK_NORMAL_RATE
		tickSound.Parent = bomb
	end
	tickSound:Play()
	self._tickSound = tickSound
end

function BombController:_DestroyBombAttachment()
	if self._tickSound then
		self._tickSound:Stop()
		self._tickSound = nil
	end
	if self._bombAttachment then
		self._bombAttachment:Destroy()
		self._bombAttachment = nil
	end
end

function BombController:ClearBombVisuals()
	self._currentHolder = nil
	self._timerEndTime = 0
	self:_DestroyBombAttachment()
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
	-- Keep the bomb attached in case the character respawned mid-round
	-- (we'd lose the weld and the bomb would fall out of the world).
	self:EnsureBombVisuals()

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
	if self._ui and self._timerText then
		return
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
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
	self:_ResolveUI()
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
	local seconds = math.max(0, math.ceil(remainingSeconds))
	label.Text = tostring(seconds)

	-- Visually escalate as time runs out: turn the text red in the
	-- final stretch so players can tell at a glance the fuse is short.
	local uiController = self.Controllers and self.Controllers:Get("UIController")
	-- UIController may not exist yet; treat its absence as "no theme".
	local _ = uiController -- reserved for future shared theme lookups

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

	if math.abs(tick.PlaybackRate - targetRate) > 0.01 then
		-- Tween so the change is smooth rather than a hard step.  Short
		-- duration is fine -- we are only smoothing jitter, not chasing
		-- a moving target.
		TweenService:Create(tick, TweenInfo.new(0.2), { PlaybackRate = targetRate }):Play()
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
	local maid = self._maid :: any
	if maid and type(maid.DoCleaning) == "function" then
		maid:DoCleaning()
	end
	self:_StopRenderLoop()
	self:_DestroyBombAttachment()
end

return BombController
