--!strict

return {
	Name = "setpoop",
	Aliases = {},
	Permission = "Poop",
	Description = "Sets a player's poop through authoritative state.",

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
		local state = ctx.Services:Get("PlayerManager"):GetState(ctx.Target)
		if not state then
			return false
		end

		local dataManager = ctx.Services:Get("DataManager")
		state.Poop = math.max(0, math.floor(ctx.Amount))
		local profile = dataManager:GetProfile(ctx.Target)
		if profile then
			profile.Poop = state.Poop
			dataManager:MarkDirty(ctx.Target)
		end

		-- Route the leaderstats sync through CurrencyManager so this
		-- command (and any other admin commands that mutate state.Poop
		-- directly) stay in lockstep with the in-game leaderboard.
		ctx.Services:Get("CurrencyManager"):SyncLeaderstats(ctx.Target, state.Poop)

		return true
	end,
}
