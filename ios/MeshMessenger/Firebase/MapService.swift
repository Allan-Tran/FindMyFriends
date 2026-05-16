import Foundation
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseStorage

struct MapService: Sendable {
    let db: Firestore
    let storage: Storage

    init(db: Firestore = .firestore(), storage: Storage = .storage()) {
        self.db = db
        self.storage = storage
    }

    func uploadMapImage(_ data: Data, groupId: String) async throws -> String {
        let ref = storage.reference().child("maps/\(groupId)/map.jpg")
        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"
        try await putData(data, to: ref, metadata: meta)
        let url = try await ref.downloadURLWithRetry()
        try await db.collection("groups").document(groupId)
            .updateData(["mapImageUrl": url.absoluteString])
        return url.absoluteString
    }

    func uploadChatImage(_ data: Data, groupId: String, imageId: String) async throws -> String {
        let ref = storage.reference().child("chat/\(groupId)/\(imageId).jpg")
        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"
        try await putData(data, to: ref, metadata: meta)
        return try await ref.downloadURLWithRetry().absoluteString
    }

    func uploadDMImage(_ data: Data, dmId: String, imageId: String) async throws -> String {
        let ref = storage.reference().child("dms/\(dmId)/\(imageId).jpg")
        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"
        try await putData(data, to: ref, metadata: meta)
        return try await ref.downloadURLWithRetry().absoluteString
    }

    private func putData(_ data: Data, to ref: StorageReference, metadata: StorageMetadata) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ref.putData(data, metadata: metadata) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func observeMapUrl(groupId: String, onChange: @escaping (String?) -> Void) -> ListenerRegistration {
        db.collection("groups").document(groupId)
            .addSnapshotListener { snap, _ in
                onChange(snap?.data()?["mapImageUrl"] as? String)
            }
    }

    func observePins(groupId: String, onChange: @escaping ([FirestorePin]) -> Void) -> ListenerRegistration {
        let cutoff = Timestamp(date: Date().addingTimeInterval(-86_400))  // last 24 h
        return db.collection("groups").document(groupId)
            .collection("pins")
            .whereField("createdAt", isGreaterThan: cutoff)
            .order(by: "createdAt", descending: false)
            .limit(to: 200)
            .addSnapshotListener { snap, _ in
                guard let snap else { onChange([]); return }
                let pins = snap.documents.compactMap { try? $0.data(as: FirestorePin.self) }
                onChange(pins)
            }
    }

    func addPin(groupId: String, x: Double, y: Double, username: String, uid: String, colorHex: String) async throws {
        let data: [String: Any] = [
            "x": x, "y": y,
            "username": username,
            "uid": uid,
            "colorHex": colorHex,
            "createdAt": Timestamp(date: Date())
        ]
        try await db.collection("groups").document(groupId)
            .collection("pins").document().setData(data)
    }

    func deletePin(groupId: String, pinId: String) async throws {
        try await db.collection("groups").document(groupId)
            .collection("pins").document(pinId).delete()
    }
}
