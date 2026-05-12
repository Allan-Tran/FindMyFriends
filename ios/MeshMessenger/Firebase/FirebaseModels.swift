import Foundation
import FirebaseFirestore

struct FirestoreUser: Codable, Sendable {
    @DocumentID var id: String?
    var email: String
    var username: String
    var usernameLower: String
    var createdAt: Timestamp
    var fcmToken: String?
    var emailVerified: Bool
}

struct UsernameReservation: Codable, Sendable {
    @DocumentID var id: String?
    var uid: String
}

struct InviteCodeRecord: Codable, Sendable {
    @DocumentID var id: String?
    var groupId: String
}

enum FirestoreRole: String, Codable, Sendable {
    case admin
    case member
}

struct FirestoreGroup: Codable, Sendable, Identifiable {
    @DocumentID var id: String?
    var name: String
    var adminId: String
    var inviteCode: String
    var createdAt: Timestamp
    var memberIds: [String]
}

struct FirestoreMembership: Codable, Sendable {
    @DocumentID var id: String?
    var role: FirestoreRole
    var joinedAt: Timestamp
    var username: String
}

struct FirestoreRelayMessage: Codable, Sendable {
    @DocumentID var id: String?
    var envelopePayload: String
    var senderUid: String
    var storedAt: Timestamp
    var expiresAt: Timestamp
}
