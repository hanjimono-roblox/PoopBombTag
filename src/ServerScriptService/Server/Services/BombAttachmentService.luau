--!strict

-- BombAttachmentService (Server, Authority)
-- The single owner of bomb model creation, attachment, welding, and
-- destruction. Every bomb instance is parented to the character on the
-- server, which means Roblox's built-in replication ensures ALL clients
-- see the EXACT SAME bomb instance and weld. Clients NEVER create or
-- weld bombs -- they only observe the server-replicated model.
--
-- This service is idempotent: calling AttachBomb for a player who
-- already has a bomb returns the existing model. Calling DetachBomb
-- for a player without a bomb is a safe no-op.
--
-- This service MUST NOT:
--   * Fire RemoteEvents directly (replication is the model itself)
--   * Validate tag candidates (not its responsibility)
--   * Track bomb state / timer (BombManager owns that)
--   * Depend on BombManager (avoids circular dependency)
--
-- Dependencies:
--   * ReplicatedStorage:FindFirstChild("PoopBombModel") -- the bomb template
--   * Players service (for cleanup on player removal)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)

local BombAttachmentService = {}
BombAttachmentService.__index = BombAttachmentService
setmetatable(BombAttachmentService, { __index = BaseService })

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local BOMB_MODEL_NAME = "PoopBombModel"
local ATTACH_PART_NAME = "RightHand"
local BOMB_ATTACH_OFFSET = CFrame.new(0, -0.25, -0.6) * CFrame.Angles(math.rad(0), math.rad(90), 0)
local HAND_WAIT_TIMEOUT = 5.0 -- seconds to wait for RightHand to exist

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function BombAttachmentService.new()
	local self: any = BaseService.new("BombAttachmentService")
	-- Maps Player -> Model (the bomb instance attached to that player)
	self._attachedBombs = {} :: { [Player]: Model }
	-- Maps Player -> { RBXScriptConnection } for cleanup
	self._playerConnections = {} :: { [Player]: { RBXScriptConnection } }
	-- Cached bomb template from ReplicatedStorage
	self._bombTemplate = nil :: Model?
	-- Prevents double-start
	self._started = false
	return setmetatable(self, BombAttachmentService)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function BombAttachmentService:Start()
	BaseService.Start(self)

	if self._started then
		return
	end
	self._started = true

	-- Resolve and cache the bomb template ONCE at Start time. If the
	-- template is not yet replicated (edge case), we log a warning and
	-- will attempt to resolve it lazily in AttachBomb.
	local template = ReplicatedStorage:FindFirstChild(BOMB_MODEL_NAME)
	if template and template:IsA("Model") then
		self._bombTemplate = template
	else
		warn(`[BombAttachment] Template "{BOMB_MODEL_NAME}" not found in ReplicatedStorage at Start`)
	end

	print("[BombAttachmentService] Started")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- AttachBomb(player) -> Model?
