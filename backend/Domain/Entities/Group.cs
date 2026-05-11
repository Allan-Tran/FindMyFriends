namespace MeshMessenger.Domain.Entities;

public class Group
{
    public Guid Id { get; set; }
    public string Name { get; set; } = default!;
    public Guid AdminId { get; set; }
    public string InviteCode { get; set; } = default!;
    public DateTimeOffset CreatedAt { get; set; }

    public List<Membership> Memberships { get; set; } = new();
}
