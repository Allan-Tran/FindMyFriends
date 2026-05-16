import Foundation
@preconcurrency import FirebaseFirestore

struct DMRelayService: Sendable {
    let db: Firestore
    static let messageTTL: TimeInterval = 7 * 24 * 60 * 60

    init(db: Firestore = .firestore()) { self.db = db }

    // Creates the DM document if it doesn't exist. Calling when the doc already exists
    // results in a permission-denied error (UPDATE rule is false), which we let the
    // caller swallow — the doc is already there and the relay listener can proceed.
    func ensureDMDocument(
        dmId: String,
        senderUid: String, senderUsername: String,
        recipientUid: String, recipientUsername: String
    ) async throws {
        try await db.collection("dms").document(dmId).setData([
            "senderUid": senderUid,
            "senderUsername": senderUsername,
            "recipientUid": recipientUid,
            "recipientUsername": recipientUsername,
            "createdAt": Timestamp(date: Date())
        ])
    }

    func post(envelope: MeshMessage, dmId: String, senderUid: String) async throws {
        let data = try MeshCodec.encoder.encode(envelope)
        let now = Date()
        try await db.collection("dms").document(dmId)
            .collection("relay").document(envelope.id.uuidString)
            .setData([
                "envelopePayload": data.base64EncodedString(),
                "senderUid": senderUid,
                "storedAt": Timestamp(date: now),
                "expiresAt": Timestamp(date: now.addingTimeInterval(Self.messageTTL))
            ])
    }

    func observeMessages(
        dmId: String,
        since: Date?,
        onMessage: @escaping (FirestoreRelayMessage) -> Void
    ) -> ListenerRegistration {
        var query: Query = db.collection("dms").document(dmId)
            .collection("relay").order(by: "storedAt", descending: false)
        if let since { query = query.whereField("storedAt", isGreaterThan: Timestamp(date: since)) }
        return query.addSnapshotListener { snap, _ in
            guard let snap else { return }
            for change in snap.documentChanges where change.type == .added {
                if let msg = try? change.document.data(as: FirestoreRelayMessage.self) {
                    onMessage(msg)
                }
            }
        }
    }

    func fetchOnce(dmId: String, since: Date?) async throws -> [FirestoreRelayMessage] {
        var query: Query = db.collection("dms").document(dmId)
            .collection("relay").order(by: "storedAt", descending: false)
        if let since { query = query.whereField("storedAt", isGreaterThan: Timestamp(date: since)) }
        let snap = try await query.getDocuments()
        return snap.documents.compactMap { try? $0.data(as: FirestoreRelayMessage.self) }
    }

    // Returns participant usernames for an existing DM — used on background push wake.
    func participantUsernames(dmId: String) async throws -> (sender: String, recipient: String)? {
        let snap = try await db.collection("dms").document(dmId).getDocument()
        guard let d = snap.data(),
              let su = d["senderUsername"] as? String,
              let ru = d["recipientUsername"] as? String else { return nil }
        return (su, ru)
    }

    func senderUid(dmId: String) async throws -> String? {
        let snap = try await db.collection("dms").document(dmId).getDocument()
        return snap.data()?["senderUid"] as? String
    }
}
