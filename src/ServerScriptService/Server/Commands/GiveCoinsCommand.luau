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
	Name = "givecoins",
	Aliases = {},
	Permission = "Coins",
	Description = "Awards coins through CurrencyManager.",
	Execute = function(context)
		local target = findPlayer(context.Args[1] or "")
		local amount = tonumber(context.Args[2])
		if not target or not amount then
			return false
		end

		return context.Services:Get("CurrencyManager"):AddCoins(target, amount)
	end,
}
