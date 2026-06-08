--!strict

return {
	Name = "endround",
	Aliases = { "end" },
	Permission = "RoundControl",
	Description = "Ends the active round.",

	Execute = function(ctx)
		return ctx.Services:Get("RoundManager"):EndRound("AdminEnded")
	end,
}
