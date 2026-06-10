-- !strict
return {
    Name = "announce",
    Aliases = {"say"},
    Permission = "Announcement",
    Description = "Logs an announcement placeholder for future UI broadcast.",

    Arguments = {{
        Name = "message",
        Type = "string",
        Required = true
    }},

    Execute = function(ctx)
        if ctx.Message == nil or ctx.Message == "" then
            return false
        end

        ctx.Services:Get("LoggingService"):Info("ANNOUNCE", ctx.Message)
        ctx.Services:Get("ReplicationService"):BroadcastAnnouncement(ctx.Message)
        return true
    end
}
