namespace MeshMessenger.Options;

public class OtpOptions
{
    public int LengthDigits { get; set; } = 6;
    public int LifetimeMinutes { get; set; } = 10;
    public int MaxAttempts { get; set; } = 5;
    public int RateLimitWindowMinutes { get; set; } = 15;
    public int RateLimitMaxRequests { get; set; } = 3;
}

public class RelayOptions
{
    public int MessageTtlHours { get; set; } = 24;
}
