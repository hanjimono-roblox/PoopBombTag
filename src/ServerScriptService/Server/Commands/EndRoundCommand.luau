--!strict

return {
	Name = "endround",
	Aliases = { "end" },
	Permission = "RoundControl",
	Description = "Ends the active round.",
	Execute = function(context)
		return context.Services:Get("RoundManager"):EndRound("AdminEnded")
	end,
}
