--!strict

return {
	Name = "forcebomb",
	Aliases = {},
	Permission = "BombControl",
	Description = "Assigns the bomb to a specific player.",

	Arguments = {
		{
			Name = "target",
			Type = "player",
			Required = true,
		},
	},

	Execute = function(ctx)
		return ctx.Services:Get("BombManager"):AssignBomb(ctx.Target)
	end,
}
