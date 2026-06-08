--!strict

return {
	Name = "givepoop",
	Aliases = {},
	Permission = "Poop",
	Description = "Awards poop through CurrencyManager.",

	Arguments = {
		{
			Name = "target",
			Type = "player",
			Required = true,
		},
		{
			Name = "amount",
			Type = "number",
			Required = true,
		},
	},

	Execute = function(ctx)
		return ctx.Services:Get("CurrencyManager"):AddPoop(ctx.target, ctx.amount)
	end,
}
