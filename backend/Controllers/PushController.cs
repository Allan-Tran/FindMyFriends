using MeshMessenger.Auth;
using MeshMessenger.Dtos;
using MeshMessenger.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace MeshMessenger.Controllers;

[ApiController]
[Authorize]
[Route("push/register")]
public class PushController : ControllerBase
{
    private readonly AppDbContext _db;
    public PushController(AppDbContext db) => _db = db;

    [HttpPost]
    public async Task<IActionResult> Register([FromBody] RegisterDeviceDto dto, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(dto.DeviceToken) || dto.DeviceToken.Length > 256)
            return BadRequest(new { error = "invalid_token" });

        var userId = User.Id();
        var user = await _db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct);
        if (user is null) return Unauthorized();

        user.ApnsDeviceToken = dto.DeviceToken;
        await _db.SaveChangesAsync(ct);
        return NoContent();
    }

    [HttpDelete]
    public async Task<IActionResult> Unregister([FromBody] UnregisterDeviceDto dto, CancellationToken ct)
    {
        var userId = User.Id();
        var user = await _db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct);
        if (user is null) return Unauthorized();

        if (user.ApnsDeviceToken == dto.DeviceToken)
        {
            user.ApnsDeviceToken = null;
            await _db.SaveChangesAsync(ct);
        }
        return NoContent();
    }
}
