import Foundation

struct PushAPI {
    let client: APIClient

    func register(deviceToken: String) async throws {
        try await client.postNoContent("push/register", body: RegisterDeviceRequest(deviceToken: deviceToken))
    }

    func unregister(deviceToken: String) async throws {
        try await client.deleteWithBody("push/register", body: UnregisterDeviceRequest(deviceToken: deviceToken))
    }
}

struct UsersAPI {
    let client: APIClient

    func search(prefix: String) async throws -> [UserSummary] {
        try await client.get("users/search", query: [URLQueryItem(name: "q", value: prefix)])
    }

    func resolveContacts(phoneHashes: [String]) async throws -> [ContactMatch] {
        try await client.post("users/contacts", body: ContactsLookupRequest(phoneHashes: phoneHashes))
    }
}
