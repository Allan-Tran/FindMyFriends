using System.Text;
using Konscious.Security.Cryptography;
using MeshMessenger.Options;
using Microsoft.Extensions.Options;

namespace MeshMessenger.Infrastructure.Hashing;

public class PhoneNumberHasher
{
    private readonly byte[] _pepper;

    public PhoneNumberHasher(IOptions<PhoneHashOptions> opts)
    {
        var pepper = opts.Value.Pepper ?? throw new InvalidOperationException("PhoneHash:Pepper is not configured.");
        if (pepper.Length < 16)
            throw new InvalidOperationException("PhoneHash:Pepper must be at least 16 characters.");
        _pepper = Encoding.UTF8.GetBytes(pepper);
    }

    public string Hash(string phoneNumber)
    {
        var normalized = Normalize(phoneNumber);
        using var argon2 = new Argon2id(Encoding.UTF8.GetBytes(normalized))
        {
            Salt = _pepper,
            DegreeOfParallelism = 1,
            Iterations = 2,
            MemorySize = 8 * 1024
        };
        var bytes = argon2.GetBytes(32);
        return Convert.ToBase64String(bytes);
    }

    public string Lookup(string phoneNumber)
    {
        var normalized = Normalize(phoneNumber);
        return normalized.Length <= 4 ? normalized : normalized[^4..];
    }

    public static string Normalize(string phoneNumber)
    {
        if (string.IsNullOrWhiteSpace(phoneNumber))
            throw new ArgumentException("phoneNumber required", nameof(phoneNumber));
        var sb = new StringBuilder(phoneNumber.Length + 1);
        var hasPlus = phoneNumber.TrimStart().StartsWith('+');
        if (hasPlus) sb.Append('+');
        foreach (var c in phoneNumber)
            if (c >= '0' && c <= '9') sb.Append(c);
        var result = sb.ToString();
        if (result.Length < 7) throw new ArgumentException("phoneNumber too short", nameof(phoneNumber));
        return result;
    }
}
