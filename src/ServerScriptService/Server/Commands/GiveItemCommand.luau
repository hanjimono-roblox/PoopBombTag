--!strict

return {
	Name = "giveitem",
	Aliases = {},
	Permission = "Inventory",
	Description = "Grants an item through InventoryManager.",

	Arguments = {
		{
			Name = "target",
			Type = "player",
			Required = true,
		},
		{
			Name = "itemId",
			Type = "string",
			Required = true,
		},
	},

	Execute = function(ctx)
		return ctx.Services:Get("InventoryManager"):GrantItem(ctx.Target, ctx.itemId)
	end,
}
