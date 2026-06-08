--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local TimeUtil = require(ReplicatedStorage.Shared.Utility.TimeUtil)

local LoggingService = {}
LoggingService.__index = LoggingService
setmetatable(LoggingService, { __index = BaseService })

function LoggingService.new()
	local self = BaseService.new("LoggingService")
	return setmetatable(self, LoggingService)
end

function LoggingService:Start()
	BaseService.Start(self)

	EventManager:Connect(EventNames.BombTransferred, function(fromPlayer: Player, toPlayer: Player)
		self:Info("BOMB", `{fromPlayer.Name} transferred bomb to {toPlayer.Name}`)
	end)

	EventManager:Connect(EventNames.AdminCommandExecuted, function(player: Player, commandName: string, args: { string })
		self:AdminCommand(player, commandName, args)
	end)
end

function LoggingService:Info(category: string, message: string)
	print(`[${category}] {TimeUtil.UtcTimestamp()} {message}`)
end

function LoggingService:Warn(category: string, message: string)
	warn(`[{category}] {TimeUtil.UtcTimestamp()} {message}`)
end

function LoggingService:AdminCommand(player: Player, commandName: string, args: { string })
	self:Info("ADMIN", `Player: {player.Name} Command: {commandName} Args: {table.concat(args, " ")}`)
end

return LoggingService
