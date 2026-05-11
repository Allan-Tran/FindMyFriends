namespace MeshMessenger.Infrastructure.Sms;

public interface ISmsService
{
    Task SendOtpAsync(string phoneNumber, string otp, CancellationToken ct = default);
}
