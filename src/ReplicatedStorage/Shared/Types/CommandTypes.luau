--!strict

export type CommandContext = {
	Executor: Player,
	Args: { string },
	Services: any,
}

export type CommandDefinition = {
	Name: string,
	Aliases: { string }?,
	Permission: string?,
	Description: string,
	Execute: (context: CommandContext) -> boolean,
}

return {}
