--!strict

-- MovementController (Client)
-- Handles local-feel movement abilities: wall climbing, wall jumping,
-- and vine swinging. The server remains authoritative over movement
-- mode/state via MovementService.
--
-- Wall Climb uses a BodyVelocity to apply constant upward force that
-- the Humanoid physics solver cannot override.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local MovementController = {}
MovementController.__index = MovementController
setmetatable(MovementController, { __index = BaseController })

local WALL_CLIMB_DISTANCE = 5.0
local WALL_CLIMB_VELOCITY = 30.0           -- upward velocity while climbing
local WALL_JUMP_FORCE = 50.0
local RAYCAST_INTERVAL = 1
local VINE_GRAB_DISTANCE = 6.0
local VINE_SWING_FORCE = 30.0

local RAYCAST_PARAMS = RaycastParams.new()

local WALL_RAY_DIRECTIONS = {
	Vector3.new(0, 0, -1),
	Vector3.new(1, 0, -1).Unit,
	Vector3.new(1, 0, 0),
	Vector3.new(1, 0, 1).Unit,
	Vector3.new(0, 0, 1),
	Vector3.new(-1, 0, 1).Unit,
	Vector3.new(-1, 0, 0),
	Vector3.new(-1, 0, -1).Unit,
}

function MovementController.new()
	local self: any = BaseController.new("MovementController")
	self._lastWallJump = 0
	self._wallJumpLockoutUntil = 0
	self._wallClimbing = false
	self._wallNormal = nil :: Vector3?
self._wallPosition = nil :: Vector3?
	self._frameCount = 0
	self._climbConnection = nil
	self._activeSwing = nil :: RopeConstraint?
	self._vineAttachment = nil :: CFrame?
	self._movementActionRemote = nil :: RemoteEvent?
	self._baseWalkSpeed = GameConfig.Movement.DefaultWalkSpeed
	return setmetatable(self, MovementController)
end

function MovementController:Start()
	BaseController.Start(self)

	RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Blacklist
	RAYCAST_PARAMS.IgnoreWater = true

local function connectCharacter(character: Model)
    local humanoid = character:WaitForChild("Humanoid")

    humanoid.Jumping:Connect(function(active)
        if not active then
            return
        end

        if self._wallClimbing then
            self:HandleWallJump()
        end
    end)

    humanoid.StateChanged:Connect(function(_, newState)

        if
            newState == Enum.HumanoidStateType.Landed
            or newState == Enum.HumanoidStateType.Running
        then
            self:_EndWallClimb()
        end
    end)
end

local localPlayer = Players.LocalPlayer

if localPlayer.Character then
    task.spawn(connectCharacter, localPlayer.Character)
end

localPlayer.CharacterAdded:Connect(connectCharacter)

	local function rebuildBlacklist()
		local parts: { Instance } = {}
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			if character then
				for _, obj in ipairs(character:GetDescendants()) do
					if obj:IsA("BasePart") then
						table.insert(parts, obj)
					end
				end
			end
		end
		RAYCAST_PARAMS.FilterDescendantsInstances = parts
	end

	local function applyWalkSpeed()
		local character = self:GetCharacter()
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = self._baseWalkSpeed
			end
		end
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			rebuildBlacklist()
			applyWalkSpeed()
		end)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function()
			rebuildBlacklist()
			applyWalkSpeed()
		end)
	end

	task.defer(function()
		rebuildBlacklist()
		applyWalkSpeed()
	end)


	-- Also poll on Heartbeat as a backup (works alongside events)
	RunService.Heartbeat:Connect(function()
		self:OnPhysicsStep()
	end)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	self._movementActionRemote = remotes:WaitForChild("MovementAction")

end

function MovementController:OnPhysicsStep()

	local character = self:GetCharacter()
	if not character then
		self:_EndWallClimb()
		self:EndSwing()
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	-- Detect wall and manage climb state
	self:_DetectAndClimb(rootPart, humanoid)

	if self._activeSwing then
		self:_ApplySwingPhysics(rootPart)
	end

	self._frameCount = self._frameCount + 1
end

-- ---------------------------------------------------------------------------
-- Wall Climb via BodyVelocity
-- ---------------------------------------------------------------------------

