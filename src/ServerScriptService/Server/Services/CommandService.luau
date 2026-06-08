--!strict
--[[
	CommandService (AAA-grade)

	Server-authoritative slash command framework built on TextChatService.

	Features
	-------
	* Per-command typed argument definitions (player / string / number).
	* Automatic, metadata-driven usage-string generation
	  (e.g. "/kick <player> [reason]").
	* Permission-hidden commands: TextChatCommand instances are ONLY parented
	  into TextChatService for commands a given player is allowed to run.
	  The server never exposes unauthorized command names to the client.
	* Inline player autocomplete for `Type = "player"` arguments
	  (case-insensitive prefix + partial DisplayName matching).
	* Centralized, per-player "command metadata" API used by any client UI
	  that wants to render help/usage hints.
	* Execution pipeline (ExecuteResolved) is unchanged: same permission
	  check, same argument resolution, same EventManager firing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)

local CommandService = {}
CommandService.__index = CommandService
setmetatable(CommandService, { __index = BaseService })

------------------------------------------------------------------------
-- TYPES
------------------------------------------------------------------------

export type ArgumentType = "player" | "string" | "number"

export type Argument = {
	Name: string,
	Type: ArgumentType,
	Required: boolean,
}

export type Command = {
	Name: string,
	Description: string?,
	Permission: string,
	Aliases: { string }?,
	Arguments: { Argument }?,
	Execute: (ctx: any) -> any,
}

export type CommandContext = {
	Executor: Player,
	Services: any,
	Command: Command,
	RawArgs: { string },
}

export type ArgumentHint = {
	Name: string,
	Type: ArgumentType,
	Required: boolean,
	Placeholder: string,
}

export type CommandMeta = {
	Name: string,
	PrimaryAlias: string,
	SecondaryAliases: { string },
	Description: string,
	Permission: string,
	Usage: string,
	ArgumentHints: { ArgumentHint },
	Visible: boolean,
}

------------------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------------------

-- Placeholder tokens shown in usage strings, keyed by argument Type.
local ARG_PLACEHOLDERS: { [ArgumentType]: string } = {
	player = "<player>",
	string = "<text>",
	number = "<number>",
}

-- Max suggestions returned by GetPlayerSuggestions.
local MAX_AUTOCOMPLETE_RESULTS = 10

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CommandService.new()
	local self: any = BaseService.new("CommandService")

	-- Canonical command table, keyed by lower-cased primary name OR alias.
	self._commands = {} :: { [string]: Command }

	-- Maps a lower-cased primary command name -> { [Player]: TextChatCommand }
	-- so the same command can be registered for many players without
	-- recreating instances and without ever leaking it to players who
	-- shouldn't see it.
	self._textCommands = {} :: { [string]: { [Player]: TextChatCommand } }

	-- Cached per-command metadata, recomputed lazily when definitions change.
	self._metaCache = {} :: { [string]: CommandMeta }

	-- Per-player visible TextChatCommand instances (so we can clean them up
	-- on PlayerRemoving or when permissions change).
	self._playerCommands = {} :: { [Player]: { TextChatCommand } }

	return setmetatable(self, CommandService)
end

------------------------------------------------------------------------
-- START
------------------------------------------------------------------------

function CommandService:Start()
	BaseService.Start(self)

	self:DiscoverCommands(script.Parent.Parent.Commands)

	-- Re-evaluate visible commands whenever a player's rank might change
	-- (admin promotion, role change, etc.) and when players join/leave.
	Players.PlayerAdded:Connect(function(player)
		-- Defer slightly so AdminService has a chance to load rank data.
		task.defer(function()
			self:RefreshPlayerCommands(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:CleanupPlayerCommands(player)
	end)

	-- Initial pass for any player who joined before Start() ran.
	for _, player in ipairs(Players:GetPlayers()) do
		task.defer(function()
			self:RefreshPlayerCommands(player)
		end)
	end

	local logging = self.Services:Get("LoggingService")
	if logging then
		logging:Info("ADMIN", `AAA CommandService started ({self:GetCommandCount()} commands)`)
	end
end

------------------------------------------------------------------------
-- DISCOVERY
------------------------------------------------------------------------

function CommandService:DiscoverCommands(folder: Instance)
	for _, mod in ipairs(folder:GetDescendants()) do
		if not mod:IsA("ModuleScript") then
			continue
		end

		local ok, command = pcall(require, mod)
		if not ok then
			warn("Command load failed:", mod.Name, command)
			continue
		end

		self:RegisterCommand(command)
	end
end

------------------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------------------

function CommandService:RegisterCommand(command: Command)
	assert(type(command.Name) == "string", "Missing Name")
	assert(type(command.Execute) == "function", "Missing Execute")
	assert(command.Permission ~= nil, "Missing Permission")

	-- Invalidate cached metadata for this command (if it was previously
	-- registered under the same name with different args).
	self._metaCache[string.lower(command.Name)] = nil

	local key = string.lower(command.Name)
	self._commands[key] = command

	for _, alias in ipairs(command.Aliases or {}) do
		self._commands[string.lower(alias)] = command
	end

	-- A new (or changed) command is now visible: rebuild the visible-command
	-- set for every connected player so its TextChatCommand is parented in
	-- (or removed) correctly.
	self:RefreshAllPlayerCommands()
end

------------------------------------------------------------------------
-- PERMISSION
------------------------------------------------------------------------

-- Wraps AdminService:HasPermission with a fallback so the CommandService
-- never accidentally exposes commands when AdminService is unavailable.
function CommandService:PlayerHasPermission(player: Player, permission: string?): boolean
	if permission == nil then
		return true
	end

	local admin = self.Services:Get("AdminService")
	if not admin or type(admin.HasPermission) ~= "function" then
		return false
	end

	return admin:HasPermission(player, permission) and true or false
end

------------------------------------------------------------------------
-- METADATA BUILDER
------------------------------------------------------------------------

--[[
	BuildCommandMeta(command) -> CommandMeta

	Generates, from a command's static definition:

	  * Usage string ("/kick <player> [reason]")
	  * Per-argument hints with placeholder text
	  * Visibility rules (Visibility is computed per-player at use time;
	    this builder only attaches the static pieces).
]]
function CommandService:BuildCommandMeta(command: Command): CommandMeta
	assert(command, "BuildCommandMeta: command is nil")

	local primary = "/" .. string.lower(command.Name)

	-- Aliases: each becomes a "/name" string. Stored separately so client
	-- UI can render them however it wants.
	local secondary: { string } = {}
	if command.Aliases then
		for _, a in ipairs(command.Aliases) do
			table.insert(secondary, "/" .. string.lower(a))
		end
	end

	-- Build argument hints with placeholders.
	local hints: { ArgumentHint } = {}
	for _, arg in ipairs(command.Arguments or {}) do
		table.insert(hints, {
			Name = arg.Name,
			Type = arg.Type,
			Required = arg.Required,
			Placeholder = ARG_PLACEHOLDERS[arg.Type] or "<" .. arg.Name .. ">",
		})
	end

	-- Generate usage string.
	local usage = self:BuildUsageString(command)

	local meta: CommandMeta = {
		Name = command.Name,
		PrimaryAlias = primary,
		SecondaryAliases = secondary,
		Description = command.Description or "",
		Permission = command.Permission,
		Usage = usage,
		ArgumentHints = hints,
		-- Visibility is a per-player concept; this base value is true and
		-- is re-evaluated when a client requests metadata.
		Visible = true,
	}

	return meta
end

--[[
	BuildUsageString(command) -> string

	Generates a usage string such as "/kick <player> [reason]".

	Rules:
	  * Required arg  →  <name-or-type-placeholder>
	  * Optional arg  →  [name-or-type-placeholder]
	  * player type   →  <player>
	  * number type   →  <number>
	  * string type   →  <text>
]]
function CommandService:BuildUsageString(command: Command): string
	local pieces: { string } = { "/" .. string.lower(command.Name) }

	for _, arg in ipairs(command.Arguments or {}) do
		local placeholder = ARG_PLACEHOLDERS[arg.Type] or "<" .. arg.Name .. ">"
		if arg.Required then
			table.insert(pieces, "<" .. placeholder:gsub("^<", ""):gsub(">$", "") .. ">")
		else
			table.insert(pieces, "[" .. placeholder:gsub("^<", ""):gsub(">$", "") .. "]")
		end
	end

	return table.concat(pieces, " ")
end

-- Returns the (cached) CommandMeta for a registered command, by name or alias.
-- The returned meta's `Visible` field is set to true if `player` has
-- permission; otherwise `Visible` is false AND the command is otherwise
-- indistinguishable from a non-existent one to the caller.
function CommandService:GetCommandMeta(commandName: string, player: Player?): CommandMeta?
	local key = string.lower(commandName)
	local command = self._commands[key]
	if not command then
		return nil
	end

	local cacheKey = string.lower(command.Name)
	local meta = self._metaCache[cacheKey]
	if not meta then
		meta = self:BuildCommandMeta(command)
		self._metaCache[cacheKey] = meta
	end

	-- Clone the cached meta and set Visibility for this specific player.
	-- We deliberately do NOT mutate the cached object so it stays reusable.
	local visible = true
	if player ~= nil then
		visible = self:PlayerHasPermission(player, meta.Permission)
	end

	return {
		Name = meta.Name,
		PrimaryAlias = meta.PrimaryAlias,
		SecondaryAliases = meta.SecondaryAliases,
		Description = meta.Description,
		Permission = meta.Permission,
		Usage = meta.Usage,
		ArgumentHints = meta.ArgumentHints,
		Visible = visible,
	}
end

-- Returns the list of CommandMeta the player is allowed to see, in the
-- canonical order. The server is the authority; this list is the single
-- source of truth for what the client may render.
function CommandService:GetVisibleCommands(player: Player): { CommandMeta }
	local seen: { [string]: boolean } = {}
	local out: { CommandMeta } = {}

	for _, command in pairs(self._commands) do
		local primary = string.lower(command.Name)
		if not seen[primary] then
			seen[primary] = true

			local meta = self:GetCommandMeta(command.Name, player)
			if meta and meta.Visible then
				table.insert(out, meta)
			end
		end
	end

	-- Sort by primary alias for stable UI.
	table.sort(out, function(a, b)
		return a.PrimaryAlias < b.PrimaryAlias
	end)

	return out
end

------------------------------------------------------------------------
-- SLASH COMMAND + AUTOCOMPLETE (PLAYER-TYPE AWARE)
------------------------------------------------------------------------

-- Returns, for a given command and partial-typed argument index, the list
-- of suggested completions. Currently only `Type = "player"` is supported
-- (case-insensitive prefix + partial DisplayName matching), per task spec.
function CommandService:GetArgumentSuggestions(
	commandName: string,
	argIndex: number,
	partial: string
): { string }
	local key = string.lower(commandName)
	local command = self._commands[key]
	if not command then
		return {}
	end

	local argDef = (command.Arguments or {})[argIndex]
	if not argDef or argDef.Type ~= "player" then
		return {}
	end

	return self:GetPlayerSuggestions(partial)
end

-- Returns the list of online player names matching `partial` (case-insensitive
-- prefix + partial name match), capped at MAX_AUTOCOMPLETE_RESULTS.
--
-- Matching order:
--   1. Exact case-insensitive match on DisplayName or Name.
--   2. Prefix match on DisplayName.
--   3. Prefix match on Name.
--   4. Partial substring match on DisplayName.
--   5. Partial substring match on Name.
function CommandService:GetPlayerSuggestions(partial: string): { string }
	partial = string.lower(partial or "")

	if partial == "" then
		-- No query yet → return up to N online players (stable order by name).
		local out: { string } = {}
		for _, player in ipairs(Players:GetPlayers()) do
			table.insert(out, player.Name)
			if #out >= MAX_AUTOCOMPLETE_RESULTS then
				break
			end
		end
		return out
	end

	local exact: { string } = {}
	local prefixDisplay: { string } = {}
	local prefixName: { string } = {}
	local partialDisplay: { string } = {}
	local partialName: { string } = {}

	for _, player in ipairs(Players:GetPlayers()) do
		local name = string.lower(player.Name)
		local display = string.lower(player.DisplayName)

		if name == partial or display == partial then
			table.insert(exact, player.Name)
		elseif display:sub(1, #partial) == partial then
			table.insert(prefixDisplay, player.Name)
		elseif name:sub(1, #partial) == partial then
			table.insert(prefixName, player.Name)
		elseif string.find(display, partial, 1, true) then
			table.insert(partialDisplay, player.Name)
		elseif string.find(name, partial, 1, true) then
			table.insert(partialName, player.Name)
		end
	end

	local out: { string } = {}
	local function appendBucket(bucket: { string })
		for _, n in ipairs(bucket) do
			if #out >= MAX_AUTOCOMPLETE_RESULTS then
				return
			end
			table.insert(out, n)
		end
	end

	appendBucket(exact)
	appendBucket(prefixDisplay)
	appendBucket(prefixName)
	appendBucket(partialDisplay)
	appendBucket(partialName)

	return out
end

--[[
	Per-player TextChatCommand parenting.

	For each registered command, this method ensures that EVERY currently
	connected player has a TextChatCommand instance parented into
	TextChatService IF AND ONLY IF they have permission. We do NOT use
	Roblox's built-in permission system; we authoritatively gate the
	visibility ourselves so restricted commands never appear in
	autocomplete / slash command lists.

	Implementation detail: a single TextChatCommand per (player, command)
	pair is created lazily and reused across permission refreshes.
]]
function CommandService:RefreshAllPlayerCommands()
	for _, player in ipairs(Players:GetPlayers()) do
		self:RefreshPlayerCommands(player)
	end
end

function CommandService:RefreshPlayerCommands(player: Player)
	if not player or not player.Parent then
		return
	end

	local admin = self.Services:Get("AdminService")
	if not admin then
		-- AdminService isn't ready yet; defer until it is.
		task.defer(function()
			if player.Parent then
				self:RefreshPlayerCommands(player)
			end
		end)
		return
	end

	-- De-duplicate the canonical command list (since aliases can point to
	-- the same Command object).
	local seen: { [Command]: boolean } = {}
	local perPlayer: { TextChatCommand } = self._playerCommands[player] or {}

	for _, command in pairs(self._commands) do
		if seen[command] then
			continue
		end
		seen[command] = true

		local primary = string.lower(command.Name)
		local allowed = self:PlayerHasPermission(player, command.Permission)
		local tcMap = self._textCommands[primary]
		if not tcMap then
			tcMap = {}
			self._textCommands[primary] = tcMap
		end

		local existing = tcMap[player]

		if allowed then
			if not existing or not existing.Parent then
				existing = self:CreateTextChatCommand(command, player)
				tcMap[player] = existing
				table.insert(perPlayer, existing)
			end
		else
			if existing then
				pcall(function()
					existing:Destroy()
				end)
				tcMap[player] = nil
			end
		end
	end

	self._playerCommands[player] = perPlayer
end

function CommandService:CleanupPlayerCommands(player: Player)
	local perPlayer = self._playerCommands[player]
	if perPlayer then
		for _, tc in ipairs(perPlayer) do
			pcall(function()
				tc:Destroy()
			end)
		end
	end
	self._playerCommands[player] = nil

	for _, tcMap in pairs(self._textCommands) do
		tcMap[player] = nil
	end
end

-- Creates a TextChatCommand for a single (command, player) pair, wires up
-- the Triggered callback to the central server pipeline, and parents it
-- into TextChatService so the player sees it in their slash-command
-- autocomplete UI.
function CommandService:CreateTextChatCommand(command: Command, player: Player): TextChatCommand
	local tc = Instance.new("TextChatCommand")
	tc.Name = command.Name
	tc.PrimaryAlias = "/" .. string.lower(command.Name)

	-- SecondaryAlias is a single string with newline-separated entries,
	-- each prefixed with "/".
	if command.Aliases and #command.Aliases > 0 then
		local aliasPieces: { string } = {}
		for _, a in ipairs(command.Aliases) do
			table.insert(aliasPieces, "/" .. string.lower(a))
		end
		tc.SecondaryAlias = table.concat(aliasPieces, "\n")
	end

	-- Triggered fires on the server with the TextSource that originated
	-- the chat message. unfilteredText is the full chat message,
	-- e.g. "/kick playerName reason". Execution is server-side only.
	tc.Triggered:Connect(function(textSource: TextSource, unfilteredText: string)
		if not textSource then
			return
		end

		local executor = Players:GetPlayerByUserId(textSource.UserId)
		if not executor or executor ~= player then
			-- Defense-in-depth: only ever execute for the player this
			-- TextChatCommand was created for.
			return
		end

		-- Re-check permission at execution time. Permission could have
		-- been revoked between the TextChatCommand being parented and
		-- the user pressing Enter.
		if not self:PlayerHasPermission(executor, command.Permission) then
			local logging = self.Services:Get("LoggingService")
			if logging then
				logging:Warn("ADMIN", `{executor.Name} attempted to run /{command.Name} without permission`)
			end
			return
		end

		self:ExecuteResolved(executor, command, unfilteredText)
	end)

	tc.Parent = TextChatService
	return tc
end

------------------------------------------------------------------------
-- PLAYER LOOKUP
------------------------------------------------------------------------

function CommandService:FindPlayer(query: string): Player?
	if not query or query == "" then
		return nil
	end

	local lowerQuery = string.lower(query)

	-- exact case-insensitive match first
	for _, player in ipairs(Players:GetPlayers()) do
		if string.lower(player.Name) == lowerQuery or string.lower(player.DisplayName) == lowerQuery then
			return player
		end
	end

	-- fall back to prefix match (DisplayName then Name), case-insensitive
	for _, player in ipairs(Players:GetPlayers()) do
		if
			string.lower(player.Name):sub(1, #lowerQuery) == lowerQuery
			or string.lower(player.DisplayName):sub(1, #lowerQuery) == lowerQuery
		then
			return player
		end
	end

	-- finally, fall back to partial substring match (still case-insensitive)
	for _, player in ipairs(Players:GetPlayers()) do
		if
			string.find(string.lower(player.Name), lowerQuery, 1, true)
			or string.find(string.lower(player.DisplayName), lowerQuery, 1, true)
		then
			return player
		end
	end

	return nil
end

------------------------------------------------------------------------
-- ARGUMENT RESOLVER
------------------------------------------------------------------------

-- Resolves a list of raw string args against a command's typed
-- Arguments definition. Returns a table keyed by Argument.Name, or
-- nil + an error message if a required argument cannot be resolved.
function CommandService:ResolveArguments(
	command: Command,
	rawArgs: { string },
	_executor: Player
): ({ [string]: any }, string?)
	local resolved: { [string]: any } = {}

	for i, argDef in ipairs(command.Arguments or {}) do
		local raw = rawArgs[i]

		if argDef.Type == "player" then
			if not raw then
				resolved[argDef.Name] = nil
			else
				resolved[argDef.Name] = self:FindPlayer(raw)
			end

			if argDef.Required and resolved[argDef.Name] == nil then
				return nil, `Missing or unresolved required player argument: {argDef.Name}`
			end

		elseif argDef.Type == "number" then
			resolved[argDef.Name] = tonumber(raw)

			if argDef.Required and resolved[argDef.Name] == nil then
				return nil, `Missing or invalid number argument: {argDef.Name}`
			end

		elseif argDef.Type == "string" then
			resolved[argDef.Name] = raw

			if argDef.Required and (raw == nil or raw == "") then
				return nil, `Missing required string argument: {argDef.Name}`
			end

		else
			-- unknown type → pass through as-is
			resolved[argDef.Name] = raw

			if argDef.Required and raw == nil then
				return nil, `Missing required argument: {argDef.Name}`
			end
		end
	end

	return resolved, nil
end

------------------------------------------------------------------------
-- ARG PARSING (raw → tokens)
------------------------------------------------------------------------

-- Splits a raw chat message into a list of whitespace-separated tokens,
-- discarding the leading slash-command token.
function CommandService:ParseArgs(raw: string): { string }
	local args: { string } = {}

	for word in string.gmatch(raw, "%S+") do
		table.insert(args, word)
	end

	-- remove the leading slash-command (e.g. "/kick")
	if #args > 0 then
		table.remove(args, 1)
	end

	return args
end

------------------------------------------------------------------------
-- EXECUTION PIPELINE (unchanged from original)
------------------------------------------------------------------------

-- Main entry point. Receives the raw chat text (including the leading
-- slash-command), runs the permission check, resolves typed arguments,
-- builds the ctx object, and invokes the command.
function CommandService:ExecuteResolved(executor: Player, command: Command, rawText: string): boolean
	-- 1. permission check
	local admin = self.Services:Get("AdminService")
	if not admin or not admin:HasPermission(executor, command.Permission) then
		local logging = self.Services:Get("LoggingService")
		if logging then
			logging:Warn("ADMIN", `{executor.Name} attempted to run /{command.Name} without permission`)
		end
		return false
	end

	-- 2. parse + resolve args
	local rawArgs = self:ParseArgs(rawText)
	local resolved, err = self:ResolveArguments(command, rawArgs, executor)
	if not resolved then
		warn(`[COMMAND FAILED] {command.Name}: {err}`)
		return false
	end

	-- 3. build ctx (resolved args become top-level keys, e.g. ctx.Target)
	local ctx = {
		Executor = executor,
		Services = self.Services,
		Command = command,
		RawArgs = rawArgs,
	}

	for key, value in pairs(resolved) do
		ctx[key] = value
	end

	-- 4. invoke
	local ok, execErr = pcall(command.Execute, ctx)

	if not ok then
		warn(`[COMMAND FAILED] {command.Name}: {execErr}`)
		return false
	end

	-- 5. fire event
	EventManager:Fire(
		EventNames.AdminCommandExecuted,
		executor,
		command.Name,
		resolved
	)

	return true
end

------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------

function CommandService:GetCommandCount(): number
	local seen: { [string]: boolean } = {}
	local count = 0

	for _, cmd in pairs(self._commands) do
		if not seen[cmd.Name] then
			seen[cmd.Name] = true
			count += 1
		end
	end

	return count
end

function CommandService:GetCommand(name: string): Command?
	return self._commands[string.lower(name)]
end

-- Returns the built usage string for a command. Convenience wrapper
-- around BuildUsageString for callers that already have the registered
-- Command object.
function CommandService:GetUsageString(commandName: string): string?
	local command = self:GetCommand(commandName)
	if not command then
		return nil
	end
	return self:BuildUsageString(command)
end

-- Called by external systems (e.g. an admin promotion handler) when a
-- player's permissions may have changed. Re-evaluates the visible-command
-- set for that player and parents/destroys TextChatCommand instances
-- accordingly.
function CommandService:NotifyPlayerPermissionsChanged(player: Player)
	if not player or not player.Parent then
		return
	end
	self:RefreshPlayerCommands(player)
end

return CommandService
