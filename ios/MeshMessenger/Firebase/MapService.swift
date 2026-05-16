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
        _ = try await ref.putDataAsync(data, metadata: meta)
        let url = try await ref.downloadURL()
        try await db.collection("groups").document(groupId)
            .updateData(["mapImageUrl": url.absoluteString])
        return url.absoluteString
    }

    func observeMapUrl(groupId: String, onChange: @escaping (String?) -> Void) -> ListenerRegistration {
        db.collection("groups").document(groupId)
            .addSnapshotListener { snap, _ in
                onChange(snap?.data()?["mapImageUrl"] as? String)
            }
    }

    func observePins(groupId: String, onChange: @escaping ([FirestorePin]) -> Void) -> ListenerRegistration {
        db.collection("groups").document(groupId)
            .collection("pins")
            .order(by: "createdAt", descending: false)
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
