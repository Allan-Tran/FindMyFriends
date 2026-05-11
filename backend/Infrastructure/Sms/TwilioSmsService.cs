using MeshMessenger.Options;
using Microsoft.Extensions.Options;
using Twilio;
using Twilio.Rest.Api.V2010.Account;
using Twilio.Types;

namespace MeshMessenger.Infrastructure.Sms;

public class TwilioSmsService : ISmsService
{
    private readonly TwilioOptions _opts;
    private readonly ILogger<TwilioSmsService> _log;

    public TwilioSmsService(IOptions<TwilioOptions> opts, ILogger<TwilioSmsService> log)
    {
        _opts = opts.Value;
        _log = log;
        TwilioClient.Init(_opts.AccountSid, _opts.AuthToken);
    }

    public async Task SendOtpAsync(string phoneNumber, string otp, CancellationToken ct = default)
    {
        var msg = await MessageResource.CreateAsync(
            to: new PhoneNumber(phoneNumber),
            from: new PhoneNumber(_opts.FromNumber),
            body: $"Your Mesh Messenger code is {otp}. Expires in 10 minutes.");
        _log.LogInformation("Sent OTP via Twilio sid={Sid} status={Status}", msg.Sid, msg.Status);
    }
}
