import Foundation

struct RequestOtpRequest: Encodable { let phoneNumber: String }
struct VerifyOtpRequest: Encodable {
    let phoneNumber: String
    let otp: String
    let username: String?
}
struct RefreshRequest: Encodable { let refreshToken: String }
struct LogoutRequest: Encodable { let refreshToken: String }

struct AuthResponse: Decodable, Sendable {
    let accessToken: String
    let accessTokenExpiresAt: Date
    let refreshToken: String
    let refreshTokenExpiresAt: Date
    let userId: UUID
    let username: String
}

struct UserSummary: Decodable, Identifiable, Sendable {
    let id: UUID
    let username: String
}

struct ContactsLookupRequest: Encodable { let phoneHashes: [String] }
struct ContactMatch: Decodable, Sendable {
    let phoneHash: String
    let userId: UUID
    let username: String
}

enum MembershipRole: Int, Codable, Sendable {
    case member = 0
    case admin = 1
}

struct CreateGroupRequest: Encodable { let name: String }
struct JoinGroupRequest: Encodable { let inviteCode: String }
struct UpdateMemberRoleRequest: Encodable { let role: MembershipRole }

struct GroupMember: Decodable, Sendable {
    let userId: UUID
    let username: String
    let role: MembershipRole
    let joinedAt: Date
}

struct GroupResponse: Decodable, Sendable {
    let id: UUID
    let name: String
    let adminId: UUID
    let inviteCode: String
    let createdAt: Date
    let members: [GroupMember]
}

struct PostRelayMessageRequest: Encodable {
    let groupId: UUID
    let envelopePayload: String
}

struct RelayMessageResponse: Decodable, Sendable {
    let id: UUID
    let groupId: UUID
    let senderUserId: UUID
    let envelopePayload: String
    let storedAt: Date
}

struct RegisterDeviceRequest: Encodable { let deviceToken: String }
struct UnregisterDeviceRequest: Encodable { let deviceToken: String }
