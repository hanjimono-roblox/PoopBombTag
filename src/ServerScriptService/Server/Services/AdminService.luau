--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)

local AdminService = {}
AdminService.__index = AdminService
setmetatable(AdminService, { __index = BaseService })

function AdminService.new()
	return setmetatable(BaseService.new("AdminService"), AdminService)
end

function AdminService:GetRank(player: Player): string
	return AdminConfig.UserRanks[player.UserId] or "Player"
end

function AdminService:IsAdmin(player: Player): boolean
	return (AdminConfig.RankHierarchy[self:GetRank(player)] or 0) > AdminConfig.RankHierarchy.Player
end

function AdminService:HasPermission(player: Player, permission: string?): boolean
	if permission == nil then
		return true
	end

	local requiredRank = AdminConfig.Permissions[permission]
	if requiredRank == nil then
		return false
	end

	local rankName = self:GetRank(player)
	local rankValue = AdminConfig.RankHierarchy[rankName] or 0
	return rankValue >= requiredRank
end

return AdminService
