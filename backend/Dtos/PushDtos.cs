using System.ComponentModel.DataAnnotations;

namespace MeshMessenger.Dtos;

public record RegisterDeviceDto(
    [Required] string DeviceToken);

public record UnregisterDeviceDto(
    [Required] string DeviceToken);
