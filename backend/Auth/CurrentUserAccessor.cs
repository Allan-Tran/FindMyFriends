using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;

namespace MeshMessenger.Auth;

public static class CurrentUser
{
    public static Guid Id(this ClaimsPrincipal principal)
    {
        var sub = principal.FindFirstValue(JwtRegisteredClaimNames.Sub)
                  ?? principal.FindFirstValue(ClaimTypes.NameIdentifier);
        if (sub is null || !Guid.TryParse(sub, out var id))
            throw new UnauthorizedAccessException("Missing or invalid sub claim.");
        return id;
    }

    public static string Username(this ClaimsPrincipal principal) =>
        principal.FindFirstValue("username") ?? "";
}
