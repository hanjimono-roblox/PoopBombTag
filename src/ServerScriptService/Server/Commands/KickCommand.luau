--!strict

local function findPlayer(name: string): Player?
	for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
		if string.lower(player.Name) == string.lower(name) then
			return player
		end
	end

	return nil
end

return {
	Name = "kick",
	Aliases = {},
	Permission = "Kick",
	Description = "Kicks a player from the server.",
	Execute = function(context)
		local target = findPlayer(context.Args[1] or "")
		if not target then
			return false
		end

		target:Kick("Removed by an administrator.")
		return true
	end,
}
