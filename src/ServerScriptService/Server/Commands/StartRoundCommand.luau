--!strict

return {
	Name = "startround",
	Aliases = { "start" },
	Permission = "RoundControl",
	Description = "Starts a round.",

	Arguments = {
		{
			Name = "mapId",
			Type = "string",
			Required = false,
		},
	},

	Execute = function(ctx)
		return ctx.Services:Get("RoundManager"):StartRound(ctx.mapId)
	end,
}
