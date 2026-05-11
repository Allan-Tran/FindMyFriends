namespace MeshMessenger.Domain.Entities;

public enum MembershipRole
{
    Member = 0,
    Admin = 1
}

public class Membership
{
    public Guid UserId { get; set; }
    public Guid GroupId { get; set; }
    public MembershipRole Role { get; set; }
    public DateTimeOffset JoinedAt { get; set; }

    public User User { get; set; } = default!;
    public Group Group { get; set; } = default!;
}
