import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class GroupStore: ObservableObject {
    @Published private(set) var groups: [LocalGroup] = []
    @Published var lastError: String?

    private let groupService: GroupService
    private let repository: GroupRepository
    private let session: AuthSession
    weak var router: MessageRouter?

    private var listener: ListenerRegistration?

    init(session: AuthSession, groupService: GroupService = GroupService(), repository: GroupRepository) {
        self.session = session
        self.groupService = groupService
        self.repository = repository
    }

    func loadLocal() {
        do { groups = try repository.all() }
        catch { lastError = "\(error)" }
    }

    /// Stream groups for the signed-in user from Firestore and mirror them to the local DB.
    func startObserving() {
        guard let uid = session.currentUid else { return }
        stopObserving()
        listener = groupService.observeMyGroups(uid: uid) { [weak self] dtos in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.persist(dtos)
                self.loadLocal()
                self.broadcastSyncAll()
            }
        }
    }

    func stopObserving() {
        listener?.remove()
        listener = nil
    }

    func create(name: String) async -> LocalGroup? {
        guard let uid = session.currentUid, let username = session.currentUsername else {
            lastError = "Not signed in"
            return nil
        }
        do {
            let dto = try await groupService.create(name: name, adminUid: uid, adminUsername: username)
            await persist([dto])
            loadLocal()
            let group = groups.first { $0.id.uuidString == dto.id }
            if let group { broadcastSync(for: group) }
            return group
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }

    func join(inviteCode: String) async -> LocalGroup? {
        guard let uid = session.currentUid, let username = session.currentUsername else {
            lastError = "Not signed in"
            return nil
        }
        do {
            let dto = try await groupService.join(inviteCode: inviteCode, uid: uid, username: username)
            await persist([dto])
            loadLocal()
            let group = groups.first { $0.id.uuidString == dto.id }
            if let group { broadcastSync(for: group) }
            return group
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }

    func leave(groupId: UUID) async {
        guard let uid = session.currentUid else { return }
        do {
            try await groupService.leave(groupId: groupId.uuidString, uid: uid)
            try repository.remove(groupId)
            loadLocal()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func deleteGroup(_ groupId: UUID) async {
        do {
            try await groupService.delete(groupId: groupId.uuidString)
            try repository.remove(groupId)
            loadLocal()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func broadcastSyncAll() {
        for group in groups { broadcastSync(for: group) }
    }

    private func broadcastSync(for group: LocalGroup) {
        router?.broadcastGroupSync(groupId: group.id, memberUsernames: group.memberUsernames)
    }

    private func persist(_ dtos: [FirestoreGroup]) async {
        for dto in dtos {
            guard let docId = dto.id, let groupId = UUID(uuidString: docId) else { continue }
            let members = (try? await groupService.members(groupId: docId)) ?? []
            let usernames = members.map(\.username)
            let local = LocalGroup(
                id: groupId,
                name: dto.name,
                adminId: dto.adminId,
                inviteCode: dto.inviteCode,
                createdAt: dto.createdAt.dateValue(),
                memberUsernames: usernames
            )
            try? repository.upsert(local)
        }
    }
}
