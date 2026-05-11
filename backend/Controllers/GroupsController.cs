using MeshMessenger.Auth;
using MeshMessenger.Domain.Entities;
using MeshMessenger.Dtos;
using MeshMessenger.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace MeshMessenger.Controllers;

[ApiController]
[Authorize]
[Route("groups")]
public class GroupsController : ControllerBase
{
    private readonly AppDbContext _db;
    public GroupsController(AppDbContext db) => _db = db;

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] CreateGroupDto dto, CancellationToken ct)
    {
        var userId = User.Id();
        var group = new Group
        {
            Id = Guid.NewGuid(),
            Name = dto.Name.Trim(),
            AdminId = userId,
            InviteCode = await GenerateUniqueInviteCodeAsync(ct),
            CreatedAt = DateTimeOffset.UtcNow
        };
        _db.Groups.Add(group);
        _db.Memberships.Add(new Membership
        {
            UserId = userId,
            GroupId = group.Id,
            Role = MembershipRole.Admin,
            JoinedAt = DateTimeOffset.UtcNow
        });
        await _db.SaveChangesAsync(ct);
        return CreatedAtAction(nameof(Get), new { id = group.Id }, await BuildGroupDto(group.Id, ct));
    }

    [HttpGet("{id:guid}")]
    public async Task<IActionResult> Get(Guid id, CancellationToken ct)
    {
        var userId = User.Id();
        var isMember = await _db.Memberships.AnyAsync(m => m.GroupId == id && m.UserId == userId, ct);
        if (!isMember) return NotFound();
        var dto = await BuildGroupDto(id, ct);
        return dto is null ? NotFound() : Ok(dto);
    }

    [HttpPost("{id:guid}/join")]
    public async Task<IActionResult> Join(Guid id, [FromBody] JoinGroupDto dto, CancellationToken ct)
    {
        var userId = User.Id();
        var group = await _db.Groups.FirstOrDefaultAsync(g => g.Id == id, ct);
        if (group is null) return NotFound();
        if (!string.Equals(group.InviteCode, dto.InviteCode, StringComparison.Ordinal))
            return Forbid();

        var already = await _db.Memberships.AnyAsync(m => m.GroupId == id && m.UserId == userId, ct);
        if (!already)
        {
            _db.Memberships.Add(new Membership
            {
                GroupId = id,
                UserId = userId,
                Role = MembershipRole.Member,
                JoinedAt = DateTimeOffset.UtcNow
            });
            await _db.SaveChangesAsync(ct);
        }
        return Ok(await BuildGroupDto(id, ct));
    }

    [HttpDelete("{id:guid}/members/{userId:guid}")]
    public async Task<IActionResult> RemoveMember(Guid id, Guid userId, CancellationToken ct)
    {
        var callerId = User.Id();
        var group = await _db.Groups.FirstOrDefaultAsync(g => g.Id == id, ct);
        if (group is null) return NotFound();

        var isAdmin = group.AdminId == callerId;
        var isSelf = callerId == userId;
        if (!isAdmin && !isSelf) return Forbid();
        if (userId == group.AdminId) return BadRequest(new { error = "cannot_remove_admin" });

        var membership = await _db.Memberships.FirstOrDefaultAsync(m => m.GroupId == id && m.UserId == userId, ct);
        if (membership is null) return NotFound();

        _db.Memberships.Remove(membership);
        await _db.SaveChangesAsync(ct);
        return NoContent();
    }

    [HttpPut("{id:guid}/members/{userId:guid}")]
    public async Task<IActionResult> UpdateMemberRole(Guid id, Guid userId, [FromBody] UpdateMemberRoleDto dto, CancellationToken ct)
    {
        var callerId = User.Id();
        var group = await _db.Groups.FirstOrDefaultAsync(g => g.Id == id, ct);
        if (group is null) return NotFound();
        if (group.AdminId != callerId) return Forbid();

        var membership = await _db.Memberships.FirstOrDefaultAsync(m => m.GroupId == id && m.UserId == userId, ct);
        if (membership is null) return NotFound();

        membership.Role = dto.Role;
        if (dto.Role == MembershipRole.Admin)
            group.AdminId = userId;
        await _db.SaveChangesAsync(ct);

        return Ok(await BuildGroupDto(id, ct));
    }

    [HttpDelete("{id:guid}")]
    public async Task<IActionResult> Delete(Guid id, CancellationToken ct)
    {
        var callerId = User.Id();
        var group = await _db.Groups.FirstOrDefaultAsync(g => g.Id == id, ct);
        if (group is null) return NotFound();
        if (group.AdminId != callerId) return Forbid();

        _db.Groups.Remove(group);
        await _db.SaveChangesAsync(ct);
        return NoContent();
    }

    private async Task<GroupDto?> BuildGroupDto(Guid groupId, CancellationToken ct)
    {
        var group = await _db.Groups
            .Include(g => g.Memberships)
                .ThenInclude(m => m.User)
            .FirstOrDefaultAsync(g => g.Id == groupId, ct);
        if (group is null) return null;
        var members = group.Memberships
            .Select(m => new GroupMemberDto(m.UserId, m.User.Username, m.Role, m.JoinedAt))
            .ToList();
        return new GroupDto(group.Id, group.Name, group.AdminId, group.InviteCode, group.CreatedAt, members);
    }

    private async Task<string> GenerateUniqueInviteCodeAsync(CancellationToken ct)
    {
        for (var i = 0; i < 8; i++)
        {
            var code = InviteCodeGenerator.Generate();
            if (!await _db.Groups.AnyAsync(g => g.InviteCode == code, ct))
                return code;
        }
        throw new InvalidOperationException("Could not generate unique invite code.");
    }
}