function MovementController:_VerifyCurrentWall(
    rootPart: BasePart
): (Vector3?, RaycastResult?)

    if not self._wallNormal then
        return nil, nil
    end

    local result = Workspace:Raycast(
        rootPart.Position,
        -self._wallNormal * WALL_CLIMB_DISTANCE,
        RAYCAST_PARAMS
    )

    if result then
        return result.Normal, result
    end

    return nil, nil
end

function MovementController:_IsAirborne(humanoid: Humanoid): boolean
    local state = humanoid:GetState()

    return
        state == Enum.HumanoidStateType.Freefall
        or state == Enum.HumanoidStateType.Jumping
        or state == Enum.HumanoidStateType.FallingDown
end

function MovementController:_DetectAndClimb(rootPart: BasePart, humanoid: Humanoid)
	if self._frameCount % RAYCAST_INTERVAL ~= 0 then
		return
	end

	local hitNormal: Vector3?
local wallHit: RaycastResult?

if self._wallClimbing then
    hitNormal, wallHit =
        self:_VerifyCurrentWall(rootPart)
else
    hitNormal, wallHit =
        self:_DetectWall(rootPart, humanoid)
end
	local nearWall = wallHit ~= nil and hitNormal ~= nil
	local climbable = nearWall and (
		CollectionService:HasTag(wallHit.Instance, "Climbable")
		or (wallHit.Instance.Parent and CollectionService:HasTag(wallHit.Instance.Parent, "Climbable"))
	)

	-- Check if player wants to climb: Space held + airborne + near wall
	local moveDir = humanoid.MoveDirection

local pushingIntoWall = false

if nearWall and hitNormal then
    pushingIntoWall =
        moveDir.Magnitude > 0.05
        and moveDir:Dot(-hitNormal) > 0.4
end



local airborne = self:_IsAirborne(humanoid)

local wallJumpLocked =
	time() < self._wallJumpLockoutUntil

local shouldClimb =
    not wallJumpLocked
    and nearWall
    and climbable
    and airborne
    and UserInputService:IsKeyDown(Enum.KeyCode.Space)

if not self._wallClimbing then
    shouldClimb =
        shouldClimb
        and pushingIntoWall
end

	if shouldClimb then
		-- Store wall info for wall jump
		self._wallNormal = hitNormal
		self._wallPosition = wallHit.Position

		-- Create BodyVelocity if not already climbing
		if not self._wallClimbing then
    self:_StartWallClimb(rootPart, humanoid)
end

	elseif self._wallClimbing then
		-- Stop climbing
		self:_EndWallClimb()
	end
end

function MovementController:_StartWallClimb(
	rootPart: BasePart,
	humanoid: Humanoid
)
	if self._wallClimbing then
		return
	end

	self._wallClimbing = true

	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

	self._climbConnection =
	RunService.Heartbeat:Connect(function()

		if not self._wallClimbing then
			return
		end

		local wallPush = Vector3.zero

		if self._wallNormal then
			wallPush = -self._wallNormal * 4
		end

		local moveDir = humanoid.MoveDirection


rootPart.AssemblyLinearVelocity =
    Vector3.new(
        moveDir.X * 12 + wallPush.X,
        math.max(
            rootPart.AssemblyLinearVelocity.Y,
            WALL_CLIMB_VELOCITY
        ),
        moveDir.Z * 12 + wallPush.Z
    )
	end)

	self:_FireMovementAction("WallClimb")
end

function MovementController:_EndWallClimb()
	if not self._wallClimbing then
		return
	end

	self._wallClimbing = false

	if self._climbConnection then
		self._climbConnection:Disconnect()
		self._climbConnection = nil
	end

	self._wallNormal = nil
	self._wallPosition = nil

	local character = self:GetCharacter()
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")

		if humanoid then
			humanoid:ChangeState(
				Enum.HumanoidStateType.Freefall
			)
		end
	end

	self:_FireMovementAction("Default")
end

function MovementController:_DetectWall(rootPart: BasePart, humanoid: Humanoid): (Vector3?, RaycastResult?)
	local origin = rootPart.Position
	local moveDir = humanoid.MoveDirection

	-- Don't raycast if not actively moving (prevents NaN from .Unit)
	if moveDir.Magnitude < 0.05 then
		return nil, nil
	end

	local forward = moveDir.Unit
	local right = forward:Cross(Vector3.new(0, 1, 0)).Unit

	local directions = {
		forward,
		(forward + right * 0.5).Unit,
		(forward - right * 0.5).Unit,
		right,
		-right,
	}

	for _, dir in ipairs(directions) do
		local rayResult = Workspace:Raycast(
			origin,
			dir * WALL_CLIMB_DISTANCE,
			RAYCAST_PARAMS
		)

		if rayResult then
			return rayResult.Normal, rayResult
		end
	end

	return nil, nil
