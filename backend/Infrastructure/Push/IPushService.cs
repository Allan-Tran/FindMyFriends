namespace MeshMessenger.Infrastructure.Push;

public interface IPushService
{
    Task SendRelayNotificationAsync(IEnumerable<string> deviceTokens, Guid groupId, Guid messageId, CancellationToken ct = default);
}
