using MeshMessenger.Auth;
using MeshMessenger.Dtos;
using MeshMessenger.Infrastructure.Persistence;
using MeshMessenger.Infrastructure.Push;
using MeshMessenger.Infrastructure.Redis;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace MeshMessenger.Controllers;

[ApiController]
[Authorize]
[Route("relay/messages")]
public class RelayController : ControllerBase
{
    private readonly AppDbContext _db;
    private readonly RelayStore _store;
    private readonly IPushService _push;
    private readonly ILogger<RelayController> _log;

    public RelayController(AppDbContext db, RelayStore store, IPushService push, ILogger<RelayController> log)
    {
        _db = db; _store = store; _push = push; _log = log;
    }

    [HttpPost]
    public async Task<IActionResult> Post([FromBody] PostRelayMessageDto dto, CancellationToken ct)
    {
        var userId = User.Id();
        var isMember = await _db.Memberships.AnyAsync(m => m.GroupId == dto.GroupId && m.UserId == userId, ct);
        if (!isMember) return Forbid();

        if (string.IsNullOrEmpty(dto.EnvelopePayload)) return BadRequest(new { error = "empty_envelope" });
        if (dto.EnvelopePayload.Length > 16 * 1024) return BadRequest(new { error = "envelope_too_large" });

        var stored = await _store.StoreAsync(dto.GroupId, userId, dto.EnvelopePayload);

        var tokens = await _db.Memberships
            .Where(m => m.GroupId == dto.GroupId && m.UserId != userId && m.User.ApnsDeviceToken != null)
            .Select(m => m.User.ApnsDeviceToken!)
            .ToListAsync(ct);

        if (tokens.Count > 0)
        {
            _ = Task.Run(async () =>
            {
                try { await _push.SendRelayNotificationAsync(tokens, dto.GroupId, stored.Id); }
                catch (Exception ex) { _log.LogWarning(ex, "Push notification failed"); }
            }, CancellationToken.None);
        }

        return Ok(ToDto(stored));
    }

    [HttpGet]
    public async Task<IActionResult> Get([FromQuery] Guid groupId, [FromQuery] DateTimeOffset? since, CancellationToken ct)
    {
        var userId = User.Id();
        var isMember = await _db.Memberships.AnyAsync(m => m.GroupId == groupId && m.UserId == userId, ct);
        if (!isMember) return Forbid();

        var messages = await _store.FetchAsync(groupId, since);
        return Ok(messages.Select(ToDto));
    }

    [HttpDelete("{messageId:guid}")]
    public async Task<IActionResult> Delete(Guid messageId, CancellationToken ct)
    {
        var userId = User.Id();
        var msg = await _store.GetAsync(messageId);
        if (msg is null) return NoContent();

        var isMember = await _db.Memberships.AnyAsync(m => m.GroupId == msg.GroupId && m.UserId == userId, ct);
        if (!isMember && msg.SenderUserId != userId) return Forbid();

        await _store.DeleteAsync(messageId);
        return NoContent();
    }

    private static RelayMessageDto ToDto(RelayMessage m) =>
        new(m.Id, m.GroupId, m.SenderUserId, m.Envelope, m.StoredAt);
}
