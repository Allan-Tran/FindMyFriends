using System.ComponentModel.DataAnnotations;

namespace MeshMessenger.Dtos;

public record PostRelayMessageDto(
    [Required] Guid GroupId,
    [Required] string EnvelopePayload);

public record RelayMessageDto(
    Guid Id,
    Guid GroupId,
    Guid SenderUserId,
    string EnvelopePayload,
    DateTimeOffset StoredAt);
