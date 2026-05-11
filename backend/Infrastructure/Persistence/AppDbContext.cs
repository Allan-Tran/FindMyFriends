using MeshMessenger.Domain.Entities;
using Microsoft.EntityFrameworkCore;

namespace MeshMessenger.Infrastructure.Persistence;

public class AppDbContext : DbContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }

    public DbSet<User> Users => Set<User>();
    public DbSet<Group> Groups => Set<Group>();
    public DbSet<Membership> Memberships => Set<Membership>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<User>(e =>
        {
            e.ToTable("users");
            e.HasKey(x => x.Id);
            e.Property(x => x.PhoneNumberHash).IsRequired().HasMaxLength(256);
            e.Property(x => x.PhoneNumberLookup).IsRequired().HasMaxLength(8);
            e.Property(x => x.Username).IsRequired().HasMaxLength(32);
            e.Property(x => x.RefreshTokenHash).HasMaxLength(128);
            e.Property(x => x.ApnsDeviceToken).HasMaxLength(256);
            e.HasIndex(x => x.PhoneNumberHash).IsUnique();
            e.HasIndex(x => x.Username).IsUnique();
            e.HasIndex(x => x.PhoneNumberLookup);
        });

        b.Entity<Group>(e =>
        {
            e.ToTable("groups");
            e.HasKey(x => x.Id);
            e.Property(x => x.Name).IsRequired().HasMaxLength(64);
            e.Property(x => x.InviteCode).IsRequired().HasMaxLength(16);
            e.HasIndex(x => x.InviteCode).IsUnique();
        });

        b.Entity<Membership>(e =>
        {
            e.ToTable("memberships");
            e.HasKey(x => new { x.UserId, x.GroupId });
            e.HasOne(x => x.User).WithMany(u => u.Memberships).HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne(x => x.Group).WithMany(g => g.Memberships).HasForeignKey(x => x.GroupId).OnDelete(DeleteBehavior.Cascade);
            e.HasIndex(x => x.GroupId);
        });
    }
}