-- Creates a bomb model, parents it to the player's character, positions
-- it at the RightHand with the configured offset, and welds all parts
-- using WeldConstraints.
--
-- Idempotent: if the player's character already contains a bomb model
-- named PoopBombModel, returns the existing model without creating a
-- duplicate. This prevents race conditions between multiple callers.
--
-- Returns the attached bomb Model, or nil on failure.
function BombAttachmentService:AttachBomb(player: Player): Model?
	local selfAny = self :: any

	-- Validate player exists and has a character
	if not player or not player.Parent then
		print("[BombAttachment] AttachBomb rejected: player is nil or not in game")
		return nil
	end

	-- Wait for character to exist (with timeout)
	local character = self:_WaitForCharacter(player)
	if not character then
		print(`[BombAttachment] AttachBomb rejected: no character for {player.Name} after timeout`)
		return nil
	end

	-- -----------------------------------------------------------------------
	-- Idempotency guard: check if this character ALREADY has an attached bomb
	-- -----------------------------------------------------------------------
	local existingBomb = character:FindFirstChild(BOMB_MODEL_NAME)
	if existingBomb and existingBomb:IsA("Model") then
		-- Bomb already exists on this character. Return it to prevent dupes.
		-- The weld should already be intact, but we do a quick sanity check.
		-- Store it if not already tracked.
		if not selfAny._attachedBombs[player] then
			selfAny._attachedBombs[player] = existingBomb
			self:_SetupPlayerCleanup(player)
		end
		return existingBomb
	end

	-- -----------------------------------------------------------------------
	-- Resolve bomb template (lazy fallback if Start() didn't find it)
	-- -----------------------------------------------------------------------
	local template = selfAny._bombTemplate
	if not template then
		local found = ReplicatedStorage:FindFirstChild(BOMB_MODEL_NAME)
		if found and found:IsA("Model") then
			template = found
			selfAny._bombTemplate = template
		else
			-- Template not in ReplicatedStorage; raise a runtime error so the
			-- developer knows the bomb model is missing, rather than silently
			-- failing and leaving the bomb invisible on clients.
			error(`[BombAttachment] Cannot attach bomb: template "{BOMB_MODEL_NAME}" missing from ReplicatedStorage`)
			return nil
		end
	end

	-- -----------------------------------------------------------------------
	-- Resolve RightHand (with WaitForChild timeout)
	-- -----------------------------------------------------------------------
	local handPart = self:_ResolveHandPart(character)
	if not handPart then
		warn(`[BombAttachment] RightHand not found on {player.Name} after {HAND_WAIT_TIMEOUT}s, cannot attach bomb`)
		return nil
	end

	-- -----------------------------------------------------------------------
	-- Clone and configure the bomb model
	-- -----------------------------------------------------------------------
	local bomb = template:Clone()
	bomb.Name = BOMB_MODEL_NAME -- ensure consistent name for idempotency checks
	bomb.Parent = character

	-- Ensure PrimaryPart is set (use first BasePart if not already set)
	if not bomb.PrimaryPart then
		local firstPart = bomb:FindFirstChildWhichIsA("BasePart", true)
		if not firstPart then
			warn("[BombAttachment] Bomb template contains no BaseParts")
			bomb:Destroy()
			return nil
		end
		bomb.PrimaryPart = firstPart
	end

	-- Configure physics for ALL parts in the model
	for _, obj in ipairs(bomb:GetDescendants()) do
		if obj:IsA("BasePart") then
			obj.Anchored = false
			obj.CanCollide = false
			obj.CanTouch = false
			obj.CanQuery = false
			obj.Massless = true
		end
	end

	-- -----------------------------------------------------------------------
	-- Position the bomb at the hand
	-- -----------------------------------------------------------------------
	bomb:PivotTo(handPart.CFrame * BOMB_ATTACH_OFFSET)

	-- -----------------------------------------------------------------------
	-- Weld all bomb parts to the PrimaryPart
	-- -----------------------------------------------------------------------
	for _, obj in ipairs(bomb:GetDescendants()) do
		if obj:IsA("BasePart") and obj ~= bomb.PrimaryPart then
			local wc = Instance.new("WeldConstraint")
			wc.Part0 = bomb.PrimaryPart
			wc.Part1 = obj
			wc.Parent = obj
		end
	end

	-- -----------------------------------------------------------------------
	-- Weld the PrimaryPart to the player's RightHand
	-- -----------------------------------------------------------------------
	local handWeld = Instance.new("WeldConstraint")
	handWeld.Part0 = handPart
	handWeld.Part1 = bomb.PrimaryPart
	handWeld.Parent = bomb.PrimaryPart

	-- -----------------------------------------------------------------------
	-- Store reference and set up cleanup listeners
	-- -----------------------------------------------------------------------
	selfAny._attachedBombs[player] = bomb
	self:_SetupPlayerCleanup(player)

	print(`[BombAttachment] Attached bomb to {player.Name}`)
	return bomb
end

-- DetachBomb(player) -> boolean
-- Destroys the bomb model attached to the given player. Idempotent:
-- returns false if no bomb is attached.
function BombAttachmentService:DetachBomb(player: Player): boolean
	local selfAny = self :: any

	local bomb = selfAny._attachedBombs[player]
	if not bomb then
		return false
	end

	-- Clean up any bomb that is still parented to the character. The bomb
	-- may have been destroyed externally (e.g. character died), in which
	-- case the Destroy() below is a safe no-op on a Descendants-destroyed
	-- instance.
	if bomb.Parent then
		bomb:Destroy()
	end

	selfAny._attachedBombs[player] = nil

	print(`[BombAttachment] Detached bomb from {player.Name}`)
	return true
end

-- GetAttachedBomb(player) -> Model?
-- Returns the bomb model attached to the given player, or nil if none.
function BombAttachmentService:GetAttachedBomb(player: Player): Model?
	local selfAny = self :: any
	return selfAny._attachedBombs[player]
end

-- IsHoldingBomb(player) -> boolean
-- Returns true if the player currently has an attached bomb model.
function BombAttachmentService:IsHoldingBomb(player: Player): boolean
	local selfAny = self :: any
	return selfAny._attachedBombs[player] ~= nil
end

-- DetachAllBombs()
-- Detaches and destroys ALL tracked bomb models. Called on round end
-- to ensure a clean slate.
function BombAttachmentService:DetachAllBombs()
	local selfAny = self :: any

	for player, _ in pairs(selfAny._attachedBombs) do
		self:DetachBomb(player)
	end

	-- Also clean up any loose player connections
	for player, connections in pairs(selfAny._playerConnections) do
		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		selfAny._playerConnections[player] = nil
	end
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- _WaitForCharacter(player) -> Model?
-- Returns the player's character if it exists (waits up to HAND_WAIT_TIMEOUT).
function BombAttachmentService:_WaitForCharacter(player: Player): Model?
	local character = player.Character
	if character then
		return character
	end

	-- Character is being loaded. Use promise-like wait with timeout.
	local startTime = tick()
	while tick() - startTime < HAND_WAIT_TIMEOUT do
		character = player.Character
		if character then
			return character
		end
		task.wait(0.1)
	end

	return nil
end

-- _ResolveHandPart(character: Model) -> BasePart?
-- Finds the RightHand attachment point on the character. Uses
-- WaitForChild with a timeout to handle characters that load asynchronously.
function BombAttachmentService:_ResolveHandPart(character: Model): BasePart?
	-- First, try RightHand (R15 rig) or Right Arm (R6 rig) directly
	local hand = character:FindFirstChild(ATTACH_PART_NAME)
	if hand and hand:IsA("BasePart") then
		return hand
	end

	-- Fallback: RightHand may load asynchronously in R15; wait for it
	local startTime = tick()
	while tick() - startTime < HAND_WAIT_TIMEOUT do
		hand = character:FindFirstChild(ATTACH_PART_NAME)
		if hand and hand:IsA("BasePart") then
			return hand
		end
		-- Also check for Right Arm in R6
		hand = character:FindFirstChild("Right Arm")
		if hand and hand:IsA("BasePart") then
			return hand
		end
		task.wait(0.05)
	end

	-- Last resort: use HumanoidRootPart (non-ideal but prevents crash)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		warn(`[BombAttachment] RightHand not found on character, falling back to HumanoidRootPart`)
		return rootPart
	end

	return nil
end

-- _SetupPlayerCleanup(player: Player)
-- Sets up connections to clean up the bomb when the player leaves or
-- their character is removed. Prevents duplicate connections.
function BombAttachmentService:_SetupPlayerCleanup(player: Player)
	local selfAny = self :: any

	-- Avoid duplicate cleanup setup
	if selfAny._playerConnections[player] then
		return
	end

	local connections: { RBXScriptConnection } = {}

	-- When the player leaves, clean up their bomb
	table.insert(connections,
		player.AncestryChanged:Connect(function()
			if not player.Parent then
				self:DetachBomb(player)
			end
		end)
	)

	-- When the character is removed, clean up the bomb
	local character = player.Character
	if character then
		table.insert(connections,
			character.AncestryChanged:Connect(function()
				if not character.Parent then
					-- Character being destroyed; detach the bomb if any
					self:DetachBomb(player)
				end
			end)
		)
	end

	if #connections > 0 then
		selfAny._playerConnections[player] = connections
	end
end

-- ---------------------------------------------------------------------------
-- Service Registry helpers
-- ---------------------------------------------------------------------------

-- Override BaseService:Init to resolve the bomb template
function BombAttachmentService:Init()
	BaseService.Init(self)

	-- If the template wasn't found at module load, try again at Init
	-- (ReplicatedStorage should be populated by now)
	if not self._bombTemplate then
		local template = ReplicatedStorage:FindFirstChild(BOMB_MODEL_NAME)
		if template and template:IsA("Model") then
			self._bombTemplate = template
		end
	end
end

return BombAttachmentService