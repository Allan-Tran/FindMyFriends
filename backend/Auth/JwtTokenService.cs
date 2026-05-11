using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using MeshMessenger.Options;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;

namespace MeshMessenger.Auth;

public class JwtTokenService
{
    private readonly JwtOptions _opts;
    private readonly SigningCredentials _creds;

    public JwtTokenService(IOptions<JwtOptions> opts)
    {
        _opts = opts.Value;
        if (string.IsNullOrEmpty(_opts.SigningKey) || _opts.SigningKey.Length < 32)
            throw new InvalidOperationException("Jwt:SigningKey must be at least 32 characters.");
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_opts.SigningKey));
        _creds = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);
    }

    public (string Token, DateTimeOffset ExpiresAt) IssueAccessToken(Guid userId, string username)
    {
        var now = DateTimeOffset.UtcNow;
        var expires = now.AddMinutes(_opts.AccessTokenLifetimeMinutes);
        var token = new JwtSecurityToken(
            issuer: _opts.Issuer,
            audience: _opts.Audience,
            claims: new[]
            {
                new Claim(JwtRegisteredClaimNames.Sub, userId.ToString()),
                new Claim("username", username),
                new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString())
            },
            notBefore: now.UtcDateTime,
            expires: expires.UtcDateTime,
            signingCredentials: _creds);
        return (new JwtSecurityTokenHandler().WriteToken(token), expires);
    }
}
