using System.ComponentModel.DataAnnotations;

namespace MeshMessenger.Dtos;

public record UserSummaryDto(Guid Id, string Username);

public record ContactsLookupDto([Required] List<string> PhoneHashes);

public record ContactMatchDto(string PhoneHash, Guid UserId, string Username);
