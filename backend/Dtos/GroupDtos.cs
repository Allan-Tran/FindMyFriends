using System.ComponentModel.DataAnnotations;
using MeshMessenger.Domain.Entities;

namespace MeshMessenger.Dtos;

public record CreateGroupDto([Required, StringLength(64, MinimumLength = 1)] string Name);

public record GroupMemberDto(Guid UserId, string Username, MembershipRole Role, DateTimeOffset JoinedAt);

public record GroupDto(
    Guid Id,
    string Name,
    Guid AdminId,
    string InviteCode,
    DateTimeOffset CreatedAt,
    List<GroupMemberDto> Members);

public record JoinGroupDto([Required] string InviteCode);

public record UpdateMemberRoleDto([Required] MembershipRole Role);
