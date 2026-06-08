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
	Name = "giveitem",
	Aliases = {},
	Permission = "Inventory",
	Description = "Grants an item through InventoryManager.",
	Execute = function(context)
		local target = findPlayer(context.Args[1] or "")
		local itemId = context.Args[2]
		if not target or not itemId then
			return false
		end

		return context.Services:Get("InventoryManager"):GrantItem(target, itemId)
	end,
}
