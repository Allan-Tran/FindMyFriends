namespace MeshMessenger.Options;

public class ApnsOptions
{
    public string KeyId { get; set; } = "";
    public string TeamId { get; set; } = "";
    public string BundleId { get; set; } = "";
    public string PrivateKeyPath { get; set; } = "";
    public bool UseSandbox { get; set; } = true;

    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(KeyId) &&
        !string.IsNullOrWhiteSpace(TeamId) &&
        !string.IsNullOrWhiteSpace(BundleId) &&
        !string.IsNullOrWhiteSpace(PrivateKeyPath) &&
        File.Exists(PrivateKeyPath);
}
