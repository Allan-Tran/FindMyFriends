import Foundation

struct RelayAPI {
    let client: APIClient

    func post(groupId: UUID, envelope: MeshMessage) async throws -> RelayMessageResponse {
        let data = try MeshCodec.encoder.encode(envelope)
        let payload = data.base64EncodedString()
        return try await client.post(
            "relay/messages",
            body: PostRelayMessageRequest(groupId: groupId, envelopePayload: payload)
        )
    }

    func fetch(groupId: UUID, since: Date?) async throws -> [RelayMessageResponse] {
        var items: [URLQueryItem] = [URLQueryItem(name: "groupId", value: groupId.uuidString)]
        if let since = since {
            let iso = ISO8601DateFormatter().string(from: since)
            items.append(URLQueryItem(name: "since", value: iso))
        }
        return try await client.get("relay/messages", query: items)
    }

    func delete(messageId: UUID) async throws {
        try await client.delete("relay/messages/\(messageId.uuidString)")
    }
}
