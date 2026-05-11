namespace MeshMessenger.Domain.Entities;

public class User
{
    public Guid Id { get; set; }
    public string PhoneNumberHash { get; set; } = default!;
    public string PhoneNumberLookup { get; set; } = default!;
    public string Username { get; set; } = default!;
    public string? RefreshTokenHash { get; set; }
    public DateTimeOffset? RefreshTokenExpiresAt { get; set; }
    public string? ApnsDeviceToken { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    public List<Membership> Memberships { get; set; } = new();
}
