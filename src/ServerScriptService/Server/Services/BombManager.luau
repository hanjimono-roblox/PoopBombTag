--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local TimeUtil = require(ReplicatedStorage.Shared.Utility.TimeUtil)

local BombManager = {}
BombManager.__index = BombManager
setmetatable(BombManager, { __index = BaseService })

local BombEvent = ReplicatedStorage.Remotes.BombEvent

function BombManager.new()
	local self: any = BaseService.new("BombManager")
	self._holder = nil :: Player?
	self._timerEndTime = 0
	self._timerThread = nil :: thread?
	self._lastTransferAt = 0
	return setmetatable(self, BombManager)
end

function BombManager:AssignBomb(player: Player)
	if not self:IsValidBombHolder(player) then
		return false
	end

	local selfAny = self :: any
	selfAny._holder = player
	self:ResetTimer()
	print("SERVER FIRING BOMB ASSIGNED")
	BombEvent:FireAllClients(
		"Assigned",
		player,
		GameConfig.Bomb.DurationSeconds
	)
	return true
end

function BombManager:TransferBomb(fromPlayer: Player, toPlayer: Player): boolean
	print("[Bomb] TransferBomb called", fromPlayer.Name, "->", toPlayer.Name)
	local selfAny = self :: any
	if selfAny._holder ~= fromPlayer then
		print("[Bomb] Transfer failed: holder mismatch")
		return false
	end

	if not self:IsValidBombHolder(toPlayer) then
		print("[Bomb] Transfer failed: target not valid holder")
		return false
	end

	local now = TimeUtil.Now()
	if now - selfAny._lastTransferAt < GameConfig.Bomb.TransferCooldownSeconds then
		print("[Bomb] Transfer failed: cooldown")
		return false
	end

	selfAny._lastTransferAt = now
	selfAny._holder = toPlayer
	self:ResetTimer()
	BombEvent:FireAllClients(
		"Transferred",
		fromPlayer,
		toPlayer
	)
	print("[Bomb] Transfer successful")
	return true
end

function BombManager:ResetTimer()
	local selfAny = self :: any
	selfAny._timerEndTime = TimeUtil.Now() + GameConfig.Bomb.DurationSeconds

	local existingThread = selfAny._timerThread
	if existingThread then
		task.cancel(existingThread)
	end

	selfAny._timerThread = task.spawn(function()
		while TimeUtil.Now() < selfAny._timerEndTime do
			task.wait(0.03)
		end

		self:ExplodeBomb()
	end)
end

function BombManager:ExplodeBomb(): boolean
	local selfAny = self :: any
	local holder = selfAny._holder
	if not holder then
		return false
	end

	selfAny._holder = nil
	selfAny._timerThread = nil
	BombEvent:FireAllClients(
		"Exploded",
		holder
	)
	EventManager:Fire(EventNames.PlayerEliminated, holder, "BombExploded")
	return true
end

function BombManager:ClearBomb()
	local selfAny = self :: any
	local existingThread = selfAny._timerThread
	if existingThread then
		task.cancel(existingThread)
	end

	selfAny._holder = nil
	selfAny._timerEndTime = 0
	selfAny._timerThread = nil
end

function BombManager:GetBombHolder(): Player?
	local selfAny = self :: any
	return selfAny._holder
end

function BombManager:GetRemainingTime(): number
	local selfAny = self :: any
	return TimeUtil.SecondsRemaining(selfAny._timerEndTime)
end

function BombManager:ValidateTag(fromPlayer: Player, toPlayer: Player): boolean
	local selfAny = self :: any
	if fromPlayer == toPlayer or selfAny._holder ~= fromPlayer then
		return false
	end

	if not self:IsValidBombHolder(toPlayer) then
		return false
	end

	local fromRoot = self:GetRootPart(fromPlayer)
	local toRoot = self:GetRootPart(toPlayer)
	if not fromRoot or not toRoot then
		return false
	end

	local multiplier = self.Services:Get("MovementService"):GetTagRangeMultiplier(fromPlayer)
	local allowedDistance = GameConfig.Bomb.TagDistanceStuds * multiplier
	return (fromRoot.Position - toRoot.Position).Magnitude <= allowedDistance
end

function BombManager:TryTag(fromPlayer: Player, toPlayer: Player): boolean
	print("[Bomb] TryTag called", fromPlayer.Name, "->", toPlayer.Name)
	if not self:ValidateTag(fromPlayer, toPlayer) then
		print("[Bomb] TryTag rejected: ValidateTag failed")
		return false
	end
	print("[Bomb] TryTag ValidateTag passed")

	return self:TransferBomb(fromPlayer, toPlayer)
end

function BombManager:IsValidBombHolder(player: Player): boolean
	local state = self.Services:Get("PlayerManager"):GetState(player)
	return state ~= nil and state.InRound and state.Alive
end

function BombManager:GetRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

return BombManager
