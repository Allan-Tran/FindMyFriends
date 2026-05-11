using System.Security.Cryptography;
using MeshMessenger.Auth;
using MeshMessenger.Domain.Entities;
using MeshMessenger.Dtos;
using MeshMessenger.Infrastructure.Hashing;
using MeshMessenger.Infrastructure.Persistence;
using MeshMessenger.Infrastructure.Redis;
using MeshMessenger.Infrastructure.Sms;
using MeshMessenger.Options;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace MeshMessenger.Controllers;

[ApiController]
[Route("auth")]
public class AuthController : ControllerBase
{
    private readonly AppDbContext _db;
    private readonly OtpStore _otp;
    private readonly ISmsService _sms;
    private readonly PhoneNumberHasher _phoneHasher;
    private readonly JwtTokenService _jwt;
    private readonly JwtOptions _jwtOpts;
    private readonly OtpOptions _otpOpts;
    private readonly ILogger<AuthController> _log;

    public AuthController(
        AppDbContext db,
        OtpStore otp,
        ISmsService sms,
        PhoneNumberHasher phoneHasher,
        JwtTokenService jwt,
        IOptions<JwtOptions> jwtOpts,
        IOptions<OtpOptions> otpOpts,
        ILogger<AuthController> log)
    {
        _db = db; _otp = otp; _sms = sms; _phoneHasher = phoneHasher;
        _jwt = jwt; _jwtOpts = jwtOpts.Value; _otpOpts = otpOpts.Value; _log = log;
    }

    [HttpPost("request-otp")]
    public async Task<IActionResult> RequestOtp([FromBody] RequestOtpDto dto, CancellationToken ct)
    {
        string normalized;
        try { normalized = PhoneNumberHasher.Normalize(dto.PhoneNumber); }
        catch (ArgumentException) { return BadRequest(new { error = "invalid_phone" }); }

        var phoneHash = _phoneHasher.Hash(normalized);
        var allowed = await _otp.RegisterRequestAsync(phoneHash);
        if (!allowed) return StatusCode(429, new { error = "rate_limited" });

        var otp = GenerateOtp(_otpOpts.LengthDigits);
        await _otp.StoreAsync(phoneHash, otp);
        await _sms.SendOtpAsync(normalized, otp, ct);

        return Ok(new { sent = true, expiresInMinutes = _otpOpts.LifetimeMinutes });
    }

    [HttpPost("verify-otp")]
    public async Task<IActionResult> VerifyOtp([FromBody] VerifyOtpDto dto, CancellationToken ct)
    {
        string normalized;
        try { normalized = PhoneNumberHasher.Normalize(dto.PhoneNumber); }
        catch (ArgumentException) { return BadRequest(new { error = "invalid_phone" }); }

        var phoneHash = _phoneHasher.Hash(normalized);
        var verdict = await _otp.VerifyAsync(phoneHash, dto.Otp);

        switch (verdict)
        {
            case OtpVerifyResult.Mismatch: return Unauthorized(new { error = "otp_mismatch" });
            case OtpVerifyResult.NotFound: return Unauthorized(new { error = "otp_expired" });
            case OtpVerifyResult.TooManyAttempts: return Unauthorized(new { error = "otp_locked" });
            case OtpVerifyResult.Success: break;
        }

        var user = await _db.Users.FirstOrDefaultAsync(u => u.PhoneNumberHash == phoneHash, ct);

        if (user is null)
        {
            if (string.IsNullOrWhiteSpace(dto.Username))
                return BadRequest(new { error = "username_required" });
            if (!IsValidUsername(dto.Username))
                return BadRequest(new { error = "invalid_username" });
            if (await _db.Users.AnyAsync(u => u.Username == dto.Username, ct))
                return Conflict(new { error = "username_taken" });

            user = new User
            {
                Id = Guid.NewGuid(),
                PhoneNumberHash = phoneHash,
                PhoneNumberLookup = _phoneHasher.Lookup(normalized),
                Username = dto.Username,
                CreatedAt = DateTimeOffset.UtcNow
            };
            _db.Users.Add(user);
        }

        var (access, accessExp) = _jwt.IssueAccessToken(user.Id, user.Username);
        var rawRefresh = RefreshTokenHasher.GenerateRaw();
        var refreshExp = DateTimeOffset.UtcNow.AddDays(_jwtOpts.RefreshTokenLifetimeDays);
        user.RefreshTokenHash = RefreshTokenHasher.Hash(rawRefresh);
        user.RefreshTokenExpiresAt = refreshExp;

        await _db.SaveChangesAsync(ct);

        return Ok(new AuthResponseDto(access, accessExp, rawRefresh, refreshExp, user.Id, user.Username));
    }

    [HttpPost("refresh")]
    public async Task<IActionResult> Refresh([FromBody] RefreshDto dto, CancellationToken ct)
    {
        var hash = RefreshTokenHasher.Hash(dto.RefreshToken);
        var user = await _db.Users.FirstOrDefaultAsync(u => u.RefreshTokenHash == hash, ct);
        if (user is null) return Unauthorized(new { error = "invalid_refresh" });
        if (user.RefreshTokenExpiresAt is null || user.RefreshTokenExpiresAt < DateTimeOffset.UtcNow)
            return Unauthorized(new { error = "refresh_expired" });

        var (access, accessExp) = _jwt.IssueAccessToken(user.Id, user.Username);
        var rawRefresh = RefreshTokenHasher.GenerateRaw();
        var refreshExp = DateTimeOffset.UtcNow.AddDays(_jwtOpts.RefreshTokenLifetimeDays);
        user.RefreshTokenHash = RefreshTokenHasher.Hash(rawRefresh);
        user.RefreshTokenExpiresAt = refreshExp;
        await _db.SaveChangesAsync(ct);

        return Ok(new AuthResponseDto(access, accessExp, rawRefresh, refreshExp, user.Id, user.Username));
    }

    [HttpPost("logout")]
    public async Task<IActionResult> Logout([FromBody] LogoutDto dto, CancellationToken ct)
    {
        var hash = RefreshTokenHasher.Hash(dto.RefreshToken);
        var user = await _db.Users.FirstOrDefaultAsync(u => u.RefreshTokenHash == hash, ct);
        if (user is not null)
        {
            user.RefreshTokenHash = null;
            user.RefreshTokenExpiresAt = null;
            user.ApnsDeviceToken = null;
            await _db.SaveChangesAsync(ct);
        }
        return NoContent();
    }

    private static string GenerateOtp(int length)
    {
        Span<byte> bytes = stackalloc byte[length];
        RandomNumberGenerator.Fill(bytes);
        Span<char> chars = stackalloc char[length];
        for (var i = 0; i < length; i++) chars[i] = (char)('0' + (bytes[i] % 10));
        return new string(chars);
    }

    private static bool IsValidUsername(string u)
    {
        if (u.Length is < 3 or > 32) return false;
        foreach (var c in u)
            if (!(char.IsLetterOrDigit(c) || c == '_' || c == '.')) return false;
        return true;
    }
}
