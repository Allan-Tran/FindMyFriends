import Foundation
import SwiftData
import Combine

@MainActor
final class GroupStore: ObservableObject {
    @Published private(set) var groups: [LocalGroup] = []
    @Published var lastError: String?

    private let groupsAPI: GroupsAPI
    private let repository: GroupRepository

    init(client: APIClient, repository: GroupRepository) {
        self.groupsAPI = GroupsAPI(client: client)
        self.repository = repository
    }

    func loadLocal() {
        do { groups = try repository.all() }
        catch { lastError = "\(error)" }
    }

    func refresh(_ knownIds: [UUID]) async {
        for id in knownIds {
            do {
                let dto = try await groupsAPI.get(id: id)
                try save(dto)
            } catch {
                continue
            }
        }
        loadLocal()
    }

    func create(name: String) async -> LocalGroup? {
        do {
            let dto = try await groupsAPI.create(name: name)
            try save(dto)
            loadLocal()
            return groups.first { $0.id == dto.id }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }

    func join(groupId: UUID, inviteCode: String) async -> LocalGroup? {
        do {
            let dto = try await groupsAPI.join(id: groupId, inviteCode: inviteCode)
            try save(dto)
            loadLocal()
            return groups.first { $0.id == dto.id }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }

    func leave(groupId: UUID, userId: UUID) async {
        do {
            try await groupsAPI.removeMember(groupId: groupId, userId: userId)
            try repository.remove(groupId)
            loadLocal()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func save(_ dto: GroupResponse) throws {
        let local = LocalGroup(
            id: dto.id,
            name: dto.name,
            adminId: dto.adminId,
            inviteCode: dto.inviteCode,
            createdAt: dto.createdAt,
            memberUsernames: dto.members.map(\.username)
        )
        try repository.upsert(local)
    }
}
