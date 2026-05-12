import Foundation
import FirebaseFirestore

struct UserService: Sendable {
    let db: Firestore

    init(db: Firestore = .firestore()) { self.db = db }

    func get(uid: String) async throws -> FirestoreUser? {
        let snap = try await db.collection("users").document(uid).getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: FirestoreUser.self)
    }

    func setFcmToken(uid: String, token: String?) async throws {
        if let token = token {
            try await db.collection("users").document(uid).updateData(["fcmToken": token])
        } else {
            try await db.collection("users").document(uid).updateData([
                "fcmToken": FieldValue.delete()
            ])
        }
    }

    func searchByUsernamePrefix(_ prefix: String, limit: Int = 20) async throws -> [FirestoreUser] {
        let lower = prefix.lowercased()
        let upper = lower + "\u{F8FF}"
        let snap = try await db.collection("users")
            .whereField("usernameLower", isGreaterThanOrEqualTo: lower)
            .whereField("usernameLower", isLessThanOrEqualTo: upper)
            .limit(to: limit)
            .getDocuments()
        return snap.documents.compactMap { try? $0.data(as: FirestoreUser.self) }
    }
}
