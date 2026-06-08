--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local MovementController = {}
MovementController.__index = MovementController
setmetatable(MovementController, { __index = BaseController })

function MovementController.new()
	local self: any = BaseController.new("MovementController")
	self._wallGripEnabled = false
	self._activeSwing = nil :: Instance?
	return setmetatable(self, MovementController)
end

function MovementController:Start()
	BaseController.Start(self)

	RunService.RenderStepped:Connect(function(deltaTime)
		self:OnRenderStep(deltaTime)
	end)
end

function MovementController:OnRenderStep(deltaTime: number)
	local selfAny = self :: any
	if selfAny._wallGripEnabled then
		self:DetectWallContact()
		self:ApplyWallGrip(deltaTime)
	end
end

function MovementController:DetectWallContact(): RaycastResult?
	-- TODO: Add camera/character-aware wall probes and server-approved state hints.
	return nil
end

function MovementController:ApplyWallGrip(deltaTime: number)
	-- TODO: Implement local-feel friction while MovementService owns authoritative mode/modifier state.
end

function MovementController:HandleWallJump()
	-- TODO: Implement wall jump impulse and reconcile with server movement state.
end

function MovementController:HandleVineSwing()
	-- TODO: Implement constraint-based vine swing client feel.
end

function MovementController:EnableWallGrip()
	local selfAny = self :: any
	selfAny._wallGripEnabled = true
end

function MovementController:DisableWallGrip()
	local selfAny = self :: any
	selfAny._wallGripEnabled = false
end

function MovementController:BeginSwing(vine: Instance)
	local selfAny = self :: any
	selfAny._activeSwing = vine
end

function MovementController:EndSwing()
	local selfAny = self :: any
	selfAny._activeSwing = nil
end

function MovementController:GetCharacter(): Model?
	local localPlayer = Players.LocalPlayer
	return localPlayer.Character
end

return MovementController
