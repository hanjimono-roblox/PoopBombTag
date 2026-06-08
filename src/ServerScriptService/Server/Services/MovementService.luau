--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local TableUtil = require(ReplicatedStorage.Shared.Utility.TableUtil)

type MovementModifier = MovementTypes.MovementModifier
type MovementState = MovementTypes.MovementState

local MovementService = {}
MovementService.__index = MovementService
setmetatable(MovementService, { __index = BaseService })

function MovementService.new()
	local self: any = BaseService.new("MovementService")
	self._states = {} :: { [Player]: MovementState }
	return setmetatable(self, MovementService)
end

function MovementService:GetMovementState(player: Player): MovementState
	local selfAny = self :: any
	local existing = selfAny._states[player]
	if existing then
		return existing
	end

	local state: MovementState = {
		Mode = GameConfig.Movement.DefaultMode,
		Modifiers = TableUtil.ShallowCopy(GameConfig.Movement.DefaultModifiers),
	}

	selfAny._states[player] = state
	return state
end

function MovementService:SetMovementMode(player: Player, mode: string)
	local state = self:GetMovementState(player)
	state.Mode = mode
	EventManager:Fire(EventNames.MovementStateChanged, player, state)
end

function MovementService:SetMovementModifier(player: Player, modifier: MovementModifier)
	local state = self:GetMovementState(player)

	for key, value in pairs(modifier) do
		local modifiers = state.Modifiers :: any
		modifiers[key] = value
	end

	EventManager:Fire(EventNames.MovementStateChanged, player, state)
end

function MovementService:GetTagRangeMultiplier(player: Player): number
	local state = self:GetMovementState(player)
	return state.Modifiers.TagRange or 1
end

return MovementService
