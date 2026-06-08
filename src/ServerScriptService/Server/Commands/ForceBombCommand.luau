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
	Name = "forcebomb",
	Aliases = {},
	Permission = "BombControl",
	Description = "Assigns the bomb to a specific player.",
	Execute = function(context)
		local target = findPlayer(context.Args[1] or "")
		if not target then
			return false
		end

		return context.Services:Get("BombManager"):AssignBomb(target)
	end,
}