end

-- ---------------------------------------------------------------------------
-- Wall Jump
-- ---------------------------------------------------------------------------

function MovementController:HandleWallJump()

	if time() - self._lastWallJump < 0.2 then
	return
end

local character = self:GetCharacter()
if not character then
	return
end

local rootPart = character:FindFirstChild("HumanoidRootPart")
if not rootPart or not rootPart:IsA("BasePart") then
	return
end

local wallNormal = self._wallNormal
if not wallNormal then
	return
end

self._lastWallJump = time()
self._wallJumpLockoutUntil = time() +0.25

self:_EndWallClimb()

local currentVelocity =
    rootPart.AssemblyLinearVelocity

rootPart.AssemblyLinearVelocity =
    currentVelocity
    + wallNormal * WALL_JUMP_FORCE
    + Vector3.new(
        0,
        WALL_JUMP_FORCE * 0.9,
        0
    )
end

-- ---------------------------------------------------------------------------
-- Vine Swing
-- ---------------------------------------------------------------------------

function MovementController:BeginSwing(vine: Instance)
	self:EndSwing()

	local character = self:GetCharacter()
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local vinePart = vine:IsA("BasePart") and vine or vine:FindFirstChildWhichIsA("BasePart")
	if not vinePart then
		return
	end

	local vineAttachment = vinePart:FindFirstChildWhichIsA("Attachment")
	if not vineAttachment then
		vineAttachment = Instance.new("Attachment")
		vineAttachment.Name = "SwingAttachment"
		vineAttachment.Parent = vinePart
	end

	local ropeConstraint = Instance.new("RopeConstraint")
	ropeConstraint.Name = "VineSwingRope"
	ropeConstraint.Length = (rootPart.Position - vinePart.Position).Magnitude
	ropeConstraint.Thickness = 0.2
	ropeConstraint.Visible = false

	local characterAttachment = Instance.new("Attachment")
	characterAttachment.Name = "SwingCharacterAttachment"
	characterAttachment.Parent = rootPart

	ropeConstraint.Attachment0 = vineAttachment
	ropeConstraint.Attachment1 = characterAttachment
	ropeConstraint.Parent = rootPart

	self._activeSwing = ropeConstraint
	self._vineAttachment = vinePart.CFrame
	self:_FireMovementAction("BeginSwing")
end

function MovementController:EndSwing()
	if self._activeSwing then
		local attachment1 = self._activeSwing.Attachment1
		if attachment1 and attachment1.Parent then
			attachment1:Destroy()
		end
		self._activeSwing:Destroy()
		self._activeSwing = nil
		self._vineAttachment = nil
		self:_FireMovementAction("EndSwing")
	end
end

function MovementController:_ApplySwingPhysics(rootPart: BasePart)
	if not self._vineAttachment then
		return
	end

	local vinePos = self._vineAttachment.Position
	local currentPos = rootPart.Position
	local directionToVine = (vinePos - currentPos).Unit

	local velocity = rootPart.AssemblyLinearVelocity
	local tangentDir = velocity.Unit
	if velocity.Magnitude < 0.5 then
		tangentDir = directionToVine:Cross(Vector3.new(0, 1, 0)).Unit
	end

	rootPart.AssemblyLinearVelocity = rootPart.AssemblyLinearVelocity + tangentDir * VINE_SWING_FORCE

	local currentDistance = (currentPos - vinePos).Magnitude
	local maxLength = self._activeSwing and self._activeSwing.Length or VINE_GRAB_DISTANCE
	if currentDistance > maxLength * 1.1 then
		local pullDir = (vinePos - currentPos).Unit
		rootPart.AssemblyLinearVelocity = rootPart.AssemblyLinearVelocity + pullDir * (currentDistance - maxLength) * 10
	end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function MovementController:_FireMovementAction(action: string)
	local remote = self._movementActionRemote
	if remote then
		remote:FireServer(action)
	end
end

function MovementController:GetCharacter(): Model?
	local localPlayer = Players.LocalPlayer
	return localPlayer.Character
end

return MovementController