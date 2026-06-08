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
	Name = "setcoins",
	Aliases = {},
	Permission = "Coins",
	Description = "Sets a player's coins through authoritative state.",
	Execute = function(context)
		local target = findPlayer(context.Args[1] or "")
		local amount = tonumber(context.Args[2])
		if not target or not amount then
			return false
		end

		local state = context.Services:Get("PlayerManager"):GetState(target)
		if not state then
			return false
		end

		state.Coins = math.max(0, math.floor(amount))
		local profile = context.Services:Get("DataManager"):GetProfile(target)
		if profile then
			profile.Coins = state.Coins
		end

		return true
	end,
}
