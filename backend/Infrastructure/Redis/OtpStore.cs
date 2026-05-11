using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MeshMessenger.Options;
using Microsoft.Extensions.Options;
using StackExchange.Redis;

namespace MeshMessenger.Infrastructure.Redis;

public class OtpStore
{
    private readonly IConnectionMultiplexer _redis;
    private readonly OtpOptions _opts;

    public OtpStore(IConnectionMultiplexer redis, IOptions<OtpOptions> opts)
    {
        _redis = redis;
        _opts = opts.Value;
    }

    public async Task<bool> RegisterRequestAsync(string phoneHash)
    {
        var db = _redis.GetDatabase();
        var key = (RedisKey)$"otp:rate:{phoneHash}";
        var count = await db.StringIncrementAsync(key);
        if (count == 1)
            await db.KeyExpireAsync(key, TimeSpan.FromMinutes(_opts.RateLimitWindowMinutes));
        return count <= _opts.RateLimitMaxRequests;
    }

    public async Task StoreAsync(string phoneHash, string otp)
    {
        var db = _redis.GetDatabase();
        var record = new OtpRecord(HashOtp(otp), 0);
        var json = JsonSerializer.Serialize(record);
        await db.StringSetAsync(
            (RedisKey)$"otp:{phoneHash}",
            json,
            TimeSpan.FromMinutes(_opts.LifetimeMinutes));
    }

    public async Task<OtpVerifyResult> VerifyAsync(string phoneHash, string otp)
    {
        var db = _redis.GetDatabase();
        var key = (RedisKey)$"otp:{phoneHash}";
        var value = await db.StringGetAsync(key);
        if (!value.HasValue) return OtpVerifyResult.NotFound;

        OtpRecord? record;
        try { record = JsonSerializer.Deserialize<OtpRecord>((string)value!); }
        catch { record = null; }
        if (record is null) return OtpVerifyResult.NotFound;

        var providedHash = HashOtp(otp);
        if (CryptographicOperations.FixedTimeEquals(
                Encoding.ASCII.GetBytes(providedHash),
                Encoding.ASCII.GetBytes(record.OtpHash)))
        {
            await db.KeyDeleteAsync(key);
            return OtpVerifyResult.Success;
        }

        var attempts = record.Attempts + 1;
        if (attempts >= _opts.MaxAttempts)
        {
            await db.KeyDeleteAsync(key);
            return OtpVerifyResult.TooManyAttempts;
        }

        var updated = JsonSerializer.Serialize(record with { Attempts = attempts });
        var ttl = await db.KeyTimeToLiveAsync(key);
        await db.StringSetAsync(key, updated, ttl);
        return OtpVerifyResult.Mismatch;
    }

    private static string HashOtp(string otp)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(otp));
        return Convert.ToHexString(bytes);
    }

    private record OtpRecord(string OtpHash, int Attempts);
}

public enum OtpVerifyResult
{
    Success,
    Mismatch,
    NotFound,
    TooManyAttempts
}
