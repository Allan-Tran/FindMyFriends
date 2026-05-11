using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MeshMessenger.Options;
using Microsoft.Extensions.Options;

namespace MeshMessenger.Infrastructure.Push;

public class ApnsPushService : IPushService, IDisposable
{
    private readonly ApnsOptions _opts;
    private readonly ILogger<ApnsPushService> _log;
    private readonly HttpClient _http;
    private readonly ECDsa _ecdsa;
    private readonly SemaphoreSlim _jwtLock = new(1, 1);
    private string? _cachedJwt;
    private DateTimeOffset _jwtExpiresAt;

    public ApnsPushService(IOptions<ApnsOptions> opts, ILogger<ApnsPushService> log)
    {
        _opts = opts.Value;
        _log = log;

        var pem = File.ReadAllText(_opts.PrivateKeyPath);
        _ecdsa = ECDsa.Create();
        _ecdsa.ImportFromPem(pem);

        var host = _opts.UseSandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
        _http = new HttpClient(new SocketsHttpHandler
        {
            EnableMultipleHttp2Connections = true
        })
        {
            BaseAddress = new Uri(host),
            DefaultRequestVersion = HttpVersion.Version20,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionExact
        };
    }

    public async Task SendRelayNotificationAsync(IEnumerable<string> deviceTokens, Guid groupId, Guid messageId, CancellationToken ct = default)
    {
        var jwt = await GetJwtAsync();
        var payload = JsonSerializer.Serialize(new
        {
            aps = new { content_available = 1 },
            groupId = groupId.ToString(),
            messageId = messageId.ToString()
        }).Replace("content_available", "content-available");

        foreach (var token in deviceTokens.Distinct())
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Post, $"/3/device/{token}")
                {
                    Version = HttpVersion.Version20,
                    VersionPolicy = HttpVersionPolicy.RequestVersionExact,
                    Content = new StringContent(payload, Encoding.UTF8, "application/json")
                };
                req.Headers.Authorization = new AuthenticationHeaderValue("bearer", jwt);
                req.Headers.TryAddWithoutValidation("apns-topic", _opts.BundleId);
                req.Headers.TryAddWithoutValidation("apns-push-type", "background");
                req.Headers.TryAddWithoutValidation("apns-priority", "5");

                using var resp = await _http.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode)
                {
                    var body = await resp.Content.ReadAsStringAsync(ct);
                    _log.LogWarning("APNs push failed token={Token} status={Status} body={Body}",
                        token, resp.StatusCode, body);
                }
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "APNs push exception token={Token}", token);
            }
        }
    }

    private async Task<string> GetJwtAsync()
    {
        if (_cachedJwt is not null && DateTimeOffset.UtcNow < _jwtExpiresAt)
            return _cachedJwt;

        await _jwtLock.WaitAsync();
        try
        {
            if (_cachedJwt is not null && DateTimeOffset.UtcNow < _jwtExpiresAt)
                return _cachedJwt;

            var now = DateTimeOffset.UtcNow;
            var header = new { alg = "ES256", kid = _opts.KeyId, typ = "JWT" };
            var claims = new { iss = _opts.TeamId, iat = now.ToUnixTimeSeconds() };
            var headerB64 = Base64Url(JsonSerializer.SerializeToUtf8Bytes(header));
            var claimsB64 = Base64Url(JsonSerializer.SerializeToUtf8Bytes(claims));
            var signingInput = $"{headerB64}.{claimsB64}";
            var sig = _ecdsa.SignData(Encoding.ASCII.GetBytes(signingInput), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
            _cachedJwt = $"{signingInput}.{Base64Url(sig)}";
            _jwtExpiresAt = now.AddMinutes(50);
            return _cachedJwt;
        }
        finally { _jwtLock.Release(); }
    }

    private static string Base64Url(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public void Dispose()
    {
        _http.Dispose();
        _ecdsa.Dispose();
        _jwtLock.Dispose();
    }
}
