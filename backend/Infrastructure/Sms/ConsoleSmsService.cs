namespace MeshMessenger.Infrastructure.Sms;

public class ConsoleSmsService : ISmsService
{
    private readonly ILogger<ConsoleSmsService> _log;
    public ConsoleSmsService(ILogger<ConsoleSmsService> log) => _log = log;

    public Task SendOtpAsync(string phoneNumber, string otp, CancellationToken ct = default)
    {
        _log.LogWarning("[DEV SMS] Phone {Phone} OTP={Otp}", phoneNumber, otp);
        return Task.CompletedTask;
    }
}
