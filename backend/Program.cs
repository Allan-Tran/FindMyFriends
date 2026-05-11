using System.Text;
using MeshMessenger.Auth;
using MeshMessenger.Infrastructure.Hashing;
using MeshMessenger.Infrastructure.Persistence;
using MeshMessenger.Infrastructure.Push;
using MeshMessenger.Infrastructure.Redis;
using MeshMessenger.Infrastructure.Sms;
using MeshMessenger.Options;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);

builder.Services.Configure<JwtOptions>(builder.Configuration.GetSection("Jwt"));
builder.Services.Configure<PhoneHashOptions>(builder.Configuration.GetSection("PhoneHash"));
builder.Services.Configure<OtpOptions>(builder.Configuration.GetSection("Otp"));
builder.Services.Configure<RelayOptions>(builder.Configuration.GetSection("Relay"));
builder.Services.Configure<TwilioOptions>(builder.Configuration.GetSection("Twilio"));
builder.Services.Configure<ApnsOptions>(builder.Configuration.GetSection("Apns"));

builder.Services.AddDbContext<AppDbContext>(opts =>
    opts.UseNpgsql(builder.Configuration.GetConnectionString("Postgres")));

builder.Services.AddSingleton<IConnectionMultiplexer>(_ =>
    ConnectionMultiplexer.Connect(builder.Configuration.GetConnectionString("Redis")
        ?? throw new InvalidOperationException("Missing ConnectionStrings:Redis")));

builder.Services.AddSingleton<PhoneNumberHasher>();
builder.Services.AddSingleton<JwtTokenService>();
builder.Services.AddSingleton<OtpStore>();
builder.Services.AddSingleton<RelayStore>();

var twilio = builder.Configuration.GetSection("Twilio").Get<TwilioOptions>() ?? new TwilioOptions();
if (twilio.IsConfigured)
    builder.Services.AddSingleton<ISmsService, TwilioSmsService>();
else
    builder.Services.AddSingleton<ISmsService, ConsoleSmsService>();

var apns = builder.Configuration.GetSection("Apns").Get<ApnsOptions>() ?? new ApnsOptions();
if (apns.IsConfigured)
    builder.Services.AddSingleton<IPushService, ApnsPushService>();
else
    builder.Services.AddSingleton<IPushService, ConsolePushService>();

var jwt = builder.Configuration.GetSection("Jwt").Get<JwtOptions>()
          ?? throw new InvalidOperationException("Jwt section missing");

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        o.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            ValidIssuer = jwt.Issuer,
            ValidAudience = jwt.Audience,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwt.SigningKey)),
            ClockSkew = TimeSpan.FromSeconds(30)
        };
    });
builder.Services.AddAuthorization();

builder.Services.AddControllers()
    .ConfigureApiBehaviorOptions(opts =>
    {
        opts.InvalidModelStateResponseFactory = ctx =>
            new BadRequestObjectResult(new
            {
                error = "validation_failed",
                details = ctx.ModelState
                    .Where(kvp => kvp.Value?.Errors.Count > 0)
                    .ToDictionary(
                        kvp => kvp.Key,
                        kvp => kvp.Value!.Errors.Select(e => e.ErrorMessage).ToArray())
            });
    });

builder.Services.AddHealthChecks();

builder.Services.AddCors(o => o.AddDefaultPolicy(p => p.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod()));

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    using var scope = app.Services.CreateScope();
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    db.Database.EnsureCreated();
}

app.UseCors();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
app.MapHealthChecks("/health");

app.Run();
