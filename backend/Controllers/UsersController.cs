using MeshMessenger.Dtos;
using MeshMessenger.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace MeshMessenger.Controllers;

[ApiController]
[Authorize]
[Route("users")]
public class UsersController : ControllerBase
{
    private readonly AppDbContext _db;
    public UsersController(AppDbContext db) => _db = db;

    [HttpGet("search")]
    public async Task<IActionResult> Search([FromQuery] string q, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(q) || q.Length < 2)
            return BadRequest(new { error = "query_too_short" });

        var users = await _db.Users
            .Where(u => EF.Functions.ILike(u.Username, $"{q}%"))
            .OrderBy(u => u.Username)
            .Take(20)
            .Select(u => new UserSummaryDto(u.Id, u.Username))
            .ToListAsync(ct);
        return Ok(users);
    }

    [HttpPost("contacts")]
    public async Task<IActionResult> ResolveContacts([FromBody] ContactsLookupDto dto, CancellationToken ct)
    {
        if (dto.PhoneHashes.Count == 0) return Ok(new List<ContactMatchDto>());
        if (dto.PhoneHashes.Count > 1000) return BadRequest(new { error = "too_many_hashes" });

        var hashes = dto.PhoneHashes.Distinct().ToList();
        var matches = await _db.Users
            .Where(u => hashes.Contains(u.PhoneNumberHash))
            .Select(u => new ContactMatchDto(u.PhoneNumberHash, u.Id, u.Username))
            .ToListAsync(ct);
        return Ok(matches);
    }
}
