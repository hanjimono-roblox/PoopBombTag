--!strict

return {
	Name = "explodebomb",
	Aliases = { "explode" },
	Permission = "BombControl",
	Description = "Forces the current bomb to explode.",
	Execute = function(context)
		return context.Services:Get("BombManager"):ExplodeBomb()
	end,
}
