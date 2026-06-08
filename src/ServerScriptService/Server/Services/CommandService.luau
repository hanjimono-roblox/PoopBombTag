--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)

local CommandService = {}
CommandService.__index = CommandService
setmetatable(CommandService, { __index = BaseService })

function CommandService.new()
	local self: any = BaseService.new("CommandService")
	self._commands = {} :: { [string]: any }
	return setmetatable(self, CommandService)
end

function CommandService:Start()
	BaseService.Start(self)
	self:DiscoverCommands(script.Parent.Parent.Commands)

	Players.PlayerAdded:Connect(function(player)
		self:HookChatCommands(player)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		self:HookChatCommands(player)
	end
end

function CommandService:DiscoverCommands(commandsFolder: Instance)
	for _, moduleScript in ipairs(commandsFolder:GetChildren()) do
		if moduleScript:IsA("ModuleScript") then
			local command = require(moduleScript)
			self:RegisterCommand(command)
		end
	end
end

function CommandService:RegisterCommand(command)
	assert(type(command.Name) == "string", "Command requires a Name")
	assert(type(command.Execute) == "function", "Command requires Execute")

	local loweredName = string.lower(command.Name)
	local selfAny = self :: any
	selfAny._commands[loweredName] = command

	for _, alias in ipairs(command.Aliases or {}) do
		selfAny._commands[string.lower(alias)] = command
	end
end

function CommandService:HookChatCommands(player: Player)
	player.Chatted:Connect(function(message)
		self:HandleChatCommand(player, message)
	end)
end

function CommandService:HandleChatCommand(player: Player, message: string): boolean
	if string.sub(message, 1, 1) ~= "!" then
		return false
	end

	local parts = string.split(string.sub(message, 2), " ")
	local commandName = table.remove(parts, 1)
	if not commandName then
		return false
	end

	return self:Execute(player, commandName, parts)
end

function CommandService:Execute(player: Player, commandName: string, args: { string }): boolean
	local selfAny = self :: any
	local command = selfAny._commands[string.lower(commandName)]
	if not command then
		return false
	end

	if not self.Services:Get("AdminService"):HasPermission(player, command.Permission) then
		self.Services:Get("LoggingService"):Warn("ADMIN", `{player.Name} lacked permission for {commandName}`)
		return false
	end

	local ok, result = pcall(command.Execute, {
		Executor = player,
		Args = args,
		Services = self.Services,
	})

	if not ok then
		self.Services:Get("LoggingService"):Warn("ADMIN", `Command {commandName} failed: {result}`)
		return false
	end

	EventManager:Fire(EventNames.AdminCommandExecuted, player, command.Name, args)
	return result == true
end

return CommandService
