import Foundation
@preconcurrency import FirebaseFirestore

struct RelayService: Sendable {
    let db: Firestore
    static let messageTTL: TimeInterval = 24 * 60 * 60

    init(db: Firestore = .firestore()) { self.db = db }

    func post(envelope: MeshMessage, groupId: String, senderUid: String) async throws {
        let data = try MeshCodec.encoder.encode(envelope)
        let base64 = data.base64EncodedString()

        let now = Date()
        let expires = now.addingTimeInterval(Self.messageTTL)

        try await db.collection("groups").document(groupId)
            .collection("relay").document(envelope.id.uuidString)
            .setData([
                "envelopePayload": base64,
                "senderUid": senderUid,
                "storedAt": Timestamp(date: now),
                "expiresAt": Timestamp(date: expires)
            ])
    }

    /// Subscribe to new messages in a group's relay subcollection.
    /// `since` is exclusive; pass nil on first call to grab the last 24h.
    func observeMessages(
        groupId: String,
        since: Date?,
        onMessage: @escaping (FirestoreRelayMessage) -> Void
    ) -> ListenerRegistration {
        var query: Query = db.collection("groups").document(groupId)
            .collection("relay")
            .order(by: "storedAt", descending: false)
        if let since = since {
            query = query.whereField("storedAt", isGreaterThan: Timestamp(date: since))
        }
        return query.addSnapshotListener { snap, _ in
            guard let snap = snap else { return }
            for change in snap.documentChanges where change.type == .added {
                if let msg = try? change.document.data(as: FirestoreRelayMessage.self) {
                    onMessage(msg)
                }
            }
        }
    }

    func fetchOnce(groupId: String, since: Date?) async throws -> [FirestoreRelayMessage] {
        var query: Query = db.collection("groups").document(groupId)
            .collection("relay")
            .order(by: "storedAt", descending: false)
        if let since = since {
            query = query.whereField("storedAt", isGreaterThan: Timestamp(date: since))
        }
        let snap = try await query.getDocuments()
        return snap.documents.compactMap { try? $0.data(as: FirestoreRelayMessage.self) }
    }

    func delete(groupId: String, messageId: String) async throws {
        try await db.collection("groups").document(groupId)
            .collection("relay").document(messageId).delete()
    }
}
