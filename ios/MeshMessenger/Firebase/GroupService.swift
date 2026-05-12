import Foundation
import FirebaseFirestore

enum GroupServiceError: LocalizedError {
    case inviteCodeNotFound
    case alreadyMember
    case notAdmin
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .inviteCodeNotFound: return "Invite code not found."
        case .alreadyMember: return "You're already in this group."
        case .notAdmin: return "Only the group admin can do that."
        case .underlying(let e): return e.localizedDescription
        }
    }
}

struct GroupService: Sendable {
    let db: Firestore

    init(db: Firestore = .firestore()) { self.db = db }

    func myGroups(uid: String) async throws -> [FirestoreGroup] {
        let snap = try await db.collection("groups")
            .whereField("memberIds", arrayContains: uid)
            .order(by: "createdAt", descending: true)
            .getDocuments()
        return snap.documents.compactMap { try? $0.data(as: FirestoreGroup.self) }
    }

    func observeMyGroups(uid: String, onChange: @escaping ([FirestoreGroup]) -> Void) -> ListenerRegistration {
        db.collection("groups")
            .whereField("memberIds", arrayContains: uid)
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snap, _ in
                guard let snap = snap else { onChange([]); return }
                let groups = snap.documents.compactMap { try? $0.data(as: FirestoreGroup.self) }
                onChange(groups)
            }
    }

    func members(groupId: String) async throws -> [FirestoreMembership] {
        let snap = try await db.collection("groups").document(groupId)
            .collection("members").getDocuments()
        return snap.documents.compactMap { try? $0.data(as: FirestoreMembership.self) }
    }

    func create(name: String, adminUid: String, adminUsername: String) async throws -> FirestoreGroup {
        let groupId = UUID().uuidString
        let groupRef = db.collection("groups").document(groupId)
        let code = Self.generateInviteCode()
        let now = Timestamp(date: Date())

        let batch = db.batch()
        batch.setData([
            "name": name,
            "adminId": adminUid,
            "inviteCode": code,
            "createdAt": now,
            "memberIds": [adminUid]
        ], forDocument: groupRef)
        batch.setData([
            "role": FirestoreRole.admin.rawValue,
            "joinedAt": now,
            "username": adminUsername
        ], forDocument: groupRef.collection("members").document(adminUid))
        batch.setData(["groupId": groupId], forDocument: db.collection("inviteCodes").document(code))

        do { try await batch.commit() }
        catch { throw GroupServiceError.underlying(error) }

        return FirestoreGroup(
            id: groupId,
            name: name,
            adminId: adminUid,
            inviteCode: code,
            createdAt: now,
            memberIds: [adminUid]
        )
    }

    func join(inviteCode: String, uid: String, username: String) async throws -> FirestoreGroup {
        let codeKey = inviteCode.uppercased()
        let codeSnap: DocumentSnapshot
        do { codeSnap = try await db.collection("inviteCodes").document(codeKey).getDocument() }
        catch { throw GroupServiceError.underlying(error) }
        guard codeSnap.exists, let groupId = codeSnap.data()?["groupId"] as? String else {
            throw GroupServiceError.inviteCodeNotFound
        }

        let groupRef = db.collection("groups").document(groupId)
        let memberRef = groupRef.collection("members").document(uid)

        let memberSnap = try? await memberRef.getDocument()
        if memberSnap?.exists == true { throw GroupServiceError.alreadyMember }

        let batch = db.batch()
        batch.setData([
            "role": FirestoreRole.member.rawValue,
            "joinedAt": Timestamp(date: Date()),
            "username": username
        ], forDocument: memberRef)
        batch.updateData(["memberIds": FieldValue.arrayUnion([uid])], forDocument: groupRef)

        do { try await batch.commit() }
        catch { throw GroupServiceError.underlying(error) }

        let groupSnap = try await groupRef.getDocument()
        guard let group = try? groupSnap.data(as: FirestoreGroup.self) else {
            throw GroupServiceError.underlying(NSError(domain: "GroupService", code: -1))
        }
        return group
    }

    func leave(groupId: String, uid: String) async throws {
        let groupRef = db.collection("groups").document(groupId)
        let batch = db.batch()
        batch.deleteDocument(groupRef.collection("members").document(uid))
        batch.updateData(["memberIds": FieldValue.arrayRemove([uid])], forDocument: groupRef)
        try await batch.commit()
    }

    func delete(groupId: String) async throws {
        let groupRef = db.collection("groups").document(groupId)
        let snap = try await groupRef.getDocument()
        guard let group = try? snap.data(as: FirestoreGroup.self) else { return }

        let members = try await groupRef.collection("members").getDocuments()
        let batch = db.batch()
        for m in members.documents { batch.deleteDocument(m.reference) }
        batch.deleteDocument(db.collection("inviteCodes").document(group.inviteCode))
        batch.deleteDocument(groupRef)
        try await batch.commit()
    }

    static func generateInviteCode(length: Int = 8) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var chars: [Character] = []
        chars.reserveCapacity(length)
        for _ in 0..<length {
            chars.append(alphabet.randomElement()!)
        }
        return String(chars)
    }
}
