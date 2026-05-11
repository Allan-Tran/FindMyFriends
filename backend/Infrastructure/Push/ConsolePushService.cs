namespace MeshMessenger.Infrastructure.Push;

public class ConsolePushService : IPushService
{
    private readonly ILogger<ConsolePushService> _log;
    public ConsolePushService(ILogger<ConsolePushService> log) => _log = log;

    public Task SendRelayNotificationAsync(IEnumerable<string> deviceTokens, Guid groupId, Guid messageId, CancellationToken ct = default)
    {
        foreach (var token in deviceTokens)
            _log.LogWarning("[DEV PUSH] token={Token} groupId={GroupId} messageId={MessageId}", token, groupId, messageId);
        return Task.CompletedTask;
    }
}
