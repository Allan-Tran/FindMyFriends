using System.Text.Json;
using MeshMessenger.Options;
using Microsoft.Extensions.Options;
using StackExchange.Redis;

namespace MeshMessenger.Infrastructure.Redis;

public record RelayMessage(Guid Id, Guid GroupId, Guid SenderUserId, string Envelope, DateTimeOffset StoredAt);

public class RelayStore
{
    private readonly IConnectionMultiplexer _redis;
    private readonly RelayOptions _opts;

    public RelayStore(IConnectionMultiplexer redis, IOptions<RelayOptions> opts)
    {
        _redis = redis;
        _opts = opts.Value;
    }

    public async Task<RelayMessage> StoreAsync(Guid groupId, Guid senderUserId, string envelope)
    {
        var db = _redis.GetDatabase();
        var msg = new RelayMessage(Guid.NewGuid(), groupId, senderUserId, envelope, DateTimeOffset.UtcNow);
        var json = JsonSerializer.Serialize(msg);

        var ttl = TimeSpan.FromHours(_opts.MessageTtlHours);
        var msgKey = (RedisKey)$"relay:msg:{msg.Id}";
        await db.StringSetAsync(msgKey, json, ttl);

        var setKey = (RedisKey)$"relay:group:{groupId}";
        var score = msg.StoredAt.ToUnixTimeMilliseconds();
        await db.SortedSetAddAsync(setKey, msg.Id.ToString(), score);

        var cutoff = DateTimeOffset.UtcNow.AddHours(-_opts.MessageTtlHours).ToUnixTimeMilliseconds();
        await db.SortedSetRemoveRangeByScoreAsync(setKey, double.NegativeInfinity, cutoff);
        await db.KeyExpireAsync(setKey, TimeSpan.FromHours(_opts.MessageTtlHours * 2));

        return msg;
    }

    public async Task<List<RelayMessage>> FetchAsync(Guid groupId, DateTimeOffset? since)
    {
        var db = _redis.GetDatabase();
        var setKey = (RedisKey)$"relay:group:{groupId}";
        var fromScore = since.HasValue ? (double)since.Value.ToUnixTimeMilliseconds() : double.NegativeInfinity;
        var entries = await db.SortedSetRangeByScoreAsync(setKey, fromScore, double.PositiveInfinity);
        if (entries.Length == 0) return new List<RelayMessage>();

        var keys = entries.Select(e => (RedisKey)$"relay:msg:{(string)e!}").ToArray();
        var values = await db.StringGetAsync(keys);

        var result = new List<RelayMessage>(values.Length);
        for (var i = 0; i < values.Length; i++)
        {
            if (!values[i].HasValue)
            {
                await db.SortedSetRemoveAsync(setKey, entries[i]);
                continue;
            }
            try
            {
                var msg = JsonSerializer.Deserialize<RelayMessage>((string)values[i]!);
                if (msg is not null) result.Add(msg);
            }
            catch { /* ignore corrupt entries */ }
        }
        return result;
    }

    public async Task<RelayMessage?> GetAsync(Guid messageId)
    {
        var db = _redis.GetDatabase();
        var v = await db.StringGetAsync((RedisKey)$"relay:msg:{messageId}");
        if (!v.HasValue) return null;
        try { return JsonSerializer.Deserialize<RelayMessage>((string)v!); }
        catch { return null; }
    }

    public async Task DeleteAsync(Guid messageId)
    {
        var db = _redis.GetDatabase();
        var msg = await GetAsync(messageId);
        if (msg is null) return;
        await db.KeyDeleteAsync((RedisKey)$"relay:msg:{messageId}");
        await db.SortedSetRemoveAsync((RedisKey)$"relay:group:{msg.GroupId}", messageId.ToString());
    }
}
