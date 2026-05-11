using System.ComponentModel.DataAnnotations;

namespace MeshMessenger.Dtos;

public record RequestOtpDto([Required] string PhoneNumber);

public record VerifyOtpDto(
    [Required] string PhoneNumber,
    [Required] string Otp,
    string? Username);

public record RefreshDto([Required] string RefreshToken);

public record LogoutDto([Required] string RefreshToken);

public record AuthResponseDto(
    string AccessToken,
    DateTimeOffset AccessTokenExpiresAt,
    string RefreshToken,
    DateTimeOffset RefreshTokenExpiresAt,
    Guid UserId,
    string Username);
