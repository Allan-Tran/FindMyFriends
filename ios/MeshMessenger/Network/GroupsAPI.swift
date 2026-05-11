import Foundation

struct GroupsAPI {
    let client: APIClient

    func create(name: String) async throws -> GroupResponse {
        try await client.post("groups", body: CreateGroupRequest(name: name))
    }

    func get(id: UUID) async throws -> GroupResponse {
        try await client.get("groups/\(id.uuidString)")
    }

    func join(id: UUID, inviteCode: String) async throws -> GroupResponse {
        try await client.post("groups/\(id.uuidString)/join", body: JoinGroupRequest(inviteCode: inviteCode))
    }

    func removeMember(groupId: UUID, userId: UUID) async throws {
        try await client.delete("groups/\(groupId.uuidString)/members/\(userId.uuidString)")
    }

    func updateMemberRole(groupId: UUID, userId: UUID, role: MembershipRole) async throws -> GroupResponse {
        try await client.put("groups/\(groupId.uuidString)/members/\(userId.uuidString)", body: UpdateMemberRoleRequest(role: role))
    }

    func delete(id: UUID) async throws {
        try await client.delete("groups/\(id.uuidString)")
    }
}
