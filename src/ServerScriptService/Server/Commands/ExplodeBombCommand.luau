--!strict

return {
	Name = "explodebomb",
	Aliases = { "explode" },
	Permission = "BombControl",
	Description = "Forces the current bomb to explode.",

	Execute = function(ctx)
		return ctx.Services:Get("BombManager"):ExplodeBomb()
	end,
}
